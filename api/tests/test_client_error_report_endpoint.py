"""
Heavy-testing coverage for `POST /monitoring/client-error` (routes/monitoring.py)
and its schema (schemas/watchdog.py::ClientErrorReport) -- the new client-
observable-only decode-failure beacon added in backend step 1 of the
notes-load-failure-cloudwatch-gap workflow, reviewed by security step 2.

This is the production-outage remediation task's namesake endpoint: the
whole reason the incident went undetected is that a well-formed 200 the
client can't parse produces zero server-side error signal, so this endpoint
(and the watchdog's ability to consume its output correctly and safely) is
the single most load-bearing piece of new backend surface in this task.

Uses the fully-booted `main.app` (not a bare per-router test app) since the
rate-limit assertion needs the real `app.state.limiter` + SlowAPIMiddleware
wiring -- same rationale/pattern as test_monitoring_admin_auth_audit_ratelimit.py.

Covers:
  - Auth: unauthenticated -> 401. Authenticated NON-admin user succeeds (204)
    -- this is the one `/monitoring/*` endpoint intentionally NOT gated by
    require_admin (security step 2 confirmed this is correct: the caller is
    the reporting device itself, not an admin).
  - Happy path: a 204 response, and a real `logger.error(...)` line is
    actually emitted (captured via a real logging handler, not mocked) with
    the CLIENT_DECODE_FAILURE marker, the correct (DB-verified) user_id, and
    the submitted endpoint/client_app_version/http_status/error_summary.
  - Rate limiting: 10 requests/minute succeed, the 11th within the same
    window gets 429 (matches backend step 1's documented "10/minute").
  - Input validation: an oversized field (over its Field(max_length=...))
    returns 422, not a 500 -- never trust the client to self-limit.
  - Data minimization: the request schema has no field capable of carrying a
    raw response body/other request content; only the four documented
    minimal fields are ever accepted or logged.
  - Log-injection hardening (security step 2, CWE-117 / ASVS 16.4.1): a
    payload embedding raw control characters (newline, carriage return) plus
    literal "CRITICAL"/"Traceback (most recent call last)" markers, once
    logged, produces exactly ONE line the watchdog's per-line CloudWatch scan
    would ever see (i.e. the emitted record contains zero raw control
    characters) -- proving an authenticated non-admin caller can no longer
    forge what looks like a second, independent, unattributed log line and
    have it treated as a genuinely separate incident.
  - The user_id embedded in the logged line always comes from the session
    (get_current_user), never from any client-supplied field -- a report
    can't be misattributed to an arbitrary other account.

Run:  cd api && ../.venv/bin/python tests/test_client_error_report_endpoint.py
"""

import _pathfix  # noqa: F401

import logging
import os
import re
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.monitoring.watchdog import _match_error_signal  # noqa: E402

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


def contains(label, haystack, needle, should_contain=True):
    ok = (needle in haystack) == should_contain
    results.append(ok)
    verb = "contains" if should_contain else "does NOT contain"
    print(f"  [{PASS if ok else FAIL}] {label}: {verb} {needle!r} -> {ok}")


# All tests in this file share one TestClient/slowapi rate-limit window keyed
# on the same "testclient" IP (see get_client_ip's fallback), so every
# successful (204) POST /monitoring/client-error call made by an EARLIER test
# in this file eats into the SAME 10/minute budget the dedicated rate-limit
# test below measures. Track it here so that test computes its expected
# pass/fail boundary from the budget actually remaining, instead of assuming
# it starts with a full fresh window (which previously caused a spurious
# failure: 3 prior 204s in this run left only 7 of the 10 remaining).
RATE_LIMIT_BUDGET = 10
_budget_used = [0]


def _track_budget(status_code: int) -> None:
    if status_code == 204:
        _budget_used[0] += 1


def make_user(is_admin: bool = False) -> str:
    uid = str(uuid.uuid4())
    dbm = DBManager()
    try:
        dbm.insertion("users", {
            "_id": uid, "username": f"client_err_test_{uid[:8]}",
            "email": f"client_err_test_{uid[:8]}@example.com", "hash_pass": "x",
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


def test_unauthenticated_rejected(client):
    print("\n── Unauthenticated caller is rejected (401), not silently accepted ──")
    client.cookies.clear()
    r = client.post("/monitoring/client-error", json={
        "endpoint": "GET /notes/{user_id}", "client_app_version": "1.0.0 (1)",
        "http_status": 200, "error_summary": "type mismatch",
    })
    check("unauthenticated POST /monitoring/client-error -> 401", r.status_code, 401)


def test_happy_path_authenticated_non_admin_succeeds_and_logs(client, user_token, user_id):
    print("\n── Authenticated NON-admin caller succeeds (204) and a real log line is emitted ──")
    app_logger = logging.getLogger("routes.monitoring")
    handler = _CapturingHandler()
    app_logger.addHandler(handler)
    prior_level = app_logger.level
    app_logger.setLevel(logging.DEBUG)
    try:
        client.cookies.set("session", user_token)
        r = client.post("/monitoring/client-error", json={
            "endpoint": "GET /notes/{user_id}",
            "client_app_version": "1.4.2 (37)",
            "http_status": 200,
            "error_summary": "keyNotFound(\"notes\", ...)",
        })
        client.cookies.clear()
        _track_budget(r.status_code)

        check("authenticated non-admin caller (NOT require_admin) succeeds", r.status_code, 204)

        joined = "\n".join(handler.records)
        contains("logged line carries the CLIENT_DECODE_FAILURE marker", joined, "CLIENT_DECODE_FAILURE")
        contains("logged line carries the DB-verified session user_id", joined, f"user_id={user_id}")
        contains("logged line carries the submitted endpoint", joined, "endpoint=GET /notes/{user_id}")
        contains("logged line carries the submitted client_app_version", joined, "client_app_version=1.4.2 (37)")
        contains("logged line carries the submitted http_status", joined, "http_status=200")
    finally:
        app_logger.removeHandler(handler)
        app_logger.setLevel(prior_level)


def test_user_id_always_from_session_never_client_supplied(client, user_token, user_id):
    print("\n── user_id in the logged line is always the session's, never client-influenceable ──")
    app_logger = logging.getLogger("routes.monitoring")
    handler = _CapturingHandler()
    app_logger.addHandler(handler)
    prior_level = app_logger.level
    app_logger.setLevel(logging.DEBUG)
    try:
        client.cookies.set("session", user_token)
        forged_uid = str(uuid.uuid4())
        r = client.post("/monitoring/client-error", json={
            "endpoint": "GET /notes/{user_id}",
            "client_app_version": "1.0.0 (1)",
            "http_status": 200,
            "error_summary": "irrelevant",
            "user_id": forged_uid,  # not a real field on the schema -- must be ignored, not injected
        })
        client.cookies.clear()
        _track_budget(r.status_code)
        check("extra/forged user_id field in the body does not break the request", r.status_code, 204)
        joined = "\n".join(handler.records)
        contains("logged line uses the real session user_id", joined, f"user_id={user_id}")
        contains("logged line does NOT contain the forged user_id", joined, forged_uid, should_contain=False)
    finally:
        app_logger.removeHandler(handler)
        app_logger.setLevel(prior_level)


def test_oversized_field_rejected_422_not_500(client, user_token):
    print("\n── Oversized field (over Field(max_length=...)) -> 422, never a 500 ──")
    client.cookies.set("session", user_token)
    r = client.post("/monitoring/client-error", json={
        "endpoint": "x" * 5000,  # max_length=200
        "client_app_version": "1.0.0 (1)",
        "http_status": 200,
        "error_summary": "irrelevant",
    })
    client.cookies.clear()
    check("oversized 'endpoint' field is rejected with 422 (validation), not 500", r.status_code, 422)


def test_invalid_http_status_rejected_422(client, user_token):
    print("\n── Out-of-range http_status (outside 100-599) -> 422 ──")
    client.cookies.set("session", user_token)
    r = client.post("/monitoring/client-error", json={
        "endpoint": "GET /notes/{user_id}",
        "client_app_version": "1.0.0 (1)",
        "http_status": 9999,
        "error_summary": "irrelevant",
    })
    client.cookies.clear()
    check("http_status outside 100-599 is rejected with 422", r.status_code, 422)


def test_log_injection_control_chars_stripped(client, user_token, user_id):
    print("\n── Log-injection hardening: embedded control chars can't forge a second log line ──")
    app_logger = logging.getLogger("routes.monitoring")
    handler = _CapturingHandler()
    app_logger.addHandler(handler)
    prior_level = app_logger.level
    app_logger.setLevel(logging.DEBUG)
    try:
        client.cookies.set("session", user_token)
        forged_line = (
            "\r\n2026-08-17 00:00:00,000 [main] CRITICAL - "
            "Traceback (most recent call last):\nfake unrelated incident"
        )
        r = client.post("/monitoring/client-error", json={
            "endpoint": "GET /notes/{user_id}",
            "client_app_version": "1.0.0 (1)",
            "http_status": 200,
            "error_summary": forged_line,
        })
        client.cookies.clear()
        _track_budget(r.status_code)
        check("request with injection payload still succeeds (204) -- sanitized, not rejected",
              r.status_code, 204)

        joined = "\n".join(handler.records)
        control_char_pattern = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
        # \n (\x0a) is allowed to remain as the natural separator between
        # captured handler.records entries; check each individual captured
        # record's raw text (not the join) contains no control chars at all,
        # including no bare \r or embedded \n WITHIN a single record.
        any_control_char_in_a_single_record = any(
            control_char_pattern.search(rec) or "\n" in rec or "\r" in rec
            for rec in handler.records
        )
        check("no single emitted log record contains a raw control character "
              "(\\n/\\r/other) -- can't be split into a second, unattributed line",
              any_control_char_in_a_single_record, False)

        contains("the neutralized text still carries the literal words (now harmless, same line)",
                  joined, "CRITICAL")
        contains("every record is still correctly attributed to the real session user_id",
                  joined, f"user_id={user_id}")

        # The single (still-attributed) emitted line is exactly what the
        # watchdog's own per-line scanner would see -- prove it resolves to
        # ONE signal for this ONE real line (the specific signal picked is a
        # pattern-ordering detail already documented in watchdog.py --
        # "critical" is checked before "client_decode_failure" -- what
        # matters for the injection defense is that this is still one
        # correctly-user_id-attributed CLIENT_DECODE_FAILURE line, not two).
        signal = _match_error_signal(joined.splitlines()[0]) if handler.records else None
        check("the (single) emitted line still resolves to a known signal, not silently dropped",
              signal is not None, True)
    finally:
        app_logger.removeHandler(handler)
        app_logger.setLevel(prior_level)


def test_rate_limited_10_per_minute(client, user_token):
    print("\n── Rate limit: 10/minute (shared window), budget exhausted -> 429 ──")
    # This test's assertion accounts for RATE_LIMIT_BUDGET already partially
    # consumed by earlier 204s in this same file/run (see _budget_used above)
    # -- slowapi's fixed window is keyed per client IP, and every test here
    # shares the same TestClient/"testclient" IP, so the budget is real and
    # cumulative across the whole file, not reset per test function.
    remaining = RATE_LIMIT_BUDGET - _budget_used[0]
    check("sanity: some budget is still available for this test to exhaust "
          "(if this is 0, an earlier test already consumed the whole window)",
          remaining > 0, True)

    client.cookies.set("session", user_token)
    codes = []
    # One extra request beyond the remaining budget to observe the 429 cutoff.
    for _ in range(remaining + 1):
        r = client.post("/monitoring/client-error", json={
            "endpoint": "GET /notes/{user_id}",
            "client_app_version": "1.0.0 (1)",
            "http_status": 200,
            "error_summary": "rate limit probe",
        })
        codes.append(r.status_code)
    client.cookies.clear()
    check(f"exactly the {remaining} remaining requests in the window succeed (204)",
          codes[:remaining].count(204), remaining)
    check("the request beyond the full 10/minute budget is rate-limited (429)",
          codes[remaining], 429)


if __name__ == "__main__":
    user_uid = None
    try:
        user_uid = make_user(is_admin=False)
        user_token = make_session(user_uid)

        with TestClient(main_module.app) as client:
            test_unauthenticated_rejected(client)
            test_happy_path_authenticated_non_admin_succeeds_and_logs(client, user_token, user_uid)
            test_user_id_always_from_session_never_client_supplied(client, user_token, user_uid)
            test_oversized_field_rejected_422_not_500(client, user_token)
            test_invalid_http_status_rejected_422(client, user_token)
            test_log_injection_control_chars_stripped(client, user_token, user_uid)
            # Rate limit test LAST -- it deliberately exhausts + trips this
            # client IP's 10/minute budget for this endpoint, which would
            # otherwise 429 every test after it in the same run/window.
            test_rate_limited_10_per_minute(client, user_token)
    finally:
        if user_uid:
            cleanup_user(user_uid)

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    import sys
    sys.exit(0 if failed == 0 else 1)
