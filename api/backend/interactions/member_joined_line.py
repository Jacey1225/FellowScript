"""In-chat "member joined" system line (task 20261016-push-notifications-and-ui, G2).

When a user becomes a member of a group (invite redeem, join-request approval,
direct member-list edit) one row is persisted in ``messages`` with
``system_kind = 'member_joined'``, ``from_user`` = the new member and a constant
text (``joined the group``). It reuses the pin system-line mechanism
(``messages.system_kind``), so no DDL is needed.

Safety properties:
- Persisted directly, never through the websocket send path: no chat push, no
  live frame, no ``message_recipients`` rows (group history is read by
  ``group_id``), so it cannot notify anyone or arrive on a shipped client by
  surprise.
- Hidden by default. Group history readers only return these rows when the
  caller opts in with ``include_system=1``; clients that do not send it (the
  shipped iOS build, the web app) never see the row, and the contact-list
  "last message / unread" load (which does not opt in) is unaffected.
- Idempotent per join: skipped when the user already has a live line in this
  group within ``DEDUPE_WINDOW`` (a retried approval or a double add), when the
  user is not currently a member, or when the user does not exist. A leave and
  later re-join (outside the window) writes a new line.
- Never raises: a failure is logged (type only) and the join is unaffected.
"""
from __future__ import annotations

import logging
import uuid

from backend import content_store
from db import DBManager

logger = logging.getLogger(__name__)

SYSTEM_KIND = "member_joined"
SYSTEM_TEXT = "joined the group"
DEDUPE_WINDOW_SECONDS = 600
MAX_LINES_PER_CALL = 50


def _canon(value) -> str | None:
    try:
        return str(uuid.UUID(str(value))).lower()
    except (ValueError, AttributeError, TypeError):
        return None


def record_member_joined(group_id: str, new_member_ids: list[str]) -> int:
    """Write one line per genuinely new member. Returns the number written.
    Blocking (run in an executor from async code). Never raises."""
    gid = _canon(group_id)
    joined = list(dict.fromkeys(c for c in (_canon(u) for u in (new_member_ids or [])) if c))
    if gid is None or not joined:
        return 0
    written = 0
    db = None
    try:
        db = DBManager()
        db.cur.execute("SELECT COALESCE(users, '{}') FROM groups WHERE _id = %s", (gid,))
        row = db.cur.fetchone()
        db.conn.rollback()
        if not row:
            return 0
        members = {c for c in (_canon(u) for u in row[0]) if c}
        for uid in joined[:MAX_LINES_PER_CALL]:
            if uid not in members:
                continue
            try:
                db.cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (f"member_joined:{gid}:{uid}",))
                db.cur.execute(
                    "SELECT 1 FROM messages WHERE group_id = %s::uuid AND from_user = %s::uuid "
                    "AND system_kind = %s AND timestamp > NOW() - make_interval(secs => %s) LIMIT 1",
                    (gid, uid, SYSTEM_KIND, DEDUPE_WINDOW_SECONDS),
                )
                if db.cur.fetchone():
                    db.conn.rollback()
                    continue
                new_id = str(uuid.uuid4())
                db.cur.execute(
                    "INSERT INTO messages (_id, from_user, group_id, text, system_kind) "
                    "SELECT %s::uuid, u._id, %s::uuid, %s, %s FROM users u WHERE u._id = %s::uuid",
                    (new_id, gid, content_store.seal(new_id, content_store.F_MESSAGE_TEXT, SYSTEM_TEXT),
                     SYSTEM_KIND, uid),
                )
                written += db.cur.rowcount
                db.conn.commit()
            except Exception as e:  # noqa: BLE001 - isolate per user
                db.conn.rollback()
                logger.warning("MEMBER_JOINED_LINE failed reason=%s", type(e).__name__)
    except Exception as e:  # noqa: BLE001 - a history line must never break a join
        logger.warning("MEMBER_JOINED_LINE aborted reason=%s", type(e).__name__)
    finally:
        if db is not None:
            try:
                db.close()
            except Exception:  # noqa: BLE001
                pass
    return written
