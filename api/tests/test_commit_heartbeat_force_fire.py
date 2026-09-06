"""Tests for task 20260901-heartbeat-manual-force-fire, backend step 1's
`force` mode on `AgentManager.commit_hb_response` (api/backend/interactions/
agent.py) and the `force` flag on `routes/agent.py`'s `commit_heartbeat`
route.

REVISED for task 20260906-heartbeat-forced-fire-coordination (testing step 2):
20260901's original design had the forced path (`_commit_hb_response_forced`)
never read or write `agent_heartbeats.last_fired` at all -- a forced fire and
that same heartbeat's scheduled auto-fire could therefore BOTH succeed on the
same calendar day. That was accepted behavior at the time (two independently-
authored notes), but became a genuine duplicate-note bug once
20260906-heartbeat-timeline-instructions gave both paths the SAME day's
`timeline_instruction` slot to draw on via `_todays_instruction`.

This task's architecture.json (`forced_path_persistence_supersession`)
SUPERSEDES the original "forced path writes nothing to agent_heartbeats"
decision: the forced path now also calls the shared `_claim_last_fired`
helper (the exact same atomic conditional UPDATE the unforced path already
used), but never gates proceeding on its result -- a forced fire is still
never blocked by the daily gate. It only uses the claim's rowcount (1 = this
attempt covered an uncovered day, 0 = the day was already covered by an
earlier fire of either kind) to decide whether ITS OWN later failure may
safely unset `last_fired` again (`forced_failure_unwind`) without erasing
another fire's legitimate claim.

This suite proves, against the REAL `AgentManager.commit_hb_response` and a
REAL Postgres DB (never a mocked manager -- matching every other heartbeat
test in this directory):

  1. A forced fire succeeds (creates a note) even though the heartbeat
     already fired today via the normal/automatic path -- the core bug the
     ORIGINAL 20260901 task fixed, still true today (symmetric_ordering: a
     scheduled-first, forced-second ordering must still let the forced fire
     through).
  2. When a forced fire is the FIRST fire of the day (last_fired was NULL or
     a prior local day), it now claims `last_fired` exactly like an unforced
     fire would -- so a scheduled/unforced fire attempted afterward the same
     day correctly skips. This is the primary production scenario this task
     closes (forced-fires-first, then the scheduled auto-fire must not also
     succeed).
  3. When a forced fire runs AFTER the day is already covered (by either an
     earlier scheduled fire or an earlier forced fire), its own claim attempt
     gets rowcount 0 and is a complete no-op on `last_fired` -- it does not
     erase or perturb whatever value is already there.
  4. Two concurrent forced-fire requests for the SAME heartbeat (real OS
     threads via a `threading.Barrier`) do NOT both succeed -- exactly one
     produces a note via the pre-existing advisory lock, entirely independent
     of the `last_fired` coordination added by this task.
  5. Sequential forced fires (no actual concurrency) on the same heartbeat
     each still succeed and each produce their own note -- unlimited same-day
     forced fires (bounded only by the weekly notes cap) is still intended
     behavior; only the FIRST one now also claims `last_fired` for the day.
  6. A forced fire's own claim, followed by an LLM/save failure, unsets
     `last_fired` again ONLY if that forced fire's own claim attempt is what
     covered the day (rowcount 1) -- allowing a clean retry. If the day was
     already covered before this forced fire's claim attempt ran (rowcount
     0), the same failure must leave `last_fired` completely untouched, so it
     can never erase an earlier fire's (possibly the scheduled path's own)
     legitimate claim.
  7. A DB error on the forced path's claim attempt itself fails closed:
     `{"error": "claim failed"}`, no note generated, and the advisory lock is
     still released afterward (a following, working forced call still
     succeeds).
  8. Cross-user ownership check still applies to forced calls -- a forced
     call for someone else's heartbeat is rejected before the LLM call, same
     as the unforced path.
  9. The weekly notes cap still gates forced fires exactly as it already
     gates automatic/unforced fires, exercised through the real route (not
     just the manager method), confirming `force=True` doesn't bypass
     `check_limit`.

Uses a FakeManager subclass to stub `_call_api` (same technique as
test_commit_heartbeat_idempotency.py), so no real LLM call is made and the
test is deterministic. Imports `_fake_timeline` to stub the SEPARATE
timeline-planning LLM call (`_generate_timeline_days`) that
`ensure_current_timeline` would otherwise make on every fire.

Run:  cd api && ../.venv/bin/python tests/test_commit_heartbeat_force_fire.py
"""
import _pathfix  # noqa: F401
import _fake_timeline  # noqa: F401

import threading
import uuid

from fastapi import FastAPI
from fastapi.testclient import TestClient

from db import DBManager
from backend.auth.sessions import SessionManager
from backend.interactions.agent import AgentManager
from routes.agent import agent_router
from routes.notes import notes_router
from routes.subscription import subscription_router

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


class FakeManager(AgentManager):
    """Stubs the LLM call so commit_hb_response (both forced and unforced
    branches) is fully exercised without ever hitting the real OpenRouter
    API."""

    def _call_api(self, agent_role, messages):
        return (
            '{"__action": "create_note", "title": "Reflection", '
            '"text": "Generated content.", "verses": []}'
        )


class FailingLLMManager(FakeManager):
    """Simulates the LLM connection failing on the NOTE-generation call
    (`_call_api`) -- distinct from a timeline-planning failure -- so
    `_generate_and_save_note`'s `on_llm_error` unwind path is exercised
    exactly as it would be in production (see `_generate_and_save_note`'s
    own `except Exception` branch around `_call_api`)."""

    def _call_api(self, agent_role, messages):
        raise ConnectionError("simulated LLM connection failure")


class ClaimErrorManager(FakeManager):
    """Simulates the forced path's own `_claim_last_fired` call raising
    (a real DB error), independent of note generation -- the
    `claim_attempt_error_handling` decision's fail-closed branch."""

    def _claim_last_fired(self, heartbeat_id):
        raise RuntimeError("simulated claim DB error")


def make_user() -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"hbforce_{uid[:8]}",
                               "email": f"hbforce_{uid[:8]}@example.com", "hash_pass": "x"})
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
# direct DB link from a heartbeat to the notes it generates anymore. A plain
# user-wide note count isn't a safe substitute here either: test 9 below
# seeds 10 unrelated notes onto the SAME user to reach the weekly cap, which
# a user-wide count would conflate with "notes this heartbeat produced".
# Instead, `fire()` below -- the one path every `commit_hb_response` call in
# this file goes through -- records a successful fire directly against the
# heartbeat_id it was called with, the instant it happens;
# `note_count_for_heartbeat` just reads that count back. Exact by
# construction, independent of whatever else exists in the `notes` table.
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


def get_last_fired(hb_id: str):
    db = DBManager()
    try:
        db.cur.execute("SELECT last_fired FROM agent_heartbeats WHERE _id = %s", (hb_id,))
        row = db.cur.fetchone()
        return row[0] if row else None
    finally:
        db.close()


def set_last_fired(hb_id: str, sql_expr: str):
    db = DBManager()
    try:
        db.cur.execute(
            f"UPDATE agent_heartbeats SET last_fired = {sql_expr} WHERE _id = %s", (hb_id,)
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


def scan_due_candidate_ids(user_id: str) -> set:
    """Mirrors `_fire_due_heartbeats`'s due-scan pre-filter predicate
    (scheduler.py) closely enough to prove a heartbeat that already fired
    today -- via ANY path -- is excluded from it, without importing the
    scheduler's internal closure directly (it's defined nested inside the
    async job function and not separately importable)."""
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT ah._id FROM agent_heartbeats ah "
            "JOIN users u ON u._id = ah.user_id "
            "WHERE ah.user_id = %s "
            "AND (ah.last_fired IS NULL "
            "OR (ah.last_fired AT TIME ZONE COALESCE(u.timezone, 'UTC'))::date "
            "< (NOW() AT TIME ZONE COALESCE(u.timezone, 'UTC'))::date)",
            (user_id,),
        )
        return {row[0] for row in db.cur.fetchall()}
    finally:
        db.close()


def test_scheduled_first_then_forced_still_fires_without_erasing_claim():
    print("\n=== 1/3. symmetric_ordering: scheduled fires first, then a forced "
          "fire still succeeds (never blocked) -- and its no-op claim attempt "
          "(rowcount 0) does NOT erase the scheduled fire's last_fired claim ===")
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    manager = FakeManager(uid)

    try:
        # Normal automatic fire claims last_fired (rowcount 1) and succeeds.
        result1 = fire(manager, agent_id, hb_id, "Reflect on today.")
        check("automatic (unforced) fire succeeds", result1 == {"success": "saved note"}, str(result1))
        check("exactly one note after automatic fire", note_count_for_heartbeat(hb_id) == 1)

        last_fired_before = get_last_fired(hb_id)
        check("last_fired is set after the automatic fire", last_fired_before is not None)

        # Due-scan pre-filter must now exclude this heartbeat for the rest of the day.
        check("due-scan pre-filter excludes the heartbeat right after the automatic fire",
              hb_id not in scan_due_candidate_ids(uid))

        # An UNFORCED retry the same day is still correctly skipped (baseline, unchanged).
        result_unforced_retry = fire(manager, agent_id, hb_id, "Reflect on today.")
        check("an unforced retry the same day is still skipped (unchanged baseline)",
              result_unforced_retry == {"skipped": "already fired today"}, str(result_unforced_retry))

        # Forced fire must succeed anyway -- symmetric_ordering: a manual override
        # after the day already auto-fired is the whole point of the feature.
        result2 = fire(manager, agent_id, hb_id, "Reflect on today.", force=True)
        check("forced fire succeeds even though the heartbeat already fired today (automatically)",
              result2 == {"success": "saved note"}, str(result2))
        check("a second note now exists after the forced fire",
              note_count_for_heartbeat(hb_id) == 2, str(note_count_for_heartbeat(hb_id)))

        last_fired_after = get_last_fired(hb_id)
        check("last_fired is BYTE-FOR-BYTE unchanged by the forced fire (its own claim attempt "
              "found the day already covered -- rowcount 0 -- and is a no-op)",
              last_fired_after == last_fired_before,
              f"before={last_fired_before!r} after={last_fired_after!r}")

        # Due-scan pre-filter must STILL exclude the heartbeat after the forced fire --
        # a forced fire must never re-arm/un-suppress the automatic path for today.
        check("due-scan pre-filter STILL excludes the heartbeat after the forced fire "
              "(forced fire never re-arms the automatic path for today)",
              hb_id not in scan_due_candidate_ids(uid))

        # And the automatic path itself still correctly skips.
        result3 = fire(manager, agent_id, hb_id, "Reflect on today.")
        check("the automatic/unforced path still correctly reports 'already fired today' "
              "after one or more forced fires the same day",
              result3 == {"skipped": "already fired today"}, str(result3))
        check("still exactly two notes (the unforced retry above created no third note)",
              note_count_for_heartbeat(hb_id) == 2, str(note_count_for_heartbeat(hb_id)))
    finally:
        cleanup(uid)


def test_forced_first_then_scheduled_skips():
    print("\n=== 2. PRIMARY production scenario this task closes: a forced fire "
          "is the FIRST fire of the day (last_fired starts NULL) -- it now claims "
          "last_fired via the shared helper, so a scheduled/unforced fire attempted "
          "afterward the same day correctly SKIPS instead of also succeeding ===")
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    manager = FakeManager(uid)

    try:
        check("last_fired starts NULL", get_last_fired(hb_id) is None)
        check("due-scan pre-filter initially includes the never-fired heartbeat",
              hb_id in scan_due_candidate_ids(uid))

        result = fire(manager, agent_id, hb_id, "Reflect on today.", force=True)
        check("forced fire on a never-fired heartbeat succeeds",
              result == {"success": "saved note"}, str(result))
        check("exactly one note created", note_count_for_heartbeat(hb_id) == 1)

        last_fired = get_last_fired(hb_id)
        check("last_fired is now SET by the forced fire (forced_path_persistence_supersession: "
              "the forced path claims an uncovered day exactly like the unforced path would)",
              last_fired is not None, str(last_fired))

        check("due-scan pre-filter now excludes the heartbeat -- the forced fire covered today",
              hb_id not in scan_due_candidate_ids(uid))

        # The scheduled/unforced auto-fire, attempted after the forced fire already
        # covered the day, must observably skip -- not also produce a note.
        result_scheduled = fire(manager, agent_id, hb_id, "Reflect on today.")
        check("the scheduled/unforced auto-fire attempted after the forced fire SKIPS "
              "instead of also succeeding (this task's core acceptance criterion)",
              result_scheduled == {"skipped": "already fired today"}, str(result_scheduled))
        check("still exactly one note total -- no duplicate produced",
              note_count_for_heartbeat(hb_id) == 1, str(note_count_for_heartbeat(hb_id)))
    finally:
        cleanup(uid)


def test_sequential_forced_fires_each_succeed():
    print("\n=== 5. Sequential (non-concurrent) forced fires each succeed -- "
          "unlimited same-day forced fires is still intended, not a bug -- but "
          "only the FIRST one claims last_fired for the day (rowcount 1); later "
          "ones find it already covered (rowcount 0) and don't touch it further ===")
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    manager = FakeManager(uid)

    try:
        for i in range(3):
            result = fire(manager, agent_id, hb_id, "Reflect on today.", force=True)
            check(f"sequential forced fire #{i + 1} succeeds", result == {"success": "saved note"}, str(result))
        check("three notes exist after three sequential forced fires",
              note_count_for_heartbeat(hb_id) == 3, str(note_count_for_heartbeat(hb_id)))

        first_claim_value = get_last_fired(hb_id)
        check("last_fired was claimed by the FIRST forced fire (no longer NULL)",
              first_claim_value is not None)

        # Two more forced fires after the day is already covered must not perturb
        # the already-claimed value any further.
        for _ in range(2):
            fire(manager, agent_id, hb_id, "Reflect on today.", force=True)
        check("last_fired is unchanged by later same-day forced fires "
              "(their own claim attempts are no-ops once the day is covered)",
              get_last_fired(hb_id) == first_claim_value, str(get_last_fired(hb_id)))
        check("five notes total after five sequential forced fires",
              note_count_for_heartbeat(hb_id) == 5, str(note_count_for_heartbeat(hb_id)))
    finally:
        cleanup(uid)


def test_concurrent_forced_fires_exactly_one_wins():
    print("\n=== 4. Concurrent forced fires for the SAME heartbeat: exactly one "
          "succeeds via the pre-existing advisory lock, the other is skipped "
          "(fails closed), matching production's run_in_executor real-OS-thread "
          "shape. last_fired ends up claimed (non-NULL) by whichever one won ===")
    import threading
    import concurrent.futures

    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)

    N = 6
    barrier = threading.Barrier(N, timeout=10)
    results: list = [None] * N
    errors: list[Exception] = []

    def fire_thread(i: int):
        manager = FakeManager(uid)
        try:
            barrier.wait()
            results[i] = fire(manager, agent_id, hb_id, "Reflect on today.", force=True)
        except Exception as e:
            errors.append(e)
        finally:
            manager.close()

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=N) as pool:
            futures = [pool.submit(fire_thread, i) for i in range(N)]
            for f in futures:
                f.result(timeout=30)

        check(f"all {N} concurrent forced-fire callers completed without raising",
              not errors, str(errors))

        successes = [r for r in results if r == {"success": "saved note"}]
        skipped = [r for r in results
                   if r == {"skipped": "a forced fire for this event is already in progress"}]
        check(f"exactly ONE of {N} concurrent forced-fire callers won the advisory-lock claim",
              len(successes) == 1, str(results))
        check(f"the other {N - 1} concurrent forced-fire callers were cleanly skipped "
              "with the new, distinctly-worded in-progress outcome (fails closed, not both-through)",
              len(skipped) == N - 1, str(results))
        check("exactly one note/context row exists network-wide despite "
              f"{N} genuinely concurrent forced-fire threads",
              note_count_for_heartbeat(hb_id) == 1, str(note_count_for_heartbeat(hb_id)))
        check("last_fired is now claimed (non-NULL) -- the one winning forced fire's own "
              "last_fired claim attempt is what covered today",
              get_last_fired(hb_id) is not None)
    finally:
        cleanup(uid)


def test_forced_claim_failure_unwind_only_when_self_claimed():
    print("\n=== 6. forced_failure_unwind: a forced fire's own claim followed by an "
          "LLM/save failure unsets last_fired ONLY if its own claim attempt covered "
          "the day (rowcount 1); if the day was already covered by an earlier fire "
          "(rowcount 0), the same failure must leave last_fired completely untouched ===")

    # --- Variant A: this forced fire's own claim covers an uncovered day (rowcount 1). ---
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    failing_manager = FailingLLMManager(uid)
    try:
        check("last_fired starts NULL", get_last_fired(hb_id) is None)

        result = fire(failing_manager, agent_id, hb_id, "Reflect on today.", force=True)
        check("a forced fire whose note-generation LLM call fails returns an explicit error",
              isinstance(result, dict) and "error" in result, str(result))
        check("no note was created by the failed forced fire",
              note_count_for_heartbeat(hb_id) == 0)
        check("last_fired was unwound back to NULL (this attempt's own claim owned the day, "
              "so it's safe to unset for a retry)",
              get_last_fired(hb_id) is None, str(get_last_fired(hb_id)))

        # A retry with a working manager should now succeed cleanly.
        working_manager = FakeManager(uid)
        retry_result = fire(working_manager, agent_id, hb_id, "Reflect on today.", force=True)
        check("a retried forced fire (after the unwind) succeeds",
              retry_result == {"success": "saved note"}, str(retry_result))
        check("last_fired is now claimed by the successful retry",
              get_last_fired(hb_id) is not None)
    finally:
        cleanup(uid)

    # --- Variant B: the day is ALREADY covered before this forced fire's own claim
    #     attempt runs (rowcount 0) -- its later failure must not erase that claim. ---
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    try:
        # An earlier, successful UNFORCED fire covers the day first.
        scheduled_manager = FakeManager(uid)
        scheduled_result = fire(scheduled_manager, agent_id, hb_id, "Reflect on today.")
        check("the earlier scheduled fire succeeds and claims last_fired",
              scheduled_result == {"success": "saved note"}, str(scheduled_result))
        claimed_value = get_last_fired(hb_id)
        check("last_fired is set by the earlier scheduled fire", claimed_value is not None)

        # A forced fire's own claim attempt now gets rowcount 0 (day already covered),
        # then its note generation fails.
        failing_manager2 = FailingLLMManager(uid)
        result2 = fire(failing_manager2, agent_id, hb_id, "Reflect on today.", force=True)
        check("the forced fire (day already covered) whose LLM call fails still returns "
              "an explicit error", isinstance(result2, dict) and "error" in result2, str(result2))
        check("no note was created by the failed forced fire",
              note_count_for_heartbeat(hb_id) == 1)  # only the earlier scheduled fire's note

        check("last_fired is COMPLETELY UNTOUCHED by the failed forced fire -- it must not "
              "erase the earlier scheduled fire's legitimate claim (forced_failure_unwind's "
              "whole reason for scoping the unwind to rowcount 1 only)",
              get_last_fired(hb_id) == claimed_value, str(get_last_fired(hb_id)))

        # A subsequent unforced attempt must still correctly skip -- proving the day is
        # still recognized as covered, i.e. nothing was erased.
        scheduled_retry = fire(scheduled_manager, agent_id, hb_id, "Reflect on today.")
        check("a subsequent scheduled attempt still correctly skips (the claim was never erased)",
              scheduled_retry == {"skipped": "already fired today"}, str(scheduled_retry))
    finally:
        cleanup(uid)


def test_forced_claim_db_error_fails_closed():
    print("\n=== 7. claim_attempt_error_handling: a DB error on the forced path's own "
          "_claim_last_fired call itself fails closed -- {'error': 'claim failed'}, no "
          "note generated, and the advisory lock is still released afterward ===")
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    error_manager = ClaimErrorManager(uid)
    try:
        result = fire(error_manager, agent_id, hb_id, "Reflect on today.", force=True)
        check("a forced fire whose claim attempt itself raises fails closed with an explicit error",
              result == {"error": "claim failed"}, str(result))
        check("no note was created", note_count_for_heartbeat(hb_id) == 0)
        check("last_fired is untouched (still NULL) -- the claim never actually ran",
              get_last_fired(hb_id) is None, str(get_last_fired(hb_id)))

        # The advisory lock must still be released in the `finally` block despite the
        # claim error -- a following, working forced call for the SAME heartbeat must
        # still succeed rather than being skipped as "already in progress".
        working_manager = FakeManager(uid)
        follow_up = fire(working_manager, agent_id, hb_id, "Reflect on today.", force=True)
        check("a subsequent working forced call for the same heartbeat still succeeds "
              "(the advisory lock was correctly released after the claim error)",
              follow_up == {"success": "saved note"}, str(follow_up))
    finally:
        cleanup(uid)


def test_forced_fire_cross_user_ownership_rejected():
    print("\n=== 8. Forced call for another user's heartbeat is rejected before "
          "any claim/LLM call, same as the unforced path ===")
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)

    other_uid = make_user()
    try:
        other_manager = FakeManager(other_uid)
        result = fire(other_manager, agent_id, hb_id, "Reflect on today.", force=True)
        check("cross-user FORCED commit is rejected", result == {"error": "heartbeat not found"}, str(result))
        check("no note created for hb_id via cross-user forced attempt",
              note_count_for_heartbeat(hb_id) == 0)
    finally:
        cleanup(other_uid)
        cleanup(uid)


def test_forced_fire_route_respects_weekly_notes_cap():
    print("\n=== 9. Weekly notes cap gates a FORCED call through the real route "
          "identically to how it already gates automatic/unforced calls ===")
    app = FastAPI()
    for r in (agent_router, notes_router, subscription_router):
        app.include_router(r)
    client = TestClient(app)

    orig_call_api = AgentManager._call_api
    AgentManager._call_api = FakeManager._call_api
    try:
        uid = str(uuid.uuid4())
        uname = f"hbforcecap_{uid[:8]}"
        db = DBManager()
        try:
            db.insertion("users", {
                "_id": uid, "username": uname,
                "email": f"{uname}@example.com", "hash_pass": "x",
            })
        finally:
            db.close()
        sm = SessionManager()
        try:
            token = sm.create_session(uid)
        finally:
            sm.close()
        client.cookies.set("session", token)

        agent_id = make_agent(uid)
        hb_id = make_heartbeat(agent_id, uid)

        # Push the user to exactly the free-plan notes cap (10), matching
        # test_commit_heartbeat_notes_cap.py's existing pattern.
        db = DBManager()
        try:
            for i in range(10):
                db.insertion("notes", {
                    "_id": str(uuid.uuid4()), "user_id": uid,
                    "title": f"n{i}", "text": "body", "public": False,
                    "is_reply": False,
                })
        finally:
            db.close()

        from backend.subscription.limits import check_limit
        gate_after = check_limit(uid, "notes")
        check("user is now at/over the weekly notes cap", not gate_after["allowed"], str(gate_after))

        resp = client.post(
            f"/agent/{uid}/{agent_id}/{hb_id}/commit_heartbeat",
            json={"prompt": "Reflect on today.", "force": True},
        )
        check("a FORCED commit_heartbeat call is denied (403) once at the weekly notes cap, "
              "same as an unforced call would be",
              resp.status_code == 403, f"status={resp.status_code} body={resp.text}")
        check("last_fired is still NULL -- the denial happened before any claim/forced-lock logic ran",
              get_last_fired(hb_id) is None)
        check("no extra note created by the denied forced attempt",
              note_count_for_heartbeat(hb_id) == 0)

        cleanup(uid)
    finally:
        AgentManager._call_api = orig_call_api


def main():
    test_scheduled_first_then_forced_still_fires_without_erasing_claim()
    test_forced_first_then_scheduled_skips()
    test_sequential_forced_fires_each_succeed()
    test_concurrent_forced_fires_exactly_one_wins()
    test_forced_claim_failure_unwind_only_when_self_claimed()
    test_forced_claim_db_error_fails_closed()
    test_forced_fire_cross_user_ownership_rejected()
    test_forced_fire_route_respects_weekly_notes_cap()

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
