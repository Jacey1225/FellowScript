"""User-facing delete of a group chat message (flag ``message_delete``).

Semantics (contract: THR Q1-Q3, Q19):

- Author only, while still a current, non-suspended member of the message's
  group. Group messages only (DMs have ``group_id IS NULL`` and never match).
  Messages whose author account is gone (``from_user`` NULL) match nobody.
- Soft delete: ``deleted_at`` / ``deleted_by`` are set at once and every reader
  hides the row. The undo window (``undo_seconds``) governs RESTORE only; the
  text and the S3 object are NOT cleared at that point.
- Evidence retention: the sweeper purges text and attachment columns only after
  ``evidence_retention_days`` and only when no ``content_reports`` row for that
  id is still ``open``. ``reports._resolve_message`` deliberately has no
  ``deleted_at`` filter so a late report still captures the text.
- The S3 object is never deleted here or per key: its key goes into the SF
  ``pending_s3_deletes`` outbox, and only when it is under the author's own
  ``attachments/<author_id>/`` prefix and no other row references it.

Both write paths are ONE atomic UPDATE (author + group match + live membership
+ author not suspended + state), so a failure of any condition is simply "no
row" and the route answers a uniform 404 (no oracle for ids, membership or
state). No text is ever logged.

R-SCHED: ``run_message_purge_job`` is a thin ``async def``; all psycopg2 work
runs in ``purge_once`` through ``loop.run_in_executor``. The job never checks
the flag, so purges continue while ``message_delete`` is off. One aggregated
WARNING per run when anything failed, counts only; the bare word ERROR never
appears in non-error lines (watchdog rule).
"""
from __future__ import annotations

import asyncio
import logging
import uuid

from db import DBManager
from backend.interactions.attachments import generate_download_url
from backend.interactions.lifecycle import enqueue_s3_deletes
from backend.interactions.send_guard import validate_attachment_key
from backend.interactions.groups import live_member_ids
from backend.interactions.threads_config import get_message_delete_config

logger = logging.getLogger(__name__)

JOB_ID = "message_purge_sweep"
SWEEP_INTERVAL_SECONDS = 15 * 60

_UUID_RE = "'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'"

# Live membership of the message's group for the author, through the same
# CASE-guarded cast the shared LIVE_MEMBER_JOIN uses (a junk element never
# raises a uuid cast error). ``g`` and ``m`` are the outer aliases.
_AUTHOR_IS_MEMBER = (
    "EXISTS (SELECT 1 FROM unnest(g.users) AS x(member_id) "
    f"WHERE CASE WHEN x.member_id ~* {_UUID_RE} THEN x.member_id::uuid END = m.from_user)"
)

_DELETE_SQL = (
    "UPDATE messages m SET deleted_at = NOW(), deleted_by = m.from_user "
    "FROM groups g, users u "
    "WHERE m._id = %s::uuid AND m.group_id = %s::uuid AND g._id = m.group_id "
    "AND m.from_user = %s::uuid AND u._id = m.from_user AND u.suspended_at IS NULL "
    "AND m.deleted_at IS NULL AND " + _AUTHOR_IS_MEMBER + " "
    "RETURNING m._id::text, m.deleted_at"
)

_RESTORE_SQL = (
    "UPDATE messages m SET deleted_at = NULL, deleted_by = NULL "
    "FROM groups g, users u "
    "WHERE m._id = %s::uuid AND m.group_id = %s::uuid AND g._id = m.group_id "
    "AND m.from_user = %s::uuid AND u._id = m.from_user AND u.suspended_at IS NULL "
    "AND m.deleted_at IS NOT NULL AND m.deleted_by = m.from_user "
    "AND m.deleted_at > NOW() - make_interval(secs => %s) "
    "AND " + _AUTHOR_IS_MEMBER + " "
    "RETURNING m._id::text, u.username, m.text, m.timestamp, COALESCE(m.seq, 0), "
    "m.attachment_kind, m.attachment_key, m.attachment_meta"
)


def _canon(value) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def audit(action: str, user_id: str, group_id: str, message_id: str) -> None:
    """Ids only, never text (the audit rule)."""
    logger.info("MESSAGE_%s user=%s group=%s message=%s", action, user_id, group_id, message_id)


class MessageDeleteManager(DBManager):
    """Delete / restore one group message; returns None for every denial."""

    def __init__(self, user_id: str) -> None:
        super().__init__()
        self.user_id = user_id

    def delete(self, group_id: str, message_id: str) -> "dict | None":
        uid, gid, mid = _canon(self.user_id), _canon(group_id), _canon(message_id)
        if not (uid and gid and mid):
            return None
        try:
            self.cur.execute(_DELETE_SQL, (mid, gid, uid))
            row = self.cur.fetchone()
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise
        if not row:
            return None
        return {
            "id": row[0],
            "group_id": gid,
            "deleted_at": row[1],
            "undo_seconds": get_message_delete_config().undo_seconds,
        }

    def restore(self, group_id: str, message_id: str) -> "dict | None":
        uid, gid, mid = _canon(self.user_id), _canon(group_id), _canon(message_id)
        if not (uid and gid and mid):
            return None
        try:
            self.cur.execute(_RESTORE_SQL, (mid, gid, uid, get_message_delete_config().undo_seconds))
            row = self.cur.fetchone()
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise
        if not row:
            return None
        meta = row[7] if isinstance(row[7], dict) else {}
        return {
            "id": row[0], "group_id": gid, "sender": row[1], "body": row[2],
            "created_at": row[3], "seq": int(row[4]),
            "attachment_kind": row[5], "attachment_key": row[6], "attachment_meta": meta,
        }

    def frame_recipients(self, group_id: str, author_id: str, *, skip_blocked: bool) -> list[str]:
        """Live member ids to receive a frame. ``skip_blocked`` drops anyone in
        a block relationship with the author (either direction); needed for the
        restore frame because it carries content. Read-only."""
        try:
            members = live_member_ids(self.cur, group_id)
            if skip_blocked and members:
                self.cur.execute(
                    "SELECT blocked_id::text FROM blocked_users WHERE blocker_id = %s::uuid "
                    "UNION SELECT blocker_id::text FROM blocked_users WHERE blocked_id = %s::uuid",
                    (author_id, author_id),
                )
                blocked = {str(r[0]).lower() for r in self.cur.fetchall()}
                members = [m for m in members if m not in blocked or m == author_id]
            return members
        finally:
            self.conn.rollback()


def deleted_frame(group_id: str, message_id: str, deleted_at) -> dict:
    """Live frame. Has ``type`` and neither ``from_user`` nor ``text``, so build 78
    clients (which render any frame carrying those) ignore it."""
    return {"type": "message_deleted", "id": message_id, "group_id": group_id,
            "deleted_at": deleted_at.isoformat() if hasattr(deleted_at, "isoformat") else str(deleted_at)}


def restored_frame(restored: dict) -> dict:
    """Live frame carrying what a client needs to re-insert the row. Key names
    follow the thread_message frame (``sender``/``body``), never ``from_user``/``text``."""
    ts = restored["created_at"]
    key = restored["attachment_key"]
    return {
        "type": "message_restored",
        "id": restored["id"],
        "group_id": restored["group_id"],
        "sender": restored["sender"],
        "body": restored["body"],
        "created_at": ts.isoformat() if hasattr(ts, "isoformat") else str(ts),
        "seq": restored["seq"],
        "attachment_kind": restored["attachment_kind"],
        "attachment_meta": restored["attachment_meta"],
        "attachment_url": generate_download_url(key) if key else None,
    }


async def fan_out(manager, user_ids: list[str], frame: dict) -> None:
    """Send ``frame`` to every listed user with a live socket. Never raises: a
    failed send is logged by type and left to the heartbeat to evict."""
    for uid in user_ids:
        ws = manager.active_connections.get(uid)
        if not ws:
            continue
        try:
            await ws.send_json(frame)
        except Exception as e:  # noqa: BLE001
            logger.warning("Frame send to %s failed: %s", uid, type(e).__name__)


# --------------------------------------------------------------------------
# Retention sweeper
# --------------------------------------------------------------------------

_CANDIDATES_SQL = (
    "SELECT m._id::text FROM messages m "
    "WHERE m.deleted_at IS NOT NULL AND m.deleted_at < NOW() - make_interval(days => %s) "
    "AND (m.text <> '' OR m.attachment_key IS NOT NULL OR m.attachment_kind IS NOT NULL) "
    "AND NOT EXISTS (SELECT 1 FROM content_reports r WHERE r.content_id = m._id AND r.status = 'open') "
    "ORDER BY m.deleted_at LIMIT %s"
)

# Re-check under the row lock so a report filed or a restore between candidate
# selection and the purge wins.
_LOCK_SQL = (
    "SELECT m.from_user::text, m.attachment_kind, m.attachment_key FROM messages m "
    "WHERE m._id = %s::uuid AND m.deleted_at IS NOT NULL "
    "AND m.deleted_at < NOW() - make_interval(days => %s) "
    "AND NOT EXISTS (SELECT 1 FROM content_reports r WHERE r.content_id = m._id AND r.status = 'open') "
    "FOR UPDATE OF m"
)


def _key_is_unreferenced(cur, message_id: str, key: str) -> bool:
    cur.execute(
        "SELECT 1 FROM messages WHERE attachment_key = %s AND _id <> %s::uuid "
        "UNION ALL SELECT 1 FROM thread_messages WHERE attachment_key = %s LIMIT 1",
        (key, message_id, key),
    )
    return cur.fetchone() is None


def purge_once(batch_size: int | None = None) -> dict:
    """Purge one batch. Returns counts ``found``, ``purged``, ``queued``
    (keys sent to the outbox), ``key_kept`` (key not queued: foreign prefix,
    unknown author or still referenced) and ``failed``."""
    cfg = get_message_delete_config()
    if batch_size is None:
        batch_size = cfg.sweep_batch_size
    counts = {"found": 0, "purged": 0, "queued": 0, "key_kept": 0, "failed": 0}
    db = DBManager()
    try:
        db.cur.execute(_CANDIDATES_SQL, (cfg.evidence_retention_days, batch_size))
        ids = [r[0] for r in db.cur.fetchall()]
        db.conn.rollback()
        counts["found"] = len(ids)
        for mid in ids:
            try:
                db.cur.execute(_LOCK_SQL, (mid, cfg.evidence_retention_days))
                row = db.cur.fetchone()
                if not row:
                    db.conn.rollback()
                    continue
                author, kind, key = row
                if key:
                    if (author and validate_attachment_key(author, kind, key)
                            and _key_is_unreferenced(db.cur, mid, key)):
                        counts["queued"] += enqueue_s3_deletes(db.cur, [key])
                    else:
                        counts["key_kept"] += 1
                db.cur.execute(
                    "UPDATE messages SET text = '', attachment_kind = NULL, attachment_key = NULL, "
                    "attachment_meta = '{}'::jsonb WHERE _id = %s::uuid",
                    (mid,),
                )
                # A thread keeps a short copy of its root's text; drop it too.
                db.cur.execute(
                    "UPDATE threads SET root_preview = NULL WHERE root_message_id = %s::uuid", (mid,)
                )
                db.conn.commit()
                counts["purged"] += 1
            except Exception:  # noqa: BLE001 - one bad row must not stop the sweep
                db.conn.rollback()
                counts["failed"] += 1
    finally:
        db.close()
    if counts["failed"]:
        logger.warning(
            "MESSAGE_PURGE partial: found=%d purged=%d queued=%d key_kept=%d failed=%d",
            counts["found"], counts["purged"], counts["queued"], counts["key_kept"], counts["failed"],
        )
    elif counts["purged"]:
        logger.info("MESSAGE_PURGE purged=%d queued=%d key_kept=%d",
                    counts["purged"], counts["queued"], counts["key_kept"])
    return counts


async def run_message_purge_job() -> None:
    """Scheduler entry: thin async wrapper, all DB work off the event loop."""
    loop = asyncio.get_running_loop()
    try:
        await loop.run_in_executor(None, purge_once)
    except Exception as e:  # noqa: BLE001 - a failed run is retried next tick
        logger.warning("MESSAGE_PURGE run failed: %s", type(e).__name__)
