"""
Proves the structural fix at the heart of the 2026-08-14 OOM incident: the
watchdog's self-exclusion filter (`_is_self_originated` / `_SELF_EXCLUSION_RE`
in backend/monitoring/watchdog.py) actually breaks the self-amplifying
feedback loop, and does so *securely* -- an attacker who can influence logged
message text cannot forge the exclusion to evade detection (the log-forging
vector security.json step 5 found and fixed by anchoring the regex to the
first bracket pair at the start of the line).

Covers:
  - Lines the watchdog/debug-agent/scheduler-job's own logging would
    actually produce (matching main.py's `logging.basicConfig` format,
    "%(asctime)s [%(name)s] %(levelname)s - %(message)s") are excluded from
    detection, for all three self-logger names.
  - A genuine application ERROR line (different logger name) is still
    detected normally -- the filter is narrow, not a blanket "no ERROR ever
    matches" regression.
  - SECURITY: an attacker-influenced message that merely *contains* one of
    the excluded logger names as a substring later in the line (not in the
    real name field CloudWatch/the logging formatter emits first) is NOT
    excluded -- proves the anchor-to-first-bracket fix actually holds, not
    just an unanchored substring search that a log-forging attacker could
    exploit to evade detection.
  - A line with no bracket at all, or an unrelated bracketed prefix, is
    unaffected either way.

Run:  cd api && ../.venv/bin/python tests/test_watchdog_self_exclusion_and_forgery.py
"""

import _pathfix  # noqa: F401

import sys

from backend.monitoring.watchdog import (
    _is_self_originated,
    _match_error_signal,
    _SELF_LOGGER_NAMES,
)

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


def test_self_logger_names_are_the_expected_three():
    print("\n── _SELF_LOGGER_NAMES covers watchdog, debug_agent, scheduler's child logger ──")
    check("exactly the three names this workflow's structural fix targets",
          set(_SELF_LOGGER_NAMES),
          {"backend.monitoring.watchdog", "backend.monitoring.debug_agent",
           "backend.interactions.scheduler.watchdog"})


def test_self_originated_lines_excluded():
    print("\n── Real self-originated failure lines are excluded from detection ──")
    lines = [
        "2026-08-15 10:00:00,000 [backend.monitoring.watchdog] ERROR - "
        "Watchdog poll failed for /fellowscript/app: simulated failure",
        "2026-08-15 10:00:00,000 [backend.monitoring.debug_agent] ERROR - "
        "Debug agent OpenRouter call failed for detection abc123: 500",
        "2026-08-15 10:00:00,000 [backend.interactions.scheduler.watchdog] ERROR - "
        "CloudWatch watchdog cycle failed: connection refused",
    ]
    for line in lines:
        check(f"_is_self_originated True for: {line[:70]}...", _is_self_originated(line), True)
        check(f"_match_error_signal returns None (excluded) for: {line[:70]}...",
              _match_error_signal(line), None)


def test_unrelated_real_error_still_detected():
    print("\n── A genuine, unrelated application error is still detected normally ──")
    line = "2026-08-15 10:00:00,000 [routes.notes] ERROR - Failed to save note: connection refused"
    check("_is_self_originated False for an unrelated logger", _is_self_originated(line), False)
    check("_match_error_signal still flags it", _match_error_signal(line), "error_level")


def test_log_forging_cannot_evade_detection():
    print("\n── SECURITY: an attacker cannot forge the exclusion via message content ──")
    # A genuine, unrelated error whose *message* happens to contain the
    # literal excluded-name substring later in the line (e.g. an echoed
    # exception message, a user-supplied string) -- this must NOT be
    # excluded, since the real `[%(name)s)]` field the logging formatter
    # emits is `routes.notes`, not one of the self-logger names. Excluding
    # this would be exactly the detection-evasion vector security.json's
    # step 5 review found and fixed.
    forged = (
        "2026-08-15 10:00:00,000 [routes.notes] ERROR - ValueError: malformed "
        "payload containing the literal text [backend.monitoring.watchdog] "
        "injected by request body"
    )
    check("forged substring deeper in the line does NOT trigger self-exclusion",
          _is_self_originated(forged), False)
    check("forged line is still detected as a real error (not evaded)",
          _match_error_signal(forged), "error_level")

    for name in _SELF_LOGGER_NAMES:
        forged2 = f"2026-08-15 10:00:00,000 [routes.agent] ERROR - echoing user input: [{name}] hi"
        check(f"forged substring for {name!r} outside the first-bracket field is not excluded",
              _is_self_originated(forged2), False)


def test_no_bracket_or_unrelated_bracket_unaffected():
    print("\n── Lines with no bracket, or an unrelated first bracket, are unaffected ──")
    check("no bracket at all -- not self-originated",
          _is_self_originated("plain traceback line with no logger field ERROR here"), False)
    check("unrelated first-bracket logger -- not self-originated",
          _is_self_originated("2026-08-15 10:00:00,000 [backend.subscription.subscriptions] "
                               "ERROR - webhook processing failed"), False)


if __name__ == "__main__":
    test_self_logger_names_are_the_expected_three()
    test_self_originated_lines_excluded()
    test_unrelated_real_error_still_detected()
    test_log_forging_cannot_evade_detection()
    test_no_bracket_or_unrelated_bracket_unaffected()

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)
