"""Announcements as group-chat timeline lines (task 20261030-chat-announcements;
flag ``chat_announcements``, ships OFF).

One announcement record, one optional timeline line. The line is a
server-generated ``messages`` row (``system_kind = 'announcement'``,
``announcement_id`` -> the announcement, constant text, author = the poster),
persisted directly like the pin line, never through the websocket send path.
All content (title, banner, polls, RSVP, style) stays in ``group_announcements``
and is read through ``AnnouncementsManager``; there is no second content store.

Rules:
- Opt-in per post: the author sends ``post_to_chat: true`` on create (422 while
  the flag is off for them, fail closed). Same membership check, free-plan
  limit and content filter as any announcement; nobody gains new rights.
- Emitted once, when the announcement is published and the poster is still a
  live member: right after create for an immediate post, by the scheduler tick
  for a scheduled one. A unique index on ``messages.announcement_id`` makes
  emission idempotent. Reminders and repeats never emit. Nothing is back-filled:
  only rows created with ``post_to_chat`` qualify, and the scheduler only looks
  back ``DUE_WINDOW_SECONDS``.
- Visibility is derived at read time, never copied: history hides the line when
  the flag is off for the viewer, when the announcement is soft-deleted (restore
  within the grace window brings it back) or not yet published, and the usual
  author_set rule hides lines from blocked / departed authors. So delete,
  restore and edit need no row rewrites and cannot drift.
- Pushes: none from the line. The existing announcement push is the only one.
- Live frames: the line frame (a normal message frame plus ``announcement_id``
  and a viewer-neutral ``announcement`` card) and ``announcement_updated``
  (``action`` = updated / deleted / restored, ids only), both only to current
  members who have the flag on. Best effort: a failed send never fails the
  write. Clients re-GET the announcement for viewer-specific fields.
- Logs carry ids and error types only.
"""
from __future__ import annotations

import asyncio
import functools
import logging
import uuid

from backend import content_store
from backend.interactions import flags, paging
from backend.interactions.attachments import generate_download_url
from db import DBManager

logger = logging.getLogger(__name__)

FLAG = "chat_announcements"
SYSTEM_KIND = "announcement"
SYSTEM_TEXT = "posted an announcement"
POLL_INTERVAL_SECONDS = 60
MAX_ROWS_PER_TICK = 20
# A scheduled post whose publish time is older than this is never turned into a
# line (long outage, flag turned on later): no back-fill.
DUE_WINDOW_SECONDS = 3600
# edited marker: updated_at this much later than created_at counts as an edit.
EDITED_AFTER_SECONDS = 5

_NOT_DELETED_PUBLISHED = (
    "EXISTS (SELECT 1 FROM group_announcements ga WHERE ga._id = messages.announcement_id "
    "AND ga.deleted_at IS NULL AND ga.publish_at <= now())"
)


def _canon(value) -> str | None:
    try:
        return str(uuid.UUID(str(value))).lower()
    except (ValueError, AttributeError, TypeError):
        return None


# -- create-time gate / marker --------------------------------------------------

def checked_post_flag(user_id: str, requested) -> bool:
    """Normalise the create field. ``True`` needs the flag on for the poster,
    otherwise ValueError (the route answers 422). ``None`` / ``False`` -> False."""
    if not requested:
        return False
    if not flags.is_enabled(FLAG, user_id):
        raise ValueError("post_to_chat is not available")
    return True


def mark_in_txn(cur, announcement_id: str) -> None:
    """Flag the row for the timeline inside the create transaction."""
    cur.execute("UPDATE group_announcements SET post_to_chat = TRUE WHERE _id = %s::uuid", (announcement_id,))


# -- read side (hooked into groups.py) -----------------------------------------

def history_filter_sql(viewer_id: str) -> str:
    """SQL suffix for every group history reader. Constant text only."""
    if not flags.is_enabled(FLAG, viewer_id):
        return f" AND system_kind IS DISTINCT FROM '{SYSTEM_KIND}' "
    return f" AND (announcement_id IS NULL OR {_NOT_DELETED_PUBLISHED}) "


def attach_announcements(db, messages: list[dict], viewer_id: str) -> None:
    """Add ``announcement`` (the viewer's serialized announcement plus
    ``edited``) and ``announcement_id`` to each announcement line, in place,
    with a fixed number of queries. No-op while the flag is off for the viewer.
    A line whose announcement can't be loaded is dropped from ``messages``
    (never rendered as a placeholder)."""
    if not messages or not flags.is_enabled(FLAG, viewer_id):
        return
    lines = [m for m in messages if m.get("system_kind") == SYSTEM_KIND and _canon(m.get("id"))]
    if not lines:
        return
    try:
        db.cur.execute(
            "SELECT _id::text, announcement_id::text FROM messages "
            "WHERE _id = ANY(%s::uuid[]) AND group_id = %s::uuid AND announcement_id IS NOT NULL",
            ([_canon(m["id"]) for m in lines], db.group_id),
        )
        link = {r[0]: r[1] for r in db.cur.fetchall()}
    finally:
        db.conn.rollback()
    from backend.interactions.announcements import _COLUMNS, _FROM, AnnouncementsManager  # lazy: imports groups
    mgr = AnnouncementsManager(viewer_id, db.group_id)
    try:
        ids = list(dict.fromkeys(link.values()))
        by_id: dict[str, dict] = {}
        if ids:
            mgr.cur.execute(
                f"SELECT {_COLUMNS} {_FROM} WHERE a.group_id = %s AND a._id = ANY(%s::uuid[]) "
                "AND a.deleted_at IS NULL AND a.publish_at <= now()",
                (db.group_id, ids),
            )
            rows = mgr.cur.fetchall()
            mgr.conn.rollback()
            for d in mgr._serialize_many(rows, mgr._group_creator_id()):
                d["edited"] = _is_edited(d)
                by_id[d["id"]] = d
    finally:
        mgr.close()
    for m in lines:
        aid = link.get(_canon(m["id"]))
        card = by_id.get(aid) if aid else None
        if card is None:
            messages.remove(m)
            continue
        m["announcement_id"] = aid
        m["announcement"] = card


def _is_edited(card: dict) -> bool:
    from datetime import datetime
    try:
        created = datetime.fromisoformat(card["created_at"])
        updated = datetime.fromisoformat(card["updated_at"])
    except (KeyError, ValueError, TypeError):
        return False
    return (updated - created).total_seconds() > EDITED_AFTER_SECONDS


# -- write side ------------------------------------------------------------------

def _neutral_card(row: tuple) -> dict:
    """Viewer-neutral card for the live frame (core fields only; flag-gated
    extras and viewer fields come from a re-GET)."""
    aid, title, description, banner_key, creator, username, title_color, publish_at, created_at, updated_at = row
    card = {
        "id": str(aid), "title": title, "description": description,
        "banner_url": generate_download_url(banner_key), "creator_id": str(creator) if creator else None,
        "creator_username": username, "title_color": title_color,
        "publish_at": publish_at.isoformat(), "created_at": created_at.isoformat(),
        "updated_at": updated_at.isoformat(),
    }
    card["edited"] = _is_edited(card)
    return card


def emit_line(db: DBManager, announcement_id: str) -> dict | None:
    """Insert the timeline line if it is due. Returns the frame plus
    ``recipients``, or None when nothing was written (already emitted, not due,
    deleted, poster no longer a member, flag off for the poster). Raises on a
    database error (rolled back); the scheduler retries inside the window."""
    aid = _canon(announcement_id)
    if aid is None:
        return None
    try:
        db.cur.execute(
            "SELECT a.creator_id::text, a.group_id::text FROM group_announcements a "
            "JOIN groups g ON g._id = a.group_id "
            "WHERE a._id = %s::uuid AND a.post_to_chat AND a.deleted_at IS NULL AND a.publish_at <= now() "
            "AND a.creator_id::text = ANY(g.users)",
            (aid,),
        )
        head = db.cur.fetchone()
        if not head or not flags.is_enabled(FLAG, head[0]):
            db.conn.rollback()
            return None
        creator, gid = head
        new_id = str(uuid.uuid4())
        db.cur.execute(
            "INSERT INTO messages (_id, from_user, group_id, text, system_kind, announcement_id) "
            "VALUES (%s::uuid, %s::uuid, %s::uuid, %s, %s, %s::uuid) "
            "ON CONFLICT (announcement_id) WHERE announcement_id IS NOT NULL DO NOTHING RETURNING timestamp",
            (new_id, creator, gid, content_store.seal(new_id, content_store.F_MESSAGE_TEXT, SYSTEM_TEXT),
             SYSTEM_KIND, aid),
        )
        written = db.cur.fetchone()
        if not written:
            db.conn.rollback()
            return None
        db.conn.commit()
        from backend.interactions.groups import author_set  # lazy: groups imports this module
        recipients = author_set(db.cur, gid, creator)
        db.cur.execute(
            "SELECT a._id, a.title, a.description, a.banner_key, a.creator_id, u.username, a.title_color, "
            "a.publish_at, a.created_at, a.updated_at FROM group_announcements a "
            "LEFT JOIN users u ON u._id = a.creator_id WHERE a._id = %s::uuid",
            (aid,),
        )
        card_row = db.cur.fetchone()
        db.conn.rollback()
    except Exception:
        db.conn.rollback()
        raise
    if not card_row:
        return None
    frame = {
        "id": new_id, "from_user": creator, "text": SYSTEM_TEXT, "group_id": gid,
        "timestamp": paging.format_timestamp(written[0]), "attachment_kind": None,
        "attachment_meta": {}, "attachment_url": None, "system_kind": SYSTEM_KIND,
        "announcement_id": aid, "announcement": _neutral_card(card_row),
    }
    return {"frame": frame, "recipients": recipients}


def _flag_recipients(recipients: list[str]) -> list[str]:
    return [u for u in recipients if flags.is_enabled(FLAG, u)]


async def _fan_out(recipients: list[str], frame: dict) -> None:
    from backend.interactions.message_delete import fan_out  # lazy: heavy import chain
    from routes.messaging import manager as ws_manager
    await fan_out(ws_manager, _flag_recipients(recipients), frame)


def _emit_sync(announcement_id: str) -> dict | None:
    db = DBManager()
    try:
        return emit_line(db, announcement_id)
    finally:
        db.close()


async def emit_and_broadcast(announcement_id: str) -> None:
    """Background task after an immediate post. Never raises; a miss is picked
    up by the scheduler tick inside ``DUE_WINDOW_SECONDS``."""
    try:
        result = await asyncio.get_running_loop().run_in_executor(
            None, functools.partial(_emit_sync, announcement_id))
        if result:
            await _fan_out(result["recipients"], result["frame"])
    except Exception as e:  # noqa: BLE001
        logger.error("CHAT_ANNOUNCEMENT emit failed announcement=%s reason=%s", announcement_id, type(e).__name__)


def _due_ids() -> list[str]:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT a._id::text FROM group_announcements a "
            "WHERE a.post_to_chat AND a.deleted_at IS NULL AND a.publish_at <= now() "
            "AND a.publish_at > now() - make_interval(secs => %s) "
            "AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.announcement_id = a._id) "
            "ORDER BY a.publish_at LIMIT %s",
            (DUE_WINDOW_SECONDS, MAX_ROWS_PER_TICK),
        )
        rows = [r[0] for r in db.cur.fetchall()]
        db.conn.rollback()
        return rows
    finally:
        db.close()


async def fire_due_chat_announcements() -> None:
    """Scheduler job: turn each due scheduled post into its timeline line once."""
    loop = asyncio.get_running_loop()
    try:
        ids = await loop.run_in_executor(None, _due_ids)
        for aid in ids:
            await emit_and_broadcast(aid)
    except Exception as e:  # noqa: BLE001
        logger.error("CHAT_ANNOUNCEMENT scheduler error reason=%s", type(e).__name__)


async def broadcast_sync(group_id: str, announcement_id: str, action: str) -> None:
    """Tell members to refresh one announcement line (``updated`` / ``deleted``
    / ``restored``). Sent only when the announcement has a line. Ids only.
    Never raises."""
    try:
        def _recipients() -> list[str] | None:
            db = DBManager()
            try:
                db.cur.execute(
                    "SELECT m.from_user::text FROM messages m WHERE m.announcement_id = %s::uuid AND m.group_id = %s::uuid",
                    (announcement_id, group_id),
                )
                row = db.cur.fetchone()
                db.conn.rollback()
                if not row:
                    return None
                from backend.interactions.groups import author_set
                out = author_set(db.cur, group_id, row[0])
                db.conn.rollback()
                return out
            finally:
                db.close()

        recipients = await asyncio.get_running_loop().run_in_executor(None, _recipients)
        if recipients:
            await _fan_out(recipients, {"type": "announcement_updated", "group_id": group_id,
                                        "announcement_id": announcement_id, "action": action})
    except Exception as e:  # noqa: BLE001
        logger.warning("CHAT_ANNOUNCEMENT sync frame failed reason=%s", type(e).__name__)
