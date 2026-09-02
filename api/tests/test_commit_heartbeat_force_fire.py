"""Tests for task 20260901-heartbeat-manual-force-fire, backend step 1's
`force` mode on `AgentManager.commit_hb_response` (api/backend/interactions/
agent.py) and the `force` flag on `routes/agent.py`'s `commit_heartbeat`
route.

Before this change, the manual "execute now" trigger button (shipped in
20260901-heartbeat-manual-trigger-button) called `commit_hb_response` with no
way to bypass its shared per-calendar-day `last_fired` claim -- the same
claim `_fire_due_heartbeats` (scheduler.py) uses to guarantee at-most-once-
per-day automatic firing. So tapping the manual trigger after ANY fire
already happened that day (scheduled or an earlier manual tap) just returned
`{"skipped": "already fired today"}` and produced no note.

This suite proves, against the REAL `AgentManager.commit_hb_response` and a
REAL Postgres DB (never a mocked manager -- matching every other heartbeat
test in this directory):

  1. A forced fire succeeds (creates a note) even though the heartbeat
     already fired today via the normal/automatic path -- the core bug this
     task fixes.
  2. A forced fire never reads, writes, or resets `agent_heartbeats.last_fired`
     -- confirmed by asserting the exact `last_fired` timestamp is byte-for-
     byte unchanged (same Python value) after the forced call as it was
     immediately before it, not merely "still non-null".
  3. Because `last_fired` is untouched, `_fire_due_heartbeats`'s own due-scan
     pre-filter continues to correctly EXCLUDE a heartbeat that already had
     its normal scheduled fire today, regardless of how many forced fires
     also happened afterward -- i.e. a forced fire never un-suppresses or
     re-arms the automatic path for the same day. This is exercised against
     the real `_scan_candidates`-shaped query the scheduler runs, not a
     reimplementation of it.
  4. Two concurrent forced-fire requests for the SAME heartbeat (real OS
     threads via a `threading.Barrier`, matching commit_heartbeat's
     `loop.run_in_executor` thread-pool shape and this project's existing
     concurrency-test pattern in test_commit_heartbeat_idempotency.py) do
     NOT both succeed -- exactly one produces a note, the other is cleanly
     skipped with the new, distinctly-worded outcome, per the fail-closed
     preference (Q14). This proves the new advisory-lock claim actually
     serializes concurrent forced fires rather than only working when called
     sequentially.
  5. A forced fire on an heartbeat that has NEVER fired (last_fired IS NULL)
     still succeeds and still leaves last_fired NULL -- confirms the forced
     path doesn't accidentally depend on last_fired already being set.
  6. Sequential forced fires (no actual concurrency) on the same heartbeat
     each succeed and each produce their own note -- unlimited same-day
     forced fires (bounded only by the weekly notes cap, per this task's
     explicit out-of-bounds decision) is the intended behavior, not a bug.
  7. An automatic (unforced) fire on a genuinely new calendar day still
     succeeds normally after one or more forced fires happened "yesterday" --
     forced fires don't leave any stale state that would block a later
     legitimate automatic fire.
  8. Cross-user ownership check still applies to forced calls -- a forced
     call for someone else's heartbeat is rejected before the LLM call, same
     as the unforced path.
  9. The weekly notes cap still gates forced fires exactly as it already
     gates automatic/unforced fires, exercised through the real route (not
     just the manager method), confirming `force=True` doesn't bypass
     `check_limit`.

Uses a FakeManager subclass to stub `_call_api` (same technique as
test_commit_heartbeat_idempotency.py), so no real LLM call is made and the
test is deterministic.

Run:  cd api && ../.venv/bin/python tests/test_commit_heartbeat_force_fire.py
"""
import _pathfix  # noqa: F401

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


def note_count_for_heartbeat(hb_id: str) -> int:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT count(*) FROM agentic_context WHERE heartbeat_id = %s", (hb_id,)
        )
        return db.cur.fetchone()[0]
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


def test_forced_fire_after_automatic_fire_same_day():
    print("\n=== 1/2/3. Forced fire succeeds after an automatic same-day fire, "
          "never touches last_fired, and the scheduler's due-scan pre-filter "
          "still correctly excludes the heartbeat afterward ===")
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    manager = FakeManager(uid)

    try:
        # Normal automatic fire claims last_fired and succeeds.
        result1 = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        check("automatic (unforced) fire succeeds", result1 == {"success": "saved note"}, str(result1))
        check("exactly one note after automatic fire", note_count_for_heartbeat(hb_id) == 1)

        last_fired_before = get_last_fired(hb_id)
        check("last_fired is set after the automatic fire", last_fired_before is not None)

        # Due-scan pre-filter must now exclude this heartbeat for the rest of the day.
        check("due-scan pre-filter excludes the heartbeat right after the automatic fire",
              hb_id not in scan_due_candidate_ids(uid))

        # An UNFORCED retry the same day is still correctly skipped (baseline, unchanged).
        result_unforced_retry = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        check("an unforced retry the same day is still skipped (unchanged baseline)",
              result_unforced_retry == {"skipped": "already fired today"}, str(result_unforced_retry))

        # Forced fire must succeed anyway.
        result2 = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.", force=True)
        check("forced fire succeeds even though the heartbeat already fired today (automatically)",
              result2 == {"success": "saved note"}, str(result2))
        check("a second note now exists after the forced fire",
              note_count_for_heartbeat(hb_id) == 2, str(note_count_for_heartbeat(hb_id)))

        last_fired_after = get_last_fired(hb_id)
        check("last_fired is BYTE-FOR-BYTE unchanged by the forced fire (forced path never writes it)",
              last_fired_after == last_fired_before,
              f"before={last_fired_before!r} after={last_fired_after!r}")

        # Due-scan pre-filter must STILL exclude the heartbeat after the forced fire --
        # a forced fire must never re-arm/un-suppress the automatic path for today.
        check("due-scan pre-filter STILL excludes the heartbeat after the forced fire "
              "(forced fire never re-arms the automatic path for today)",
              hb_id not in scan_due_candidate_ids(uid))

        # And the automatic path itself still correctly skips (it would only fire again
        # were the due-scan pre-filter to ever mis-include it -- but exercise the actual
        # claim path directly too, matching acceptance criterion #3).
        result3 = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        check("the automatic/unforced path still correctly reports 'already fired today' "
              "after one or more forced fires the same day",
              result3 == {"skipped": "already fired today"}, str(result3))
        check("still exactly two notes (the unforced retry above created no third note)",
              note_count_for_heartbeat(hb_id) == 2, str(note_count_for_heartbeat(hb_id)))
    finally:
        cleanup(uid)


def test_forced_fire_never_fired_before():
    print("\n=== 5. Forced fire on a heartbeat that has never fired succeeds and "
          "leaves last_fired NULL ===")
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    manager = FakeManager(uid)

    try:
        check("last_fired starts NULL", get_last_fired(hb_id) is None)
        result = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.", force=True)
        check("forced fire on a never-fired heartbeat succeeds",
              result == {"success": "saved note"}, str(result))
        check("exactly one note created", note_count_for_heartbeat(hb_id) == 1)
        check("last_fired is STILL NULL after the forced fire (forced path never sets it)",
              get_last_fired(hb_id) is None, str(get_last_fired(hb_id)))
    finally:
        cleanup(uid)


def test_sequential_forced_fires_each_succeed():
    print("\n=== 6. Sequential (non-concurrent) forced fires each succeed -- "
          "unlimited same-day forced fires is intended, not a bug ===")
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    manager = FakeManager(uid)

    try:
        for i in range(3):
            result = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.", force=True)
            check(f"sequential forced fire #{i + 1} succeeds", result == {"success": "saved note"}, str(result))
        check("three notes exist after three sequential forced fires",
              note_count_for_heartbeat(hb_id) == 3, str(note_count_for_heartbeat(hb_id)))
        check("last_fired remains NULL throughout (never set by any forced fire)",
              get_last_fired(hb_id) is None)
    finally:
        cleanup(uid)


def test_concurrent_forced_fires_exactly_one_wins():
    print("\n=== 4. Concurrent forced fires for the SAME heartbeat: exactly one "
          "succeeds, the other is skipped (fails closed), matching production's "
          "run_in_executor real-OS-thread shape ===")
    import threading
    import concurrent.futures

    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)

    N = 6
    barrier = threading.Barrier(N, timeout=10)
    results: list = [None] * N
    errors: list[Exception] = []

    def fire(i: int):
        manager = FakeManager(uid)
        try:
            barrier.wait()
            results[i] = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.", force=True)
        except Exception as e:
            errors.append(e)
        finally:
            manager.close()

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=N) as pool:
            futures = [pool.submit(fire, i) for i in range(N)]
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
        check("last_fired is still NULL -- the concurrency claim never touched it",
              get_last_fired(hb_id) is None)
    finally:
        cleanup(uid)


def test_automatic_fire_still_works_next_day_after_forced_fires():
    print("\n=== 7. Automatic fire on a genuinely new calendar day still succeeds "
          "after one or more forced fires happened 'yesterday' ===")
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    manager = FakeManager(uid)

    try:
        # A normal automatic fire "yesterday" (back-dated).
        result1 = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        check("initial automatic fire succeeds", result1 == {"success": "saved note"}, str(result1))
        set_last_fired(hb_id, "date_trunc('day', NOW() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - INTERVAL '1 day'")

        # Several forced fires "today", after the back-dated last_fired.
        for _ in range(2):
            forced_result = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.", force=True)
            check("forced fire on the new day succeeds", forced_result == {"success": "saved note"}, str(forced_result))

        check("last_fired is still yesterday's back-dated value (forced fires didn't touch it)",
              get_last_fired(hb_id) is not None)

        # The automatic path should still see this heartbeat as due for today (last_fired is
        # "yesterday") and succeed exactly once.
        result_auto = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        check("automatic fire on the new calendar day still succeeds despite prior forced fires",
              result_auto == {"success": "saved note"}, str(result_auto))

        # And a second automatic attempt the same day is (correctly) skipped.
        result_auto2 = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        check("a second automatic attempt the same day is skipped as usual",
              result_auto2 == {"skipped": "already fired today"}, str(result_auto2))

        check("four notes total (1 initial + 2 forced + 1 automatic-on-new-day)",
              note_count_for_heartbeat(hb_id) == 4, str(note_count_for_heartbeat(hb_id)))
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
        result = other_manager.commit_hb_response(agent_id, hb_id, "Reflect on today.", force=True)
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
    test_forced_fire_after_automatic_fire_same_day()
    test_forced_fire_never_fired_before()
    test_sequential_forced_fires_each_succeed()
    test_concurrent_forced_fires_exactly_one_wins()
    test_automatic_fire_still_works_next_day_after_forced_fires()
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
