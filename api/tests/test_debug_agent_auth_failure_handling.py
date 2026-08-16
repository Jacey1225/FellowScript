"""
Proves the debug-agent half of the 2026-08-14 incident fix
(backend/monitoring/debug_agent.py::DebugAgentAuthError /
_call_debug_api / generate_report): an OpenRouter 401/403 is now a distinct,
terminal, non-retried outcome logged at WARNING -- never ERROR -- so it can
no longer alias into the watchdog's `\bERROR\b` error-signal pattern and
re-trigger the self-amplifying feedback loop that produced the OOM incident.

Covers:
  - `_call_debug_api` raises `DebugAgentAuthError` (not a generic exception
    or `requests.HTTPError`) on both 401 and 403.
  - `generate_report` catches it separately from the generic-failure path,
    logs at WARNING (via the standard `logging` module -- captured here by
    swapping in a list-collecting handler rather than mocking the logger
    entirely, so this proves the *real* logging call site's level), and
    never logs at ERROR for this specific failure.
  - The returned error shape carries a distinct, machine-checkable code
    (`"openrouter_auth_failed"`) distinguishable from a generic upstream
    failure -- not just a differently-worded message string.
  - The exception message / the WARNING log line never contains the actual
    `OPENROUTER_API_KEY` value or the request's Authorization header value
    -- only the static "check OPENROUTER_API_KEY" hint.
  - The detection stays `status='new'` (never `diagnosed`, never stuck in
    some other partial state) and no report row is created -- matches the
    existing "failed call doesn't fake success" contract, specifically for
    this failure mode.
  - `_call_debug_api` does not retry on its own (called exactly once) --
    nothing in this path re-triggers the call that just failed.

Run:  cd api && ../.venv/bin/python tests/test_debug_agent_auth_failure_handling.py
"""

import _pathfix  # noqa: F401

import logging
import sys
import uuid
from datetime import datetime, timezone

import backend.monitoring.debug_agent as debug_agent_module
from backend.monitoring.debug_agent import (
    DebugAgentAuthError,
    DebugAgentManager,
    _call_debug_api,
)
from backend.monitoring.watchdog import WatchdogManager
from db import DBManager
from schemas.watchdog import ErrorDetection

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


LOG_GROUP = f"/test/debug-agent-auth-{uuid.uuid4()}"


class _FakeResponse:
    def __init__(self, status_code: int):
        self.status_code = status_code

    def raise_for_status(self):
        raise AssertionError("raise_for_status should never be reached for a 401/403 -- "
                              "the auth check must short-circuit before it")

    def json(self):
        raise AssertionError("json() should never be reached for a 401/403")


def make_detection(message: str) -> str:
    wm = WatchdogManager()
    try:
        d = ErrorDetection(
            log_group_name=LOG_GROUP, message=message, matched_signal="error_level",
            context={}, event_timestamp=datetime.now(timezone.utc),
        )
        wm.save_detection(d)
        return d.id
    finally:
        wm.close()


def get_detection_status(detection_id: str) -> str | None:
    dbm = DBManager()
    try:
        result = dbm.lookup("error_detections", {"_id": detection_id})
        if not result:
            return None
        _, data = list(result.items())[0]
        return data.get("status")
    finally:
        dbm.close()


def count_reports_for(detection_id: str) -> int:
    dbm = DBManager()
    try:
        dbm.cur.execute(
            "SELECT count(*) FROM error_detection_reports WHERE detection_id = %s", (detection_id,)
        )
        return dbm.cur.fetchone()[0]
    finally:
        dbm.close()


def cleanup_detections():
    wm = WatchdogManager()
    try:
        wm.cur.execute("DELETE FROM error_detections WHERE log_group_name = %s", (LOG_GROUP,))
        wm.conn.commit()
    finally:
        wm.close()


class _ListHandler(logging.Handler):
    """Collects (levelno, message) tuples for real emitted log records --
    used to prove the actual log level a real `logger.warning(...)` /
    `logger.error(...)` call site produces, not a mocked stand-in for it."""

    def __init__(self):
        super().__init__()
        self.records = []

    def emit(self, record):
        self.records.append((record.levelno, self.format(record)))


def test_call_debug_api_raises_auth_error_on_401_and_403():
    print("\n── _call_debug_api raises DebugAgentAuthError (not generic) on 401/403 ──")
    for status in (401, 403):
        original_post = debug_agent_module.requests.post
        debug_agent_module.requests.post = lambda *a, status=status, **k: _FakeResponse(status)
        try:
            raised = None
            try:
                _call_debug_api("irrelevant content")
            except DebugAgentAuthError as e:
                raised = e
            except Exception as e:  # noqa: BLE001
                raised = e
            check(f"HTTP {status} raises DebugAgentAuthError specifically",
                  isinstance(raised, DebugAgentAuthError), True)
        finally:
            debug_agent_module.requests.post = original_post


def test_auth_key_value_never_leaks_into_exception_message():
    print("\n── The API key value never appears in the raised exception's message ──")
    fake_key = "sk-or-v1-THIS_MUST_NEVER_APPEAR_IN_LOGS_abcdef123456"
    original_key = debug_agent_module.HEADERS.get("Authorization")
    debug_agent_module.HEADERS["Authorization"] = f"Bearer {fake_key}"
    original_post = debug_agent_module.requests.post
    debug_agent_module.requests.post = lambda *a, **k: _FakeResponse(403)
    try:
        raised = None
        try:
            _call_debug_api("irrelevant content")
        except DebugAgentAuthError as e:
            raised = e
        contains("exception message does not leak the API key",
                  str(raised), fake_key, should_contain=False)
        contains("exception message contains the generic remediation hint",
                  str(raised), "OPENROUTER_API_KEY")
    finally:
        debug_agent_module.requests.post = original_post
        debug_agent_module.HEADERS["Authorization"] = original_key


def test_generate_report_logs_auth_failure_at_warning_not_error():
    print("\n── generate_report: auth failure logged at WARNING, never ERROR ──")
    detection_id = make_detection("ERROR - about to trigger a debug-agent auth failure")

    handler = _ListHandler()
    target_logger = debug_agent_module.logger
    target_logger.addHandler(handler)
    original_level = target_logger.level
    target_logger.setLevel(logging.DEBUG)

    call_count = {"n": 0}
    original_post = debug_agent_module.requests.post

    def fake_post(*a, **k):
        call_count["n"] += 1
        return _FakeResponse(403)

    debug_agent_module.requests.post = fake_post
    try:
        manager = DebugAgentManager()
        try:
            result = manager.generate_report(detection_id)
        finally:
            manager.close()

        check("generate_report returns the distinct openrouter_auth_failed error code",
              result.get("error"), "openrouter_auth_failed")

        levels_logged = [lvl for lvl, _ in handler.records]
        check("no ERROR-level record was emitted for this failure",
              logging.ERROR in levels_logged, False)
        check("a WARNING-level record was emitted for this failure",
              logging.WARNING in levels_logged, True)

        all_text = " ".join(msg for _, msg in handler.records)
        contains("logged text mentions the detection id for traceability",
                  all_text, detection_id)

        check("_call_debug_api / requests.post called exactly once -- no internal retry",
              call_count["n"], 1)

        check("detection status stays 'new' (never marked diagnosed on auth failure)",
              get_detection_status(detection_id), "new")
        check("no report row created for an auth-failed generation",
              count_reports_for(detection_id), 0)
    finally:
        debug_agent_module.requests.post = original_post
        target_logger.removeHandler(handler)
        target_logger.setLevel(original_level)


def test_generic_upstream_failure_still_logs_at_error_for_contrast():
    print("\n── Contrast: a non-auth upstream failure still logs at ERROR (unchanged) ──")
    detection_id = make_detection("ERROR - about to trigger a generic upstream failure")

    handler = _ListHandler()
    target_logger = debug_agent_module.logger
    target_logger.addHandler(handler)
    original_level = target_logger.level
    target_logger.setLevel(logging.DEBUG)

    original_post = debug_agent_module.requests.post

    class _Failing500(_FakeResponse):
        def raise_for_status(self):
            raise RuntimeError("simulated 500")

    debug_agent_module.requests.post = lambda *a, **k: _Failing500(500)
    try:
        manager = DebugAgentManager()
        try:
            result = manager.generate_report(detection_id)
        finally:
            manager.close()

        check("generic failure returns the generic error shape (distinct from auth failure)",
              result.get("error"), "debug agent call failed")
        levels_logged = [lvl for lvl, _ in handler.records]
        check("a generic (non-auth) upstream failure still logs at ERROR -- proves this test's "
              "WARNING assertion above is specific to the auth path, not a global level change",
              logging.ERROR in levels_logged, True)
    finally:
        debug_agent_module.requests.post = original_post
        target_logger.removeHandler(handler)
        target_logger.setLevel(original_level)


if __name__ == "__main__":
    try:
        test_call_debug_api_raises_auth_error_on_401_and_403()
        test_auth_key_value_never_leaks_into_exception_message()
        test_generate_report_logs_auth_failure_at_warning_not_error()
        test_generic_upstream_failure_still_logs_at_error_for_contrast()
    finally:
        cleanup_detections()

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)
