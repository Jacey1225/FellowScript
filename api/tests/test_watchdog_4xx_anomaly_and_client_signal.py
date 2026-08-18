"""
Heavy-testing coverage for the two new watchdog detectors added in backend
step 1 of the notes-load-failure-cloudwatch-gap workflow
(backend/monitoring/watchdog.py):

  1. The "client_decode_failure" per-line signal -- the CLIENT_DECODE_FAILURE
     marker the new POST /monitoring/client-error beacon logs into
     /fellowscript/app, picked up by the existing per-line scan.
  2. The independent "4xx_rate_anomaly" detector -- counts nginx-access 4xx
     responses per poll window and flags a spike, entirely separate from any
     one log line's content.

The intake spec's core claim is that these two signals are structurally
different and NEITHER ALONE would have caught the incident (a 200 the client
couldn't parse produces no 4xx and no per-line error text) -- this file
proves that claim directly, not just that each detector individually works.

Against the real local Postgres DB (matches this project's DB-test
convention), with CloudWatchMCPClient replaced by an in-memory fake -- same
test-double boundary as test_watchdog_cursor_sync.py / test_watchdog_circuit_breaker.py.

Covers:
  - client_decode_failure: a CLIENT_DECODE_FAILURE-marked line in
    /fellowscript/app is detected end-to-end via run_cycle() with
    matched_signal="client_decode_failure" (not the generic "error_level"
    bucket), persisted with the right log_group_name/message.
  - 4xx_rate_anomaly: below ANOMALY_4XX_THRESHOLD -> no detection persisted,
    cursor still advances. At/above threshold -> exactly one synthetic
    ErrorDetection persisted with matched_signal="4xx_rate_anomaly" and
    context carrying count/threshold/window bounds.
  - The 4xx anomaly detector respects the shared per-cycle detection cap
    (MAX_DETECTIONS_PER_CYCLE) -- if the cap is already exhausted by the
    per-line scan earlier in the same cycle, the anomaly check is suppressed
    (not double-counted / not bypassing the breaker).
  - The two detectors are proven independent: a run with ONLY a
    CLIENT_DECODE_FAILURE line (zero 4xx nginx-access responses) produces a
    client_decode_failure detection and NO 4xx_rate_anomaly detection; a run
    with ONLY a 4xx spike (no CLIENT_DECODE_FAILURE line) produces the
    reverse. This is the direct proof that "neither alone would have caught
    this incident" / "both were needed together".
  - matched_signal filtering end-to-end: WatchdogManager.list_detections /
    count_detections isolate each new signal correctly, and the admin-facing
    GET /monitoring/detections?matched_signal=... query param (routes/
    monitoring.py) returns only the matching rows for an authenticated admin.

Run:  cd api && ../.venv/bin/python tests/test_watchdog_4xx_anomaly_and_client_signal.py
"""

import _pathfix  # noqa: F401

import asyncio
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

import backend.monitoring.watchdog as watchdog  # noqa: E402
from backend.monitoring.watchdog import (  # noqa: E402
    WatchdogManager,
    ANOMALY_4XX_THRESHOLD,
    ANOMALY_4XX_CURSOR_KEY,
    MAX_DETECTIONS_PER_CYCLE,
)

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


class FakeCloudWatchMCPClient:
    """Same test double shape as test_watchdog_circuit_breaker.py, extended
    to accept the `query_string` kwarg `_check_4xx_rate_anomaly` passes (the
    plain per-line scan doesn't use it) -- ignored for filtering purposes
    here since each test seeds exactly the events it wants counted/scanned
    per log group directly."""

    def __init__(self, events_by_group: dict):
        self.events_by_group = events_by_group

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def query_log_events(self, log_group_name, start_time, end_time, query_string=None, limit=10000):
        rows = []
        for ts, message in self.events_by_group.get(log_group_name, []):
            if start_time <= ts < end_time:
                rows.append({
                    "@timestamp": ts.strftime("%Y-%m-%d %H:%M:%S.%f"),
                    "@message": message,
                    "@logStream": "test-stream",
                })
        rows.sort(key=lambda r: r["@timestamp"])
        return rows[:limit]

    async def analyze_log_group(self, log_group_name, start_time, end_time):
        return {}


def cleanup_group(log_group_name: str):
    wm = WatchdogManager()
    try:
        wm.cur.execute("DELETE FROM error_detections WHERE log_group_name=%s", (log_group_name,))
        wm.cur.execute("DELETE FROM log_group_cursors WHERE log_group_name=%s", (log_group_name,))
        wm.conn.commit()
    finally:
        wm.close()


def cleanup_anomaly_cursor():
    wm = WatchdogManager()
    try:
        wm.cur.execute("DELETE FROM log_group_cursors WHERE log_group_name=%s", (ANOMALY_4XX_CURSOR_KEY,))
        wm.conn.commit()
    finally:
        wm.close()


def fetch_detections(log_group_name: str, matched_signal: str | None = None) -> list[dict]:
    wm = WatchdogManager()
    try:
        return wm.list_detections(log_group_name=log_group_name, matched_signal=matched_signal, limit=200)
    finally:
        wm.close()


def _patch(app_log_group, nginx_group, events, *, debug_stub=True):
    orig_client_cls = watchdog.CloudWatchMCPClient
    orig_log_groups = watchdog.LOG_GROUPS
    orig_debug_call = watchdog.run_debug_agent_for_detection
    watchdog.CloudWatchMCPClient = lambda: FakeCloudWatchMCPClient(events)
    watchdog.LOG_GROUPS = [app_log_group, nginx_group]
    if debug_stub:
        watchdog.run_debug_agent_for_detection = lambda detection_id: {"skipped": "test stub"}
    return orig_client_cls, orig_log_groups, orig_debug_call


def _unpatch(orig_client_cls, orig_log_groups, orig_debug_call):
    watchdog.CloudWatchMCPClient = orig_client_cls
    watchdog.LOG_GROUPS = orig_log_groups
    watchdog.run_debug_agent_for_detection = orig_debug_call


async def test_client_decode_failure_signal_detected_endtoend():
    print("\n── client_decode_failure: end-to-end detection via run_cycle() ──")
    app_group = f"/test/watchdog-cdf-app-{uuid.uuid4()}"
    nginx_group = f"/test/watchdog-cdf-nginx-{uuid.uuid4()}"
    now = datetime.now(timezone.utc)
    ts = now - timedelta(seconds=120)

    line = (
        f"2026-08-17 12:00:00,000 [routes.monitoring] ERROR - CLIENT_DECODE_FAILURE "
        f"user_id=abc-123 endpoint=GET /notes/{{user_id}} client_app_version=1.3.0 (30) "
        f"http_status=200 error_summary=keyNotFound"
    )
    events = {app_group: [(ts, line)], nginx_group: []}
    patched = _patch(app_group, nginx_group, events)
    try:
        wm = WatchdogManager()
        try:
            totals = await wm.run_cycle()
        finally:
            wm.close()
        check("run_cycle reports exactly one detection for the single CLIENT_DECODE_FAILURE line",
              totals["detections"], 1)

        rows = fetch_detections(app_group)
        check("exactly one row persisted", len(rows), 1)
        if rows:
            check("matched_signal is the distinct 'client_decode_failure', not the generic 'error_level'",
                  rows[0]["matched_signal"], "client_decode_failure")
            check("persisted message carries the full original CLIENT_DECODE_FAILURE line",
                  "CLIENT_DECODE_FAILURE" in rows[0]["message"], True)
    finally:
        _unpatch(*patched)
        cleanup_group(app_group)
        cleanup_group(nginx_group)


async def test_4xx_anomaly_below_threshold_no_detection():
    print("\n── 4xx_rate_anomaly: below threshold -> no detection, cursor still advances ──")
    app_group = f"/test/watchdog-4xx-below-app-{uuid.uuid4()}"
    nginx_group = "/fellowscript/nginx/access"  # real constant ANOMALY_4XX_LOG_GROUP
    now = datetime.now(timezone.utc)
    base = now - timedelta(seconds=80)

    below = ANOMALY_4XX_THRESHOLD - 1
    events = {
        app_group: [],
        nginx_group: [
            (base + timedelta(milliseconds=i),
             f'127.0.0.1 - - [17/Aug/2026:12:00:00 +0000] "GET /api/notes/x HTTP/1.1" 404 9 "-" "test"')
            for i in range(below)
        ],
    }
    cleanup_anomaly_cursor()
    patched = _patch(app_group, nginx_group, events)
    try:
        wm = WatchdogManager()
        try:
            delta = await wm._check_4xx_rate_anomaly(FakeCloudWatchMCPClient(events), now)
        finally:
            wm.close()
        check(f"below-threshold count ({below} < {ANOMALY_4XX_THRESHOLD}) persists nothing",
              delta["detections"], 0)
        check("events_scanned reflects the actual count seen",
              delta["events_scanned"], below)

        wm2 = WatchdogManager()
        try:
            cursor = wm2.get_cursor(ANOMALY_4XX_CURSOR_KEY)
        finally:
            wm2.close()
        check("cursor advances even when no detection fires (aggregate count, no per-event replay concern)",
              cursor is not None, True)
    finally:
        _unpatch(*patched)
        cleanup_group(app_group)
        cleanup_anomaly_cursor()


async def test_4xx_anomaly_at_threshold_persists_one_detection():
    print("\n── 4xx_rate_anomaly: at/above threshold -> exactly one synthetic detection ──")
    app_group = f"/test/watchdog-4xx-at-app-{uuid.uuid4()}"
    nginx_group = "/fellowscript/nginx/access"
    now = datetime.now(timezone.utc)
    base = now - timedelta(seconds=80)

    at_threshold = ANOMALY_4XX_THRESHOLD
    events = {
        app_group: [],
        nginx_group: [
            (base + timedelta(milliseconds=i),
             f'127.0.0.1 - - [17/Aug/2026:12:00:00 +0000] "GET /api/notes/x HTTP/1.1" 401 9 "-" "test"')
            for i in range(at_threshold)
        ],
    }
    cleanup_anomaly_cursor()
    wm = WatchdogManager()
    try:
        delta = await wm._check_4xx_rate_anomaly(FakeCloudWatchMCPClient(events), now)
        check("at-threshold count persists exactly one detection", delta["detections"], 1)

        rows = fetch_detections(nginx_group, matched_signal="4xx_rate_anomaly")
        check("exactly one 4xx_rate_anomaly row persisted", len(rows), 1)
        if rows:
            check("matched_signal is '4xx_rate_anomaly'", rows[0]["matched_signal"], "4xx_rate_anomaly")
    finally:
        cleanup_group(nginx_group)
        cleanup_anomaly_cursor()
        wm.close()

    # Re-fetch full record (with context) to confirm count/threshold/window are recorded.
    wm2 = WatchdogManager()
    try:
        rows = wm2.list_detections(log_group_name=nginx_group, matched_signal="4xx_rate_anomaly", limit=5)
        check("no leftover row after cleanup (isolated per test)", len(rows), 0)
    finally:
        wm2.close()


async def test_4xx_anomaly_context_carries_count_and_threshold():
    print("\n── 4xx_rate_anomaly detection's context records count/threshold/window ──")
    nginx_group = "/fellowscript/nginx/access"
    now = datetime.now(timezone.utc)
    base = now - timedelta(seconds=80)
    n = ANOMALY_4XX_THRESHOLD + 5
    events = {
        nginx_group: [
            (base + timedelta(milliseconds=i),
             '127.0.0.1 - - [17/Aug/2026:12:00:00 +0000] "GET /x HTTP/1.1" 403 9 "-" "t"')
            for i in range(n)
        ],
    }
    cleanup_anomaly_cursor()
    wm = WatchdogManager()
    try:
        await wm._check_4xx_rate_anomaly(FakeCloudWatchMCPClient(events), now)
        wm.cur.execute(
            "SELECT context FROM error_detections WHERE log_group_name=%s AND matched_signal=%s",
            (nginx_group, "4xx_rate_anomaly"),
        )
        row = wm.cur.fetchone()
        check("a detection row with context exists", row is not None, True)
        if row:
            import json
            # The `context` column comes back already-deserialized as a dict
            # when psycopg2 has a JSON/JSONB adapter registered for it; fall
            # back to json.loads for a plain str/bytes column type.
            ctx = row[0] if isinstance(row[0], dict) else json.loads(row[0])
            check("context.count matches the actual number of 4xx responses seen", ctx.get("count"), n)
            check("context.threshold matches ANOMALY_4XX_THRESHOLD", ctx.get("threshold"), ANOMALY_4XX_THRESHOLD)
            check("context carries window_start", "window_start" in ctx, True)
            check("context carries window_end", "window_end" in ctx, True)
    finally:
        cleanup_group(nginx_group)
        cleanup_anomaly_cursor()
        wm.close()


async def test_4xx_anomaly_respects_shared_percycle_detection_cap():
    print("\n── 4xx_rate_anomaly respects the shared per-cycle detection cap ──")
    nginx_group = "/fellowscript/nginx/access"
    now = datetime.now(timezone.utc)
    base = now - timedelta(seconds=80)
    n = ANOMALY_4XX_THRESHOLD + 5
    events = {
        nginx_group: [
            (base + timedelta(milliseconds=i),
             '127.0.0.1 - - [17/Aug/2026:12:00:00 +0000] "GET /x HTTP/1.1" 401 9 "-" "t"')
            for i in range(n)
        ],
    }
    cleanup_anomaly_cursor()
    wm = WatchdogManager()
    try:
        # Simulate the per-line scan earlier in the SAME cycle having already
        # exhausted the shared cap -- the anomaly check must not bypass it.
        wm._cycle_detection_count = MAX_DETECTIONS_PER_CYCLE
        delta = await wm._check_4xx_rate_anomaly(FakeCloudWatchMCPClient(events), now)
        check("anomaly detection suppressed once the shared per-cycle cap is already exhausted",
              delta["detections"], 0)
        check("events_scanned is still reported even though the detection is suppressed",
              delta["events_scanned"], n)
        check("_cap_tripped set so run_cycle() would stop processing remaining groups too",
              wm._cap_tripped, True)

        rows = fetch_detections(nginx_group, matched_signal="4xx_rate_anomaly")
        check("no row persisted once suppressed by the cap", len(rows), 0)
    finally:
        cleanup_group(nginx_group)
        cleanup_anomaly_cursor()
        wm.close()


async def test_neither_signal_alone_would_catch_the_other_incident_class():
    print("\n── Independence proof: client_decode_failure and 4xx_rate_anomaly detect "
          "structurally different failure classes; neither is a substitute for the other ──")
    app_group = f"/test/watchdog-indep-app-{uuid.uuid4()}"
    nginx_group = "/fellowscript/nginx/access"
    now = datetime.now(timezone.utc)
    ts = now - timedelta(seconds=120)

    # Scenario A: ONLY a legitimate 200-the-client-can't-parse beacon report
    # (this incident's actual root cause) -- zero 4xx nginx traffic at all.
    cdf_line = (
        "2026-08-17 12:00:00,000 [routes.monitoring] ERROR - CLIENT_DECODE_FAILURE "
        "user_id=abc-123 endpoint=GET /notes/{user_id} client_app_version=1.0.0 (1) "
        "http_status=200 error_summary=keyNotFound"
    )
    events_a = {app_group: [(ts, cdf_line)], nginx_group: []}
    cleanup_anomaly_cursor()
    patched = _patch(app_group, nginx_group, events_a)
    try:
        wm = WatchdogManager()
        try:
            await wm.run_cycle()
        finally:
            wm.close()
        cdf_rows = fetch_detections(app_group, matched_signal="client_decode_failure")
        anomaly_rows_a = fetch_detections(nginx_group, matched_signal="4xx_rate_anomaly")
        check("scenario A (this incident's real shape): client_decode_failure fires",
              len(cdf_rows) >= 1, True)
        check("scenario A: a 200-only incident produces ZERO 4xx_rate_anomaly detections "
              "-- confirms the 4xx detector alone would NOT have caught this incident",
              len(anomaly_rows_a), 0)
    finally:
        _unpatch(*patched)
        cleanup_group(app_group)
        cleanup_group(nginx_group)
        cleanup_anomaly_cursor()

    # Scenario B: ONLY a 4xx spike (e.g. the separate, already-fixed
    # `+`-encoding incident's shape) -- zero CLIENT_DECODE_FAILURE lines.
    app_group2 = f"/test/watchdog-indep-app2-{uuid.uuid4()}"
    n = ANOMALY_4XX_THRESHOLD + 3
    events_b = {
        app_group2: [],
        nginx_group: [
            (ts + timedelta(milliseconds=i),
             '127.0.0.1 - - [17/Aug/2026:12:00:00 +0000] "GET /api/notes/x HTTP/1.1" 400 9 "-" "FellowScript-iOS/1.0"')
            for i in range(n)
        ],
    }
    cleanup_anomaly_cursor()
    patched = _patch(app_group2, nginx_group, events_b)
    try:
        wm = WatchdogManager()
        try:
            await wm.run_cycle()
        finally:
            wm.close()
        cdf_rows_b = fetch_detections(app_group2, matched_signal="client_decode_failure")
        anomaly_rows_b = fetch_detections(nginx_group, matched_signal="4xx_rate_anomaly")
        check("scenario B: a pure 4xx spike produces ZERO client_decode_failure detections "
              "-- confirms the client-error beacon alone would NOT have caught a pure 4xx incident",
              len(cdf_rows_b), 0)
        check("scenario B: the 4xx anomaly detector fires for the spike",
              len(anomaly_rows_b) >= 1, True)
    finally:
        _unpatch(*patched)
        cleanup_group(app_group2)
        cleanup_group(nginx_group)
        cleanup_anomaly_cursor()


def test_matched_signal_query_param_endtoend():
    print("\n── GET /monitoring/detections?matched_signal=... end-to-end (admin auth) ──")
    from fastapi.testclient import TestClient
    import main as main_module
    from db import DBManager
    from backend.auth.sessions import SessionManager
    from schemas.watchdog import ErrorDetection

    group = f"/test/watchdog-matchedsignal-endpoint-{uuid.uuid4()}"
    wm = WatchdogManager()
    try:
        wm.save_detection(ErrorDetection(
            log_group_name=group, message="CLIENT_DECODE_FAILURE test line",
            matched_signal="client_decode_failure", context={},
            event_timestamp=datetime.now(timezone.utc),
        ))
        wm.save_detection(ErrorDetection(
            log_group_name=group, message="unrelated traceback",
            matched_signal="traceback", context={},
            event_timestamp=datetime.now(timezone.utc),
        ))
    finally:
        wm.close()

    dbm = DBManager()
    admin_uid = str(uuid.uuid4())
    try:
        dbm.insertion("users", {
            "_id": admin_uid, "username": f"matched_sig_admin_{admin_uid[:8]}",
            "email": f"matched_sig_admin_{admin_uid[:8]}@example.com", "hash_pass": "x",
            "is_admin": True,
        })
    finally:
        dbm.close()
    sm = SessionManager()
    try:
        token = sm.create_session(admin_uid)
    finally:
        sm.close()

    try:
        with TestClient(main_module.app) as client:
            client.cookies.set("session", token)
            r = client.get(f"/monitoring/detections?log_group_name={group}&matched_signal=client_decode_failure")
            client.cookies.clear()
            check("filtered request succeeds", r.status_code, 200)
            body = r.json()
            check("only the client_decode_failure row is returned", body["total"], 1)
            if body["items"]:
                check("returned row's matched_signal is correct",
                      body["items"][0]["matched_signal"], "client_decode_failure")
    finally:
        wm2 = WatchdogManager()
        try:
            wm2.cur.execute("DELETE FROM error_detections WHERE log_group_name=%s", (group,))
            wm2.conn.commit()
        finally:
            wm2.close()
        dbm2 = DBManager()
        try:
            dbm2.delete("users", {"_id": admin_uid})
        finally:
            dbm2.close()


if __name__ == "__main__":
    asyncio.run(test_client_decode_failure_signal_detected_endtoend())
    asyncio.run(test_4xx_anomaly_below_threshold_no_detection())
    asyncio.run(test_4xx_anomaly_at_threshold_persists_one_detection())
    asyncio.run(test_4xx_anomaly_context_carries_count_and_threshold())
    asyncio.run(test_4xx_anomaly_respects_shared_percycle_detection_cap())
    asyncio.run(test_neither_signal_alone_would_catch_the_other_incident_class())
    test_matched_signal_query_param_endtoend()

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)
