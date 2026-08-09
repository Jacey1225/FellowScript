"""Integration test for task 20260808-timezone-not-persisting.

Proves the actual bug is fixed end to end against the REAL app (main.app,
lifespan included) and a real Postgres connection — not a mocked DB, per this
project's testing standard:

  1. Picking a non-UTC timezone and saving it round-trips through a FRESH
     GET (a separate request from the PUT, so an in-memory-only "success"
     can't fake it) — acceptance criteria 1 & 2.
  2. The specific root cause the backend gate found and fixed — the server's
     tzdata package was missing IANA's ~150 legacy alias names (e.g.
     "US/Pacific", which iOS's TimeZone.knownTimeZoneIdentifiers can and does
     produce) — is exercised directly: an alias identifier must validate and
     persist, not 422.
  3. A genuinely invalid timezone is rejected (422) and does NOT get written
     — the row must be left exactly as it was (guards against a validation
     bypass silently reverting to/stuck at UTC).
  4. If the write to Postgres itself fails, update_user() must surface a 500
     and must NOT return a 200 body claiming the new value stuck (this is
     the "looks saved in the moment, reverts to UTC on reload" bug pattern
     from the intake spec) — exercised by forcing save_user_row to raise.
  5. Regression: username/email/password updates via the same PUT endpoint
     are unaffected by the persistence-path rewrite.

Run:  cd api && ../.venv/bin/python tests/test_user_timezone.py
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
    token = r.cookies.get("session")
    return r.json()["user_id"], token


def login(client, username):
    r = client.post("/login", json={"username": username, "plain_pass": "TestPass123!"})
    assert r.status_code == 200, f"login failed: {r.status_code} {r.text}"
    return r.cookies.get("session")


def raw_timezone_in_db(uid: str) -> str | None:
    """Bypass the app entirely — read straight from Postgres, so a test can't
    be fooled by a route that reads back its own in-memory mutation."""
    db = DBManager()
    try:
        db.cur.execute("SELECT timezone FROM users WHERE _id = %s", (uid,))
        row = db.cur.fetchone()
        return row[0] if row else None
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
        check("app boots and lifespan starts", True)

        uid, token = signup(client, f"tz_test_{uuid.uuid4().hex[:8]}")
        print(f"  created uid={uid}")

        try:
            # ── 1. Round-trip through a FRESH GET, not the PUT response ──────
            print("\n=== 1. Non-UTC timezone round-trips through a fresh GET ===")
            r = client.get(f"/user/{uid}", headers=cookie_header(token))
            check("baseline: new account defaults to UTC", r.json().get("timezone") == "UTC", r.text)

            r = client.put(f"/user/{uid}", json={"timezone": "America/Los_Angeles"}, headers=cookie_header(token))
            check("PUT non-UTC timezone -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            check("PUT response reflects new value", r.json().get("timezone") == "America/Los_Angeles", r.text)

            # Separate request, separate round trip to the DB — proves it's
            # not just an in-memory echo of the PUT body.
            r = client.get(f"/user/{uid}", headers=cookie_header(token))
            check("fresh GET after PUT shows new value", r.json().get("timezone") == "America/Los_Angeles", r.text)
            check("value is actually in Postgres, not just app-visible",
                  raw_timezone_in_db(uid) == "America/Los_Angeles", raw_timezone_in_db(uid))

            # ── 2. Survives "relaunch / re-login" (criterion 2) ───────────────
            print("\n=== 2. Persisted value survives logout + re-login ===")
            client.post("/logout", headers=cookie_header(token))
            token = login(client, r.json()["username"])
            r = client.get(f"/user/{uid}", headers=cookie_header(token))
            check("timezone unchanged after logout+login", r.json().get("timezone") == "America/Los_Angeles", r.text)

            # ── 3. The actual root cause: legacy IANA alias identifiers ──────
            print("\n=== 3. Legacy alias identifier (iOS can produce, root cause of the bug) ===")
            r = client.put(f"/user/{uid}", json={"timezone": "US/Pacific"}, headers=cookie_header(token))
            check("PUT with legacy alias 'US/Pacific' -> 200 (not 422)", r.status_code == 200, f"{r.status_code} {r.text}")
            r = client.get(f"/user/{uid}", headers=cookie_header(token))
            check("alias identifier persists and round-trips", r.json().get("timezone") == "US/Pacific", r.text)
            check("alias identifier actually landed in Postgres",
                  raw_timezone_in_db(uid) == "US/Pacific", raw_timezone_in_db(uid))

            # ── 4. Invalid timezone is rejected AND leaves the row untouched ──
            print("\n=== 4. Invalid timezone is rejected, does not silently revert/corrupt ===")
            before = raw_timezone_in_db(uid)
            r = client.put(f"/user/{uid}", json={"timezone": "Not/ARealZone"}, headers=cookie_header(token))
            check("PUT invalid timezone -> 422", r.status_code == 422, f"{r.status_code} {r.text}")
            check("row unchanged after rejected update", raw_timezone_in_db(uid) == before, raw_timezone_in_db(uid))

            # ── 5. Persistence failure -> 500, never a false 200 ──────────────
            print("\n=== 5. A genuine save failure surfaces as 500, not a false success ===")
            before = raw_timezone_in_db(uid)

            def boom(*_a, **_k):
                raise RuntimeError("simulated Postgres write failure")

            original_save_user_row = main_module.save_user_row
            main_module.save_user_row = boom
            try:
                r = client.put(f"/user/{uid}", json={"timezone": "Asia/Tokyo"}, headers=cookie_header(token))
                check("failed persistence -> 500 (never 200)", r.status_code == 500, f"{r.status_code} {r.text}")
            finally:
                main_module.save_user_row = original_save_user_row

            check("row genuinely untouched after simulated failure", raw_timezone_in_db(uid) == before, raw_timezone_in_db(uid))
            r = client.get(f"/user/{uid}", headers=cookie_header(token))
            check("subsequent fresh GET also shows no phantom update", r.json().get("timezone") == before, r.text)

            # ── 6. Regression: username/email/password via same endpoint ─────
            print("\n=== 6. Regression: username/email/password updates unaffected ===")
            new_username = f"tz_renamed_{uuid.uuid4().hex[:8]}"
            r = client.put(
                f"/user/{uid}",
                json={"username": new_username, "email": f"{new_username}@example.com", "plain_pass": "NewPass456!"},
                headers=cookie_header(token),
            )
            check("username/email/password update -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            check("username updated", r.json().get("username") == new_username, r.text)
            check("hash_pass never returned in response", "hash_pass" not in r.json(), str(r.json().keys()))
            # Old password must no longer work; new one must.
            r = client.post("/login", json={"username": new_username, "plain_pass": "TestPass123!"})
            check("old password rejected after change -> 401", r.status_code == 401, f"{r.status_code} {r.text}")
            r = client.post("/login", json={"username": new_username, "plain_pass": "NewPass456!"})
            check("new password logs in -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            new_token = r.cookies.get("session")
            check("new password login returns a session cookie", bool(new_token), "no session cookie")
            r = client.get(f"/user/{uid}", headers=cookie_header(new_token))
            check("timezone from step 4 untouched by username/password-only update",
                  r.json().get("timezone") == before, r.text)

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
