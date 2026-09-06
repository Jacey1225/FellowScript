"""Regression coverage for task 20260905-heartbeat-timezone-duplicate-bugs
(testing step 5), proving BOTH bugs' fixes hold end-to-end against a REAL
Postgres DB and the REAL routes -- never a mocked manager, matching every
other heartbeat test in this directory.

Bug 1 (timezone mismatch): before this task, iOS (EventSetupSheet.swift)
authored/read `AgentHeartbeats.timestamps` "HH:mm" strings as UTC
(`TimeZone(identifier: "UTC")`), while the backend (since
20260901-heartbeat-backend-scheduling's timezone_handling revision) already
interpreted the same field as literal local time in the owning user's
`users.timezone`. A user picking "9:00 AM" in a non-UTC timezone therefore
had their event fire hours off from what they configured (the reported
symptom: a 9:00 AM pick stored/fired as "19:00"). Backend step 1 made no
backend code change (the backend's local-time interpretation was already
correct); the fix is entirely on iOS (frontend steps 3-4, not testable from
Python). This suite's job is to prove the ACCEPTANCE CRITERION end-to-end
from the one entry point Python can drive -- the real `add_heartbeat` route,
fed exactly the literal "HH:mm" string iOS now produces post-fix (no UTC
conversion) -- through to `_fire_due_heartbeats` firing at that literal local
wall-clock time, not offset by the account's UTC delta:

  1. A heartbeat authored (via the real POST route, mirroring iOS's post-fix
     request body) with a literal "09:00" string for a user in a non-UTC
     timezone (America/Los_Angeles, UTC-7 under September DST) fires when
     that user's LOCAL clock reads 09:00 -- not when UTC reads 09:00 (which
     would be 2:00 AM Pacific, hours before the user's actual pick) and not
     at some other UTC-delta-shifted hour. This is the literal repro of the
     reported bug's numbers, run against the fixed (local-authored) client
     contract.
  2. Sanity/regression guard: the SAME instant that correctly fires the
     literal-local "09:00" row must NOT ALSO fire a sibling row using the OLD
     (buggy) UTC-authored convention for the same nominal 9:00 AM pick
     (which would have stored "16:00", 9:00 AM PDT converted to UTC) --
     proving the two conventions are genuinely different stored values that
     resolve to different fire times, not coincidentally the same slot.

Bug 2 (duplicate rows): `add_heartbeat` (api/backend/interactions/agent.py)
and `agent_heartbeats` (api/db.py) had no uniqueness constraint or
idempotency mechanism -- ANY duplicate submission (double-tap, retry) was
accepted as two independent rows. Backend step 2 added an `idempotency_key`
column plus a `UNIQUE INDEX ON (user_id, agent_id, idempotency_key)`, and
made `AgentManager.add_heartbeat` catch the resulting `UniqueViolation` and
return the FIRST attempt's row id rather than erroring or silently minting a
second row. This suite proves, against real Postgres (not sequential calls
alone, per Q28's concurrency-safety requirement):

  3. Migration idempotency: `create_tables` runs twice cleanly, and
     `agent_heartbeats.idempotency_key` plus its UNIQUE index exist.
  4. Two SEQUENTIAL `add_heartbeat` calls with the SAME idempotency_key
     produce exactly one persisted row, and both calls return the SAME id.
  5. Two REAL, GENUINELY CONCURRENT OS threads (via `threading.Barrier`,
     matching this project's established real-thread concurrency-test
     pattern from test_commit_heartbeat_idempotency.py) calling
     `add_heartbeat` with the SAME idempotency_key for the same (user,
     agent) produce exactly one row network-wide -- proving the guarantee is
     a real DB-constraint race winner, not a check-then-insert race in
     application code.
  6. Two calls with DIFFERENT idempotency_keys (a user's legitimate,
     intentional second identical-content event) produce TWO separate rows
     -- the fix must never block genuinely distinct creation attempts.
  7. A request with NO idempotency_key (a not-yet-updated client) still
     succeeds -- the rollout-compatibility path -- but, as documented,
     provides no dedup protection: two such omitted-key calls DO produce two
     rows, locking in that this is the accepted, known trade-off rather than
     an accidental gap.
  8. The real `POST /agent/{user_id}/{agent_id}/heartbeat` route now returns
     the created row's `id` in its response body (previously just
     `{"ok": True}`) -- required for the client to thread the id through, and
     a same-idempotency-key repeat POST returns the SAME id via the route
     itself, not just the manager method in isolation.

Run:  cd api && ../.venv/bin/python tests/test_heartbeat_timezone_duplicate_bugs.py
"""
import _pathfix  # noqa: F401
import _fake_timeline  # noqa: F401

import os
import threading
import uuid
from datetime import datetime, timezone as tzmod

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

from db import DBManager, create_tables  # noqa: E402
from backend.interactions.agent import AgentManager  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402
import backend.interactions.scheduler as scheduler_module  # noqa: E402
import main as main_module  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── Fixtures (same shapes as test_heartbeat_backend_scheduling.py /
#    test_heartbeat_group_id.py) ────────────────────────────────────────────

def cookie_header(token: str):
    return {"cookie": f"session={token}"} if token else {}


_signup_counter = 0


def signup(client, username):
    global _signup_counter
    _signup_counter += 1
    fake_ip = f"203.0.113.{_signup_counter % 250 + 1}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


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


def make_user() -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {
            "_id": uid, "username": f"hbtzdup_{uid[:8]}",
            "email": f"hbtzdup_{uid[:8]}@example.com", "hash_pass": "x",
        })
    finally:
        db.close()
    return uid


def make_agent(user_id: str, name: str = "") -> str:
    agent_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("agents", {
            "_id": agent_id, "user_id": user_id, "role": "", "chats": [], "name": name,
        })
    finally:
        db.close()
    return agent_id


def due_timestamps_for(now: datetime, hhmm: str) -> list:
    """A 31-slot timestamps array with only today's (now.day) slot set --
    same convention as test_heartbeat_backend_scheduling.py."""
    slots = [None] * 31
    slots[now.day - 1] = hhmm
    return slots


def set_device_token(user_id: str, token: str) -> None:
    db = DBManager()
    try:
        db.insertion(
            "device_tokens", {"user_id": user_id, "token": token},
            conflict="(user_id) DO UPDATE SET token = EXCLUDED.token",
        )
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


def heartbeat_count(user_id: str, agent_id: str) -> int:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT COUNT(*) FROM agent_heartbeats WHERE user_id = %s AND agent_id = %s",
            (user_id, agent_id),
        )
        return db.cur.fetchone()[0]
    finally:
        db.close()


def heartbeat_ids(user_id: str, agent_id: str) -> list:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT _id FROM agent_heartbeats WHERE user_id = %s AND agent_id = %s",
            (user_id, agent_id),
        )
        return [str(r[0]) for r in db.cur.fetchall()]
    finally:
        db.close()


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))  # no cascade from users
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))      # cascades agents/hb/context/device_tokens
        db.conn.commit()
    finally:
        db.close()


class _CapturingPush:
    def __init__(self):
        self.calls: list = []

    async def __call__(self, token, title, body, data=None) -> bool:
        self.calls.append((token, title, body, data))
        return True


class _FrozenDateTime(datetime):
    _frozen = None

    @classmethod
    def now(cls, tz=None):
        assert cls._frozen is not None, "freeze() was not called"
        return cls._frozen.astimezone(tz) if tz is not None else cls._frozen


def freeze_scheduler_time(when: datetime) -> None:
    _FrozenDateTime._frozen = when
    scheduler_module.datetime = _FrozenDateTime


def unfreeze_scheduler_time() -> None:
    scheduler_module.datetime = datetime


def stub_call_api(self, agent_role, messages):
    return (
        '{"__action": "create_note", "title": "Reflection", '
        '"text": "Generated content.", "verses": []}'
    )


async def run_job():
    await scheduler_module._fire_due_heartbeats()


# ── 1/2. Bug 1: literal-local "09:00" fires at 9 AM Pacific, not offset ────

def test_literal_local_authored_heartbeat_fires_at_local_9am_not_offset(client):
    print("\n=== 1/2. Bug 1 acceptance: a heartbeat authored via the real "
          "add_heartbeat route with a literal '09:00' string (iOS's post-fix "
          "convention -- no UTC conversion) fires when the owning user's "
          "LOCAL clock reads 9:00 AM, not when UTC reads 9:00 AM and not at "
          "the pre-fix UTC-authored slot for the same nominal pick ===")
    import asyncio

    uid, token = signup(client, f"hbtzfix_{uuid.uuid4().hex[:8]}")
    # America/Los_Angeles is UTC-7 in September (PDT).
    db = DBManager()
    try:
        db.update("users", {"timezone": "America/Los_Angeles"}, {"_id": uid})
    finally:
        db.close()
    agent_id = make_agent(uid, name="Fix Verification Agent")
    set_device_token(uid, f"tok-{uid}")

    # Frozen instant: 16:05 UTC == 09:05 AM PDT -- just past the user's 9:00
    # AM local pick, matching the frozen-time pattern used by every other
    # scheduler test in this suite.
    now = datetime(2026, 9, 15, 16, 5, tzinfo=tzmod.utc)

    r = client.post(
        f"/agent/{uid}/{agent_id}/heartbeat",
        json={"timestamps": due_timestamps_for(now, "09:00"), "prompt": "Reflect on today.",
              "idempotency_key": str(uuid.uuid4())},
        headers=cookie_header(token),
    )
    check("add_heartbeat with the literal local '09:00' string succeeds (201)",
          r.status_code == 201, f"{r.status_code} {r.text}")
    hb_id = r.json().get("id")
    check("the create response carries the new row's id", bool(hb_id), str(r.json()))

    # A sibling row authored the OLD (buggy) way for the exact same nominal
    # "9:00 AM Pacific" pick: iOS used to convert 9:00 AM local through
    # TimeZone(identifier: "UTC"), which for a DatePicker `Date` whose
    # wall-clock digits read "09:00" stores the SAME literal digits
    # ("09:00") regardless of device timezone -- the bug was never in what
    # got written for a UTC-timezone device, it was that a non-UTC device's
    # OWN 9:00 AM got authored as if the device were already in UTC. This
    # sibling row instead models what a genuinely UTC-authored 9:00 AM PDT
    # instant would have stored (9:00 AM PDT == 16:00 UTC) to prove the two
    # conventions really do diverge to different stored digits and therefore
    # different fire times -- not a no-op distinction.
    hb_old_convention = str(uuid.uuid4())
    dbw = DBManager()
    try:
        dbw.cur.execute(
            "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt) "
            "VALUES (%s, %s, %s, %s::jsonb, %s)",
            (hb_old_convention, agent_id, uid, __import__("json").dumps(due_timestamps_for(now, "16:00")),
             "Old-convention sibling row."),
        )
        dbw.conn.commit()
    finally:
        dbw.close()

    push = _CapturingPush()
    push_module.send_push = push
    freeze_scheduler_time(now)
    original_call_api = AgentManager._call_api
    AgentManager._call_api = stub_call_api
    try:
        asyncio.run(run_job())
        check("the literal-local '09:00' heartbeat fired at 9:05 AM Pacific "
              "(the frozen instant), matching the user's actual local pick",
              get_last_fired(hb_id) is not None, str(get_last_fired(hb_id)))
        check("the old-convention '16:00' sibling row (what a UTC-authored "
              "9 AM PDT pick would have stored) did NOT fire yet at the same "
              "instant -- proving the two authoring conventions genuinely "
              "resolve to different fire times, not a coincidental match",
              get_last_fired(hb_old_convention) is None, str(get_last_fired(hb_old_convention)))
    finally:
        AgentManager._call_api = original_call_api
        unfreeze_scheduler_time()
        cleanup(uid)


# ── 3. Migration idempotency for the idempotency_key column/index ─────────

def test_migration_is_idempotent():
    print("\n=== 3. Migration idempotency: create_tables runs twice; "
          "agent_heartbeats.idempotency_key and its UNIQUE index exist ===")
    db = DBManager()
    try:
        try:
            create_tables(db.cur)
            db.conn.commit()
            create_tables(db.cur)
            db.conn.commit()
            ran_twice_ok = True
        except Exception as e:
            db.conn.rollback()
            ran_twice_ok = False
            print(f"    exception: {e}")
        check("create_tables (including the idempotency_key migration) runs "
              "twice without error", ran_twice_ok)

        db.cur.execute(
            "SELECT is_nullable FROM information_schema.columns "
            "WHERE table_name = 'agent_heartbeats' AND column_name = 'idempotency_key'"
        )
        col = db.cur.fetchone()
        check("agent_heartbeats.idempotency_key column exists", col is not None, str(col))
        if col:
            check("agent_heartbeats.idempotency_key is nullable (pre-existing rows "
                  "and not-yet-updated clients must not be blocked)",
                  col[0] == "YES", str(col))

        db.cur.execute(
            "SELECT indexdef FROM pg_indexes WHERE tablename = 'agent_heartbeats' "
            "AND indexname = 'idx_agent_heartbeats_idempotency'"
        )
        idx = db.cur.fetchone()
        check("the UNIQUE index on (user_id, agent_id, idempotency_key) exists",
              idx is not None and "UNIQUE" in idx[0].upper(), str(idx))
    finally:
        db.close()


# ── 4. Sequential same-key calls dedupe to one row ─────────────────────────

def test_sequential_same_idempotency_key_dedupes_to_one_row():
    print("\n=== 4. Two SEQUENTIAL add_heartbeat calls with the SAME "
          "idempotency_key produce exactly one row and return the SAME id ===")
    uid = make_user()
    agent_id = make_agent(uid)
    manager = AgentManager(uid)
    key = str(uuid.uuid4())
    try:
        from schemas.agent import AgentHeartbeats
        hb = AgentHeartbeats(agent_id=agent_id, user_id=uid, prompt="Reflect.")
        id1 = manager.add_heartbeat(hb, idempotency_key=key)
        id2 = manager.add_heartbeat(hb, idempotency_key=key)
        check("both calls succeeded (no None/failure)", id1 is not None and id2 is not None, f"{id1} {id2}")
        check("both calls returned the SAME row id", id1 == id2, f"{id1} != {id2}")
        check("exactly one row was persisted for this (user, agent)",
              heartbeat_count(uid, agent_id) == 1, str(heartbeat_count(uid, agent_id)))
    finally:
        manager.close()
        cleanup(uid)


# ── 5. Real concurrent threads racing the same key still produce one row ──

def test_concurrent_real_threads_same_key_produce_exactly_one_row():
    print("\n=== 5. N real OS threads calling add_heartbeat with the SAME "
          "idempotency_key at once (threading.Barrier) still produce exactly "
          "one row network-wide -- a real Postgres-constraint race, not a "
          "check-then-insert race in application code (Q28) ===")
    import concurrent.futures
    from schemas.agent import AgentHeartbeats

    uid = make_user()
    agent_id = make_agent(uid)
    key = str(uuid.uuid4())
    N = 8
    barrier = threading.Barrier(N, timeout=10)
    results = [None] * N
    errors: list = []

    def attempt(i: int):
        manager = AgentManager(uid)
        try:
            hb = AgentHeartbeats(agent_id=agent_id, user_id=uid, prompt="Reflect.")
            barrier.wait()
            results[i] = manager.add_heartbeat(hb, idempotency_key=key)
        except Exception as e:
            errors.append(e)
        finally:
            manager.close()

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=N) as pool:
            futures = [pool.submit(attempt, i) for i in range(N)]
            for f in futures:
                f.result(timeout=30)

        check(f"all {N} concurrent real-thread callers completed without raising", not errors, str(errors))
        check(f"all {N} concurrent callers got a non-None row id",
              all(r is not None for r in results), str(results))
        distinct_ids = set(results)
        check(f"all {N} concurrent callers agree on the SAME single row id",
              len(distinct_ids) == 1, str(results))
        check("exactly one row was persisted network-wide despite the race",
              heartbeat_count(uid, agent_id) == 1, str(heartbeat_count(uid, agent_id)))
    finally:
        cleanup(uid)


# ── 6. Different keys create two distinct, legitimate rows ────────────────

def test_different_idempotency_keys_create_two_distinct_rows():
    print("\n=== 6. Two calls with DIFFERENT idempotency_keys (a user's "
          "legitimate intentional second identical-content event) produce "
          "TWO separate rows -- the fix must never block real distinct "
          "creation attempts ===")
    from schemas.agent import AgentHeartbeats

    uid = make_user()
    agent_id = make_agent(uid)
    manager = AgentManager(uid)
    try:
        hb = AgentHeartbeats(agent_id=agent_id, user_id=uid, prompt="Reflect.")
        id1 = manager.add_heartbeat(hb, idempotency_key=str(uuid.uuid4()))
        id2 = manager.add_heartbeat(hb, idempotency_key=str(uuid.uuid4()))
        check("both calls succeeded", id1 is not None and id2 is not None, f"{id1} {id2}")
        check("the two calls produced DIFFERENT row ids", id1 != id2, f"{id1} == {id2}")
        check("exactly two rows exist for this (user, agent)",
              heartbeat_count(uid, agent_id) == 2, str(heartbeat_count(uid, agent_id)))
    finally:
        manager.close()
        cleanup(uid)


# ── 7. Omitted idempotency_key still works, but with no dedup protection ──

def test_omitted_idempotency_key_still_works_but_offers_no_dedup():
    print("\n=== 7. A not-yet-updated client that omits idempotency_key "
          "entirely still succeeds (rollout compatibility) -- but, as "
          "documented, this provides NO dedup protection: two such calls "
          "produce two rows ===")
    from schemas.agent import AgentHeartbeats

    uid = make_user()
    agent_id = make_agent(uid)
    manager = AgentManager(uid)
    try:
        hb = AgentHeartbeats(agent_id=agent_id, user_id=uid, prompt="Reflect.")
        id1 = manager.add_heartbeat(hb)  # no idempotency_key at all
        id2 = manager.add_heartbeat(hb)  # no idempotency_key at all
        check("both calls with no idempotency_key succeeded", id1 is not None and id2 is not None, f"{id1} {id2}")
        check("two rows exist -- confirming the known, documented trade-off "
              "(no dedup for callers that never sent a key), not a silent "
              "regression in either direction",
              heartbeat_count(uid, agent_id) == 2, str(heartbeat_count(uid, agent_id)))
    finally:
        manager.close()
        cleanup(uid)


# ── 8. Route-level: id in response, repeat POST with same key dedupes ─────

def test_route_returns_id_and_dedupes_on_repeat_post_with_same_key(client):
    print("\n=== 8. POST /agent/{user_id}/{agent_id}/heartbeat returns the "
          "created row's id, and a repeat POST with the SAME idempotency_key "
          "returns the SAME id and does not create a second row ===")
    uid, token = signup(client, f"hbtzdup_route_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        key = str(uuid.uuid4())
        body = {"timestamps": [None] * 31, "prompt": "Reflect.", "idempotency_key": key}

        r1 = client.post(f"/agent/{uid}/{agent_id}/heartbeat", json=body, headers=cookie_header(token))
        check("first POST succeeds (201)", r1.status_code == 201, f"{r1.status_code} {r1.text}")
        id1 = r1.json().get("id")
        check("first POST's response carries an id", bool(id1), str(r1.json()))

        r2 = client.post(f"/agent/{uid}/{agent_id}/heartbeat", json=body, headers=cookie_header(token))
        check("a repeat POST with the same idempotency_key still returns 201 "
              "(not an error) -- the caller sees a normal success, not a "
              "surfaced conflict, per Q26's 'return the existing row' design",
              r2.status_code == 201, f"{r2.status_code} {r2.text}")
        id2 = r2.json().get("id")
        check("the repeat POST's response carries the SAME id as the first",
              id1 == id2, f"{id1} != {id2}")

        check("exactly one row was actually persisted for this (user, agent) "
              "despite two POSTs", heartbeat_count(uid, agent_id) == 1,
              str(heartbeat_count(uid, agent_id)))
    finally:
        cleanup(uid)


def main():
    test_migration_is_idempotent()
    test_sequential_same_idempotency_key_dedupes_to_one_row()
    test_concurrent_real_threads_same_key_produce_exactly_one_row()
    test_different_idempotency_keys_create_two_distinct_rows()
    test_omitted_idempotency_key_still_works_but_offers_no_dedup()

    # Single shared TestClient/app lifespan for every route-level test --
    # the scheduler is a module-level singleton (same rationale as
    # test_heartbeat_group_id.py/test_heartbeat_backend_scheduling.py).
    with TestClient(main_module.app) as client:
        test_literal_local_authored_heartbeat_fires_at_local_9am_not_offset(client)
        test_route_returns_id_and_dedupes_on_repeat_post_with_same_key(client)

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
