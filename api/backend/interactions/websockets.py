import asyncio
import json
import logging
import threading
import time

import psycopg2
from fastapi import WebSocket
from schemas.message import Message, ATTACHMENT_KINDS
from db import DBManager
from backend.errors import SaveFailedError
from backend.interactions.attachments import generate_download_url
from backend.interactions.push import send_push
from backend.moderation.content_filter import check_clean, ContentRejected, rejection_message

logger = logging.getLogger(__name__)

# Push-notification fallback body for an attachment-only message (empty
# `text`) -- otherwise the push would show a blank body. Purely cosmetic;
# has no bearing on what's actually persisted/rendered in-thread.
_ATTACHMENT_PUSH_LABELS = {
    "image": "📷 Photo",
    "video": "🎥 Video",
    "file":  "📎 File",
    "gif":   "GIF",
}


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
        # Guards _execute/_reconnect below (task 20260910-ws-stale-cursor-crash).
        # This app runs a single uvicorn worker with no thread pool for these
        # synchronous DB calls (see main.py's uvicorn invocation), so two
        # coroutines can't literally execute a query at the same instant --
        # but nothing in this class enforces that as an invariant, and a lock
        # around "check/repair the shared cursor, then use it" costs nothing
        # here. Kept explicit rather than relying on today's deployment shape
        # (Implementation Philosophy Q28: design with concurrency in mind).
        self._db_lock = threading.Lock()

    def _reconnect(self) -> None:
        """Tear down this singleton's (stale/closed) connection and open a
        fresh one with the exact same parameters DBManager.__init__ used.

        Only ConnectionManager needs this: every other DBManager subclass in
        this codebase is instantiated fresh per request and just gets thrown
        away, so it never lives long enough to go stale. This one is a
        module-level singleton (`manager = ConnectionManager()`,
        routes/messaging.py) that has to survive for the life of the server
        process -- see this class's docstring/`__init__` comment.
        """
        try:
            self.cur.close()
        except Exception:
            pass
        try:
            self.conn.close()
        except Exception:
            pass
        super().__init__(self.db_name)
        self.conn.autocommit = True
        logger.warning("ConnectionManager reconnected to Postgres after a stale/closed connection.")

    def _execute(self, query: str, params: tuple = ()) -> None:
        """Run a query on the shared cursor, transparently reconnecting once
        if the long-lived connection has gone stale/closed underneath it.

        Root cause (task 20260910-ws-stale-cursor-crash, evidence-backed, not
        a blind patch): production logs showed `psycopg2.InterfaceError:
        cursor already closed` recurring from this class's unguarded
        `self.cur.execute` calls. DB-side causes were checked and ruled out
        -- `SHOW idle_session_timeout` is 0 (disabled) on the production
        server, and Postgres's own `pg_postmaster_start_time()` predates the
        crash window by weeks (no DB restart). But `pg_stat_activity` showed
        this singleton's connection was already gone from Postgres's own
        view by the time the error surfaced -- a genuinely dead TCP session,
        not just client-side confusion. With no DB-side connection pooler/
        proxy in front of Postgres (host networking straight to `localhost`,
        per docker-compose.yml) and no keepalives previously configured on
        this connection, the most evidence-consistent explanation is an
        idle, keepalive-less TCP connection silently dropped at the OS/
        network level sometime over this singleton's many-hours-long
        lifetime, with neither side finding out until the next query. DBManager's
        `sql.connect(...)` now sets TCP keepalives (db.py) to make that far
        less likely going forward; this retry is the safety net for whenever
        it (or any other stale-connection cause) still happens -- a single
        reconnect-and-retry actually repairs the connection rather than just
        catching and logging the symptom, and a second failure (a genuinely
        unreachable database) still propagates instead of being masked.
        """
        with self._db_lock:
            try:
                self.cur.execute(query, params)
            except (psycopg2.InterfaceError, psycopg2.OperationalError) as e:
                logger.warning(
                    "ConnectionManager cursor stale/closed (%s: %s) -- reconnecting and retrying once.",
                    type(e).__name__, e,
                )
                self._reconnect()
                self.cur.execute(query, params)

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
                there's no HTTP response to raise into here. Also raised
                (task 20260910-ws-stale-cursor-crash) if the INSERT itself
                still fails after ``_execute``'s one reconnect-and-retry --
                that means the database is genuinely unreachable, not just
                this singleton's cursor being stale, so it's surfaced the
                same way rather than crashing the WebSocket connection.
        """
        try:
            self._execute(
                "INSERT INTO messages "
                "(from_user, group_id, text, timestamp, attachment_kind, attachment_key, attachment_meta) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING _id",
                (
                    msg.from_user, msg.group_id or None, msg.text, str(msg.timestamp),
                    msg.attachment_kind, msg.attachment_key, json.dumps(msg.attachment_meta or {}),
                )
            )
        except (psycopg2.InterfaceError, psycopg2.OperationalError) as e:
            try:
                self.conn.rollback()
            except Exception:
                pass
            logger.error("save_message INSERT failed after reconnect retry: %s", e)
            raise SaveFailedError() from e
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

        # Attachment support (task 20260904-messaging-attachments). Fail
        # closed (Security Posture Q14): a message that claims an
        # attachment_kind but doesn't carry the reference that kind actually
        # needs, or names a kind outside the recognized enum, is dropped
        # entirely rather than persisted with an ambiguous/broken reference
        # -- mirrors the existing early-return-on-empty-to_users pattern
        # above. A message with no attachment_kind at all (the ordinary
        # text-only case) is completely unaffected by any of this.
        attachment_kind = payload.get("attachment_kind")
        attachment_key  = payload.get("attachment_key")
        attachment_meta = payload.get("attachment_meta") or {}
        if attachment_kind is not None:
            if attachment_kind not in ATTACHMENT_KINDS:
                logger.warning(
                    "Dropping message from %s: unrecognized attachment_kind=%r",
                    from_user_id, attachment_kind,
                )
                return
            if attachment_kind == "gif":
                # GIFs never populate attachment_key (no upload of our own) --
                # the provider's url must be present in attachment_meta instead.
                if not attachment_meta.get("url"):
                    logger.warning("Dropping message from %s: gif attachment missing url", from_user_id)
                    return
            elif not attachment_key:
                logger.warning(
                    "Dropping message from %s: %s attachment missing object key",
                    from_user_id, attachment_kind,
                )
                return

        # Guideline 1.2 content filter — this is the one message-creation path
        # with no HTTP request/response cycle, so a rejection can't be a normal
        # HTTPException; reply only to the sender's own socket instead. A
        # user-supplied filename riding along a "file" attachment is passed
        # through too -- it's just as much a free-text side channel as `text`
        # itself (Security Posture Q7: don't trust a single boundary).
        attachment_filename = attachment_meta.get("filename") if attachment_kind == "file" else None
        try:
            check_clean(text=text, attachment_filename=attachment_filename)
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
        #
        # This was the exact query production logs caught crashing with
        # `psycopg2.InterfaceError: cursor already closed` (task
        # 20260910-ws-stale-cursor-crash) -- it had no try/except at all, so
        # the exception propagated straight into websocket_endpoint's loop
        # and killed the sender's connection before any error frame could
        # ever be sent, which is why build 42's client-side error-frame
        # handling never had a chance to fire. `_execute` now transparently
        # reconnects and retries once; if it still fails, fail CLOSED
        # (Security Posture Q14) rather than silently falling through as if
        # no block existed -- tell the sender explicitly instead, the same
        # way ContentRejected/SaveFailedError already do just above/below.
        try:
            self._execute(
                "SELECT blocked_id FROM blocked_users WHERE blocker_id = %s "
                "UNION SELECT blocker_id FROM blocked_users WHERE blocked_id = %s",
                (from_user_id, from_user_id),
            )
        except (psycopg2.InterfaceError, psycopg2.OperationalError) as e:
            logger.error("Blocked-relationship check failed after reconnect retry: %s", e)
            sender_ws = self.active_connections.get(from_user_id)
            if sender_ws:
                await sender_ws.send_json({
                    "type": "error",
                    "reason": "send_failed",
                    "detail": "Couldn't send your message. Please try again.",
                })
            return
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
            "attachment_kind": attachment_kind,
            "attachment_meta": attachment_meta,
            # Freshly presigned at delivery time, never the stored key
            # itself (see attachments.py's module docstring) -- None for a
            # text-only message or a gif (whose url already lives in
            # attachment_meta above).
            "attachment_url": generate_download_url(attachment_key) if attachment_key else None,
        }

        # Resolve sender username once for the notification title. Already
        # had a generic catch-and-fall-back before this task -- that stays,
        # it just wasn't addressing *why* the cursor was stale. Routed
        # through `_execute` now so the common stale-cursor case is actually
        # repaired (reconnect + retry) rather than only ever degrading to
        # the "FellowScript" fallback every time it recurred.
        sender_name = "FellowScript"
        try:
            self._execute("SELECT username FROM users WHERE _id = %s", (from_user_id,))
            row = self.cur.fetchone()
            if row:
                sender_name = row[0]
        except Exception as e:
            logger.warning("Could not resolve sender username: %s", e)

        # Batch-fetch device tokens for the whole recipient set once, rather
        # than one query per offline recipient inside the loop below — the
        # per-recipient delivery/eviction logic itself still has to stay
        # per-recipient, only the token lookup is batched. Same treatment as
        # the sender-username lookup above -- routed through `_execute` so a
        # stale cursor gets repaired instead of just degrading every time.
        device_tokens: dict[str, str] = {}
        try:
            self._execute(
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
                        if text:
                            body = text if len(text) <= 100 else text[:97] + "…"
                        else:
                            # Attachment-only message (empty text) — fall back
                            # to a per-kind label so the push isn't blank.
                            body = _ATTACHMENT_PUSH_LABELS.get(attachment_kind, "")
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
