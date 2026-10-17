"""Pure rules for recurring announcement reminders (task 20261016-announcement-recurring-reminder).

No DB access here: the flag, tunables, input validation and the occurrence
math, shared by ``announcements.py`` (create/update/serialize) and the
``announcement_repeat`` scheduler job.

Occurrence model: occurrence ``k`` (k >= 1; k = 0 is the publish push itself)
is ``publish_at`` + k days / 7k days / k calendar months, computed on the
WALL CLOCK in the anchor zone (``repeat_tz``, an IANA name; NULL = UTC) and
then converted to a UTC-aware instant. Anchoring each occurrence to the
original ``publish_at`` (not the previous occurrence) means months never
drift (Jan 31 -> Feb 28 -> Mar 31) and DST never shifts the wall-clock time
or double-fires. A wall time that does not exist (spring-forward gap) resolves
deterministically to the instant after the gap; an ambiguous one (fall-back)
resolves to its first instance.
"""
from __future__ import annotations

import calendar
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from zoneinfo import ZoneInfo, available_timezones

# Feature flag (Configuration Philosophy: flag new functionality by default).
# A plain module constant, matching the neighbouring announcement modules
# (ANNOUNCEMENTS_ENABLED / ANNOUNCEMENT_PUSH_ENABLED). Turned ON by Jacey's
# explicit decision on 2026-10-17 ("Flag on and ship everything"). While False:
# create/update reject a non-null repeat (422), the job claims and sends
# nothing, and the announcement payload has no repeat keys.
ANNOUNCEMENT_REPEAT_ENABLED = True

REPEAT_INTERVALS = frozenset({"daily", "weekly", "monthly"})
# Lifetime cap on repeat pushes for one announcement.
ANNOUNCEMENT_REPEAT_MAX_OCCURRENCES = 52
# A repeat with no explicit end stops this long after it was last set, and
# repeat_until may be at most this far ahead.
ANNOUNCEMENT_REPEAT_HORIZON_DAYS = 365
# Active (armed, non-deleted) repeating announcements per group.
ANNOUNCEMENT_REPEAT_MAX_ACTIVE_PER_GROUP = 3
# Per-group budget: pushes (publish, creation, repeat) of OTHER announcements
# in the window, at or above which a due repeat is skipped.
ANNOUNCEMENT_REPEAT_GROUP_CAP = 5
ANNOUNCEMENT_REPEAT_GROUP_CAP_WINDOW_SECONDS = 24 * 3600
ANNOUNCEMENT_REPEAT_POLL_INTERVAL_SECONDS = 60
ANNOUNCEMENT_REPEAT_MAX_ROWS_PER_TICK = 50
# A due occurrence older than this is advanced past but not pushed (outage,
# flag flipped on late, restore long after).
ANNOUNCEMENT_REPEAT_STALE_AFTER_SECONDS = 3600
REPEAT_TZ_MAX_LENGTH = 64


class RepeatLimitReached(ValueError):
    """A repeat cap blocks this change (422 with a short, user-safe message)."""


@lru_cache(maxsize=1)
def _known_zones() -> frozenset[str]:
    return frozenset(available_timezones())


def normalize_repeat_interval(value) -> str | None:
    """Exact allowlist match or None (= no repeat). Never coerces."""
    if value is None:
        return None
    if not isinstance(value, str) or value not in REPEAT_INTERVALS:
        raise ValueError("repeat_interval must be daily, weekly or monthly")
    return value


def normalize_repeat_tz(value) -> str | None:
    """A known IANA zone name or None (= UTC). Invalid is a 422, never ignored."""
    if value is None:
        return None
    if (not isinstance(value, str) or len(value) > REPEAT_TZ_MAX_LENGTH
            or value not in _known_zones()):
        raise ValueError("repeat_tz must be an IANA timezone name")
    return value


def parse_repeat_until(value, *, publish_at: datetime, now: datetime | None = None) -> datetime | None:
    """tz-aware ISO-8601, after ``publish_at`` and now, at most the horizon ahead."""
    if value is None:
        return None
    now = now or datetime.now(timezone.utc)
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        raise ValueError("repeat_until must be an ISO-8601 timestamp")
    if parsed.tzinfo is None:
        raise ValueError("repeat_until must include a timezone offset")
    if parsed <= publish_at or parsed <= now:
        raise ValueError("repeat_until must be in the future and after the publish time")
    if parsed > now + timedelta(days=ANNOUNCEMENT_REPEAT_HORIZON_DAYS):
        raise ValueError(f"repeat_until can be at most {ANNOUNCEMENT_REPEAT_HORIZON_DAYS} days ahead")
    return parsed


def _add_months(naive: datetime, months: int) -> datetime:
    index = naive.year * 12 + (naive.month - 1) + months
    year, month = divmod(index, 12)
    month += 1
    day = min(naive.day, calendar.monthrange(year, month)[1])
    return naive.replace(year=year, month=month, day=day)


def occurrence(anchor: datetime, interval: str, tz: str | None, k: int) -> datetime:
    """UTC instant of occurrence ``k`` (k >= 1). Raises ValueError on a bad
    interval/zone (callers fail closed)."""
    if interval not in REPEAT_INTERVALS:
        raise ValueError("unknown repeat interval")
    zone = ZoneInfo(tz) if tz else timezone.utc
    naive = anchor.astimezone(zone).replace(tzinfo=None)
    if interval == "daily":
        shifted = naive + timedelta(days=k)
    elif interval == "weekly":
        shifted = naive + timedelta(days=7 * k)
    else:
        shifted = _add_months(naive, k)
    return shifted.replace(tzinfo=zone).astimezone(timezone.utc)


def first_occurrence_after(anchor: datetime, interval: str, tz: str | None, after: datetime) -> datetime:
    """The first occurrence (k >= 1) strictly after ``after``. Forward only:
    missed occurrences are never returned."""
    delta_days = max(0, (after - anchor).days)
    if interval == "daily":
        k = delta_days
    elif interval == "weekly":
        k = delta_days // 7
    else:
        k = delta_days // 31
    k = max(1, k - 1)
    while True:
        candidate = occurrence(anchor, interval, tz, k)
        if candidate > after:
            return candidate
        k += 1


def effective_end(repeat_until: datetime | None, started_at: datetime | None) -> datetime | None:
    """Explicit end if set, else horizon after the repeat was set. None only
    when neither is known (callers treat that as unparseable state)."""
    if repeat_until is not None:
        return repeat_until
    if started_at is None:
        return None
    return started_at + timedelta(days=ANNOUNCEMENT_REPEAT_HORIZON_DAYS)


def next_armed(anchor: datetime, interval: str, tz: str | None, after: datetime,
               end: datetime | None, pushed: int) -> datetime | None:
    """Next occurrence to arm, or None when the end or occurrence cap stops it."""
    if end is None or pushed >= ANNOUNCEMENT_REPEAT_MAX_OCCURRENCES:
        return None
    nxt = first_occurrence_after(anchor, interval, tz, after)
    return nxt if nxt <= end else None
