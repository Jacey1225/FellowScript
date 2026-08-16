"""
Proves the per-cycle circuit breaker (`MAX_DETECTIONS_PER_CYCLE` /
`MAX_DEBUG_AGENT_CALLS_PER_CYCLE` in backend/monitoring/watchdog.py) actually
bounds growth within a single `run_cycle()` -- the defense-in-depth half of
the 2026-08-14 incident's structural fix, independent of whether the
self-exclusion filter happens to catch the specific failure mode (per the
resolved open question: "regardless of which specific bug caused a spike").

Against the real local Postgres DB (matches this project's DB-test
convention), with CloudWatchMCPClient replaced by an in-memory fake -- same
test-double boundary as test_watchdog_cursor_sync.py.

Covers:
  - A burst of real (non-self-originated) ERROR lines in one cycle, well
    over MAX_DETECTIONS_PER_CYCLE, persists at most MAX_DETECTIONS_PER_CYCLE
    detection rows -- not one row per matching line.
  - The breaker trips cleanly: `run_cycle()` returns without raising, and
    logs a warning (not an unbounded crash/loop) once tripped.
  - Once tripped, remaining log groups in the same cycle are skipped
    entirely (cursors left untouched) rather than partially processed --
    proven by an untouched trailing group's cursor staying None after the
    cycle that tripped the breaker.
  - The debug-agent call count within one cycle never exceeds
    MAX_DEBUG_AGENT_CALLS_PER_CYCLE even when far more than that many
    detections are persisted in the same cycle (detections beyond the
    debug-agent cap still persist -- only the automatic report is skipped).
  - The breaker resets cleanly on the *next* cycle -- proven by a second,
    much smaller cycle detecting its own events normally instead of staying
    permanently tripped.

Run:  cd api && ../.venv/bin/python tests/test_watchdog_circuit_breaker.py
"""

import _pathfix  # noqa: F401

import asyncio
import sys
import uuid
from datetime import datetime, timedelta, timezone

import backend.monitoring.watchdog as watchdog
from backend.monitoring.watchdog import (
    WatchdogManager,
    MAX_DETECTIONS_PER_CYCLE,
    MAX_DEBUG_AGENT_CALLS_PER_CYCLE,
)

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


class FakeCloudWatchMCPClient:
    def __init__(self, events_by_group: dict):
        self.events_by_group = events_by_group

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def query_log_events(self, log_group_name, start_time, end_time, limit=10000):
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


def count_detections(log_group_name: str) -> int:
    wm = WatchdogManager()
    try:
        wm.cur.execute(
            "SELECT count(*) FROM error_detections WHERE log_group_name=%s", (log_group_name,)
        )
        return wm.cur.fetchone()[0]
    finally:
        wm.close()


async def test_detection_cap_bounds_a_burst_and_skips_remaining_groups():
    print("\n── Circuit breaker: a burst well over the cap persists at most the cap ──")
    burst_group = f"/test/watchdog-burst-{uuid.uuid4()}"
    trailing_group = f"/test/watchdog-trailing-{uuid.uuid4()}"

    now = datetime.now(timezone.utc)
    event_ts = now - timedelta(seconds=120)

    # 3x the cap worth of distinct genuine ERROR lines in one group.
    burst_count = MAX_DETECTIONS_PER_CYCLE * 3
    burst_events = [
        (event_ts + timedelta(milliseconds=i),
         f"2026-08-15 10:00:00,{i:03d} [routes.notes] ERROR - burst failure #{i}")
        for i in range(burst_count)
    ]
    # Trailing group has its own real event too -- must be entirely skipped
    # (cursor left untouched) once the breaker trips on the group before it.
    trailing_events = [(event_ts, "2026-08-15 10:00:00,000 [routes.notes] ERROR - trailing failure")]

    events = {burst_group: burst_events, trailing_group: trailing_events}
    client_factory = lambda: FakeCloudWatchMCPClient(events)

    orig_client_cls = watchdog.CloudWatchMCPClient
    orig_log_groups = watchdog.LOG_GROUPS
    orig_debug_call = watchdog.run_debug_agent_for_detection
    watchdog.CloudWatchMCPClient = client_factory
    watchdog.LOG_GROUPS = [burst_group, trailing_group]
    # Debug-agent calls are irrelevant to this scenario's assertions and
    # would otherwise try a real OpenRouter/DB round trip per detection --
    # stub it out to a cheap no-op, matching how this cap is independent of
    # the debug-agent cap (covered in the next test).
    watchdog.run_debug_agent_for_detection = lambda detection_id: {"skipped": "test stub"}

    wm = WatchdogManager()
    try:
        totals = await wm.run_cycle()

        check("run_cycle does not raise even under a 3x-cap burst", True, True)
        check("persisted detections capped at MAX_DETECTIONS_PER_CYCLE, not the full burst",
              totals["detections"], MAX_DETECTIONS_PER_CYCLE)
        check("DB row count matches the capped total (no over-persist)",
              count_detections(burst_group), MAX_DETECTIONS_PER_CYCLE)
        check("breaker tripped flag set on the manager", wm._cap_tripped, True)

        cursor_trailing = wm.get_cursor(trailing_group)
        check("trailing group's cursor left untouched -- entirely skipped once breaker tripped",
              cursor_trailing, None)
    finally:
        watchdog.CloudWatchMCPClient = orig_client_cls
        watchdog.LOG_GROUPS = orig_log_groups
        watchdog.run_debug_agent_for_detection = orig_debug_call
        cleanup_group(burst_group)
        cleanup_group(trailing_group)
        wm.close()


async def test_debug_agent_cap_independent_of_detection_cap():
    print("\n── Debug-agent call cap: bounded independently of the detection cap ──")
    group = f"/test/watchdog-debugcap-{uuid.uuid4()}"
    now = datetime.now(timezone.utc)
    event_ts = now - timedelta(seconds=120)

    # In production both caps share the same value (25), so a plain burst
    # can't distinguish "the debug-agent cap enforces its own limit" from
    # "the detection cap simply capped things first". Temporarily lower the
    # module's debug-agent cap so it trips well before the (separately
    # verified, in the previous test) detection cap -- isolating that this
    # is really a second, independent counter/cap, not the same one reused.
    lowered_debug_cap = 5
    assert lowered_debug_cap < MAX_DETECTIONS_PER_CYCLE

    n = lowered_debug_cap + 10  # more detections than the (lowered) debug-agent cap
    events = [
        (event_ts + timedelta(milliseconds=i),
         f"2026-08-15 10:00:00,{i:03d} [routes.notes] ERROR - failure #{i}")
        for i in range(n)
    ]

    client_factory = lambda: FakeCloudWatchMCPClient({group: events})
    orig_client_cls = watchdog.CloudWatchMCPClient
    orig_log_groups = watchdog.LOG_GROUPS
    orig_debug_call = watchdog.run_debug_agent_for_detection
    orig_debug_cap = watchdog.MAX_DEBUG_AGENT_CALLS_PER_CYCLE
    watchdog.CloudWatchMCPClient = client_factory
    watchdog.LOG_GROUPS = [group]
    watchdog.MAX_DEBUG_AGENT_CALLS_PER_CYCLE = lowered_debug_cap

    calls = []
    watchdog.run_debug_agent_for_detection = lambda detection_id: calls.append(detection_id) or {}

    wm = WatchdogManager()
    try:
        totals = await wm.run_cycle()
        check(f"all {n} detections persisted (below the real detection cap)", totals["detections"], n)
        check("debug-agent invoked at most the (lowered) debug-agent cap",
              len(calls) <= lowered_debug_cap, True)
        check("debug-agent invoked exactly the lowered cap's worth of times (not fewer, not all n)",
              len(calls), lowered_debug_cap)
        check("detections beyond the debug-agent cap still persisted -- only the auto-report was skipped",
              n > len(calls), True)
    finally:
        watchdog.CloudWatchMCPClient = orig_client_cls
        watchdog.LOG_GROUPS = orig_log_groups
        watchdog.run_debug_agent_for_detection = orig_debug_call
        watchdog.MAX_DEBUG_AGENT_CALLS_PER_CYCLE = orig_debug_cap
        cleanup_group(group)
        wm.close()


async def test_breaker_resets_on_next_cycle():
    print("\n── Breaker resets cleanly -- does not stay permanently tripped ──")
    burst_group = f"/test/watchdog-reset-burst-{uuid.uuid4()}"
    followup_group = f"/test/watchdog-reset-followup-{uuid.uuid4()}"
    now = datetime.now(timezone.utc)

    # Cycle 1: trip the breaker with a burst on its own group.
    burst_ts = now - timedelta(seconds=600)
    burst_events = [
        (burst_ts + timedelta(milliseconds=i),
         f"2026-08-15 10:00:00,{i:03d} [routes.notes] ERROR - burst #{i}")
        for i in range(MAX_DETECTIONS_PER_CYCLE * 2)
    ]

    orig_client_cls = watchdog.CloudWatchMCPClient
    orig_log_groups = watchdog.LOG_GROUPS
    orig_debug_call = watchdog.run_debug_agent_for_detection
    watchdog.run_debug_agent_for_detection = lambda detection_id: {}

    wm = WatchdogManager()
    try:
        watchdog.CloudWatchMCPClient = lambda: FakeCloudWatchMCPClient({burst_group: burst_events})
        watchdog.LOG_GROUPS = [burst_group]

        totals1 = await wm.run_cycle()
        check("cycle1 trips the breaker and caps detections",
              totals1["detections"], MAX_DETECTIONS_PER_CYCLE)
        check("cycle1: _cap_tripped set", wm._cap_tripped, True)

        # Cycle 2: entirely different, fresh (no-cursor) log group with one
        # genuine new event -- isolates "does the breaker reset" from any
        # cursor-truncation/dedup subtlety on the group that tripped it.
        followup_ts = now - timedelta(seconds=60)
        followup_events = [(followup_ts, "2026-08-15 10:00:00,000 [routes.notes] ERROR - followup after reset")]
        watchdog.CloudWatchMCPClient = lambda: FakeCloudWatchMCPClient({followup_group: followup_events})
        watchdog.LOG_GROUPS = [followup_group]

        totals2 = await wm.run_cycle()
        check("cycle2: breaker flag reset at the top of the new cycle", wm._cap_tripped, False)
        check("cycle2: a genuine event on a fresh group is detected normally post-reset",
              totals2["detections"], 1)
    finally:
        watchdog.CloudWatchMCPClient = orig_client_cls
        watchdog.LOG_GROUPS = orig_log_groups
        watchdog.run_debug_agent_for_detection = orig_debug_call
        cleanup_group(burst_group)
        cleanup_group(followup_group)
        wm.close()


if __name__ == "__main__":
    asyncio.run(test_detection_cap_bounds_a_burst_and_skips_remaining_groups())
    asyncio.run(test_debug_agent_cap_independent_of_detection_cap())
    asyncio.run(test_breaker_resets_on_next_cycle())

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)
