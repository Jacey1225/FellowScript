"""
Proves the watchdog's application-level error-signal regex correctly flags
error-shaped lines from each of the five log-group formats it actually
polls, and does NOT false-positive on normal traffic -- a false positive
here means noise flooding the admin feed forever; a false negative means a
real production error silently never gets detected.

Line shapes are taken from the intake spec's addendum (real `uvicorn.log`
tail from the production box) and this app's own logging setup
(`logging.basicConfig(format="%(asctime)s [%(name)s] %(levelname)s -
%(message)s")` in main.py), plus documented uvicorn/nginx line shapes for
the other four log groups the watchdog polls.

Run:  cd api && ../.venv/bin/python tests/test_watchdog_error_signal_regex.py
"""

import _pathfix  # noqa: F401

import sys
from datetime import timezone

from backend.monitoring.watchdog import _match_error_signal, _parse_event_timestamp

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


CASES = [
    # (description, log line, expected matched_signal or None)

    # /fellowscript/app -- this app's own logging.basicConfig format.
    ("app: basicConfig ERROR line",
     "2026-08-11 22:43:48,123 [routes.monitoring] ERROR - Failed to fetch detection: connection refused",
     "error_level"),
    ("app: basicConfig CRITICAL line",
     # 2026-08-15 structural-fix follow-up: this line's logger name
     # ("routes.monitoring") is deliberately NOT one of watchdog.py's
     # _SELF_LOGGER_NAMES -- a CRITICAL line whose logger *is* self-
     # originated (e.g. "[backend.monitoring.watchdog]") is now, by design,
     # excluded regardless of level (see
     # test_watchdog_self_exclusion_and_forgery.py), so this case keeps
     # testing the "critical" pattern itself rather than colliding with
     # that intentional behavior change.
     "2026-08-11 22:43:48,123 [routes.monitoring] CRITICAL - disk full, cannot persist detection",
     "critical"),
    ("app: self-originated CRITICAL line is excluded regardless of severity "
     "(self-exclusion is logger-based, not level-based -- see watchdog.py's "
     "_SELF_EXCLUSION_RE docstring)",
     "2026-08-11 22:43:48,123 [backend.monitoring.watchdog] CRITICAL - disk full, cannot persist detection",
     None),
    ("app: basicConfig INFO line -- must NOT false-positive",
     "2026-08-11 22:43:48,123 [routes.monitoring] INFO - Handled GET /monitoring/detections",
     None),
    ("app: basicConfig WARNING line -- must NOT false-positive",
     "2026-08-11 22:43:48,123 [backend.monitoring.watchdog] WARNING - Context query slow (2.1s)",
     None),
    ("app: real production evidence from intake spec addendum (Errno 98 bind failure)",
     "2026-08-11 22:43:48,123 [main] ERROR - Failed to bind: [Errno 98] Address already in use",
     "error_level"),  # ERROR check fires before errno in pattern order -- both would match, error_level wins
    ("app: bare errno line with no ERROR/CRITICAL wrapper still flags via errno pattern",
     "OSError: [Errno 98] Address already in use",
     "errno"),
    ("app: lowercase 'errors' inside otherwise-normal text must NOT match (\\bERROR\\b is case-sensitive)",
     "2026-08-11 22:43:48,123 [routes.notes] INFO - User acknowledged: no errors found, all clear",
     None),
    ("app: Python traceback header line",
     "Traceback (most recent call last):",
     "traceback"),
    ("app: uvicorn's own ERROR: prefix (not basicConfig format)",
     "ERROR:    Exception in ASGI application",
     "error_level"),

    # db-write-failure-signaling workflow, step 1: db.py's DBManager.
    # insertion/.update/.delete now log a dedicated DB_WRITE_FAILURE marker
    # (via logger.error(...)) on every caught sql.Error, matching the
    # CLIENT_DECODE_FAILURE precedent above -- checked before the generic
    # "error_level" pattern so DB write failures are separately queryable.
    ("app: DB_WRITE_FAILURE marker (db.py's own [%(levelname)s] format, insert)",
     "2026-08-31 13:49:21 [ERROR] DB_WRITE_FAILURE op=insert table=sessions "
     "error=insert or update on table \"sessions\" violates foreign key constraint",
     "db_write_failure"),
    ("app: DB_WRITE_FAILURE marker still wins over the generic ERROR check "
     "(both would match; db_write_failure is checked first, same ordering "
     "guarantee as client_decode_failure)",
     "2026-08-31 13:49:21 [ERROR] DB_WRITE_FAILURE op=update table=users error=x",
     "db_write_failure"),
    ("app: a plain ERROR line that happens to mention 'write failure' in "
     "prose, but without the literal DB_WRITE_FAILURE marker, must NOT "
     "false-positive as db_write_failure specifically (still flags as "
     "error_level, just not the dedicated marker)",
     "2026-08-11 22:43:48,123 [routes.notes] ERROR - a write failure occurred saving the note",
     "error_level"),

    # /fellowscript/nginx/error
    ("nginx error log: [error] severity tag",
     "2026/08/11 22:43:48 [error] 12345#12345: *1 connect() failed (111: Connection refused) "
     "while connecting to upstream, client: 1.2.3.4, server: fellowscript.com",
     "nginx_severity_tag"),
    ("nginx error log: [crit] severity tag",
     "2026/08/11 22:43:48 [crit] 12345#12345: *1 SSL_do_handshake() failed",
     "nginx_severity_tag"),
    ("nginx error log: [notice] severity -- must NOT false-positive",
     "2026/08/11 22:43:48 [notice] 12345#12345: signal process started",
     None),

    # /fellowscript/nginx/access
    ("nginx access log: 502 bad gateway",
     '127.0.0.1 - - [11/Aug/2026:22:43:48 +0000] "GET /api/health HTTP/1.1" 502 0 "-" "curl/7.81.0"',
     "http_5xx"),
    ("nginx access log: 503 service unavailable",
     '127.0.0.1 - - [11/Aug/2026:22:43:48 +0000] "POST /api/notes HTTP/1.1" 503 12 "-" "FellowScript-iOS/1.0"',
     "http_5xx"),
    ("nginx access log: 200 OK -- must NOT false-positive",
     '127.0.0.1 - - [11/Aug/2026:22:43:48 +0000] "GET /api/health HTTP/1.1" 200 15 "-" "curl/7.81.0"',
     None),
    ("nginx access log: 404 -- must NOT false-positive (only 5xx is a server-side error signal)",
     '127.0.0.1 - - [11/Aug/2026:22:43:48 +0000] "GET /api/nope HTTP/1.1" 404 9 "-" "curl/7.81.0"',
     None),

    # /fellowscript/syslog, /fellowscript/auth -- normal lines must not false-positive
    ("syslog: normal systemd unit start -- must NOT false-positive",
     "Aug 11 22:43:48 ip-10-0-0-1 systemd[1]: Started Session 42 of user ubuntu.",
     None),
    ("auth log: normal accepted ssh login -- must NOT false-positive",
     "Aug 11 22:43:48 ip-10-0-0-1 sshd[1234]: Accepted publickey for ubuntu from 1.2.3.4 port 51000 ssh2",
     None),

    # Empty / missing message must not crash.
    ("empty message string", "", None),
]


def test_match_error_signal():
    print("\n── _match_error_signal ──────────────────────────────────────")
    for description, line, expected in CASES:
        check(description, _match_error_signal(line), expected)


def test_match_error_signal_none_message():
    print("\n── _match_error_signal(None) does not crash ────────────────")
    check("None message returns None instead of raising", _match_error_signal(None), None)


def test_parse_event_timestamp():
    print("\n── _parse_event_timestamp ───────────────────────────────────")
    parsed = _parse_event_timestamp({"@timestamp": "2026-08-11 10:00:00.123", "@message": "x"})
    check("parses real CloudWatch Logs Insights @timestamp shape", parsed is not None, True)
    if parsed is not None:
        check("parsed timestamp is tz-aware UTC", parsed.tzinfo, timezone.utc)
        check("parsed timestamp fields correct",
              (parsed.year, parsed.month, parsed.day, parsed.hour, parsed.minute, parsed.second),
              (2026, 8, 11, 10, 0, 0))

    unparseable = _parse_event_timestamp({"@timestamp": "not-a-real-timestamp", "@message": "x"})
    check("unrecognized timestamp format returns None instead of raising", unparseable, None)

    missing = _parse_event_timestamp({"@message": "x"})
    check("missing @timestamp key returns None instead of raising", missing, None)


if __name__ == "__main__":
    test_match_error_signal()
    test_match_error_signal_none_message()
    test_parse_event_timestamp()

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)
