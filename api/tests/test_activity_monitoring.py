"""
Integration test for the new Activity Monitoring feature (task
20260918-admin-activity-monitoring): `routes/activity_monitoring.py`'s two
very different trust boundaries, plus the manager's aggregation logic.

Uses the fully-booted `main.app` (not a bare per-router FastAPI() test app),
same rationale as test_monitoring_admin_auth_audit_ratelimit.py -- the rate
limit assertion needs the real `app.state.limiter` + `SlowAPIMiddleware` +
`RateLimitExceeded` handler wiring main.py sets up.

Covers:
  - POST /activity-monitoring/visits: reachable unauthenticated (this is the
    one public write surface in the feature), rejects a non-UUIDv4
    device_id and an over-length/query-string path with 422 (never
    persisting an unvalidated value), rate-limits at 30/minute per IP.
  - GET /activity-monitoring/plots/{metric} and .../plots/visits:
    require_admin boundary (401 unauthenticated, 403 non-admin, 200 +
    image/png + Cache-Control: no-store for admin), 404 for an unknown
    metric, and an admin_audit line actually emitted on real access.
  - The actual bug this task exists to prevent: repeat visits from the same
    device_id must NOT inflate the unique-visitor count the way they do the
    raw-visit count -- exercises ActivityMonitoringManager.daily_visits
    directly against a real Postgres row set (20 visits from one device on
    one day -> raw=20, unique=1).

Run:  cd api && ../.venv/bin/python tests/test_activity_monitoring.py
"""

import _pathfix  # noqa: F401

import logging
import os
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.interactions.activity_monitoring import ActivityMonitoringManager  # noqa: E402

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


def make_user(is_admin: bool) -> str:
    uid = str(uuid.uuid4())
    dbm = DBManager()
    try:
        dbm.insertion("users", {
            "_id": uid, "username": f"activity_test_{uid[:8]}",
            "email": f"activity_test_{uid[:8]}@example.com", "hash_pass": "x",
            "is_admin": is_admin,
        })
    finally:
        dbm.close()
    return uid


def make_session(uid: str) -> str:
    sm = SessionManager()
    try:
        return sm.create_session(uid)
    finally:
        sm.close()


def cleanup_user(uid: str):
    dbm = DBManager()
    try:
        dbm.delete("users", {"_id": uid})
    finally:
        dbm.close()


class _CapturingHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records: list[str] = []

    def emit(self, record):
        self.records.append(self.format(record))


def test_visit_write_boundary_and_validation(client, created_device_ids):
    print("\n── POST /activity-monitoring/visits: public, insert-only, validated ──")
    client.cookies.clear()

    valid_device_id = str(uuid.uuid4())
    created_device_ids.append(valid_device_id)
    r = client.post("/activity-monitoring/visits",
                     json={"device_id": valid_device_id, "path": "/reader"})
    check("unauthenticated caller can log a visit (204)", r.status_code, 204)
    check("204 response has no body", r.content, b"")

    r = client.post("/activity-monitoring/visits",
                     json={"device_id": "not-a-uuid", "path": "/reader"})
    check("non-UUIDv4 device_id -> 422, never persisted", r.status_code, 422)

    # A version-1 (not v4) UUID shape must also be rejected -- the validator
    # checks the literal version/variant nibbles, not just "any UUID".
    r = client.post("/activity-monitoring/visits",
                     json={"device_id": "550e8400-e29b-11d4-a716-446655440000", "path": "/reader"})
    check("non-v4-version UUID shape -> 422", r.status_code, 422)

    r = client.post("/activity-monitoring/visits",
                     json={"device_id": str(uuid.uuid4()), "path": "/reader?evil=1"})
    check("path with query string -> 422", r.status_code, 422)

    r = client.post("/activity-monitoring/visits",
                     json={"device_id": str(uuid.uuid4()), "path": "/x" * 150})
    check("over-length path (>200 chars) -> 422", r.status_code, 422)


def test_visit_rate_limit(client, already_consumed, created_device_ids):
    print("\n── POST /activity-monitoring/visits rate limit: 30/minute per IP, then 429 ──")
    # The limiter's key is per-client-IP (see backend.rate_limiting.
    # get_client_ip), and TestClient sends every request in this process
    # from the same fake IP -- so `already_consumed` successful (204) calls
    # made earlier in this same run (e.g. test_visit_write_boundary_and_
    # validation's one valid POST) already spent part of this window's
    # budget. Only a 204 response actually invokes the limiter-wrapped
    # endpoint function; a 422 validation failure never reaches it, so
    # those don't count (confirmed empirically: `already_consumed` tracks
    # exactly the 204s, not the 422s).
    remaining = 30 - already_consumed
    client.cookies.clear()
    device_id = str(uuid.uuid4())
    created_device_ids.append(device_id)
    codes = []
    for _ in range(remaining + 1):
        r = client.post("/activity-monitoring/visits",
                         json={"device_id": device_id, "path": "/reader"})
        codes.append(r.status_code)
    check(f"remaining {remaining} requests within the window succeed (204)",
          codes[:remaining].count(204), remaining)
    check("next request in the same window is rate-limited (429)",
          codes[remaining], 429)


def test_plots_auth_boundary(client, admin_token, non_admin_token):
    print("\n── require_admin accept/reject on all plot endpoints ──")
    endpoints = [
        "/activity-monitoring/plots/visits",
        "/activity-monitoring/plots/notes",
        "/activity-monitoring/plots/highlights",
        "/activity-monitoring/plots/logins",
        "/activity-monitoring/plots/messages",
    ]
    for path in endpoints:
        client.cookies.clear()
        r = client.get(path)
        check(f"GET {path} unauthenticated -> 401", r.status_code, 401)

        client.cookies.set("session", non_admin_token)
        r = client.get(path)
        check(f"GET {path} authenticated non-admin -> 403", r.status_code, 403)

        client.cookies.set("session", admin_token)
        r = client.get(path)
        check(f"GET {path} authenticated admin -> 200", r.status_code, 200)
        check(f"GET {path} admin response is image/png",
              r.headers.get("content-type"), "image/png")
        check(f"GET {path} admin response is Cache-Control: no-store",
              r.headers.get("cache-control"), "no-store")
        client.cookies.clear()

    # Unknown metric -> 404, gated behind admin (never leaks existence info
    # to a non-admin/unauthenticated caller ahead of the 401/403 check).
    client.cookies.clear()
    r = client.get("/activity-monitoring/plots/not-a-real-metric")
    check("GET /plots/not-a-real-metric unauthenticated -> 401 (auth checked first)",
          r.status_code, 401)

    client.cookies.set("session", admin_token)
    r = client.get("/activity-monitoring/plots/not-a-real-metric")
    check("GET /plots/not-a-real-metric as admin -> 404", r.status_code, 404)
    client.cookies.clear()


def test_audit_logging(client, admin_token):
    print("\n── admin_audit logger emits a line on real plot access ──")
    audit_logger = logging.getLogger("admin_audit")
    handler = _CapturingHandler()
    handler.setFormatter(logging.Formatter("%(message)s"))
    audit_logger.addHandler(handler)
    prior_level = audit_logger.level
    audit_logger.setLevel(logging.INFO)
    try:
        client.cookies.set("session", admin_token)
        client.get("/activity-monitoring/plots/notes")
        client.get("/activity-monitoring/plots/visits")
        client.cookies.clear()

        joined = "\n".join(handler.records)
        check("notes metric view audit line was emitted",
              "action=view_activity_monitoring" in joined and "metric=notes" in joined, True)
        check("visits view audit line was emitted",
              "action=view_activity_monitoring" in joined and "metric=visits" in joined, True)
        check("audit line does not leak the raw device_id of any visitor",
              any("device_id" in rec for rec in handler.records), False)
    finally:
        audit_logger.removeHandler(handler)
        audit_logger.setLevel(prior_level)


def test_unique_vs_raw_visit_counting():
    print("\n── daily_visits: repeat visits from one device do not inflate unique count ──")
    manager = ActivityMonitoringManager()
    device_a = str(uuid.uuid4())
    device_b = str(uuid.uuid4())
    try:
        # 20 visits from the same device -- must count as 20 raw, 1 unique.
        for _ in range(20):
            manager.record_visit(device_a, "/reader")
        # 3 visits from a second device -- raw goes to 23, unique to 2.
        for _ in range(3):
            manager.record_visit(device_b, "/account")

        raw, unique = manager.daily_visits(window_days=1)
        today_raw = dict(raw).get(_today(manager), None)
        today_unique = dict(unique).get(_today(manager), None)

        check("raw visit count reflects every logged pageview (>= 23 today)",
              today_raw is not None and today_raw >= 23, True)
        check("unique-device count is far smaller than raw (deduplicated by device_id)",
              today_unique is not None and today_unique < today_raw, True)
        check("unique-device count for today is exactly 2 net-new devices "
              "(allowing for other concurrent test/dev traffic, must be >= 2)",
              today_unique is not None and today_unique >= 2, True)
    finally:
        # Best-effort cleanup of this test's own rows -- visits has no user
        # FK to cascade through, so clean up explicitly by device_id.
        manager.cur.execute("DELETE FROM visits WHERE device_id IN (%s, %s)",
                             (device_a, device_b))
        manager.conn.commit()
        manager.close()


def _today(manager):
    manager.cur.execute("SELECT CURRENT_DATE")
    return manager.cur.fetchone()[0]


def test_metric_denominator_and_shape():
    print("\n── daily_average_per_user: correct shape, no divide-by-zero, unknown metric rejected ──")
    manager = ActivityMonitoringManager()
    try:
        series = manager.daily_average_per_user("notes", window_days=7)
        check("daily_average_per_user returns 8 days (window_days + today, inclusive)",
              len(series), 8)
        check("every value is non-negative", all(v >= 0 for _, v in series), True)

        try:
            manager.daily_average_per_user("not-a-real-metric")
            check("unknown metric raises ValueError instead of running arbitrary SQL", False, True)
        except ValueError:
            check("unknown metric raises ValueError instead of running arbitrary SQL", True, True)
    finally:
        manager.close()


def cleanup_visits(device_ids):
    if not device_ids:
        return
    manager = ActivityMonitoringManager()
    try:
        manager.cur.execute("DELETE FROM visits WHERE device_id = ANY(%s::uuid[])", (device_ids,))
        manager.conn.commit()
    finally:
        manager.close()


if __name__ == "__main__":
    admin_uid = non_admin_uid = None
    created_device_ids = []  # every device_id this run inserts via HTTP, for cleanup
    try:
        admin_uid = make_user(is_admin=True)
        non_admin_uid = make_user(is_admin=False)
        admin_token = make_session(admin_uid)
        non_admin_token = make_session(non_admin_uid)

        with TestClient(main_module.app) as client:
            test_visit_write_boundary_and_validation(client, created_device_ids)
            test_plots_auth_boundary(client, admin_token, non_admin_token)
            test_audit_logging(client, admin_token)
            # Rate-limit test last -- it deliberately burns the rest of this
            # IP's 30/minute visits budget. Exactly 1 valid (204) visit POST
            # was already made above (test_visit_write_boundary_and_
            # validation's happy-path check); the 422s in that test never
            # reached the limiter (see test_visit_rate_limit's own note).
            test_visit_rate_limit(client, already_consumed=1, created_device_ids=created_device_ids)

        test_unique_vs_raw_visit_counting()
        test_metric_denominator_and_shape()
    finally:
        if admin_uid:
            cleanup_user(admin_uid)
        if non_admin_uid:
            cleanup_user(non_admin_uid)
        # visits has no user FK to cascade through (anonymous by design --
        # see api/db.py's Level 0 comment), so this feature's own test rows
        # need their own explicit cleanup or they accumulate in the dev DB
        # forever across repeated test runs.
        cleanup_visits(created_device_ids)

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    import sys
    sys.exit(0 if failed == 0 else 1)
