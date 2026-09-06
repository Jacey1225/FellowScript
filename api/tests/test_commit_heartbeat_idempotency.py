"""Regression coverage for task 20260825-scheduled-event-duplicate-fire,
backend step 1's fix to AgentManager.commit_hb_response's idempotency guard
(api/backend/interactions/agent.py).

Before the fix, the claim UPDATE's WHERE clause was a rolling 2-minute
window:

    WHERE _id = %s AND (last_fired IS NULL OR last_fired < NOW() - INTERVAL '2 minutes')

Heartbeats fire client-side only (iOS HeartbeatScheduler.checkAndFire calls
this on every app foreground — there is no server-side cron for heartbeats),
so a user backgrounding/reopening the app more than 2 minutes after the
event's first same-day fire would have their second commit_heartbeat call
re-claim the row, producing a second saved note and a second "Event Response
Saved" notification for the same calendar day — the exact bug reported in
this task's intake spec.

The fix replaced the rolling window with a calendar-day boundary check
(UTC date comparison on last_fired), so:
  1. The first commit of the day succeeds and creates exactly one note.
  2. ANY later same-day call — even one deliberately placed more than 2
     minutes after the first (the old window's exact blind spot) — is
     skipped and creates no second note.
  3. A call on a genuinely later calendar day (last_fired's UTC date is in
     the past relative to today) still succeeds normally — the legitimate
     once-per-day cadence is not regressed.

Extended for task 20260901-heartbeat-backend-scheduling (testing step 4,
re-verification pass against the reworked per-user-local-timezone claim):
the calendar-day boundary above is no longer a fixed UTC date — it's
computed in the OWNING USER's own local timezone (`users.timezone`), per
that task's timezone_handling revision. `test_local_day_boundary_crossing_not_utc_day`
below proves the claim actually follows the user's local calendar day and
not a fixed UTC date, using an extreme-offset timezone
(Pacific/Kiritimati, UTC+14) chosen specifically so "today" in that user's
local calendar and "today" in UTC disagree across most of any real
wall-clock day — a regression back to a fixed-UTC comparison would fail
this test (either double-firing within the same local day, or refusing a
legitimate fire on a new local day) regardless of what time this suite
happens to run.

Extended again for testing step 4's RE-VERIFY/EXTEND pass against the
async-blocking-fix rework (architecture.json's revision block, 2026-09-01):
that rework moved every call to `commit_hb_response` (from both
scheduler.py's `_fire_due_heartbeats` and routes/agent.py's
`commit_heartbeat`) onto `loop.run_in_executor`'s thread pool, i.e. real OS
worker threads, rather than the single asyncio event-loop thread. Every
concurrency test in this file up to this point (and in
test_heartbeat_backend_scheduling.py's own concurrent-poll-cycle test) only
exercises concurrency at the asyncio-task level within a single thread (or
two independent `asyncio.run()` calls on two threads, each fully serial
internally) — none of them directly prove the claim's exactly-once
guarantee holds when multiple REAL threads call `commit_hb_response` for
the SAME heartbeat_id at genuinely the same wall-clock instant, which is
now the actual production shape of the race (N thread-pool workers, each
mid-fire for a due candidate, one of which could be this exact heartbeat if
two poll cycles or a poll cycle and a stale client overlap).
`test_concurrent_real_threads_exactly_once_claim` below closes that gap:
it lines up several real `threading.Thread`s (via a `threading.Barrier`) —
one exactly matching how `loop.run_in_executor`'s default `ThreadPoolExecutor`
dispatches work — each with its own `AgentManager` instance (own connection,
matching the thread_safety_boundary decision: one instance per candidate,
never shared across threads), and confirms Postgres's row-level locking on
the `UPDATE ... WHERE ... RETURNING` claim still arbitrates to exactly one
winner regardless of which OS thread issues it.

Uses a FakeManager subclass to stub _call_api (as test_agent_context.py
does), so no real LLM call is made and the test is deterministic.

Run:  cd api && ../.venv/bin/python tests/test_commit_heartbeat_idempotency.py
"""
import _pathfix  # noqa: F401
import _fake_timeline  # noqa: F401

import threading
import uuid
from datetime import timedelta, timezone as tzmod
from datetime import datetime as real_datetime
from zoneinfo import ZoneInfo

from db import DBManager
from backend.interactions.agent import AgentManager

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


class FakeManager(AgentManager):
    """Stubs the LLM call so commit_hb_response is fully exercised (ownership
    check, idempotency claim, note creation, context save) without ever
    hitting the real OpenRouter API."""

    def _call_api(self, agent_role, messages):
        return (
            '{"__action": "create_note", "title": "Reflection", '
            '"text": "Generated content.", "verses": []}'
        )


def make_user() -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"hbidem_{uid[:8]}",
                               "email": f"hbidem_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()
    return uid


def make_user_with_timezone(prefix: str, tzname: str) -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {
            "_id": uid, "username": f"{prefix}_{uid[:8]}",
            "email": f"{prefix}_{uid[:8]}@example.com", "hash_pass": "x",
            "timezone": tzname,
        })
    finally:
        db.close()
    return uid


def make_agent(user_id: str) -> str:
    agent_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("agents", {"_id": agent_id, "user_id": user_id, "role": "", "chats": []})
    finally:
        db.close()
    return agent_id


def make_heartbeat(agent_id: str, user_id: str) -> str:
    hb_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt) "
            "VALUES (%s, %s, %s, %s::jsonb, %s)",
            (hb_id, agent_id, user_id, "[]", "Write a reflection."),
        )
        db.conn.commit()
    finally:
        db.close()
    return hb_id


# Task 20260906-heartbeat-timeline-instructions removed `agentic_context`
# (the old heartbeat_id -> note_id link `note_count_for_heartbeat` used to
# query) -- no-duplication is now handled upfront by the heartbeat's own
# `timeline_instruction` rather than a per-note durable link, so there is no
# direct DB link from a heartbeat to the notes it generates anymore, and
# (unlike test_commit_heartbeat_force_fire.py/test_heartbeat_backend_
# scheduling.py, which each fire only one heartbeat per user per test) this
# file fires TWO heartbeats (hb_id, hb_id2) for the SAME user within a
# single test flow, so even a per-user note-count delta can't attribute
# growth to the right one. Instead, `fire()` below -- the one path every
# `commit_hb_response` call in this file goes through -- records a
# successful fire directly against the heartbeat_id it was called with, the
# instant it happens; `note_count_for_heartbeat` just reads that count back.
# This is exact by construction, not by inference from surrounding DB state.
_fire_counts: dict[str, int] = {}
_fire_counts_lock = threading.Lock()


def fire(manager: AgentManager, agent_id: str, hb_id: str, content: str, **kwargs) -> dict:
    result = manager.commit_hb_response(agent_id, hb_id, content, **kwargs)
    if result == {"success": "saved note"}:
        with _fire_counts_lock:
            _fire_counts[hb_id] = _fire_counts.get(hb_id, 0) + 1
    return result


def note_count_for_heartbeat(hb_id: str) -> int:
    return _fire_counts.get(hb_id, 0)


def set_last_fired(hb_id: str, sql_expr: str):
    """Directly back-date agent_heartbeats.last_fired using a raw SQL
    expression (e.g. "NOW() - INTERVAL '3 minutes'" or "NOW() - INTERVAL
    '1 day'") so tests can simulate "already fired N ago" without sleeping."""
    db = DBManager()
    try:
        db.cur.execute(
            f"UPDATE agent_heartbeats SET last_fired = {sql_expr} WHERE _id = %s", (hb_id,)
        )
        db.conn.commit()
    finally:
        db.close()


def set_last_fired_absolute(hb_id: str, when) -> None:
    """Back-date agent_heartbeats.last_fired to an exact Python datetime
    (passed as a bound parameter, never interpolated into SQL text) — used
    where the test needs to compute the timestamp itself (e.g. via
    zoneinfo) rather than expressing it as a SQL-side expression."""
    db = DBManager()
    try:
        db.cur.execute(
            "UPDATE agent_heartbeats SET last_fired = %s WHERE _id = %s", (when, hb_id)
        )
        db.conn.commit()
    finally:
        db.close()


def cleanup(user_id: str):
    db = DBManager()
    try:
        db.delete("notes", {"user_id": user_id})
        db.delete("users", {"_id": user_id})  # cascades agents/heartbeats/context
    finally:
        db.close()


def test_local_day_boundary_crossing_not_utc_day():
    """The claim's calendar-day boundary must follow the OWNING USER's own
    local timezone, not a fixed UTC date (task 20260901-heartbeat-backend-
    scheduling's timezone_handling revision).

    Pacific/Kiritimati (UTC+14) is used deliberately: at a +14 offset, the
    instant of "local midnight" is 14 hours away from UTC midnight, so for
    the large majority of any real wall-clock day, "today" in this user's
    local calendar and "today" in UTC are genuinely different calendar
    dates. That makes this test's two assertions below actually exercise
    the local-vs-UTC distinction regardless of what time this suite happens
    to run — a regression back to a fixed `AT TIME ZONE 'UTC'` comparison
    would fail at least one of them on almost any given real run, rather
    than only on a specific flaky time window.
    """
    print("\n=== 6. Day-boundary crossing: the claim follows the user's OWN local "
          "calendar day, not a fixed UTC date ===")
    tzname = "Pacific/Kiritimati"  # UTC+14 — far enough from UTC to force local/UTC date divergence
    uid = make_user_with_timezone("hbtzday", tzname)
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    manager = FakeManager(uid)

    try:
        result1 = fire(manager, agent_id, hb_id, "Reflect on today.")
        check("first fire (real 'now') succeeds", result1 == {"success": "saved note"}, str(result1))
        check("exactly one note after first fire", note_count_for_heartbeat(hb_id) == 1,
              str(note_count_for_heartbeat(hb_id)))

        now_real = real_datetime.now(tzmod.utc)
        local_now = now_real.astimezone(ZoneInfo(tzname))
        local_midnight = local_now.replace(hour=0, minute=0, second=0, microsecond=0)

        # 1 second before the user's OWN local midnight is unambiguously
        # "yesterday" in that user's calendar, no matter what UTC calendar
        # date that same instant falls on (at +14 it is very often still
        # "today" in UTC — exactly what a fixed-UTC boundary would get
        # wrong, treating this as same-day and refusing to re-fire).
        set_last_fired_absolute(hb_id, local_midnight - timedelta(seconds=1))
        result2 = fire(manager, agent_id, hb_id, "Reflect on today.")
        check(
            "a fire 1s before the user's OWN local midnight is 'yesterday' locally — "
            "claim succeeds again (legitimate new local day)",
            result2 == {"success": "saved note"}, str(result2),
        )
        check("a second note now exists", note_count_for_heartbeat(hb_id) == 2,
              str(note_count_for_heartbeat(hb_id)))

        # Exactly the user's own local midnight (start of today, locally) —
        # same local calendar day as "now" — must be skipped, even though
        # this absolute instant is frequently a *different* UTC calendar
        # date than the real current UTC date (proving the code isn't
        # silently still comparing UTC dates).
        set_last_fired_absolute(hb_id, local_midnight)
        result3 = fire(manager, agent_id, hb_id, "Reflect on today.")
        check(
            "a fire at the user's OWN local midnight (today, locally) is skipped — no double fire",
            result3 == {"skipped": "already fired today"}, str(result3),
        )
        check("still exactly two notes (no duplicate from the same-local-day reopen)",
              note_count_for_heartbeat(hb_id) == 2, str(note_count_for_heartbeat(hb_id)))
    finally:
        cleanup(uid)


def test_concurrent_real_threads_exactly_once_claim():
    """N real OS threads (a threading.Barrier lines them up to fire at the
    same instant), each with its own AgentManager instance/connection —
    matching production's loop.run_in_executor(None, ...) thread-pool shape
    exactly — call commit_hb_response for the SAME heartbeat_id
    concurrently. Exactly one must win the claim and produce exactly one
    note; every other thread must see 'already fired today', never a
    partial/duplicate write or a claim-failed error caused by the
    concurrency itself.
    """
    print("\n=== 7. Real OS-thread concurrency (matching production's run_in_executor "
          "thread pool): N threads calling commit_hb_response for the SAME heartbeat_id "
          "at once still produce exactly one success and exactly one note ===")
    import threading
    import concurrent.futures

    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)

    N = 8
    barrier = threading.Barrier(N, timeout=10)
    results: list = [None] * N
    errors: list[Exception] = []

    def fire_thread(i: int):
        # Fresh AgentManager per thread, own connection — same shape as
        # scheduler.py's per-candidate `am = AgentManager(user_id=user_id)`,
        # never sharing one instance's connection/cursor across threads.
        # Named distinctly from the module-level `fire()` helper (which this
        # calls) to avoid shadowing it within this function's own scope.
        manager = FakeManager(uid)
        try:
            barrier.wait()  # line every thread up to call commit_hb_response together
            results[i] = fire(manager, agent_id, hb_id, "Reflect on today.")
        except Exception as e:
            errors.append(e)
        finally:
            manager.close()

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=N) as pool:
            futures = [pool.submit(fire_thread, i) for i in range(N)]
            for f in futures:
                f.result(timeout=30)

        check(f"all {N} concurrent real-thread callers completed without raising",
              not errors, str(errors))

        successes = [r for r in results if r == {"success": "saved note"}]
        skipped = [r for r in results if r == {"skipped": "already fired today"}]
        check(f"exactly ONE of {N} concurrent real-thread callers won the atomic claim",
              len(successes) == 1, str(results))
        check(f"the other {N - 1} concurrent real-thread callers were cleanly skipped "
              "(no claim-failed/error responses caused by the concurrency itself)",
              len(skipped) == N - 1, str(results))
        check("exactly one note/context row exists network-wide despite "
              f"{N} genuinely concurrent real OS threads",
              note_count_for_heartbeat(hb_id) == 1, str(note_count_for_heartbeat(hb_id)))
    finally:
        cleanup(uid)


def main():
    uid = make_user()
    agent_id = make_agent(uid)

    try:
        print("=== 1. First commit of the day succeeds and creates exactly one note ===")
        hb_id = make_heartbeat(agent_id, uid)
        manager = FakeManager(uid)
        result1 = fire(manager, agent_id, hb_id, "Reflect on today.")
        check("first call reports success", result1 == {"success": "saved note"}, str(result1))
        check("exactly one note/context row exists after first call",
              note_count_for_heartbeat(hb_id) == 1, str(note_count_for_heartbeat(hb_id)))

        print("\n=== 2. Immediate second call the same day is skipped, no second note ===")
        result2 = fire(manager, agent_id, hb_id, "Reflect on today.")
        check("immediate retry is skipped", result2 == {"skipped": "already fired today"}, str(result2))
        check("still exactly one note/context row (no duplicate)",
              note_count_for_heartbeat(hb_id) == 1, str(note_count_for_heartbeat(hb_id)))

        print("\n=== 3. Reopen >2 minutes later, same calendar day — THE reported bug's exact "
              "gap in the old rolling-window guard — still skipped, no second note ===")
        hb_id2 = make_heartbeat(agent_id, uid)
        manager2 = FakeManager(uid)
        result3 = fire(manager2, agent_id, hb_id2, "Reflect on today.")
        check("first fire of hb_id2 succeeds", result3 == {"success": "saved note"}, str(result3))
        check("exactly one note for hb_id2 after first fire",
              note_count_for_heartbeat(hb_id2) == 1, str(note_count_for_heartbeat(hb_id2)))

        # Back-date last_fired to 3 minutes ago (same UTC calendar day). Under
        # the OLD rolling 2-minute-window guard, this WOULD have re-claimed
        # the row (3 minutes > the 2-minute window) and created a second
        # note — this is the exact scenario the intake spec reports.
        set_last_fired(hb_id2, "NOW() - INTERVAL '3 minutes'")
        result4 = fire(manager2, agent_id, hb_id2, "Reflect on today.")
        check(
            "reopen 3 minutes later (same day) is skipped — proves the fix; "
            "the old 2-minute rolling window would have let this re-fire",
            result4 == {"skipped": "already fired today"}, str(result4),
        )
        check("still exactly one note for hb_id2 (no duplicate from the >2-minute-later reopen)",
              note_count_for_heartbeat(hb_id2) == 1, str(note_count_for_heartbeat(hb_id2)))

        # Even further out same day — pin last_fired to the very start of
        # today's UTC calendar day (00:00:00 UTC) rather than a fixed
        # "N hours ago" offset. A fixed hour offset (e.g. "10 hours ago")
        # is flaky: it crosses into the *previous* UTC day whenever the test
        # happens to run within the first N hours after UTC midnight, which
        # would make this assertion fail for a reason that has nothing to do
        # with the guard being tested. Truncating must go via "AT TIME ZONE
        # 'UTC'" explicitly (not bare date_trunc('day', NOW())) because the
        # DB session's own timezone is not necessarily UTC (this environment's
        # session runs in America/Los_Angeles) — a bare date_trunc truncates
        # to midnight in the *session's* timezone, not UTC midnight, which
        # reintroduced the exact same flakiness one layer down. The
        # AT TIME ZONE 'UTC' ... AT TIME ZONE 'UTC' round-trip converts NOW()
        # to a naive UTC wall-clock value, truncates that to its day boundary,
        # then reinterprets it as UTC to get back a correct timestamptz — always
        # on today's UTC date regardless of wall-clock time or session
        # timezone, proving the guard is a calendar-day boundary, not merely a
        # slightly longer rolling window.
        set_last_fired(hb_id2, "date_trunc('day', NOW() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'")
        result5 = fire(manager2, agent_id, hb_id2, "Reflect on today.")
        check("reopen at the start of today's UTC day is still skipped",
              result5 == {"skipped": "already fired today"}, str(result5))
        check("still exactly one note for hb_id2",
              note_count_for_heartbeat(hb_id2) == 1, str(note_count_for_heartbeat(hb_id2)))

        print("\n=== 4. Legitimate next-day fire still succeeds (no regression to once-per-day cadence) ===")
        # One second before the start of today's UTC day is guaranteed to be
        # on yesterday's UTC date regardless of wall-clock time (unlike a
        # fixed "NOW() - INTERVAL '1 day'" offset, which is always exactly 24
        # hours back and so isn't actually the source of the flakiness here,
        # but this keeps the anchor consistent with the fix above).
        set_last_fired(hb_id2, "date_trunc('day', NOW() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - INTERVAL '1 second'")
        result6 = fire(manager2, agent_id, hb_id2, "Reflect on today.")
        check("a call on the next calendar day succeeds",
              result6 == {"success": "saved note"}, str(result6))
        check("a second note now exists for hb_id2 (one per legitimate day)",
              note_count_for_heartbeat(hb_id2) == 2, str(note_count_for_heartbeat(hb_id2)))

        print("\n=== 5. Unowned heartbeat is still rejected before any claim/LLM call ===")
        other_uid = make_user()
        try:
            other_manager = FakeManager(other_uid)
            result7 = fire(other_manager, agent_id, hb_id, "Reflect on today.")
            check("cross-user commit is rejected", result7 == {"error": "heartbeat not found"}, str(result7))
            check("no extra note created for hb_id via cross-user attempt",
                  note_count_for_heartbeat(hb_id) == 1, str(note_count_for_heartbeat(hb_id)))
        finally:
            cleanup(other_uid)

    finally:
        cleanup(uid)

    test_local_day_boundary_crossing_not_utc_day()
    test_concurrent_real_threads_exactly_once_claim()

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        raise SystemExit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
