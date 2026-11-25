"""Per-user activity calendar (task 20261114-activity-calendar).

Read model only: chat and notes are DERIVED from existing tables (no new
write-path bookkeeping); the one new record is the Bible-reading day, which
stores the local day and nothing else (no book/chapter/verse).

Counted as activity, bucketed to the day in the user's own ``users.timezone``
(invalid or missing zone falls back to UTC; changing the zone re-buckets past
days):
  chat   agent_messages the user sent (title='user'); messages and
         thread_messages the user authored, not soft-deleted, and (messages)
         not server-generated system lines (system_kind). Received messages
         never count.
  note   notes the user authored, replies included. Edits do not count (notes
         have no edit timestamp). Excluded: session-summary fan-out copies
         (summary_dedupe_key) and agent-written heartbeat notes (theme set).
         Authoring time is LEAST(timestamp, created_at): created_at was
         backfilled to the migration time on legacy rows, so ``timestamp``
         wins there; on new rows both are the authoring time.
  bible  bible_reading_days. Starts empty at ship; cannot be backfilled.

This module never reads message or note text and logs no activity details.
It does not touch ActivityManager or activity_monitoring.
"""
import logging
from datetime import date
from zoneinfo import available_timezones

from db import DBManager
from constants import DEFAULT_TIMEZONE
from schemas.activity_calendar import MonthActivity

logger = logging.getLogger(__name__)

_FALLBACK_TZ = DEFAULT_TIMEZONE
MIN_YEAR, MAX_YEAR = 2000, 2100

# %(s)s / %(e)s are the first day of the month and of the next month; local
# midnight in the user's zone is computed by Postgres (DST-correct). UNION
# de-duplicates (day, kind) pairs.
_MONTH_SQL = """
WITH b AS (
  SELECT (%(s)s::date)::timestamp AT TIME ZONE %(tz)s AS s_ts,
         (%(e)s::date)::timestamp AT TIME ZONE %(tz)s AS e_ts
)
SELECT day, kind FROM (
  SELECT (a.timestamp AT TIME ZONE %(tz)s)::date AS day, 'chat' AS kind
    FROM agent_messages a, b
   WHERE a.user_id = %(u)s AND a.title = 'user'
     AND a.timestamp >= b.s_ts AND a.timestamp < b.e_ts
  UNION
  SELECT (m.timestamp AT TIME ZONE %(tz)s)::date, 'chat'
    FROM messages m, b
   WHERE m.from_user = %(u)s AND m.deleted_at IS NULL AND m.system_kind IS NULL
     AND m.timestamp >= b.s_ts AND m.timestamp < b.e_ts
  UNION
  SELECT (t.created_at AT TIME ZONE %(tz)s)::date, 'chat'
    FROM thread_messages t, b
   WHERE t.from_user = %(u)s AND t.deleted_at IS NULL
     AND t.created_at >= b.s_ts AND t.created_at < b.e_ts
  UNION
  SELECT (LEAST(n.timestamp, n.created_at) AT TIME ZONE %(tz)s)::date, 'note'
    FROM notes n, b
   WHERE n.user_id = %(u)s AND n.summary_dedupe_key IS NULL
     AND COALESCE(n.theme, '') = ''
     AND LEAST(n.timestamp, n.created_at) >= b.s_ts
     AND LEAST(n.timestamp, n.created_at) < b.e_ts
  UNION
  SELECT r.day, 'bible'
    FROM bible_reading_days r
   WHERE r.user_id = %(u)s AND r.day >= %(s)s::date AND r.day < %(e)s::date
) x
ORDER BY day, kind
"""


def _valid_tz(name) -> str:
    return name if isinstance(name, str) and name in available_timezones() else _FALLBACK_TZ


class ActivityCalendarManager(DBManager):
    """Scoped to one user; the id must come from the verified session."""

    def __init__(self, user_id: str) -> None:
        super().__init__()
        self.user_id = user_id

    def _timezone(self) -> str:
        self.cur.execute("SELECT timezone FROM users WHERE _id = %s", (self.user_id,))
        row = self.cur.fetchone()
        return _valid_tz(row[0] if row else None)

    def month_activity(self, year: int, month: int) -> MonthActivity | dict:
        """Return the month's activity, or ``{"error": ...}`` on bad input.

        Raises on database failure (the route maps it to 500): never returns
        an empty calendar for a failed read.
        """
        if not (MIN_YEAR <= year <= MAX_YEAR and 1 <= month <= 12):
            return {"error": "Invalid month"}
        tz = self._timezone()
        start = date(year, month, 1)
        end = date(year + 1, 1, 1) if month == 12 else date(year, month + 1, 1)
        try:
            self.cur.execute(_MONTH_SQL, {"s": start, "e": end, "tz": tz, "u": self.user_id})
            rows = self.cur.fetchall()
        except Exception:
            self.conn.rollback()
            raise
        days: dict[str, list[str]] = {}
        for day, kind in rows:
            days.setdefault(day.isoformat(), []).append(kind)
        return MonthActivity(year=year, month=month, timezone=tz, days=days)

    def record_bible_day(self) -> dict:
        """Idempotently record that the user read today (their local day).

        The day is computed here from the server clock in the user's zone; the
        client supplies nothing, so a day cannot be forged or back-dated.
        Raises on database failure.
        """
        tz = self._timezone()
        try:
            self.cur.execute(
                "INSERT INTO bible_reading_days (user_id, day) "
                "VALUES (%s, (NOW() AT TIME ZONE %s)::date) ON CONFLICT DO NOTHING",
                (self.user_id, tz),
            )
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise
        return {}
