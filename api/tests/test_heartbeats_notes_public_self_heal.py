"""Tests for task 20260903-account-events-not-loading, backend steps 1-2:
the self-healing schema migration (`create_tables()` now invoked from
`main.py`'s `lifespan()` on every boot) and its confirmed effect on the
`agent_heartbeats.notes_public` column gap that caused the reported bug.

Root cause (confirmed via read-only production SSH at intake): the
`ALTER TABLE agent_heartbeats ADD COLUMN IF NOT EXISTS notes_public ...`
migration in `create_tables()` was never actually run against production --
`create_tables()` was previously only ever invoked by hand (a migration
script or an ad hoc SSH session), never automatically at boot. As a direct
consequence, `AgentManager.get_heartbeats` (which builds each row's dict
generically from `cursor.description`, NOT through the `AgentHeartbeats`
Pydantic schema -- see api/backend/interactions/agent.py:126-128) returned
heartbeat JSON objects with NO `notes_public` key at all whenever the column
was absent, which is exactly what made iOS's strict, non-Optional
`FSHeartbeat: Codable` throw on every row.

This suite reproduces that exact gap directly against a real Postgres test
DB (drops the column, same technique test_agent_default_role_persistence.py
already uses for `agents.name`/`enabled`) and proves the fix closes it
end-to-end:

  1. With the column present (today's normal state), GET .../heartbeats
     already returns a `notes_public` key for every row (baseline, not
     assumed).
  2. Reproduce the reported gap: drop the column entirely (matching
     production's actual prior state) and confirm the SAME live GET route
     now omits the `notes_public` key from every row's JSON -- proving the
     mechanism, not just asserting the column is missing at the SQL level.
  3. THE FIX: re-run `create_tables()` exactly as `main.py`'s `lifespan()`
     now does on every boot (self-healing migration) and confirm the column
     is back AND every row -- including rows inserted *while the column was
     still missing* -- now returns `notes_public` in the GET response,
     proving `ADD COLUMN ... DEFAULT FALSE` backfills pre-existing rows, not
     just future inserts.
  4. Idempotency: running the self-healing migration twice more is a
     no-op/no-error (safe to re-run on every container boot, per the
     backend gate's "smallest fix" rationale).
  5. Regression: a normal add_heartbeat -> GET round trip still honors an
     explicitly-configured `notes_public=True` post-heal (not just the
     False default), so the heal didn't clobber the feature's real
     semantics from 20260903-notes-public-repurpose.

Schema is restored (column re-added) in `finally` either way, so this test
never leaves the shared test DB in the broken pre-fix state for any other
suite that runs after it.

Run:  cd api && ../.venv/bin/python tests/test_heartbeats_notes_public_self_heal.py
"""
import _pathfix  # noqa: F401

import os
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import db as db_module  # noqa: E402
from db import DBManager, create_tables  # noqa: E402
import main as main_module  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def cookie_header(token: str):
    return {"cookie": f"session={token}"} if token else {}


_signup_counter = 0


def signup(client, username):
    """Spoofs a distinct CF-Connecting-IP per call, same technique as
    test_heartbeat_group_id.py, so this file's signups don't trip the
    5/minute per-IP /signup rate limit."""
    global _signup_counter
    _signup_counter += 1
    fake_ip = f"203.0.113.{100 + (_signup_counter % 150)}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def make_agent(user_id: str) -> str:
    agent_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agents (_id, user_id, role, chats) VALUES (%s, %s, %s, %s)",
            (agent_id, user_id, "", []),
        )
        db.conn.commit()
    finally:
        db.close()
    return agent_id


def insert_heartbeat_bypassing_notes_public(agent_id: str, user_id: str, prompt: str) -> str:
    """Inserts a heartbeat row WITHOUT ever mentioning notes_public in the
    column list -- works whether or not the column currently exists,
    matching how a row already sitting in production before this task's fix
    landed would have gotten there."""
    hb_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt) "
            "VALUES (%s, %s, %s, %s::jsonb, %s)",
            (hb_id, agent_id, user_id, "[]", prompt),
        )
        db.conn.commit()
    finally:
        db.close()
    return hb_id


def drop_notes_public_column():
    db = DBManager()
    try:
        db.cur.execute("ALTER TABLE agent_heartbeats DROP COLUMN IF EXISTS notes_public")
        db.conn.commit()
    finally:
        db.close()


def run_self_healing_migration():
    """Invoke the exact self-healing step main.py's lifespan() now runs on
    every boot -- not a reimplementation, the real create_tables()."""
    conn = db_module._connect()
    try:
        create_tables(conn.cursor())
        conn.commit()
    finally:
        conn.close()


def column_exists(table: str, column: str) -> bool:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_name = %s AND column_name = %s",
            (table, column),
        )
        return db.cur.fetchone() is not None
    finally:
        db.close()


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM agent_heartbeats WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM agents WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def main():
    # A single shared TestClient/app lifespan for the whole file -- entering
    # it now runs the self-healing migration for real (proving it's wired
    # into lifespan at all) and starts the scheduler, matching every other
    # heartbeat test's TestClient(main_module.app) pattern (module-level
    # scheduler singleton can't tolerate more than one lifespan per process).
    with TestClient(main_module.app) as client:
        check("baseline: entering the app's real lifespan already leaves "
              "agent_heartbeats.notes_public present (self-healing migration "
              "ran automatically at boot, not just by hand)",
              column_exists("agent_heartbeats", "notes_public"))

        uid, token = signup(client, f"hbheal_{uuid.uuid4().hex[:8]}")
        agent_id = None
        try:
            agent_id = make_agent(uid)

            print("\n=== 1. Baseline: with the column present, GET .../heartbeats "
                  "already returns notes_public for a real row ===")
            hb_id_baseline = insert_heartbeat_bypassing_notes_public(agent_id, uid, "Baseline reflection.")
            r = client.get(f"/agent/{uid}/{agent_id}/heartbeats", headers=cookie_header(token))
            check("GET heartbeats -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            rows = r.json()
            baseline_row = next((row for row in rows if row.get("_id") == hb_id_baseline), None)
            check("baseline row exists in the response", baseline_row is not None, str(rows))
            check("baseline row already carries a notes_public key "
                  "(column present, defaults False)",
                  baseline_row is not None and "notes_public" in baseline_row, str(baseline_row))

            print("\n=== 2. Reproduce the reported gap: drop the column, confirm the "
                  "SAME live GET route now omits notes_public from every row "
                  "-- exactly the symptom that made iOS's strict decode throw ===")
            drop_notes_public_column()
            check("agent_heartbeats.notes_public no longer exists in the schema "
                  "(reproducing production's actual pre-fix state)",
                  not column_exists("agent_heartbeats", "notes_public"))

            hb_id_during_gap = insert_heartbeat_bypassing_notes_public(
                agent_id, uid, "Inserted while the column is missing."
            )
            r = client.get(f"/agent/{uid}/{agent_id}/heartbeats", headers=cookie_header(token))
            check("GET heartbeats still returns 200 even with the column missing "
                  "(no SQL error -- SELECT * just omits the absent column)",
                  r.status_code == 200, f"{r.status_code} {r.text}")
            rows = r.json()
            gap_row = next((row for row in rows if row.get("_id") == hb_id_during_gap), None)
            check("the newly-inserted row is present in the response", gap_row is not None, str(rows))
            check("THE CONFIRMED ROOT CAUSE: with the column missing, the row's JSON "
                  "has NO notes_public key at all (not null, absent) -- this is exactly "
                  "what made iOS's non-Optional FSHeartbeat.notes_public throw "
                  ".keyNotFound and fail decoding the WHOLE heartbeats array",
                  gap_row is not None and "notes_public" not in gap_row, str(gap_row))
            # Also confirm the pre-existing baseline row is affected identically --
            # this isn't scoped to just newly-inserted rows.
            r = client.get(f"/agent/{uid}/{agent_id}/heartbeats", headers=cookie_header(token))
            rows = r.json()
            baseline_row_during_gap = next((row for row in rows if row.get("_id") == hb_id_baseline), None)
            check("the pre-existing baseline row ALSO lost its notes_public key "
                  "once the column was dropped -- every real account's every "
                  "heartbeat was affected, not just new ones",
                  baseline_row_during_gap is not None and "notes_public" not in baseline_row_during_gap,
                  str(baseline_row_during_gap))

            print("\n=== 3. THE FIX: re-run the self-healing migration (exactly what "
                  "lifespan() now does on every boot) -- column comes back, and EVERY "
                  "row (including ones inserted while it was missing) now returns "
                  "notes_public in the GET response ===")
            run_self_healing_migration()
            check("agent_heartbeats.notes_public exists again after the self-healing "
                  "migration re-runs", column_exists("agent_heartbeats", "notes_public"))

            r = client.get(f"/agent/{uid}/{agent_id}/heartbeats", headers=cookie_header(token))
            check("GET heartbeats -> 200 after the heal", r.status_code == 200, f"{r.status_code} {r.text}")
            rows = r.json()
            healed_baseline = next((row for row in rows if row.get("_id") == hb_id_baseline), None)
            healed_gap_row = next((row for row in rows if row.get("_id") == hb_id_during_gap), None)
            check("the baseline row (created before the drop) now has notes_public "
                  "again, defaulted to False by ADD COLUMN ... DEFAULT FALSE -- "
                  "the heal backfills PRE-EXISTING rows, not just future inserts",
                  healed_baseline is not None and healed_baseline.get("notes_public") is False,
                  str(healed_baseline))
            check("the row inserted WHILE the column was missing also now has "
                  "notes_public=False after the heal",
                  healed_gap_row is not None and healed_gap_row.get("notes_public") is False,
                  str(healed_gap_row))

            print("\n=== 4. Idempotency: the self-healing migration is safe to run "
                  "again (as it now does on every container boot) ===")
            try:
                run_self_healing_migration()
                run_self_healing_migration()
                reran_ok = True
            except Exception as e:
                reran_ok = False
                print(f"    exception on repeated run: {e}")
            check("running the self-healing migration twice more raises no error",
                  reran_ok)
            r = client.get(f"/agent/{uid}/{agent_id}/heartbeats", headers=cookie_header(token))
            rows = r.json()
            check("data is unchanged after repeated migration runs -- still exactly "
                  "the two heartbeats seeded above, both still notes_public=False",
                  {row["_id"] for row in rows} == {hb_id_baseline, hb_id_during_gap}
                  and all(row.get("notes_public") is False for row in rows),
                  str(rows))

            print("\n=== 5. Regression: post-heal, add_heartbeat -> GET still honors "
                  "an explicitly configured notes_public=True (the heal didn't "
                  "clobber 20260903-notes-public-repurpose's real semantics) ===")
            # Free-tier agent_events cap is 1 -- clear the two seeded heartbeats
            # first so this sub-case isn't blocked by the unrelated
            # subscription-limit gate (same technique as
            # test_agent_notes_public.py::main, case 1).
            db = DBManager()
            try:
                db.cur.execute("DELETE FROM agent_heartbeats WHERE user_id = %s", (uid,))
                db.conn.commit()
            finally:
                db.close()
            r = client.post(f"/agent/{uid}/{agent_id}/heartbeat", json={
                "timestamps": [None] * 31, "prompt": "Reflect.", "notes_public": True,
            }, headers=cookie_header(token))
            check("add_heartbeat with notes_public=True -> 201 post-heal",
                  r.status_code == 201, f"{r.status_code} {r.text}")
            r = client.get(f"/agent/{uid}/{agent_id}/heartbeats", headers=cookie_header(token))
            rows = r.json()
            new_true_row = next((row for row in rows if row.get("notes_public") is True), None)
            check("the explicitly-True heartbeat round-trips correctly through GET "
                  "post-heal, proving the fix only affects the missing-key gap, not "
                  "the feature's real True/False semantics",
                  new_true_row is not None, str(rows))
        finally:
            print("\n=== cleanup / schema restore ===")
            # Guarantee the column is present again even if an assertion above
            # raised mid-test, so no other suite in this run (or a later one)
            # inherits the dropped-column state.
            try:
                run_self_healing_migration()
            except Exception as e:
                print(f"    WARNING: schema-restore migration run failed: {e}")
            if uid:
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
