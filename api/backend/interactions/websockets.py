import asyncio
import logging
import time

from fastapi import WebSocket
from schemas.message import Message
from db import DBManager
from backend.errors import SaveFailedError
from backend.interactions.push import send_push
from backend.moderation.content_filter import check_clean, ContentRejected, rejection_message

logger = logging.getLogger(__name__)


class ConnectionManager(DBManager):
    """Manages active WebSocket connections keyed by user ID."""

    # `active_connections` presence alone used to be treated as proof a
    # recipient was online. It isn't: a TCP-level `ws.send_json()` can
    # succeed into a backgrounded/suspended (or killed, or network-dropped)
    # client that will never surface the frame as a notification, so
    # send_msg's `ws truthy` check never fell through to the offline-push
    # branch for those recipients (task
    # 20260902-chat-push-notification-failure). HEARTBEAT_INTERVAL/TIMEOUT
    # drive a periodic background liveness probe (`run_heartbeat_check`,
    # started once via `start_heartbeat` from the app's lifespan) that
    # proactively evicts anything that hasn't proven it's alive recently —
    # feeding the *existing* evict-then-push fallback already in send_msg by
    # keeping `active_connections`/`last_seen` accurate, without touching
    # that fallback itself.
    #
    # "Proof of life" here is either (a) a probe `send_json` actually
    # raising -- the fastest, unambiguous signal, since a truly closed
    # connection (a clean client-side disconnect, or the OS tearing down a
    # killed process's sockets) surfaces as a write failure quickly -- or
    # (b) any inbound frame at all from that user's own connection (`touch`,
    # called from `websocket_endpoint`'s receive loop for every frame,
    # including a future explicit "pong" reply). HEARTBEAT_TIMEOUT is
    # deliberately generous (a few missed probe intervals, not one) so a
    # genuinely-foreground user who simply hasn't sent anything recently
    # isn't mistaken for stale and doesn't get an over-notifying duplicate
    # push -- see the acceptance criteria in this task's intake spec.
    HEARTBEAT_INTERVAL = 25.0
    HEARTBEAT_TIMEOUT   = 70.0

    def __init__(self) -> None:
        super().__init__()
        # This manager is a long-lived module-level singleton, so its Postgres
        # connection stays open for the app's lifetime. Run it in autocommit mode:
        # otherwise every SELECT (e.g. resolving a sender's username) leaves the
        # connection "idle in transaction", pinning a snapshot and holding locks
        # that can block DDL and stall vacuum until the next write.
        self.conn.autocommit = True
        self.active_connections: dict[str, WebSocket] = {}
        self.last_seen: dict[str, float] = {}
        self._heartbeat_task: "asyncio.Task | None" = None

    def save_message(self, msg: Message) -> None:
        """Persist the message and its recipient links.

        Raises:
            SaveFailedError: If a ``message_recipients`` link fails to
                write -- the message row itself was already committed by
                the first successful ``insertion`` call below (they share
                this manager's one connection), but a recipient who never
                got linked would silently never see it delivered/loaded,
                which is exactly the fake-success outcome this workflow
                exists to remove. ``send_msg`` (the only caller) catches
                this and tells the sender over their own socket, since
                there's no HTTP response to raise into here.
        """
        self.cur.execute(
            "INSERT INTO messages (from_user, group_id, text, timestamp) "
            "VALUES (%s, %s, %s, %s) RETURNING _id",
            (msg.from_user, msg.group_id or None, msg.text, str(msg.timestamp))
        )
        row = self.cur.fetchone()
        if row:
            message_id = str(row[0])
            for uid in msg.to_users:
                if not self.insertion("message_recipients", {"message_id": message_id, "user_id": uid}):
                    self.conn.commit()
                    raise SaveFailedError()
        self.conn.commit()

    async def connect(self, user_id: str, ws: WebSocket) -> None:
        """Accept a new WebSocket connection and register it.

        Args:
            user_id: UUID of the connecting user.
            ws: The accepted WebSocket instance.
        """
        await ws.accept()
        self.active_connections[user_id] = ws
        self.last_seen[user_id] = time.monotonic()

    async def disconnect(self, user_id: str) -> None:
        """Remove a user's WebSocket from the active registry on disconnect.

        Args:
            user_id: UUID of the disconnecting user.
        """
        self.active_connections.pop(user_id, None)
        self.last_seen.pop(user_id, None)

    def touch(self, user_id: str) -> None:
        """Record proof of life for ``user_id``'s connection.

        Called by ``websocket_endpoint`` for every frame it receives on that
        user's own socket (a real chat/signal send, or any future explicit
        "pong" reply) -- this is what lets `run_heartbeat_check` tell a
        quiet-but-live connection apart from a genuinely stale one.
        """
        if user_id in self.active_connections:
            self.last_seen[user_id] = time.monotonic()

    def start_heartbeat(self) -> None:
        """Start the periodic background liveness-probe loop.

        Idempotent -- safe to call more than once (e.g. if it's ever wired
        into more than one startup hook). Must be called from within a
        running event loop; the app's ``lifespan`` is the intended caller,
        not module import time, since this module-level singleton is
        constructed before any event loop exists.
        """
        if self._heartbeat_task is None or self._heartbeat_task.done():
            self._heartbeat_task = asyncio.create_task(self._heartbeat_loop())

    async def _heartbeat_loop(self) -> None:
        while True:
            await asyncio.sleep(self.HEARTBEAT_INTERVAL)
            await self.run_heartbeat_check()

    async def run_heartbeat_check(self) -> None:
        """One heartbeat tick: probe every registered connection and evict
        anything that hasn't proven liveness within HEARTBEAT_TIMEOUT.

        Split out from `_heartbeat_loop` (which just sleeps and calls this)
        so tests can drive a single tick deterministically instead of
        waiting on real timers.
        """
        now = time.monotonic()
        for uid in list(self.active_connections.keys()):
            ws = self.active_connections.get(uid)
            if ws is None:
                continue
            try:
                await ws.send_json({"type": "ping"})
            except Exception as e:
                logger.warning("Heartbeat ping to %s failed, evicting stale connection: %s", uid, e)
                self.active_connections.pop(uid, None)
                self.last_seen.pop(uid, None)
                continue
            if now - self.last_seen.get(uid, now) > self.HEARTBEAT_TIMEOUT:
                logger.warning(
                    "No liveness from %s in over %.0fs, evicting stale connection",
                    uid, self.HEARTBEAT_TIMEOUT,
                )
                self.active_connections.pop(uid, None)
                self.last_seen.pop(uid, None)

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

        try:
            self.save_message(Message(**payload))
        except SaveFailedError as e:
            # Mirror the ContentRejected handling just above: no HTTP
            # response exists on this path, so tell the sender's own
            # socket rather than raising into the WS connection loop
            # (which would otherwise crash this connection for an
            # unrelated later message too).
            sender_ws = self.active_connections.get(from_user_id)
            if sender_ws:
                await sender_ws.send_json({
                    "type": "error",
                    "reason": "message_not_saved",
                    "detail": e.message,
                })
            return

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
            if uid == from_user_id:
                # Group `to_users` includes the sender (see ChatThreadView.swift's
                # `contact.toUsers`), but the sender already has their own
                # optimistic local copy of this message — echoing it back over
                # their own live socket would duplicate it in their thread. Skip
                # entirely: no WS echo, and no push either (the existing
                # `uid != from_user_id` guard below already excludes self-push,
                # so this is a no-op there, just made explicit up front).
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
                # Recipient is offline (or was just evicted above, whether by
                # a live send failure or the heartbeat eviction in
                # run_heartbeat_check) — send APNs push notification.
                #
                # Flagged, not fixed, here (task
                # 20260902-chat-push-notification-failure, step 1): if
                # `token` is missing (recipient never registered a device
                # token) or `send_push` itself fails (env mismatch retry
                # exhausted, expired token, etc.), this is a silent no-op —
                # only logged, no retry/backoff and no surfaced signal to the
                # sender or any monitoring. That's a separate, likely
                # lower-priority gap from the stale-connection root cause
                # this step addresses; out of scope here, left for future
                # triage per the intake spec's open questions.
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
