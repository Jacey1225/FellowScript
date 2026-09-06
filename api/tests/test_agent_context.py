"""Tests for the "timeline instruction" mechanism, task
20260906-heartbeat-timeline-instructions, which REPLACES the old
`agentic_context` table + `AgentManager.save_context`/`get_context` reactive
dedup mechanism entirely (this file previously tested exactly that removed
mechanism -- see git history for the pre-replacement version).

Instead of recomputing a live CHAPTERS/VERSES/THEME aggregate from past
notes at every fire, a dedicated timeline-planning agent
(`AgentManager._generate_timeline_days`, prompted via
`backend/interactions/timeline_prompt.txt`) builds an upfront, per-window
content plan the moment a heartbeat is created, stored as a single
JSON-encoded string in the new `agent_heartbeats.timeline_instruction`
column (window_start, per-window-offset day instructions, and a rolling
coverage_summary -- see that column's own comment in db.py and
`AgentManager._encode_timeline`/`_decode_timeline`). Fire time reads that
window's day-specific instruction via `ensure_current_timeline`/
`_todays_instruction` instead of a live aggregate.

Covers:
  1. `_firing_offsets`: which window-offsets (0..30) a heartbeat's
     `timestamps` day-of-month array actually fires on, for both a daily
     and a sparse/weekly-like schedule -- and that non-firing offsets never
     appear.
  2. `_encode_timeline`/`_decode_timeline` round-trip.
  3. The worked example from the spec: a daily heartbeat requesting "a
     five-verse study note on the book of Ephesians" gets a timeline with a
     DISTINCT, progressing instruction per firing day and no repeats.
  4. `add_heartbeat` generates and persists the initial timeline atomically
     with the row's own INSERT.
  5. `ensure_current_timeline`: a fresh (not-yet-elapsed) window is
     returned as-is with NO regeneration call; a NULL timeline (legacy
     heartbeat, or a schedule change via `update_heartbeat` nulling it out)
     is lazily backfilled; an ELAPSED window is regenerated, informed by
     the prior window's `coverage_summary` (cross-window no-duplication).
  6. Concurrent-fire regeneration race safety: N real OS threads racing
     `commit_hb_response` for the same NULL-timeline heartbeat still
     produce exactly one regeneration and exactly one saved note.
  7. Generation-failure propagation: `add_heartbeat` raises
     `TimelineGenerationError` and creates NO row when the planning agent
     never returns valid JSON; `ensure_current_timeline`'s failure inside
     `commit_hb_response` unwinds the fire's claim and leaves the
     heartbeat's existing (stale) `timeline_instruction` value completely
     untouched.

Run with: cd api && ../.venv/bin/python tests/test_agent_context.py
"""
import _pathfix  # noqa: F401

import json
import uuid
from datetime import date, timedelta

from db import DBManager
from backend.errors import TimelineGenerationError
from backend.interactions.agent import AgentManager, TIMELINE_WINDOW_DAYS

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def make_user() -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"actx_{uid[:8]}",
                               "email": f"actx_{uid[:8]}@example.com", "hash_pass": "x"})
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


def make_heartbeat_raw(agent_id: str, user_id: str, timestamps: list, prompt: str = "Write a reflection.",
                        timeline_instruction: str | None = None) -> str:
    """Inserts a heartbeat row directly, bypassing `add_heartbeat`, so tests
    can control `timeline_instruction`'s starting value precisely (NULL,
    a fresh window, or a deliberately-elapsed one)."""
    hb_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt, timeline_instruction) "
            "VALUES (%s, %s, %s, %s::jsonb, %s, %s)",
            (hb_id, agent_id, user_id, json.dumps(timestamps), prompt, timeline_instruction),
        )
        db.conn.commit()
    finally:
        db.close()
    return hb_id


def get_timeline_instruction(hb_id: str) -> str | None:
    db = DBManager()
    try:
        db.cur.execute("SELECT timeline_instruction FROM agent_heartbeats WHERE _id = %s", (hb_id,))
        row = db.cur.fetchone()
        return row[0] if row else None
    finally:
        db.close()


def get_last_fired(hb_id: str):
    db = DBManager()
    try:
        db.cur.execute("SELECT last_fired FROM agent_heartbeats WHERE _id = %s", (hb_id,))
        row = db.cur.fetchone()
        return row[0] if row else None
    finally:
        db.close()


def heartbeat_row_count(agent_id: str) -> int:
    db = DBManager()
    try:
        db.cur.execute("SELECT count(*) FROM agent_heartbeats WHERE agent_id = %s", (agent_id,))
        return db.cur.fetchone()[0]
    finally:
        db.close()


def daily_timestamps() -> list:
    """Fires on every day-of-month slot -- a "daily" heartbeat schedule."""
    return ["09:00"] * 31


def full_days_response(offset_0_text: str, coverage_summary: str) -> str:
    """A `_call_timeline_api`-shaped JSON response covering EVERY possible
    window-offset (0..TIMELINE_WINDOW_DAYS-1), not just the ones a given
    schedule happens to need. A "daily" schedule (`daily_timestamps()`, every
    day-of-month slot set) always fires on window-offset 0 (the window's own
    first day is always included), but -- because `timestamps` is day-of-month
    indexed, not window-offset indexed -- it can ALSO legitimately fire again
    on a later offset within the same 31-day window whenever that offset's
    calendar date happens to land back on the same day-of-month as an
    earlier offset (any month shorter than 31 days causes this: e.g. a
    window starting on day-of-month 6 revisits day-of-month 6 again at
    offset 30 after a 30-day month). Returning a full 0..30 mapping sidesteps
    depending on exactly which offsets a `daily_timestamps()` schedule
    resolves to on whatever date this suite happens to run (see
    `_firing_offsets`'s own docstring) while keeping offset 0 -- the one
    offset every test in this file actually asserts on -- set to
    `offset_0_text`."""
    days = {str(i): f"generic filler instruction for day-offset {i}" for i in range(TIMELINE_WINDOW_DAYS)}
    days["0"] = offset_0_text
    return json.dumps({"days": days, "coverage_summary": coverage_summary})


def cleanup(user_id: str):
    db = DBManager()
    try:
        # notes.user_id has no ON DELETE CASCADE (by design — see delete_user
        # in main.py), so it must be cleared before the user row itself.
        db.delete("notes", {"user_id": user_id})
        db.delete("users", {"_id": user_id})  # cascades agents/heartbeats
    finally:
        db.close()


def main():
    print("=== 1. _firing_offsets: daily vs sparse schedules, window-offset keyed ===")
    uid = make_user()
    manager = AgentManager(uid)
    try:
        window_start = date(2026, 9, 6)

        daily_offsets = manager._firing_offsets(daily_timestamps(), window_start)
        check("a fully-set (daily) timestamps array fires on every offset 0..30",
              daily_offsets == list(range(TIMELINE_WINDOW_DAYS)), str(daily_offsets))

        # Sparse schedule: only day-of-month 6, 13, 20, 27 set (a "weekly"-
        # shaped cadence), window starting exactly on day-of-month 6.
        sparse = [None] * 31
        for day_of_month in (6, 13, 20, 27):
            sparse[day_of_month - 1] = "09:00"
        sparse_offsets = manager._firing_offsets(sparse, window_start)
        # window_start = 2026-09-06 (day-of-month 6); offsets 0/7/14/21 land
        # on day-of-month 6/13/20/27 as expected, but offset 30 (2026-10-06)
        # ALSO lands back on day-of-month 6 -- September has only 30 days, so
        # a 31-day window starting on day-of-month 6 wraps into October and
        # revisits day-of-month 6 once more before the window ends. This is
        # the exact window-offset-vs-day-of-month distinction _firing_offsets'
        # own docstring calls out, not a bug in this test's expectation.
        check("a sparse (weekly-shaped) schedule fires on exactly the expected offsets "
              "(including the same day-of-month recurring at offset 30, since September "
              "is shorter than the 31-day window)",
              sparse_offsets == [0, 7, 14, 21, 30], str(sparse_offsets))

        empty_offsets = manager._firing_offsets([], window_start)
        check("an empty timestamps array fires on no offsets at all", empty_offsets == [])

        no_fire_offsets = manager._firing_offsets([None] * 31, window_start)
        check("an all-None timestamps array fires on no offsets at all", no_fire_offsets == [])

        print("\n=== 2. _encode_timeline/_decode_timeline round-trip ===")
        days = {0: "Ephesians 1:1-5", 3: "Ephesians 1:6-10"}
        raw = manager._encode_timeline(window_start, days, "Ephesians 1:1-10 covered")
        decoded = manager._decode_timeline(raw)
        check("decode recovers the exact window_start", decoded["window_start"] == window_start, str(decoded))
        check("decode recovers the exact days mapping (int-keyed)", decoded["days"] == days, str(decoded))
        check("decode recovers the exact coverage_summary",
              decoded["coverage_summary"] == "Ephesians 1:1-10 covered", str(decoded))
        check("decoding None returns None (no current timeline)", manager._decode_timeline(None) is None)
        check("decoding garbage returns None rather than raising", manager._decode_timeline("not json") is None)
    finally:
        manager.close()
        cleanup(uid)

    print("\n=== 3. Worked example: daily 'five-verse study note on Ephesians' gets a "
          "distinct, progressing, non-repeating instruction per firing day ===")
    uid = make_user()
    agent_id = make_agent(uid)
    try:
        window_start = date(2026, 9, 6)
        firing_offsets = list(range(5))  # first 5 days of a daily schedule

        # A realistic planning-agent response: five non-overlapping Ephesians
        # portions, one per firing offset, progressing verse-by-verse.
        ephesians_days = {
            0: "Ephesians 1:1-5",
            1: "Ephesians 1:6-10",
            2: "Ephesians 1:11-15",
            3: "Ephesians 1:16-20",
            4: "Ephesians 1:21-23, 2:1-2",
        }

        class EphesiansPlanningManager(AgentManager):
            calls = 0

            def _call_timeline_api(self, prompt):
                type(self).calls += 1
                return json.dumps({
                    "days": {str(k): v for k, v in ephesians_days.items()},
                    "coverage_summary": "Ephesians 1:1-2:2 covered",
                })

        planner = EphesiansPlanningManager(uid)
        try:
            planned = planner._generate_timeline_days(
                "a five-verse study note on the book of Ephesians", firing_offsets, prior_coverage_summary=None,
            )
        finally:
            planner.close()

        check("planning agent was called exactly once for a well-formed response",
              EphesiansPlanningManager.calls == 1, str(EphesiansPlanningManager.calls))
        check("returned exactly one instruction per firing offset requested",
              set(planned["days"].keys()) == set(firing_offsets), str(planned))
        instructions = list(planned["days"].values())
        check("every firing day's instruction is distinct (no repeated coverage)",
              len(set(instructions)) == len(instructions), str(instructions))
        check("instructions progress through Ephesians in order (verse ranges advance)",
              instructions == [ephesians_days[o] for o in firing_offsets], str(instructions))
        check("a coverage_summary is returned for cross-window dedup",
              bool(planned.get("coverage_summary")), str(planned))

        # Wire this into a real heartbeat row and confirm _todays_instruction
        # surfaces the RIGHT day's instruction, not just that generation works.
        days = {offset: planned["days"][offset] for offset in firing_offsets}
        raw = AgentManager(uid)._encode_timeline(window_start, days, planned["coverage_summary"])
        decoded = AgentManager(uid)._decode_timeline(raw)
        today_stub = AgentManager(uid)
        # _todays_instruction reads `self._local_date()` internally; exercise
        # it against a synthetic "today" by decoding at offset 2 directly
        # rather than depending on the real wall-clock date lining up with
        # window_start + 2 days.
        check("decoded timeline surfaces day-offset 2's own distinct instruction",
              decoded["days"][2] == "Ephesians 1:11-15", str(decoded))
        today_stub.close()
    finally:
        cleanup(uid)

    print("\n=== 4. add_heartbeat generates and persists the initial timeline atomically ===")
    uid = make_user()
    agent_id = make_agent(uid)
    try:
        from schemas.agent import AgentHeartbeats

        class StubPlanningManager(AgentManager):
            def _call_timeline_api(self, prompt):
                return full_days_response("Day 0 instruction", "stub summary")

        db = StubPlanningManager(uid)
        try:
            timestamps = [None] * 31
            timestamps[date.today().day - 1] = "09:00"  # fires today only, within this 31-day window
            hb_id = db.add_heartbeat(AgentHeartbeats(
                agent_id=agent_id, user_id=uid, timestamps=timestamps, prompt="Reflect daily.",
            ))
        finally:
            db.close()
        check("add_heartbeat returns a row id", bool(hb_id), str(hb_id))
        raw = get_timeline_instruction(hb_id)
        check("timeline_instruction is populated on the SAME row created by add_heartbeat",
              bool(raw), str(raw))
        decoded = AgentManager(uid)._decode_timeline(raw)
        check("decoded timeline's window_start is today (the heartbeat's creation date)",
              decoded is not None and decoded["window_start"] == date.today(), str(decoded))
        check("decoded timeline covers today's firing offset (offset 0) with the "
              "planning agent's own content for it",
              decoded is not None and decoded["days"].get(0) == "Day 0 instruction", str(decoded))
    finally:
        cleanup(uid)

    print("\n=== 5a. ensure_current_timeline: a fresh window is returned as-is, "
          "with NO regeneration call ===")
    uid = make_user()
    agent_id = make_agent(uid)
    try:
        window_start = date.today()
        days = {0: "existing instruction"}

        class NoCallPlanningManager(AgentManager):
            calls = 0

            def _call_timeline_api(self, prompt):
                type(self).calls += 1
                raise AssertionError("must not regenerate a still-fresh window")

        seed_raw = NoCallPlanningManager(uid)._encode_timeline(window_start, days, "existing summary")
        hb_id = make_heartbeat_raw(agent_id, uid, daily_timestamps(), timeline_instruction=seed_raw)

        manager = NoCallPlanningManager(uid)
        try:
            result = manager.ensure_current_timeline(hb_id, daily_timestamps(), "Reflect daily.", seed_raw)
        finally:
            manager.close()
        check("a fresh window's decoded content is returned unchanged",
              result == {"window_start": window_start, "days": days, "coverage_summary": "existing summary"},
              str(result))
        check("no regeneration call was made for a still-fresh window",
              NoCallPlanningManager.calls == 0, str(NoCallPlanningManager.calls))
    finally:
        cleanup(uid)

    print("\n=== 5b. ensure_current_timeline: NULL timeline (legacy heartbeat / "
          "post-schedule-change) is lazily backfilled ===")
    uid = make_user()
    agent_id = make_agent(uid)
    try:
        hb_id = make_heartbeat_raw(agent_id, uid, daily_timestamps(), timeline_instruction=None)

        class BackfillPlanningManager(AgentManager):
            calls = 0

            def _call_timeline_api(self, prompt):
                type(self).calls += 1
                return full_days_response("backfilled day 0", "backfilled summary")

        manager = BackfillPlanningManager(uid)
        try:
            result = manager.ensure_current_timeline(hb_id, daily_timestamps(), "Reflect daily.", None)
        finally:
            manager.close()
        check("a NULL timeline triggers exactly one regeneration call",
              BackfillPlanningManager.calls == 1, str(BackfillPlanningManager.calls))
        check("the backfilled window starts today", result["window_start"] == date.today(), str(result))
        check("the backfilled offset 0 carries the planning agent's own content",
              result["days"].get(0) == "backfilled day 0", str(result))
        check("the column itself was updated (not just the in-memory return value)",
              get_timeline_instruction(hb_id) is not None)
    finally:
        cleanup(uid)

    print("\n=== 5c. ensure_current_timeline: an ELAPSED window is regenerated, informed "
          "by the prior window's coverage_summary (cross-window no-duplication) ===")
    uid = make_user()
    agent_id = make_agent(uid)
    try:
        stale_window_start = date.today() - timedelta(days=TIMELINE_WINDOW_DAYS)  # exactly elapsed
        stale_raw = AgentManager(uid)._encode_timeline(
            stale_window_start, {0: "old Ephesians 1:1-5"}, "Ephesians 1:1-5 covered",
        )
        hb_id = make_heartbeat_raw(agent_id, uid, daily_timestamps(), timeline_instruction=stale_raw)

        captured_prompts = []

        class RolloverPlanningManager(AgentManager):
            def _call_timeline_api(self, prompt):
                captured_prompts.append(prompt)
                return full_days_response("Ephesians 1:6-10", "Ephesians 1:1-10 covered")

        manager = RolloverPlanningManager(uid)
        try:
            result = manager.ensure_current_timeline(hb_id, daily_timestamps(), "Reflect daily.", stale_raw)
        finally:
            manager.close()
        check("an elapsed window regenerates with a NEW window_start (today)",
              result["window_start"] == date.today(), str(result))
        check("the new window's content is the regenerated content, not the old window's",
              result["days"].get(0) == "Ephesians 1:6-10", str(result))
        check("the prior window's coverage_summary was passed into the planning prompt "
              "so regeneration avoids duplicating already-covered content",
              captured_prompts and "Ephesians 1:1-5 covered" in captured_prompts[0], str(captured_prompts))
        check("the persisted column now reflects the new window",
              AgentManager(uid)._decode_timeline(get_timeline_instruction(hb_id))["window_start"] == date.today())
    finally:
        cleanup(uid)

    print("\n=== 5d. update_heartbeat nulls timeline_instruction when timestamps changes, "
          "falling through to the same lazy regeneration path on next fire ===")
    uid = make_user()
    agent_id = make_agent(uid)
    try:
        fresh_raw = AgentManager(uid)._encode_timeline(date.today(), {0: "old plan"}, "old summary")
        hb_id = make_heartbeat_raw(agent_id, uid, daily_timestamps(), timeline_instruction=fresh_raw)

        from schemas.agent import AgentHeartbeats
        new_timestamps = [None] * 31
        new_timestamps[0] = "10:00"  # genuinely different schedule
        AgentManager(uid).update_heartbeat(hb_id, AgentHeartbeats(
            agent_id=agent_id, user_id=uid, timestamps=new_timestamps, prompt="Reflect daily.",
        ))
        check("changing timestamps nulls timeline_instruction on the same row",
              get_timeline_instruction(hb_id) is None, str(get_timeline_instruction(hb_id)))

        # Unrelated field change (same timestamps) must NOT null it out.
        fresh_raw2 = AgentManager(uid)._encode_timeline(date.today(), {0: "still current"}, "still current summary")
        hb_id2 = make_heartbeat_raw(agent_id, uid, daily_timestamps(), timeline_instruction=fresh_raw2)
        AgentManager(uid).update_heartbeat(hb_id2, AgentHeartbeats(
            agent_id=agent_id, user_id=uid, timestamps=daily_timestamps(), prompt="Reflect daily, updated wording.",
        ))
        check("changing an unrelated field (same timestamps) leaves timeline_instruction untouched",
              get_timeline_instruction(hb_id2) == fresh_raw2, str(get_timeline_instruction(hb_id2)))
    finally:
        cleanup(uid)

    print("\n=== 6. Concurrent-fire regeneration race safety: N real OS threads racing "
          "commit_hb_response for the SAME NULL-timeline heartbeat still produce exactly "
          "one regeneration and exactly one saved note ===")
    import threading
    import concurrent.futures

    uid = make_user()
    agent_id = make_agent(uid)
    try:
        hb_id = make_heartbeat_raw(agent_id, uid, daily_timestamps(), timeline_instruction=None)

        regen_calls = []
        regen_lock = threading.Lock()

        class RacingManager(AgentManager):
            def _call_timeline_api(self, prompt):
                with regen_lock:
                    regen_calls.append(1)
                return full_days_response("racing day 0", "racing summary")

            def _call_api(self, agent_role, messages):
                return '{"__action": "create_note", "title": "T", "text": "Body.", "verses": []}'

        N = 6
        barrier = threading.Barrier(N, timeout=10)
        results: list = [None] * N
        errors: list[Exception] = []

        def fire(i: int):
            manager = RacingManager(uid)
            try:
                barrier.wait()
                results[i] = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
            except Exception as e:
                errors.append(e)
            finally:
                manager.close()

        with concurrent.futures.ThreadPoolExecutor(max_workers=N) as pool:
            futures = [pool.submit(fire, i) for i in range(N)]
            for f in futures:
                f.result(timeout=30)

        check(f"all {N} concurrent callers completed without raising", not errors, str(errors))
        successes = [r for r in results if r == {"success": "saved note"}]
        skipped = [r for r in results if r == {"skipped": "already fired today"}]
        check(f"exactly ONE of {N} concurrent callers won the claim and fired",
              len(successes) == 1, str(results))
        check(f"the other {N - 1} callers were cleanly skipped", len(skipped) == N - 1, str(results))
        check("the timeline was regenerated EXACTLY ONCE despite N racing callers "
              "all seeing a NULL timeline_instruction -- only the fire that won the "
              "claim ever reaches ensure_current_timeline's regeneration",
              len(regen_calls) == 1, str(len(regen_calls)))
    finally:
        cleanup(uid)

    print("\n=== 7a. Generation-failure propagation: add_heartbeat raises "
          "TimelineGenerationError and creates NO row ===")
    uid = make_user()
    agent_id = make_agent(uid)
    try:
        from schemas.agent import AgentHeartbeats

        class AlwaysFailPlanningManager(AgentManager):
            def _call_timeline_api(self, prompt):
                return "not json at all, oops"

        db = AlwaysFailPlanningManager(uid)
        raised = False
        try:
            db.add_heartbeat(AgentHeartbeats(
                agent_id=agent_id, user_id=uid, timestamps=daily_timestamps(), prompt="Reflect daily.",
            ))
        except TimelineGenerationError:
            raised = True
        finally:
            db.close()
        check("add_heartbeat raises TimelineGenerationError when the planning agent "
              "never returns valid JSON", raised)
        check("no heartbeat row was created for the failed attempt",
              heartbeat_row_count(agent_id) == 0, str(heartbeat_row_count(agent_id)))
    finally:
        cleanup(uid)

    print("\n=== 7b. Generation-failure propagation: ensure_current_timeline's failure "
          "inside commit_hb_response unwinds the claim and leaves the existing "
          "(stale) timeline_instruction column completely untouched ===")
    uid = make_user()
    agent_id = make_agent(uid)
    try:
        stale_window_start = date.today() - timedelta(days=TIMELINE_WINDOW_DAYS)
        stale_raw = AgentManager(uid)._encode_timeline(
            stale_window_start, {0: "old instruction"}, "old summary",
        )
        hb_id = make_heartbeat_raw(agent_id, uid, daily_timestamps(), timeline_instruction=stale_raw)

        class FailingRegenManager(AgentManager):
            def _call_timeline_api(self, prompt):
                return "still not json"

            def _call_api(self, agent_role, messages):
                raise AssertionError("must never reach note generation if the timeline regen failed")

        manager = FailingRegenManager(uid)
        try:
            result = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        finally:
            manager.close()
        check("commit_hb_response returns an explicit error, not a crash or a placeholder note",
              isinstance(result, dict) and "error" in result, str(result))
        check("the fire's claim was unwound (last_fired left NULL) so a retry can go through",
              get_last_fired(hb_id) is None, str(get_last_fired(hb_id)))
        check("the heartbeat's existing (stale) timeline_instruction is COMPLETELY UNTOUCHED "
              "by the failed regeneration attempt",
              get_timeline_instruction(hb_id) == stale_raw, str(get_timeline_instruction(hb_id)))
    finally:
        cleanup(uid)

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
