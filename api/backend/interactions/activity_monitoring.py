"""Aggregation queries + the visit-write path for the admin Activity
Monitoring panel (task 20260918-admin-activity-monitoring, step 2).

Context-free manager (Style B in the backend-architecture skill, matching
DevotionManager/ActivityManager) -- every method takes its own parameters
rather than operating on one fixed acting user, since this whole feature has
no "acting user" concept at all (the write path is anonymous; the read path
is scoped to "everyone," not one user).

Time window / granularity (intake spec's open question, resolved here):
trailing 30 days, daily granularity -- a stable, unsurprising default absent
any other instruction. `DEFAULT_WINDOW_DAYS` is the one place this would
change.

"Average X per user" denominator: every method below divides by the
*current* total user count (`COUNT(*) FROM users`), not a historically
accurate "how many users existed on that day" count. This is a deliberate
simplification -- an exact signup-date-aware denominator would need a
per-day cohort query for every metric, which is materially more complex for
a snapshot admin dashboard that isn't billing- or SLA-critical. Documented
here rather than silently approximated.

"Logins" (intake spec's open question, resolved here): there is no
dedicated login-event table, and `sessions` is the closest existing proxy
(a row is created on every successful login). `avg_logins_per_user` counts
`sessions.created_at` rows per day -- this over-counts relative to "distinct
login events" if a single login somehow created more than one session row,
but nothing in this codebase's session-creation path does that
(`backend/auth/sessions.py::create_session` inserts exactly one row per
call, and login/mfa_verify_login each call it exactly once), so the two are
equivalent in practice today.
"""
from datetime import date

from db import DBManager

DEFAULT_WINDOW_DAYS = 30

# Table + timestamp-column pairs backing the four "average X per user"
# metrics that share an identical query shape. Keys are also the
# `metric` path segment `routes/activity_monitoring.py` accepts, and the
# only strings ever interpolated into SQL for this feature -- always from
# this fixed, server-defined mapping, never from the request path value
# itself (the route validates the incoming `metric` against
# `ActivityMonitoringManager.PER_USER_METRICS.keys()` before calling in).
_PER_USER_METRIC_TABLES = {
    "notes": ("notes", "timestamp"),
    "highlights": ("highlights", "timestamp"),
    "messages": ("messages", "timestamp"),
    "logins": ("sessions", "created_at"),
}


class ActivityMonitoringManager(DBManager):
    PER_USER_METRICS = _PER_USER_METRIC_TABLES

    # ── Write path (public, anonymous -- routes/activity_monitoring.py's
    #    POST /activity-monitoring/visits) ──────────────────────────────────

    def record_visit(self, device_id: str, path: str) -> bool:
        """Insert one visit row. `device_id`/`path` are already validated
        (UUIDv4 shape, length-capped, no query string) by
        `schemas.activity_monitoring.VisitCreate` before this is ever
        called -- this method trusts that validation rather than repeating
        it, matching the layering convention (schemas validate, managers
        persist).

        Returns True on success, False on a caught write failure (mirrors
        `DBManager.insertion`'s own signal convention) -- the route
        deliberately doesn't surface a failure to the anonymous caller
        either way (see its own docstring), but the return value is still
        checked so a failure is at least logged, not silently swallowed
        twice over.
        """
        return self.insertion("visits", {"device_id": device_id, "path": path})

    # ── Read path (admin-only -- routes/activity_monitoring.py's
    #    GET /activity-monitoring/plots/*) ──────────────────────────────────

    def _total_users(self) -> int:
        self.cur.execute("SELECT COUNT(*) FROM users")
        row = self.cur.fetchone()
        return row[0] if row else 0

    def daily_average_per_user(
        self, metric: str, window_days: int = DEFAULT_WINDOW_DAYS
    ) -> list[tuple[date, float]]:
        """(day, avg_per_user) for each of the trailing `window_days` days
        (inclusive of today), for one of `PER_USER_METRICS`'s known metrics.

        `avg_per_user` is that day's raw row count divided by the current
        total user count (see module docstring's denominator note) -- 0.0
        for a day with no rows, and 0.0 across the board (never a
        divide-by-zero) if there are no users at all yet.
        """
        if metric not in _PER_USER_METRIC_TABLES:
            raise ValueError(f"Unknown per-user metric: {metric!r}")
        table, ts_col = _PER_USER_METRIC_TABLES[metric]
        total_users = self._total_users()

        # `table`/`ts_col` are looked up from the fixed module-level mapping
        # above, never taken directly off caller input, so this f-string
        # interpolation never carries request-controlled text into SQL --
        # the window bound is still a bound parameter (%s). `COUNT(t.*)`
        # (whole-row, not a named column) rather than `COUNT(t._id)`:
        # `sessions` (the `logins` metric's table) has no `_id` column at
        # all (its PK is `token_hash`), so a fixed column name would break
        # for that one metric -- a composite-row count correctly counts 0
        # for an unmatched LEFT JOIN side regardless of which columns the
        # joined table actually has.
        self.cur.execute(
            f"SELECT d::date AS day, COUNT(t.*) AS cnt "
            f"FROM generate_series(CURRENT_DATE - %s::int, CURRENT_DATE, interval '1 day') AS d "
            f"LEFT JOIN {table} t ON date_trunc('day', t.{ts_col}) = d::date "
            f"GROUP BY d ORDER BY d",
            (window_days,),
        )
        rows = self.cur.fetchall()
        if total_users <= 0:
            return [(r[0], 0.0) for r in rows]
        return [(r[0], r[1] / total_users) for r in rows]

    def daily_visits(
        self, window_days: int = DEFAULT_WINDOW_DAYS
    ) -> tuple[list[tuple[date, int]], list[tuple[date, int]]]:
        """(raw_visits, unique_visitors) for each of the trailing
        `window_days` days, each a list of (day, count) tuples in the same
        day order.

        `raw_visits` is every logged pageview; `unique_visitors` is the
        count of *distinct* `device_id`s that day -- so a single device
        firing the visit beacon 20 times in a day contributes 20 to the
        former and 1 to the latter, which is the whole point of tracking
        `device_id` at all (intake spec's "repeat visits from the same
        device don't inflate the unique-visitor count" requirement).
        """
        self.cur.execute(
            "SELECT d::date AS day, "
            "COUNT(v._id) AS raw_count, "
            "COUNT(DISTINCT v.device_id) AS unique_count "
            "FROM generate_series(CURRENT_DATE - %s::int, CURRENT_DATE, interval '1 day') AS d "
            "LEFT JOIN visits v ON date_trunc('day', v.created_at) = d::date "
            "GROUP BY d ORDER BY d",
            (window_days,),
        )
        rows = self.cur.fetchall()
        raw = [(r[0], r[1]) for r in rows]
        unique = [(r[0], r[2]) for r in rows]
        return raw, unique
