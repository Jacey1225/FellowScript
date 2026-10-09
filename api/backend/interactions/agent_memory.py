"""Per-chat memory for agent chats (flag ``agent_chat_memory``).

Two server-side-only pieces, both scoped by (user_id, agent_id, chat_id):

* ``AgentMemoryStore.build_context`` -- the last N turns of one chat plus the
  stored running summary (which covers only turns older than that window).
* ``refresh_summary`` -- runs OFF the request path on its own DB connection;
  folds the oldest unsummarized turns into the prior summary once more than
  ``summary_threshold`` of them sit past ``summary_through_ts`` and outside
  the window. The write is a compare-and-set on ``summary_through_ts`` so two
  concurrent refreshes of one chat can never overwrite each other, and an
  in-process guard stops a second refresh from even starting.

Failure policy: a summarizer error stores nothing (never a fabricated or
partial summary) and propagates to the caller, which logs the exception TYPE
only. Message and summary text is never logged anywhere in this module.
"""
from __future__ import annotations

import logging
import threading
from typing import Callable, Optional

import psycopg2

from backend import content_store
from backend.interactions.agent_memory_config import get_agent_memory_config

logger = logging.getLogger(__name__)

_ROLES = ("user", "assistant")

_inflight: set[str] = set()
_inflight_lock = threading.Lock()


def try_acquire(chat_id: str) -> bool:
    with _inflight_lock:
        if chat_id in _inflight:
            return False
        _inflight.add(chat_id)
        return True


def release(chat_id: str) -> None:
    with _inflight_lock:
        _inflight.discard(chat_id)


def _clip(text: Optional[str], limit: int) -> str:
    text = text or ""
    return text if len(text) <= limit else text[:limit]


class AgentMemoryStore:
    """Wraps an open ``AgentManager`` connection (needs ``cur``, ``conn``, ``user_id``)."""

    def __init__(self, db):
        self.db = db
        self.user_id = db.user_id

    def build_context(self, agent_id: str, chat_id: str) -> tuple[Optional[str], list[dict]]:
        """(summary or None, last-N turns oldest->newest) for exactly this chat.

        A DB error degrades to ``(None, [])`` (chat continues on the new
        message alone, as it does today) after a rollback; nothing is invented.
        """
        cfg = get_agent_memory_config()
        cur = self.db.cur
        try:
            cur.execute(
                "SELECT summary, summary_through_ts FROM agent_chats "
                "WHERE _id = %s AND user_id = %s AND agent_id = %s",
                (chat_id, self.user_id, agent_id),
            )
            row = cur.fetchone()
            summary, through = (
                (content_store.open_(chat_id, content_store.F_AGENT_CHAT_SUMMARY, row[0]), row[1]) if row else (None, None)
            )
            cur.execute(
                "SELECT title, content, timestamp, _id FROM agent_messages "
                "WHERE user_id = %s AND agent_id = %s AND chat_id = %s AND title = ANY(%s) "
                "ORDER BY timestamp DESC, _id DESC LIMIT %s",
                (self.user_id, agent_id, chat_id, list(_ROLES), cfg.window_messages),
            )
            rows = cur.fetchall()
        except psycopg2.Error as e:
            self.db.conn.rollback()
            logger.warning("agent memory read failed chat=%s error=%s", chat_id, type(e).__name__)
            return None, []
        rows.reverse()
        # Never repeat a turn the summary already covers.
        if through is not None:
            rows = [r for r in rows if r[2] > through]
        history = [
            {"role": r[0], "content": _clip(content_store.open_(r[3], content_store.F_AGENT_CONTENT, r[1]), cfg.message_max_chars)}
            for r in rows
        ]
        use_summary = bool(summary) and through is not None
        return (summary if use_summary else None), history


def refresh_summary(
    db,
    agent_id: str,
    chat_id: str,
    summarize: Callable[[Optional[str], list[dict]], str],
) -> bool:
    """Fold older turns into the stored summary if the threshold is exceeded.

    ``db`` is a connection owned by the calling worker thread (never the
    request's). Returns True only when the summary row was advanced. Raises
    whatever ``summarize`` raises (after a rollback); writes nothing then.
    """
    cfg = get_agent_memory_config()
    cur, user_id = db.cur, db.user_id
    cur.execute(
        "SELECT summary, summary_through_ts FROM agent_chats "
        "WHERE _id = %s AND user_id = %s AND agent_id = %s",
        (chat_id, user_id, agent_id),
    )
    row = cur.fetchone()
    if row is None:
        db.conn.rollback()
        return False
    prev_summary, through = content_store.open_(chat_id, content_store.F_AGENT_CHAT_SUMMARY, row[0]), row[1]
    cur.execute(
        "SELECT COUNT(*) FROM agent_messages "
        "WHERE user_id = %s AND agent_id = %s AND chat_id = %s AND title = ANY(%s) "
        "AND (%s::timestamptz IS NULL OR timestamp > %s::timestamptz)",
        (user_id, agent_id, chat_id, list(_ROLES), through, through),
    )
    pending = cur.fetchone()[0]
    # Turns that are both unsummarized and older than the live window.
    foldable = pending - cfg.window_messages
    if foldable <= cfg.summary_threshold:
        db.conn.rollback()
        return False
    take = min(foldable, cfg.summary_batch_max_messages)
    cur.execute(
        "SELECT title, content, timestamp, _id FROM agent_messages "
        "WHERE user_id = %s AND agent_id = %s AND chat_id = %s AND title = ANY(%s) "
        "AND (%s::timestamptz IS NULL OR timestamp > %s::timestamptz) "
        "ORDER BY timestamp ASC, _id ASC LIMIT %s",
        (user_id, agent_id, chat_id, list(_ROLES), through, through, take + 1),
    )
    rows = cur.fetchall()
    db.conn.rollback()
    if len(rows) <= take:
        return False
    boundary_ts = rows[take][2]
    batch = [r for r in rows[:take]]
    # A message sharing the boundary timestamp must stay out of the summary,
    # otherwise ``timestamp > summary_through_ts`` would drop it for good.
    while batch and batch[-1][2] == boundary_ts:
        batch.pop()
    if not batch:
        return False
    turns = [
        {"role": r[0], "content": _clip(content_store.open_(r[3], content_store.F_AGENT_CONTENT, r[1]), cfg.message_max_chars)}
        for r in batch
    ]
    new_summary = summarize(prev_summary, turns)
    if not isinstance(new_summary, str) or not new_summary.strip():
        raise ValueError("summarizer returned no summary")
    new_summary = _clip(new_summary.strip(), cfg.summary_max_chars)
    try:
        cur.execute(
            "UPDATE agent_chats SET summary = %s, summary_through_ts = %s "
            "WHERE _id = %s AND user_id = %s AND agent_id = %s "
            "AND summary_through_ts IS NOT DISTINCT FROM %s::timestamptz",
            (content_store.seal(chat_id, content_store.F_AGENT_CHAT_SUMMARY, new_summary),
             batch[-1][2], chat_id, user_id, agent_id, through),
        )
        advanced = cur.rowcount == 1
        db.conn.commit()
    except psycopg2.Error:
        db.conn.rollback()
        raise
    return advanced
