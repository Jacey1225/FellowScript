import logging

from fastapi import WebSocket
from schemas.message import Message
from db import DBManager
from backend.interactions.push import send_push

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
        self.save_message(Message(**payload))

        from_user_id = payload.get("from_user", "")
        text         = payload.get("text", "")

        frame = {
            "from_user": from_user_id,
            "text":      text,
            "group_id":  payload.get("group_id"),
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

        for uid in to_users:
            ws = self.active_connections.get(uid)
            if ws:
                # Recipient is online — deliver via WebSocket
                await ws.send_json(frame)
            elif uid != from_user_id:
                # Recipient is offline — send APNs push notification
                try:
                    self.cur.execute(
                        "SELECT token FROM device_tokens WHERE user_id = %s", (uid,)
                    )
                    token_row = self.cur.fetchone()
                    if token_row:
                        body = text if len(text) <= 100 else text[:97] + "…"
                        await send_push(token_row[0], sender_name, body)
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
                await ws.send_json(payload)

    async def broadcast(self, message: dict) -> None:
        """Send a message to every currently connected user.

        Args:
            message: Arbitrary JSON-serialisable payload to broadcast.
        """
        for ws in self.active_connections.values():
            await ws.send_json(message)
