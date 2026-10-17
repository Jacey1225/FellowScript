"""Opt-in daily reminders: prayer, check in with someone, ask a deep question (task 20261016).

Each is its own ``push_preferences`` toggle, default OFF (a user with no row is
never sent one), with a user-chosen local time of day (``<type>_time``, read in
the user's ``users.timezone``). Content is fixed and generic: no friend is named
and nothing is AI-generated; the deep question comes from the built-in
``DEEP_QUESTIONS`` pool, rotating by local date.

Scheduling: ``fire_due_user_reminders`` polls every few minutes. A reminder is
due when the user's local clock is inside ``[time, time + DUE_WINDOW)`` (so a
user who enables a reminder at 9pm for an 8am slot waits for tomorrow instead
of getting a late push) and its ``<type>_sent_date`` is not already today's
local date. The marker is claimed with an atomic single-winner UPDATE BEFORE the
send, so restarts, overlapping runs and multiple workers send at most once per
local day per type; a failed send is logged, never retried (same posture as the
announcement pushes).

Fail CLOSED: the scan only selects rows whose toggle is explicitly TRUE, and any
DB error aborts the run without sending. Users with no device token or a
suspended account are skipped. Log lines carry counts only, never user ids.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from db import DBManager

logger = logging.getLogger(__name__)

# How long after the chosen time a reminder may still be sent (poll tolerance).
DUE_WINDOW = timedelta(minutes=60)
MAX_USERS_PER_RUN = 5000

# key, title, body (None = pick from DEEP_QUESTIONS), push action
REMINDER_TYPES: tuple[tuple[str, str, str | None, str], ...] = (
    ("prayer_reminder", "Time to pray", "Take a quiet moment to pray.", "reminder_prayer"),
    ("check_in_reminder", "Check in with someone", "Is there someone you could check in on today?",
     "reminder_check_in"),
    ("deep_question_reminder", "A question to ask", None, "reminder_deep_question"),
)

DEEP_QUESTIONS: tuple[str, ...] = (
    "What is one thing you are grateful for that you rarely say out loud?",
    "When did you last feel close to God, and what was happening?",
    "What is a hard season that taught you something you still carry?",
    "Who has shaped your faith the most, and how?",
    "What is something you are afraid to pray about?",
    "What does rest look like for you, and when did you last get it?",
    "Which verse have you leaned on most this year, and why?",
    "What is one thing you wish people asked you more often?",
    "Where have you seen God show up unexpectedly?",
    "What is something you have forgiven that was hard to let go of?",
    "What do you want your life to point toward?",
    "What is a question about faith you are still wrestling with?",
    "When do you feel most like yourself?",
    "What is one way someone has loved you well recently?",
    "What would you do differently if you trusted God more?",
    "What is a habit you would like to build, and what is in the way?",
    "Who in your life needs encouragement right now?",
    "What does being faithful look like in a small, ordinary day?",
    "What is something you are hopeful about?",
    "When was a time you were wrong and glad to find out?",
    "What is the kindest thing someone has done for you without being asked?",
    "What do you find hardest to give to God?",
    "Which part of your story are you most thankful for?",
    "What are you learning about patience right now?",
    "What is a prayer that has been answered in a way you did not expect?",
    "What would it look like to be a better listener this week?",
    "What does community mean to you, and where do you find it?",
    "What is one thing you would tell your younger self about faith?",
    "What brings you peace when everything feels loud?",
    "How can the people around you pray for you this week?",
)


def deep_question_for(local_date) -> str:
    return DEEP_QUESTIONS[local_date.toordinal() % len(DEEP_QUESTIONS)]


def _local_now(tzname: str | None, now_utc: datetime) -> datetime | None:
    try:
        return now_utc.astimezone(ZoneInfo(tzname or "UTC"))
    except Exception:  # noqa: BLE001 - invalid timezone: skip this user
        return None


def is_due(local: datetime, remind_time, sent_date) -> bool:
    """True inside ``[remind_time, remind_time + DUE_WINDOW)`` on a local day
    that has not been sent yet (the window never wraps past local midnight)."""
    if sent_date == local.date():
        return False
    start = local.replace(hour=remind_time.hour, minute=remind_time.minute, second=0, microsecond=0)
    return start <= local < min(start + DUE_WINDOW, start.replace(hour=0, minute=0) + timedelta(days=1))


def _scan(now_utc: datetime) -> list[tuple[str, str, str, str, str]]:
    """``[(user_id, token, title, body, action)]`` for every reminder due now
    whose marker this call atomically claimed. Raises on DB error (fail closed)."""
    db = DBManager()
    try:
        out: list[tuple[str, str, str, str, str]] = []
        for key, title, body, action in REMINDER_TYPES:
            db.cur.execute(
                f"SELECT p.user_id::text, u.timezone, dt.token, p.{key}_time, p.{key}_sent_date "  # constants only
                f"FROM push_preferences p JOIN users u ON u._id = p.user_id "
                f"JOIN device_tokens dt ON dt.user_id = p.user_id "
                f"WHERE p.{key} = TRUE AND u.suspended_at IS NULL LIMIT %s",
                (MAX_USERS_PER_RUN,),
            )
            rows = db.cur.fetchall()
            db.conn.rollback()
            for user_id, tzname, token, remind_time, sent_date in rows:
                if not token:
                    continue
                local = _local_now(tzname, now_utc)
                if local is None or not is_due(local, remind_time, sent_date):
                    continue
                db.cur.execute(
                    f"UPDATE push_preferences SET {key}_sent_date = %s "
                    f"WHERE user_id = %s AND {key} = TRUE AND {key}_sent_date IS DISTINCT FROM %s "
                    f"RETURNING 1",
                    (local.date(), user_id, local.date()),
                )
                claimed = db.cur.fetchone()
                db.conn.commit()
                if claimed:
                    out.append((user_id, token, title, body or deep_question_for(local.date()), action))
        return out
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


async def fire_due_user_reminders() -> None:
    """Scheduler job. Never raises."""
    from backend.interactions.push import send_push

    try:
        loop = asyncio.get_running_loop()
        due = await loop.run_in_executor(None, _scan, datetime.now(timezone.utc))
        sent = failed = 0
        for _user_id, token, title, body, action in due:
            try:
                if await send_push(token, title, body, data={"action": action}):
                    sent += 1
                else:
                    failed += 1
            except Exception:  # noqa: BLE001 - per-recipient isolation (incl. APNsConfigError)
                failed += 1
        if due:
            logger.info("USER_REMINDER_PUSH sent=%d failed=%d", sent, failed)
    except Exception as e:  # noqa: BLE001
        logger.warning("USER_REMINDER_PUSH aborted reason=%s", type(e).__name__)
