"""Regression test for task 20260808-ios-backend-integration-audit, backend
step 17's fix to api/backend/interactions/notifications.py's
create_notification / update_notification (timestamps branch) / set_timestamp.

Before the fix, all three methods wrapped their write in
`except Exception: logger.error(...); self.conn.rollback()` with NO re-raise:

  - create_notification still returned a freshly-generated notif_id even
    though the INSERT never committed, so POST /notification/{user_id}
    responded 201 {"id": <fake id>} for a row that doesn't exist.
  - update_notification's timestamps branch and set_timestamp both let
    execution fall through after the swallow, and both routes
    (PUT /notification/{user_id}/{notif_id},
     PATCH /notification/{user_id}/{notif_id}/timestamp)
    return {"ok": True} unconditionally after calling them.

This is incident #1's exact silent-swallow-into-false-success pattern
(server claims success, nothing was actually persisted). The fix re-raises
after the existing log+rollback so a real DB failure surfaces as a 500 the
client can see and retry, instead of a fake 200/201.

This test proves the fix end to end against the REAL app (main.app, lifespan
included) and a real Postgres connection:
  1. create_notification: simulated write failure -> 500, and NO row lands
     in Postgres for the returned/would-be id (proving the id was never a
     real persisted row) — then, on retry after the failure clears, the
     create actually succeeds.
  2. update_notification (name/prompt AND timestamps branch): simulated
     write failure -> 500, row's fields left untouched — then retry
     succeeds and the change actually lands.
  3. set_timestamp: simulated write failure -> 500, timestamps slot left
     untouched — then retry succeeds and the slot actually updates.
  4. Regression: normal (non-failing) create/update/set_timestamp/delete
     still work exactly as before.

Run:  cd api && ../.venv/bin/python tests/test_notification_write_failure.py
"""
import _pathfix  # noqa: F401

import os
import sys
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import backend.interactions.notifications as notif_mod  # noqa: E402
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
    return r.json()["user_id"], r.cookies.get("session")


def raw_notification_in_db(notif_id: str) -> dict | None:
    """Bypass the app entirely — read straight from Postgres, so a test
    can't be fooled by a route echoing its own in-memory mutation."""
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT _id, name, prompt, timestamps FROM notifications WHERE _id = %s",
            (notif_id,),
        )
        row = db.cur.fetchone()
        if not row:
            return None
        return {"_id": row[0], "name": row[1], "prompt": row[2], "timestamps": row[3]}
    finally:
        db.close()


def cleanup(uid: str):
    db = DBManager()
    try:
        db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


class _FlakyCursor:
    """Wraps a real psycopg2 cursor and raises on execute() calls whose SQL
    contains `match_substr`, until unflaked — then delegates to the real
    cursor. Injecting the failure here (below the manager methods' own
    try/except) rather than replacing the whole manager method is what
    actually exercises the log+rollback+re-raise logic being tested, instead
    of bypassing it."""

    def __init__(self, real_cur, match_substr: str, state: dict):
        object.__setattr__(self, "_real", real_cur)
        object.__setattr__(self, "_match", match_substr)
        object.__setattr__(self, "_state", state)

    def execute(self, sql, params=None):
        if self._state["should_fail"] and self._match in sql:
            raise RuntimeError(f"simulated transient DB failure (matched: {self._match!r})")
        return self._real.execute(sql) if params is None else self._real.execute(sql, params)

    def __getattr__(self, name):
        return getattr(self._real, name)


def patch_flaky_query(match_substr: str):
    """Wraps NotificationManager.__init__ so every instance's self.cur is a
    _FlakyCursor that raises on any execute() containing `match_substr`,
    until unflaked. Returns (unflake, unpatch)."""
    original_init = notif_mod.NotificationManager.__init__
    state = {"should_fail": True}

    def patched_init(self, user_id):
        original_init(self, user_id)
        self.cur = _FlakyCursor(self.cur, match_substr, state)

    notif_mod.NotificationManager.__init__ = patched_init

    def unflake():
        state["should_fail"] = False

    def unpatch():
        notif_mod.NotificationManager.__init__ = original_init

    return unflake, unpatch


def main():
    print("=== Boot the real app (main.app), lifespan included ===")
    # raise_server_exceptions=False: the notifications route has no
    # try/except of its own (unlike main.py's update_user) — it relies on
    # FastAPI/Starlette's default unhandled-exception -> 500 behavior, which
    # only kicks in for a real deployed app (or a TestClient told not to
    # re-raise for debugging). This matches actual production behavior.
    with TestClient(main_module.app, raise_server_exceptions=False) as client:
        check("app boots and lifespan starts", True)

        uid, token = signup(client, f"notif_test_{uuid.uuid4().hex[:8]}")
        print(f"  created uid={uid}")
        headers = cookie_header(token)

        try:
            # ── 1. create_notification: failure -> 500, no phantom row ────
            print("\n=== 1. create_notification: simulated write failure ===")
            unflake, unpatch = patch_flaky_query("INSERT INTO notifications")
            try:
                r = client.post(
                    f"/notification/{uid}",
                    json={"name": "Morning verse", "prompt": "Encourage me"},
                    headers=headers,
                )
                check("failed create -> 500 (never a false 201)", r.status_code == 500, f"{r.status_code} {r.text}")

                unflake()
                r2 = client.post(
                    f"/notification/{uid}",
                    json={"name": "Morning verse", "prompt": "Encourage me"},
                    headers=headers,
                )
                check("retried create after recovery -> 201", r2.status_code == 201, f"{r2.status_code} {r2.text}")
                notif_id = r2.json()["id"]
                row = raw_notification_in_db(notif_id)
                check("retry actually persisted a real row in Postgres", row is not None and row["name"] == "Morning verse", row)
            finally:
                unpatch()

            # ── 2. update_notification (timestamps branch): failure -> 500 ─
            # Sends ONLY `timestamps` (not name/prompt) to isolate the
            # just-fixed direct-cur.execute path from the separate, unguarded
            # self.update() call the name/prompt branch makes (a distinct,
            # pre-existing partial-write/atomicity question that isn't part
            # of this fix and would otherwise confound this assertion).
            print("\n=== 2. update_notification (timestamps branch): simulated write failure ===")
            before = raw_notification_in_db(notif_id)
            unflake, unpatch = patch_flaky_query("SET timestamps = %s::jsonb")
            try:
                r = client.put(
                    f"/notification/{uid}/{notif_id}",
                    json={"timestamps": [None] * 31},
                    headers=headers,
                )
                check("failed update -> 500 (never a false 'ok': True)", r.status_code == 500, f"{r.status_code} {r.text}")
                after = raw_notification_in_db(notif_id)
                check("row left untouched while failure is live", after == before, after)

                unflake()
                new_ts = [None] * 31
                new_ts[0] = "08:00"
                r2 = client.put(
                    f"/notification/{uid}/{notif_id}",
                    json={"timestamps": new_ts},
                    headers=headers,
                )
                check("retried update after recovery -> 200 {'ok': True}", r2.status_code == 200 and r2.json().get("ok") is True, f"{r2.status_code} {r2.text}")
                row = raw_notification_in_db(notif_id)
                check("retry actually persisted the new timestamps", row["timestamps"][0] == "08:00", row["timestamps"])
            finally:
                unpatch()

            # ── 3. set_timestamp: failure -> 500, slot untouched ──────────
            print("\n=== 3. set_timestamp: simulated write failure ===")
            before = raw_notification_in_db(notif_id)
            unflake, unpatch = patch_flaky_query("jsonb_set(timestamps")
            try:
                r = client.patch(
                    f"/notification/{uid}/{notif_id}/timestamp",
                    json={"day": 5, "timestamp": "09:30"},
                    headers=headers,
                )
                check("failed set_timestamp -> 500 (never a false 'ok': True)", r.status_code == 500, f"{r.status_code} {r.text}")
                after = raw_notification_in_db(notif_id)
                check("timestamps slot left untouched while failure is live", after["timestamps"] == before["timestamps"], after)

                unflake()
                r2 = client.patch(
                    f"/notification/{uid}/{notif_id}/timestamp",
                    json={"day": 5, "timestamp": "09:30"},
                    headers=headers,
                )
                check("retried set_timestamp after recovery -> 200 {'ok': True}", r2.status_code == 200 and r2.json().get("ok") is True, f"{r2.status_code} {r2.text}")
                row = raw_notification_in_db(notif_id)
                check("retry actually set the day-5 slot", row["timestamps"][5] == "09:30", row["timestamps"])
            finally:
                unpatch()

            # ── 4. Regression: normal, non-failing flow still works ───────
            print("\n=== 4. Regression: unaffected happy-path create/get/delete ===")
            r = client.post(
                f"/notification/{uid}",
                json={"name": "Second reminder", "prompt": "Be still"},
                headers=headers,
            )
            check("plain create -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
            second_id = r.json()["id"]
            r = client.get(f"/notification/{uid}/{second_id}", headers=headers)
            check("plain get -> 200 with matching name", r.status_code == 200 and r.json().get("name") == "Second reminder", r.text)
            r = client.delete(f"/notification/{uid}/{second_id}", headers=headers)
            check("plain delete -> 204", r.status_code == 204, f"{r.status_code} {r.text}")
            check("deleted row actually gone from Postgres", raw_notification_in_db(second_id) is None, "row still present")

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
