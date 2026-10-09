"""Personal fan-out of a session summary (task 20260908-session-summary-personal-fanout).

When a summarized session is NOT tied to a real group (no ``group_id`` or a
friend-DM ``"uidA|uidB"`` room key), the summary note is written to the
personal notes (``group_id`` NULL, ``public`` false) of every verified
participant instead of only the caller. Recipients are always derived
server-side (the friendship-verified DM roster, or the persisted devotions
row); the client-supplied ``session.participants`` list can only narrow, never
add. Everything fails closed to "caller only". Logs carry ids and counts only.
"""
from __future__ import annotations

import logging
import uuid
from datetime import datetime

from fastapi import HTTPException

from backend import content_store
from backend.interactions.devotion import DevotionManager
from backend.interactions.session_summary_fanout_config import get_session_summary_fanout_config
from backend.subscription.limits import check_limit, check_paid_only

logger = logging.getLogger(__name__)

_KEY_PREFIX = "sessionsum"


def valid_session_id(raw) -> str | None:
    """Canonical uuid string, or None if ``raw`` is not a valid id."""
    if not isinstance(raw, str):
        return None
    try:
        return str(uuid.UUID(raw))
    except ValueError:
        return None


def dedupe_key(session_id: str, user_id: str) -> str:
    return f"{_KEY_PREFIX}:{session_id}:{user_id}"


def _uuid_set(values) -> set[str]:
    out = set()
    for v in values or []:
        c = valid_session_id(v)
        if c:
            out.add(c)
    return out


def resolve_recipients(user_id: str, dm_key: str | None, session: dict) -> list[str]:
    """Ordered recipient ids: caller first, then the other verified
    participants sorted, truncated to ``max_recipients_per_session``.

    Raises HTTPException 403 when the session is persisted and the caller is
    not one of its participants (IDOR guard). Every other doubt resolves to
    ``[user_id]``.
    """
    cfg = get_session_summary_fanout_config()
    caller = valid_session_id(user_id) or user_id
    dm = DevotionManager()
    try:
        if dm_key:
            roster = dm.real_group_roster(dm_key)  # mutual, non-blocked friends only
            if caller not in roster:
                return [user_id]
            candidates = _uuid_set(roster)
        else:
            sid = valid_session_id(session.get("id"))
            if not sid:
                return [user_id]
            persisted = dm.get_session(sid)
            if not persisted:
                return [user_id]
            members = _uuid_set([persisted.get("creator_id")]) | _uuid_set(persisted.get("participants"))
            if caller not in members:
                logger.warning("summarize fan-out denied: caller %s not in session %s", user_id, sid)
                raise HTTPException(status_code=403, detail="Not a participant of this session")
            candidates = members
            client = _uuid_set(session.get("participants") if isinstance(session.get("participants"), list) else [])
            if client:
                candidates = candidates & (client | {caller})
        candidates.discard(caller)
        if not candidates:
            return [user_id]
        # Only existing, non-suspended users with no block between them and the caller.
        try:
            dm.cur.execute(
                "SELECT u._id FROM users u WHERE u._id = ANY(%s::uuid[]) AND u.suspended_at IS NULL "
                "AND NOT EXISTS (SELECT 1 FROM blocked_users b "
                "  WHERE (b.blocker_id = %s AND b.blocked_id = u._id) "
                "     OR (b.blocker_id = u._id AND b.blocked_id = %s))",
                (sorted(candidates), caller, caller),
            )
            verified = {str(r[0]) for r in dm.cur.fetchall()}
        except Exception:
            logger.exception("summarize fan-out recipient verification failed; caller only")
            dm.conn.rollback()
            return [user_id]
    finally:
        dm.close()
    others = sorted(verified)
    ordered = [user_id] + others
    cap = cfg.max_recipients_per_session
    if len(ordered) > cap:
        logger.info("summarize fan-out truncated recipients: %d dropped", len(ordered) - cap)
        ordered = ordered[:cap]
    return ordered


def existing_summary_notes(db, session_id: str, recipients: list[str]) -> dict[str, str]:
    """{user_id: note_id} for recipients that already hold this session's summary."""
    keys = {dedupe_key(session_id, r): r for r in recipients}
    db.cur.execute(
        "SELECT summary_dedupe_key, _id FROM notes WHERE summary_dedupe_key = ANY(%s)",
        (list(keys),),
    )
    return {keys[k]: str(i) for k, i in db.cur.fetchall() if k in keys}


def insert_deduped_note(db, session_id: str, owner_id: str, title: str, text: str,
                        public: bool, group_id) -> tuple[str, bool]:
    """Insert one note guarded by its dedupe key. Returns (note_id, created);
    on a conflict returns the existing note's id and created=False. Commits."""
    note_id = str(uuid.uuid4())
    key = dedupe_key(session_id, owner_id)
    db.cur.execute(
        "INSERT INTO notes (_id, user_id, title, text, public, group_id, is_reply, timestamp, summary_dedupe_key) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) "
        "ON CONFLICT (summary_dedupe_key) WHERE summary_dedupe_key IS NOT NULL DO NOTHING RETURNING _id",
        (note_id, owner_id,
         content_store.seal(note_id, content_store.F_NOTE_TITLE, title),
         content_store.seal(note_id, content_store.F_NOTE_TEXT, text),
         public, group_id, False, datetime.now(), key),
    )
    row = db.cur.fetchone()
    if row:
        db.conn.commit()
        return note_id, True
    db.conn.commit()
    db.cur.execute("SELECT _id FROM notes WHERE summary_dedupe_key = %s", (key,))
    existing = db.cur.fetchone()
    return (str(existing[0]) if existing else note_id), False


def fan_out_to_others(db, session_id: str, caller_id: str, recipients: list[str],
                      title: str, text: str) -> dict:
    """Write personal copies for every recipient except the caller. Ineligible
    recipients (free plan, notes cap, already hold a copy, DB error) are
    skipped silently and only counted -- never an error, never a charge to
    anyone else."""
    written = skipped = 0
    for rid in recipients:
        if rid == caller_id:
            continue
        try:
            if not check_paid_only(rid, "session_summaries")["allowed"]:
                skipped += 1
                continue
            if not check_limit(rid, "notes")["allowed"]:
                skipped += 1
                continue
            _, created = insert_deduped_note(db, session_id, rid, title, text, False, None)
            if created:
                written += 1
            else:
                skipped += 1
        except Exception:
            logger.exception("summarize fan-out write failed for recipient %s", rid)
            try:
                db.conn.rollback()
            except Exception:
                pass
            skipped += 1
    return {"written": written, "skipped": skipped}
