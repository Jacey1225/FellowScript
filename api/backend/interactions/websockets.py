import logging

from fastapi import WebSocket
from schemas.message import Message
from db import DBManager
from backend.interactions.push import send_push
from backend.moderation.content_filter import check_clean, ContentRejected, rejection_message

logger = logging.getLogger(__name__)


class ConnectionManager(DBManager):
    """Manages active WebSocket connections keyed by user ID."""

    def __init__(self) -> None:
        super().__init__()
        # This manager is a long-lived module-level singleton, so its Postgres
        # connection stays open for the app's lifetime. Run it in autocommit mode:
        # otherwise every SELECT (e.g. resolving a sender's username) leaves the
        # connection "idle in transaction", pinning a snapshot and holding locks
        # that can block DDL and stall vacuum until the next write.
        self.conn.autocommit = True
        self.active_connections: dict[str, WebSocket] = {}

    def save_message(self, msg: Message) -> None:
        self.cur.execute(
            "INSERT INTO messages (from_user, group_id, text, timestamp) "
            "VALUES (%s, %s, %s, %s) RETURNING _id",
            (msg.from_user, msg.group_id or None, msg.text, str(msg.timestamp))
        )
        row = self.cur.fetchone()
        if row:
            message_id = str(row[0])
            for uid in msg.to_users:
                self.insertion("message_recipients", {"message_id": message_id, "user_id": uid})
        self.conn.commit()

    async def connect(self, user_id: str, ws: WebSocket) -> None:
        """Accept a new WebSocket connection and register it.

        Args:
            user_id: UUID of the connecting user.
            ws: The accepted WebSocket instance.
        """
        await ws.accept()
        self.active_connections[user_id] = ws

    async def disconnect(self, user_id: str) -> None:
        """Remove a user's WebSocket from the active registry on disconnect.

        Args:
            user_id: UUID of the disconnecting user.
        """
        self.active_connections.pop(user_id, None)

    async def send_msg(self, payload: dict) -> None:
        """Persist a chat message, deliver it to online recipients via WebSocket,
        and push-notify any offline recipients.

        Args:
            payload: Message dict with at minimum ``to_users``, ``from_user``,
                ``text``, ``group_id``, and ``timestamp``.
        """
        to_users = payload.get("to_users")
        if not to_users:
            return

        from_user_id = payload.get("from_user", "")
        text         = payload.get("text", "")
        group_id     = payload.get("group_id")

        # Guideline 1.2 content filter — this is the one message-creation path
        # with no HTTP request/response cycle, so a rejection can't be a normal
        # HTTPException; reply only to the sender's own socket instead.
        try:
            check_clean(text=text)
        except ContentRejected as e:
            sender_ws = self.active_connections.get(from_user_id)
            if sender_ws:
                await sender_ws.send_json({
                    "type": "error",
                    "reason": "message_rejected",
                    "detail": rejection_message(e),
                })
            return

        # Guideline 1.2 block enforcement. One query for the sender's full
        # bidirectional blocked-relationship set (either direction), reused
        # below for both the DM drop and the per-recipient group delivery
        # skip — avoids opening a BlockManager connection per recipient.
        self.cur.execute(
            "SELECT blocked_id FROM blocked_users WHERE blocker_id = %s "
            "UNION SELECT blocker_id FROM blocked_users WHERE blocked_id = %s",
            (from_user_id, from_user_id),
        )
        blocked_relationships = {str(r[0]) for r in self.cur.fetchall()}

        if not group_id and any(uid in blocked_relationships for uid in to_users):
            # DM with a blocked relationship — drop entirely, no save/delivery.
            return

        self.save_message(Message(**payload))

        frame = {
            "from_user": from_user_id,
            "text":      text,
            "group_id":  group_id,
            "timestamp": payload.get("timestamp"),
        }

        # Resolve sender username once for the notification title
        sender_name = "FellowScript"
        try:
            self.cur.execute("SELECT username FROM users WHERE _id = %s", (from_user_id,))
            row = self.cur.fetchone()
            if row:
                sender_name = row[0]
        except Exception as e:
            logger.warning("Could not resolve sender username: %s", e)

        # Batch-fetch device tokens for the whole recipient set once, rather
        # than one query per offline recipient inside the loop below — the
        # per-recipient delivery/eviction logic itself still has to stay
        # per-recipient, only the token lookup is batched.
        device_tokens: dict[str, str] = {}
        try:
            self.cur.execute(
                "SELECT user_id, token FROM device_tokens WHERE user_id = ANY(%s::uuid[])",
                (list(to_users),),
            )
            device_tokens = {str(r[0]): r[1] for r in self.cur.fetchall()}
        except Exception as e:
            logger.error("Batch device-token lookup failed: %s", e)

        for uid in to_users:
            if uid in blocked_relationships:
                # Group message: still persisted for other members, but skip
                # delivery to any recipient in a blocked relationship with the sender.
                continue
            ws = self.active_connections.get(uid)
            if ws:
                # Recipient is online — deliver via WebSocket. A send can fail
                # even though the socket is still registered (e.g. the peer
                # dropped the connection but no close frame has reached us
                # yet). Left unguarded, that exception would propagate out of
                # send_msg into the SENDER's websocket_endpoint loop — one
                # stale recipient socket would silently kill an unrelated,
                # perfectly healthy connection. Evict the stale entry and
                # fall through to the offline push path instead.
                try:
                    await ws.send_json(frame)
                except Exception as e:
                    logger.warning("Send to %s failed, evicting stale connection: %s", uid, e)
                    self.active_connections.pop(uid, None)
                    ws = None
            if not ws and uid != from_user_id:
                # Recipient is offline (or was just evicted above) — send APNs push notification
                try:
                    token = device_tokens.get(uid)
                    if token:
                        body = text if len(text) <= 100 else text[:97] + "…"
                        await send_push(token, sender_name, body)
                except Exception as e:
                    logger.error("Push to %s failed: %s", uid, e)

    async def send_sig(self, payload: dict) -> None:
        """Relay a WebRTC signaling frame without persisting it.

        Args:
            payload: Signaling dict with at minimum ``to_users``.
        """
        for uid in payload.get("to_users", []):
            ws = self.active_connections.get(uid)
            if ws:
                try:
                    await ws.send_json(payload)
                except Exception as e:
                    # Same rationale as send_msg: don't let a stale recipient
                    # socket raise into the sender's connection loop.
                    logger.warning("Signal send to %s failed, evicting stale connection: %s", uid, e)
                    self.active_connections.pop(uid, None)

    async def broadcast(self, message: dict) -> None:
        """Send a message to every currently connected user.

        Args:
            message: Arbitrary JSON-serialisable payload to broadcast.
        """
        for ws in self.active_connections.values():
            await ws.send_json(message)
