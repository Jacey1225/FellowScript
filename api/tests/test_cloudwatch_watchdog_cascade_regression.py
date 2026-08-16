"""
Regression test for the actual 2026-08-14 production OOM incident (commit
a8a22ecc): reproduces the self-amplifying feedback loop end-to-end and
proves it no longer produces unbounded detection/report growth, now that
step 6 has re-enabled the `cloudwatch_watchdog` scheduler job on top of the
step 1-4 fixes + step 5 security review.

The incident mechanism being reproduced:
  1. `analyze_log_group` was missing `log_group_arn` -> failed on every
     detection -> would previously have logged at ERROR.
  2. The debug agent's OpenRouter call got a 403 (bad/expired key) -> would
     previously have logged at ERROR.
  3. Both failure logs landed in `/fellowscript/app`, the very log group the
     watchdog scans, and its broad `\bERROR\b` pattern re-detected them as
     *new* errors on the next 90s cycle -> triggered more (also failing)
     work -> more ERROR logs -> indefinitely, with no cap.

This test drives multiple consecutive `run_cycle()`s against a fake
CloudWatch client whose `/fellowscript/app` log group is seeded, each
cycle, with the exact log lines the *unfixed* code would have produced from
both failure modes (self-originated ERROR lines) PLUS a growing "echo" of
prior cycles' failure lines (simulating what an unbounded loop would have
kept accumulating in the real log group) -- proving growth stays flat
rather than compounding, because those lines are now excluded from
detection entirely (self-exclusion) and, as defense in depth, could never
exceed the per-cycle cap even if the filter were somehow bypassed.

Also confirms the scheduler.py registration itself: the `cloudwatch_watchdog`
job (disabled by a8a22ecc, re-enabled in this workflow's step 6) is actually
registered under `start_scheduler()` -- not left as a standalone code fix
with no wiring, and not still commented out.

Run:  cd api && ../.venv/bin/python tests/test_cloudwatch_watchdog_cascade_regression.py
"""

import _pathfix  # noqa: F401

import asyncio
import sys
import uuid
from datetime import datetime, timedelta, timezone

import backend.monitoring.watchdog as watchdog
from backend.monitoring.watchdog import WatchdogManager, MAX_DETECTIONS_PER_CYCLE

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


class FakeCloudWatchMCPClient:
    """Its /fellowscript/app group's content for cycle N is provided by a
    callable so the test can grow it cycle-over-cycle, simulating a real
    log group accumulating lines over time (exactly what the unfixed
    incident did)."""

    def __init__(self, events_provider):
        self._events_provider = events_provider

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def query_log_events(self, log_group_name, start_time, end_time, limit=10000):
        rows = []
        for ts, message in self._events_provider(log_group_name):
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


async def test_cascade_no_longer_produces_unbounded_growth():
    print("\n── Regression: reproduce the 2026-08-14 cascade mechanism across many cycles ──")
    app_group = f"/fellowscript/app-test-{uuid.uuid4()}"

    # All the failure lines an *unfixed* watchdog would have produced,
    # landing in /fellowscript/app the same way production's real ones did.
    # Drives `_poll_one_group` directly with explicit, growing window
    # boundaries (same technique as test_watchdog_cursor_sync.py's scenario
    # 1) so each of the 5 simulated 90s cycles genuinely sees NEW
    # self-originated failure lines in its window -- not a wall-clock race
    # against how fast this test function itself executes.
    def self_originated_lines_for_cycle(cycle_n: int, cycle_start: datetime) -> list[tuple[datetime, str]]:
        lines = []
        for i in range(cycle_n):  # growth: more accumulated failure lines each cycle, unbounded if unfixed
            t = cycle_start + timedelta(seconds=1 + i * 0.01)
            lines.append((t, f"2026-08-15 10:00:00,{i:03d} [backend.monitoring.cloudwatch_mcp_client] "
                              f"WARNING - analyze_log_group context call failed for {app_group} "
                              f"(cycle {cycle_n}, echo {i}): simulated AccessDeniedException"))
            lines.append((t, f"2026-08-15 10:00:00,{i:03d} [backend.monitoring.debug_agent] "
                              f"ERROR - Debug agent OpenRouter call failed for detection "
                              f"fake-{cycle_n}-{i}: simulated 403"))
            lines.append((t, f"2026-08-15 10:00:00,{i:03d} [backend.interactions.scheduler.watchdog] "
                              f"ERROR - CloudWatch watchdog cycle failed (cycle {cycle_n}, echo {i}): "
                              f"simulated cascade"))
        return lines

    all_events: list[tuple[datetime, str]] = []

    def events_provider(log_group_name):
        return all_events if log_group_name == app_group else []

    orig_client_cls = watchdog.CloudWatchMCPClient
    orig_debug_call = watchdog.run_debug_agent_for_detection
    watchdog.CloudWatchMCPClient = lambda: FakeCloudWatchMCPClient(events_provider)
    watchdog.run_debug_agent_for_detection = lambda detection_id: {
        "error": "should never be called -- self-originated lines must never reach a real detection"
    }

    wm = WatchdogManager()
    try:
        # t0 anchors the simulated timeline (independent of real wall clock)
        # -- each "cycle" advances by the real 90s poll interval, matching
        # production's actual cadence, with WATCHDOG_POLL_INTERVAL_SECONDS
        # of new self-noise appended to the log group each time (simulating
        # what the unfixed watchdog would have kept generating every cycle).
        t0 = datetime(2026, 8, 14, 12, 0, 0, tzinfo=timezone.utc)
        window_end = t0
        detection_totals = []
        events_scanned_totals = []
        for cycle_n in range(1, 6):  # 5 consecutive simulated 90s cycles
            cycle_start = window_end
            window_end = cycle_start + timedelta(seconds=watchdog.WATCHDOG_POLL_INTERVAL_SECONDS)
            all_events.extend(self_originated_lines_for_cycle(cycle_n, cycle_start))

            async with watchdog.CloudWatchMCPClient() as client:
                totals = await wm._poll_one_group(client, app_group, window_end)
            detection_totals.append(totals["detections"])
            events_scanned_totals.append(totals["events_scanned"])

        check("run_cycle never raises across 5 consecutive cycles of growing self-noise", True, True)
        check("each cycle actually scanned new self-noise events (proves this is a real test of "
              "growing volume, not a no-op from an already-exhausted window)",
              all(n > 0 for n in events_scanned_totals), True)
        check("events scanned per cycle strictly grows (matches the unfixed incident's growth "
              "pattern -- more accumulated failure lines every cycle)",
              events_scanned_totals == sorted(events_scanned_totals) and
              events_scanned_totals[-1] > events_scanned_totals[0], True)
        check("zero detections across every cycle despite growing event volume -- the "
              "self-amplifying lines are fully excluded, not merely capped",
              detection_totals, [0, 0, 0, 0, 0])

        wm.cur.execute("SELECT count(*) FROM error_detections WHERE log_group_name=%s", (app_group,))
        db_count = wm.cur.fetchone()[0]
        check("zero rows ever persisted for the reproduced cascade content", db_count, 0)
    finally:
        watchdog.CloudWatchMCPClient = orig_client_cls
        watchdog.run_debug_agent_for_detection = orig_debug_call
        cleanup_group(app_group)
        wm.close()


async def test_defense_in_depth_even_if_self_exclusion_were_bypassed():
    print("\n── Defense-in-depth: even a hypothetical self-exclusion miss stays bounded by the cap ──")
    # This does NOT disable the real self-exclusion filter (that's proven
    # never to fire above) -- it instead proves the second, independent
    # layer (the per-cycle cap) also would have stopped runaway growth on
    # its own, per the intake spec's explicit "not an either/or choice"
    # requirement. Simulate a burst of *genuine-looking* application errors
    # (not self-originated -- a different logger name) far exceeding the
    # cap, as a stand-in for "any future recurring internal failure not
    # covered by the self-exclusion filter's specific three logger names".
    group = f"/test/cascade-defense-in-depth-{uuid.uuid4()}"
    now = datetime.now(timezone.utc)
    base_ts = now - timedelta(seconds=120)
    burst = [
        (base_ts + timedelta(milliseconds=i),
         f"2026-08-15 10:00:00,{i:03d} [some.future.unmapped.module] ERROR - recurring failure #{i}")
        for i in range(MAX_DETECTIONS_PER_CYCLE * 4)
    ]

    orig_client_cls = watchdog.CloudWatchMCPClient
    orig_log_groups = watchdog.LOG_GROUPS
    orig_debug_call = watchdog.run_debug_agent_for_detection
    watchdog.CloudWatchMCPClient = lambda: FakeCloudWatchMCPClient(lambda g: burst if g == group else [])
    watchdog.LOG_GROUPS = [group]
    watchdog.run_debug_agent_for_detection = lambda detection_id: {}

    wm = WatchdogManager()
    try:
        totals = await wm.run_cycle()
        check("even an uncovered recurring-failure burst stays capped at MAX_DETECTIONS_PER_CYCLE",
              totals["detections"], MAX_DETECTIONS_PER_CYCLE)
    finally:
        watchdog.CloudWatchMCPClient = orig_client_cls
        watchdog.LOG_GROUPS = orig_log_groups
        watchdog.run_debug_agent_for_detection = orig_debug_call
        cleanup_group(group)
        wm.close()


async def test_scheduler_job_actually_reenabled():
    print("\n── scheduler.py: cloudwatch_watchdog job is registered (not still disabled) ──")
    from backend.interactions.scheduler import scheduler, start_scheduler, _run_error_watchdog

    was_running = scheduler.running
    try:
        start_scheduler()
        job = scheduler.get_job("cloudwatch_watchdog")
        check("cloudwatch_watchdog job is registered under start_scheduler()", job is not None, True)
        if job is not None:
            check("job's function is the real _run_error_watchdog delegate",
                  job.func is _run_error_watchdog, True)
            check("job uses an interval trigger (not left as a stub/disabled one-shot)",
                  type(job.trigger).__name__, "IntervalTrigger")
    finally:
        if scheduler.running and not was_running:
            scheduler.shutdown(wait=False)


if __name__ == "__main__":
    asyncio.run(test_cascade_no_longer_produces_unbounded_growth())
    asyncio.run(test_defense_in_depth_even_if_self_exclusion_were_bypassed())
    asyncio.run(test_scheduler_job_actually_reenabled())

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)
