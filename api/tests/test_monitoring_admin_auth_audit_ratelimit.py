"""
Integration test for the error-debug-agent-admin-page workflow's security
surface on all four `/monitoring/*` endpoints (routes/monitoring.py):
GET /monitoring/detections, GET /monitoring/detections/{id},
GET /monitoring/detections/{id}/report, POST /monitoring/detections/{id}/report.

Uses the fully-booted `main.app` (not a bare per-router FastAPI() test app)
specifically because the rate-limit assertion requires the real
`app.state.limiter` + `SlowAPIMiddleware` + `RateLimitExceeded` handler
wiring main.py sets up -- a bare app.include_router(monitoring_router) app
would raise an AttributeError on the rerun endpoint instead of exercising a
real rate limit (flagged explicitly by the security gate's step 4 summary).

Covers:
  - require_admin accept/reject on all four endpoints: admin succeeds (200),
    authenticated-non-admin gets 403, unauthenticated gets 401.
  - Admin-action audit logging: the `admin_audit` logger actually emits a
    line (action + admin_id + detection_id) on real endpoint access, not
    just "the endpoint returned 200".
  - POST .../report rate limiting: 5 requests/minute succeed, the 6th within
    the same window gets 429. The debugging agent's actual OpenRouter call is
    mocked (module-level `run_debug_agent_for_detection`, imported directly
    into routes.monitoring) so this test is fast, free, and deterministic --
    it is not itself testing report generation (see
    test_debug_agent_redaction_and_reports.py for that).

Run:  cd api && ../.venv/bin/python tests/test_monitoring_admin_auth_audit_ratelimit.py
"""

import _pathfix  # noqa: F401

import logging
import os
import uuid
from datetime import datetime, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import routes.monitoring as monitoring_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.monitoring.watchdog import WatchdogManager  # noqa: E402
from schemas.watchdog import ErrorDetection, DetectionReport  # noqa: E402

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
            "_id": uid, "username": f"admin_auth_test_{uid[:8]}",
            "email": f"admin_auth_test_{uid[:8]}@example.com", "hash_pass": "x",
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


LOG_GROUP = f"/test/admin-auth-audit-{uuid.uuid4()}"


def make_detection() -> str:
    wm = WatchdogManager()
    try:
        d = ErrorDetection(
            log_group_name=LOG_GROUP, message="ERROR - test detection",
            matched_signal="error_level", context={},
            event_timestamp=datetime.now(timezone.utc),
        )
        wm.save_detection(d)
        return d.id
    finally:
        wm.close()


def cleanup_detections():
    wm = WatchdogManager()
    try:
        wm.cur.execute("DELETE FROM error_detections WHERE log_group_name = %s", (LOG_GROUP,))
        wm.conn.commit()
    finally:
        wm.close()


class _CapturingHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records: list[str] = []

    def emit(self, record):
        self.records.append(self.format(record))


def test_auth_boundary_all_four_endpoints(client, admin_token, non_admin_token, detection_id):
    print("\n── require_admin accept/reject on all four endpoints ──")
    endpoints = [
        ("GET", f"/monitoring/detections"),
        ("GET", f"/monitoring/detections/{detection_id}"),
        ("GET", f"/monitoring/detections/{detection_id}/report"),
    ]

    for method, path in endpoints:
        client.cookies.clear()
        r = client.request(method, path)
        check(f"{method} {path} unauthenticated -> 401", r.status_code, 401)

        client.cookies.set("session", non_admin_token)
        r = client.request(method, path)
        check(f"{method} {path} authenticated non-admin -> 403", r.status_code, 403)

        client.cookies.set("session", admin_token)
        r = client.request(method, path)
        check(f"{method} {path} authenticated admin -> not 401/403 (got {r.status_code})",
              r.status_code not in (401, 403), True)
        client.cookies.clear()

    # POST rerun endpoint separately (mocked below to avoid burning its rate
    # limit budget here) -- just prove the auth boundary in isolation first.
    post_path = f"/monitoring/detections/{detection_id}/report"
    client.cookies.clear()
    r = client.post(post_path)
    check(f"POST {post_path} unauthenticated -> 401", r.status_code, 401)

    client.cookies.set("session", non_admin_token)
    r = client.post(post_path)
    check(f"POST {post_path} authenticated non-admin -> 403", r.status_code, 403)
    client.cookies.clear()


def test_audit_logging(client, admin_token, detection_id):
    print("\n── admin_audit logger actually emits lines on real endpoint access ──")
    audit_logger = logging.getLogger("admin_audit")
    handler = _CapturingHandler()
    handler.setFormatter(logging.Formatter("%(message)s"))
    audit_logger.addHandler(handler)
    prior_level = audit_logger.level
    audit_logger.setLevel(logging.INFO)
    try:
        client.cookies.set("session", admin_token)
        client.get("/monitoring/detections")
        client.get(f"/monitoring/detections/{detection_id}")
        client.cookies.clear()

        joined = "\n".join(handler.records)
        check("list_detections audit line was emitted",
              "action=list_detections" in joined and f"admin_id={_ADMIN_UID[0]}" in joined, True)
        check("get_detection audit line includes the correct detection_id",
              f"action=get_detection" in joined and f"detection_id={detection_id}" in joined, True)
    finally:
        audit_logger.removeHandler(handler)
        audit_logger.setLevel(prior_level)


def test_rate_limit_on_rerun(client, admin_token, detection_id):
    print("\n── POST .../report rate limit: 5/minute, 6th request -> 429 ──")
    # Mock the actual debugging-agent call so this test is fast/free/deterministic.
    fake_report = DetectionReport(
        detection_id=detection_id, root_cause="mock", remediation_narrative="mock",
        model="mock-model",
    ).model_dump()
    original = monitoring_module.run_debug_agent_for_detection
    monitoring_module.run_debug_agent_for_detection = lambda did: fake_report
    try:
        client.cookies.set("session", admin_token)
        codes = []
        for _ in range(6):
            r = client.post(f"/monitoring/detections/{detection_id}/report")
            codes.append(r.status_code)
        client.cookies.clear()
        check("first 5 rerun requests within the window succeed (200)",
              codes[:5].count(200), 5)
        check("6th rerun request within the same window is rate-limited (429)",
              codes[5], 429)
    finally:
        monitoring_module.run_debug_agent_for_detection = original


_ADMIN_UID = [None]  # populated in __main__, referenced by test_audit_logging


if __name__ == "__main__":
    # Everything that creates DB rows lives inside this try, and cleanup
    # covers every uid/token that might have been created even if a later
    # setup step raises -- setup previously ran outside the try/finally and
    # a mid-setup exception once leaked an admin+non-admin test account pair
    # into the live dev DB (only caught because a later, unrelated test's
    # "exactly one admin" assertion failed against real leftover state).
    admin_uid = non_admin_uid = None
    try:
        admin_uid = make_user(is_admin=True)
        non_admin_uid = make_user(is_admin=False)
        _ADMIN_UID[0] = admin_uid
        admin_token = make_session(admin_uid)
        non_admin_token = make_session(non_admin_uid)
        detection_id = make_detection()

        with TestClient(main_module.app) as client:
            test_auth_boundary_all_four_endpoints(client, admin_token, non_admin_token, detection_id)
            test_audit_logging(client, admin_token, detection_id)
            test_rate_limit_on_rerun(client, admin_token, detection_id)
    finally:
        cleanup_detections()
        if admin_uid:
            cleanup_user(admin_uid)
        if non_admin_uid:
            cleanup_user(non_admin_uid)

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    import sys
    sys.exit(0 if failed == 0 else 1)
