"""Integration test for task 20260808-ios-backend-integration-audit, backend
step 11, findings #1 (CRITICAL) and #2 (CRITICAL):

  1. api/db.py's `agents` table never declared the `name`/`enabled` columns
     that routes/agent.py's create_agent/update_agent write, and
  2. `agents.role` was VARCHAR(128), too small for schemas.agent._DEFAULT_ROLE
     (~4.9KB) — the role every "default" agent gets, since iOS's
     NewAgentSheet leaves role blank and NetworkService.createAgent omits the
     "role" key entirely for that case.

Both failures were swallowed by DBManager.insertion/update (they catch
sql.Error, log, rollback, and do NOT raise), so POST /agent/{user_id} kept
returning 201 with a freshly generated id for a row that was never actually
written to Postgres — a false-success response, the same class of bug as
incident #1 (20260808-timezone-not-persisting).

Per backend step 11's summary: "the existing IDOR test suite
(test_idor_agent_notification_devotion.py) works around this bug via a raw
INSERT rather than exercising the real route" — that gap in coverage is
exactly why the bug went undetected. This test exercises the REAL route
(POST /agent/{user_id}) with iOS's exact default-agent request shape (no
"role" key in the body at all) and confirms the agent is both reported
created AND actually visible in a subsequent, separate GET — not just an
echo of the POST response.

Run:  cd api && ../.venv/bin/python tests/test_agent_default_role_persistence.py
"""
import _pathfix  # noqa: F401,E402

import os
import sys
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
from schemas.agent import _DEFAULT_ROLE as DEFAULT_ROLE  # noqa: E402

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


def signup(client, username):
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    })
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def raw_agent_row(agent_id: str):
    """Bypass the app entirely — read straight from Postgres, so the test
    can't be fooled by a route echoing back its own in-memory input."""
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT _id, user_id, role, name, enabled FROM agents WHERE _id = %s",
            (agent_id,),
        )
        row = db.cur.fetchone()
        if row is None:
            return None
        return {"_id": str(row[0]), "user_id": str(row[1]), "role": row[2],
                "name": row[3], "enabled": row[4]}
    finally:
        db.close()


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def main():
    print("=== Boot the real app (main.app), lifespan included ===")
    with TestClient(main_module.app) as client:
        uid, token = signup(client, f"agent_persist_{uuid.uuid4().hex[:8]}")
        print(f"  created uid={uid}")

        try:
            # ── 1. iOS's exact default-agent shape: no "role" key at all ──────
            print("\n=== 1. POST /agent/{user_id} with NO 'role' key (default-agent path) ===")
            r = client.post(f"/agent/{uid}", json={"user_id": uid, "chats": [], "enabled": True},
                             headers=cookie_header(token))
            check("create -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
            agent_id = r.json().get("id")
            check("response includes an id", bool(agent_id), r.text)

            # The real bug: the POST above returned 201 even pre-fix, because
            # DBManager.insertion swallows the sql.Error and never raises. The
            # only way to catch it is a SEPARATE, fresh request reading the
            # row back — proving it's not just an in-memory echo of the POST.
            r = client.get(f"/agent/{uid}", headers=cookie_header(token))
            check("fresh GET /agent/{user_id} -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            agents = r.json()
            check("the created agent id is actually present in a fresh GET",
                  agent_id in agents, f"agent_id={agent_id} agents keys={list(agents.keys())}")

            if agent_id in agents:
                got = agents[agent_id]
                check("persisted role is the full DEFAULT_ROLE (not truncated/blank)",
                      got.get("role") == DEFAULT_ROLE,
                      f"len(got role)={len(got.get('role') or '')} len(expected)={len(DEFAULT_ROLE)}")
                check("persisted name defaults to 'Spiritual Guide'",
                      got.get("name") == "Spiritual Guide", str(got.get("name")))
                check("persisted enabled defaults to True",
                      got.get("enabled") is True, str(got.get("enabled")))

            # Confirm directly against Postgres too, independent of the GET route.
            raw = raw_agent_row(agent_id) if agent_id else None
            check("row genuinely exists in Postgres", raw is not None, str(raw))
            if raw:
                check("raw role column holds the full ~4.9KB DEFAULT_ROLE, not truncated",
                      raw["role"] == DEFAULT_ROLE, f"len={len(raw['role'] or '')}")
                check("raw name column is 'Spiritual Guide'", raw["name"] == "Spiritual Guide", str(raw["name"]))
                check("raw enabled column is True", raw["enabled"] is True, str(raw["enabled"]))

            # ── 2. Regression: a custom short role + custom name still work ───
            print("\n=== 2. Regression: custom role/name (not just the default path) ===")
            r = client.post(f"/agent/{uid}", json={
                "user_id": uid, "chats": [], "enabled": False,
                "role": "You are a concise prayer companion.", "name": "Prayer Buddy",
            }, headers=cookie_header(token))
            check("custom create -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
            custom_id = r.json().get("id")

            r = client.get(f"/agent/{uid}", headers=cookie_header(token))
            agents = r.json()
            check("custom agent visible in fresh GET", custom_id in agents, str(agents.keys()))
            if custom_id in agents:
                got = agents[custom_id]
                check("custom role persisted verbatim",
                      got.get("role") == "You are a concise prayer companion.", str(got.get("role")))
                check("custom name persisted verbatim", got.get("name") == "Prayer Buddy", str(got.get("name")))
                check("custom enabled=False persisted", got.get("enabled") is False, str(got.get("enabled")))

            # ── 3. Rename round-trips through PUT -> fresh GET ─────────────────
            print("\n=== 3. PUT rename round-trips through a fresh GET ===")
            r = client.put(f"/agent/{uid}/{agent_id}", json={"name": "Renamed Guide"},
                            headers=cookie_header(token))
            check("rename -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            r = client.get(f"/agent/{uid}", headers=cookie_header(token))
            agents = r.json()
            check("renamed value visible in fresh GET",
                  agent_id in agents and agents[agent_id].get("name") == "Renamed Guide",
                  str(agents.get(agent_id)))

            # ── 4. Regression-proof: confirm this test would have caught the
            #      original bug, by re-narrowing the schema to the pre-fix
            #      shape and showing the same request silently fails to
            #      persist (201 returned, row absent) exactly as backend step
            #      11 described. Schema is restored in `finally` either way.
            print("\n=== 4. Regression-proof: reproduce the pre-fix schema and show it silently drops the row ===")
            db = DBManager()
            try:
                # Clear this test's own agent rows first — they hold the full
                # ~4.9KB DEFAULT_ROLE from step 1, which would make the
                # VARCHAR(128) ALTER below fail outright (StringDataRightTruncation)
                # rather than reproducing the silent-drop behavior being tested.
                db.cur.execute("DELETE FROM agents WHERE user_id = %s", (uid,))
                db.conn.commit()
                db.cur.execute("ALTER TABLE agents ALTER COLUMN role TYPE VARCHAR(128)")
                db.cur.execute("ALTER TABLE agents DROP COLUMN IF EXISTS name")
                db.cur.execute("ALTER TABLE agents DROP COLUMN IF EXISTS enabled")
                db.conn.commit()
            finally:
                db.close()

            try:
                r = client.post(f"/agent/{uid}", json={"user_id": uid, "chats": [], "enabled": True},
                                 headers=cookie_header(token))
                check("pre-fix schema: route STILL returns 201 (false success — this is the bug)",
                      r.status_code == 201, f"{r.status_code} {r.text}")
                broken_agent_id = r.json().get("id")

                r = client.get(f"/agent/{uid}", headers=cookie_header(token))
                agents_after = r.json()
                check("pre-fix schema: the 'created' agent is ABSENT from a fresh GET "
                      "(proves the silent-drop bug is real and this test would have caught it)",
                      broken_agent_id not in agents_after,
                      f"broken_agent_id={broken_agent_id} present={broken_agent_id in agents_after}")
            finally:
                # Restore the fixed schema so the rest of the suite (and any
                # other test relying on the real schema) is unaffected.
                db = DBManager()
                try:
                    db.cur.execute("ALTER TABLE agents ALTER COLUMN role TYPE TEXT")
                    db.cur.execute("ALTER TABLE agents ADD COLUMN IF NOT EXISTS name VARCHAR(255) DEFAULT ''")
                    db.cur.execute("ALTER TABLE agents ADD COLUMN IF NOT EXISTS enabled BOOLEAN NOT NULL DEFAULT TRUE")
                    db.conn.commit()
                finally:
                    db.close()

            # Confirm the fix is back in place and works again post-restore.
            r = client.post(f"/agent/{uid}", json={"user_id": uid, "chats": [], "enabled": True},
                             headers=cookie_header(token))
            post_restore_id = r.json().get("id")
            r = client.get(f"/agent/{uid}", headers=cookie_header(token))
            check("post-restore: schema fix back in place, default-agent create persists again",
                  post_restore_id in r.json(), str(post_restore_id))

        finally:
            print("\n=== cleanup ===")
            cleanup(uid)

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
