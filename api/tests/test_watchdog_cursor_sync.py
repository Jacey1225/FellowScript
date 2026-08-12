"""
Proves the CloudWatch watchdog's per-log-group cursor never re-processes or
skips events across consecutive polls -- the explicit "synchronized
watchdog" requirement from the cloudwatch-error-remediation intake spec
(architecture.json step 3).

Two scenarios, against the real local Postgres DB (log_group_cursors /
error_detections), with the read-only cloudwatch-mcp-server boundary
(CloudWatchMCPClient) replaced by an in-memory fake -- the real MCP server
is not reachable from this session (see backend.json step 3's own
verification notes), so this is the correct place to draw the test double.

1. test_poll_one_group_no_reprocess_no_skip -- calls the exact cursor-window
   algorithm (`WatchdogManager._poll_one_group`) twice with explicit,
   controlled window boundaries (no reliance on wall-clock timing), proving
   an event sitting exactly on the window boundary between two polls is
   caught exactly once -- never twice, never zero times.

2. test_run_cycle_dedup_and_cross_group_isolation -- calls the real,
   public `run_cycle()` entry point (the one the scheduler actually
   invokes) twice back-to-back against two log groups, one of which always
   fails its MCP query. Proves: (a) the failing group's cursor is left
   untouched and does not corrupt/desync the healthy group's cursor
   ("no cross-log-group drift"), and (b) the healthy group's single crafted
   event is detected exactly once across both calls, never re-detected on
   the immediately-following cycle.

Run:  cd api && ../.venv/bin/python tests/test_watchdog_cursor_sync.py
"""

import _pathfix  # noqa: F401

import asyncio
import sys
import uuid
from datetime import datetime, timedelta, timezone

import backend.monitoring.watchdog as watchdog
from backend.monitoring.cloudwatch_mcp_client import CloudWatchMCPError
from backend.monitoring.watchdog import WatchdogManager

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


class FakeCloudWatchMCPClient:
    """Stands in for the real (unreachable-in-this-session) cloudwatch-mcp-
    server. Filters its canned events by [start_time, end_time) -- matching
    real CloudWatch Logs Insights' inclusive-start/exclusive-end semantics,
    which is exactly what makes back-to-back [cursor, window_end) polls
    dedup correctly without an explicit "already seen" set.
    """

    def __init__(self, events_by_group: dict, fail_groups: frozenset = frozenset()):
        self.events_by_group = events_by_group
        self.fail_groups = fail_groups

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def query_log_events(self, log_group_name, start_time, end_time, limit=10000):
        if log_group_name in self.fail_groups:
            raise CloudWatchMCPError("simulated MCP failure for %s" % log_group_name)
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


def messages_for(log_group_name: str) -> set:
    wm = WatchdogManager()
    try:
        wm.cur.execute(
            "SELECT message FROM error_detections WHERE log_group_name=%s", (log_group_name,)
        )
        return {row[0] for row in wm.cur.fetchall()}
    finally:
        wm.close()


# ── Scenario 1: precise boundary math via _poll_one_group ──────────────────

async def test_poll_one_group_no_reprocess_no_skip():
    print("\n── WatchdogManager._poll_one_group: boundary dedup ──────────")
    log_group = f"/test/watchdog-boundary-{uuid.uuid4()}"

    t1 = datetime(2025, 6, 1, 12, 0, 0, tzinfo=timezone.utc)
    t2 = t1 + timedelta(seconds=200)

    events = {
        log_group: [
            (t1 - timedelta(seconds=500), "2025-06-01 11:51:40,000 [test] ERROR - boom-early"),
            (t1 - timedelta(microseconds=1), "2025-06-01 11:59:59,999999 [test] ERROR - boom-just-before-boundary"),
            (t1, "2025-06-01 12:00:00,000000 [test] ERROR - boom-at-boundary"),
            (t1 + timedelta(seconds=20), "2025-06-01 12:00:20,000000 [test] INFO - all good, nothing to see"),
            (t1 + timedelta(seconds=50), "2025-06-01 12:00:50,000000 [test] ERROR - boom-late"),
            (t1 - timedelta(seconds=1000), "2025-06-01 11:43:20,000000 [test] ERROR - boom-too-old-for-lookback"),
        ]
    }
    client = FakeCloudWatchMCPClient(events)
    wm = WatchdogManager()
    try:
        cycle1 = await wm._poll_one_group(client, log_group, t1)
        cycle2 = await wm._poll_one_group(client, log_group, t2)

        check("cycle1 scans only in-window events (excludes too-old + at/after t1)",
              cycle1["events_scanned"], 2)
        check("cycle1 detects both ERROR lines in its window",
              cycle1["detections"], 2)
        check("cycle2 scans the 3 events landing in [t1, t2)",
              cycle2["events_scanned"], 3)
        check("cycle2 detects the 2 ERROR lines in its window (INFO line excluded)",
              cycle2["detections"], 2)

        seen = messages_for(log_group)
        check("boom-early detected exactly once (present)", "boom-early" in " ".join(seen), True)
        check("boom-just-before-boundary detected in cycle1, not re-detected in cycle2",
              sum("boom-just-before-boundary" in m for m in seen), 1)
        check("boom-at-boundary detected exactly once, in cycle2 (not cycle1 -- end is exclusive)",
              sum("boom-at-boundary" in m for m in seen), 1)
        check("boom-late detected exactly once", sum("boom-late" in m for m in seen), 1)
        check("boom-too-old-for-lookback never detected (outside initial lookback window)",
              any("too-old" in m for m in seen), False)
        check("no INFO line ever produces a detection",
              any("all good" in m for m in seen), False)
        check("total distinct detections across both cycles == total ERROR lines within lookback (4)",
              len(seen), 4)

        cursor_after = wm.get_cursor(log_group)
        check("cursor advances to cycle2's window_end", cursor_after, t2)
    finally:
        cleanup_group(log_group)
        wm.close()


# ── Scenario 2: real run_cycle(), cross-group isolation + dedup ────────────

async def test_run_cycle_dedup_and_cross_group_isolation():
    print("\n── WatchdogManager.run_cycle: dedup + cross-group isolation ─")
    group_ok = f"/test/watchdog-a-{uuid.uuid4()}"
    group_fail = f"/test/watchdog-b-{uuid.uuid4()}"

    now = datetime.now(timezone.utc)
    # Comfortably inside the 15-minute initial lookback and well before the
    # ingestion-lag buffer (now - 30s), so it's guaranteed to land in cycle 1.
    event_ts = now - timedelta(seconds=120)
    events = {group_ok: [(event_ts, "2025-01-01 00:00:00,000 [test] ERROR - boom-A")]}

    client_factory = lambda: FakeCloudWatchMCPClient(events, fail_groups=frozenset({group_fail}))

    orig_client_cls = watchdog.CloudWatchMCPClient
    orig_log_groups = watchdog.LOG_GROUPS
    watchdog.CloudWatchMCPClient = client_factory
    watchdog.LOG_GROUPS = [group_ok, group_fail]

    wm = WatchdogManager()
    try:
        totals1 = await wm.run_cycle()
        check("cycle1: scans the one crafted event on the healthy group",
              totals1["events_scanned"], 1)
        check("cycle1: detects it", totals1["detections"], 1)

        cursor_ok_after1 = wm.get_cursor(group_ok)
        cursor_fail_after1 = wm.get_cursor(group_fail)
        check("cycle1: healthy group's cursor advanced", cursor_ok_after1 is not None, True)
        check("cycle1: failing group's cursor was never set (no cross-group drift)",
              cursor_fail_after1, None)

        # Immediately-following cycle: the healthy group's window is now a
        # sliver right after cycle1's window_end -- the crafted event, which
        # sits well before that, must not be re-detected.
        totals2 = await wm.run_cycle()
        check("cycle2: no re-detection of the already-processed event",
              totals2["detections"], 0)

        cursor_fail_after2 = wm.get_cursor(group_fail)
        check("cycle2: failing group's cursor still untouched", cursor_fail_after2, None)
        check("run_cycle never raises even though one group's MCP query always fails",
              True, True)

        seen = messages_for(group_ok)
        check("exactly one persisted detection for the healthy group across both cycles",
              len(seen), 1)
    finally:
        watchdog.CloudWatchMCPClient = orig_client_cls
        watchdog.LOG_GROUPS = orig_log_groups
        cleanup_group(group_ok)
        cleanup_group(group_fail)
        wm.close()


if __name__ == "__main__":
    asyncio.run(test_poll_one_group_no_reprocess_no_skip())
    asyncio.run(test_run_cycle_dedup_and_cross_group_isolation())

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)
