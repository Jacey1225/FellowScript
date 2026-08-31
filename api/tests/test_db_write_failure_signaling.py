"""Integration test for task 20260831-db-write-failure-signaling.

DBManager.insertion/.update/.delete (db.py) used to catch sql.Error, log it
locally, roll back, and return None on BOTH the happy path and the error
path -- every one of the ~30+ call sites had no way to distinguish a real
write from a silently-swallowed DB error, so callers reported fake success
to the user. This task made all three methods return an explicit bool
signal, updated every call site to check it and raise the shared
SaveFailedError (-> app-wide 503 "couldn't be saved" response) instead of
proceeding as fake success, and gave a caught write failure a dedicated
DB_WRITE_FAILURE log marker the CloudWatch-backed watchdog can classify
separately from a generic ERROR line -- with sensitive values redacted
before that line is ever emitted.

Two tiers of coverage:

  Tier A -- DBManager.insertion/.update/.delete directly, against a REAL
  Postgres connection, no mocking: success, a genuine caught sql.Error
  (duplicate key / invalid input syntax), and (for update/delete) the
  zero-rows-matched no-op case that is *also* a False return but must NOT
  emit a DB_WRITE_FAILURE log line (see db.py's own docstrings). Also
  confirms the DB_WRITE_FAILURE marker's redaction actually strips a raw
  email/row value before it would reach the CloudWatch-shipped log stream.

  Tier B -- four representative call sites named in the intake spec
  (session creation, one note CRUD path, one friend op, one subscription
  op), each exercised end to end through the real app (TestClient(main.app))
  for BOTH the success path (real Postgres, no patching) and the failure
  path. The failure path temporarily overrides one write method on the
  specific *Manager class involved (e.g. `SessionManager.insertion`) to
  return False and confirms the call site's documented behavior: raise
  SaveFailedError, which surfaces as a 503 with the shared "couldn't be
  saved" message instead of a fake-success response -- restored via
  try/finally immediately after each assertion. This is a deliberate,
  narrow exception to this project's normal "never mock the database"
  rule (see write-tests skill): Tier A already proves the real Postgres
  failure path for the three DBManager methods themselves with no
  patching at all; Tier B's job is to prove the ~30+ call sites' own
  control flow (do they check the bool and raise, or not) which is most
  reliably and precisely triggered by forcing the exact False return
  they're documented to handle, not by fighting Postgres into a specific
  constraint violation for four unrelated tables.

Run:  cd api && ../.venv/bin/python tests/test_db_write_failure_signaling.py
"""
import _pathfix  # noqa: F401,E402

import io
import logging
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.interactions.friends import FriendsManager  # noqa: E402
from backend.subscription.subscriptions import SubscriptionsManager  # noqa: E402

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


def _spoofed_ip_header() -> dict:
    """Each call spoofs a distinct CF-Connecting-IP so this file's ~10
    /signup calls (well over the 5/minute per-IP limit) don't trip
    /signup's rate limiter -- same technique as test_friend_activity.py /
    test_security_hardening.py: the limiter keys off this header rather
    than the shared TestClient connection. Purely a test-harness
    workaround for a single-IP test run."""
    global _signup_counter
    _signup_counter += 1
    return {"cf-connecting-ip": f"203.0.113.{_signup_counter % 250 + 1}"}


def signup(client, username):
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers=_spoofed_ip_header())
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def cleanup_users(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


class _CaptureLogs:
    """Captures db.py logger output for a `with` block, so a test can
    assert exactly what DB_WRITE_FAILURE line was (or wasn't) emitted,
    and that it doesn't leak a raw sensitive value."""

    def __init__(self):
        self.logger = logging.getLogger("db")
        self.stream = io.StringIO()
        self.handler = logging.StreamHandler(self.stream)

    def __enter__(self):
        self.logger.addHandler(self.handler)
        return self

    def __exit__(self, *exc):
        self.logger.removeHandler(self.handler)

    @property
    def text(self) -> str:
        return self.stream.getvalue()


# ── Tier A: DBManager.insertion/.update/.delete directly, real Postgres ────

def test_insertion_success_and_failure():
    print("\n=== Tier A: DBManager.insertion -- success and failure (real Postgres) ===")
    db = DBManager()
    uid_a = str(uuid.uuid4())
    nonexistent_user_id = str(uuid.uuid4())
    try:
        with _CaptureLogs() as logs:
            ok = db.insertion("users", {
                "_id": uid_a, "username": f"insok_{uid_a[:8]}",
                "email": f"insok_{uid_a[:8]}@example.com", "hash_pass": "x",
            })
        check("insertion returns True on a genuine successful write", ok is True, str(ok))
        row = db.lookup("users", {"_id": uid_a})
        check("the successfully-inserted row is actually present", uid_a in row, str(row))
        check("no DB_WRITE_FAILURE logged on the success path", "DB_WRITE_FAILURE" not in logs.text, logs.text)

        # Real caught sql.Error: a foreign-key violation (sessions.user_id
        # REFERENCES users(_id)). Deliberately NOT a duplicate-unique-key
        # insert: `ON CONFLICT DO NOTHING` (insertion()'s default) swallows
        # ANY unique-constraint conflict without ever raising sql.Error --
        # that's db.py's own documented idempotent-upsert behavior, not a
        # failure -- so a real error needs a violation DO NOTHING can't
        # absorb, and an FK violation is exactly that.
        with _CaptureLogs() as logs:
            ok = db.insertion("sessions", {
                "token_hash": f"tok_{uuid.uuid4().hex}",
                "user_id": nonexistent_user_id,
                "expires_at": datetime.now(timezone.utc) + timedelta(days=1),
            })
        check("insertion returns False (not None) on a caught sql.Error -- this is the bug this task fixes",
              ok is False, str(ok))
        db.cur.execute("SELECT 1 FROM sessions WHERE user_id = %s", (nonexistent_user_id,))
        check("the failed insert's row was NOT actually written (rollback held)", db.cur.fetchone() is None)
        check("a caught insert error emits the dedicated DB_WRITE_FAILURE marker "
              "(watchdog._ERROR_SIGNAL_PATTERNS' db_write_failure entry)",
              "DB_WRITE_FAILURE" in logs.text and "op=insert" in logs.text and "table=sessions" in logs.text,
              logs.text)
        check("the raw offending FK value is redacted out of the logged error, not echoed verbatim",
              nonexistent_user_id not in logs.text, logs.text)
        check("connection is still usable after rollback (a second, distinct write succeeds)",
              db.insertion("users", {
                  "_id": str(uuid.uuid4()), "username": f"insok2_{uuid.uuid4().hex[:8]}",
                  "email": f"ok2_{uuid.uuid4().hex[:8]}@example.com", "hash_pass": "x",
              }) is True)
    finally:
        db.cur.execute("SELECT _id FROM users WHERE username LIKE 'insok2_%'")
        extra_ids = [str(r[0]) for r in db.cur.fetchall()]
        cleanup_users(uid_a, *extra_ids)
        db.close()


def test_update_success_zero_rows_and_failure():
    print("\n=== Tier A: DBManager.update -- success, zero-rows no-op, and failure (real Postgres) ===")
    db = DBManager()
    uid = str(uuid.uuid4())
    try:
        db.insertion("users", {
            "_id": uid, "username": f"updtest_{uid[:8]}",
            "email": f"updtest_{uid[:8]}@example.com", "hash_pass": "x",
        })

        with _CaptureLogs() as logs:
            ok = db.update("users", {"timezone": "America/New_York"}, {"_id": uid})
        check("update returns True when a real row was matched and changed", ok is True, str(ok))
        row = db.lookup("users", {"_id": uid})
        check("the update was actually persisted", row.get(uid, {}).get("timezone") == "America/New_York",
              str(row.get(uid, {}).get("timezone")))
        check("no DB_WRITE_FAILURE logged on the success path", "DB_WRITE_FAILURE" not in logs.text, logs.text)

        with _CaptureLogs() as logs:
            ok = db.update("users", {"timezone": "UTC"}, {"_id": str(uuid.uuid4())})
        check("update returns False (not a fake success) when zero rows matched -- no exception, "
              "no row changed, but still not treated as success",
              ok is False, str(ok))
        check("a zero-rows no-op does NOT log DB_WRITE_FAILURE (it isn't a DB error, "
              "per db.py's own docstring -- would otherwise flood the watchdog pipeline)",
              "DB_WRITE_FAILURE" not in logs.text, logs.text)

        with _CaptureLogs() as logs:
            ok = db.update("users", {"timezone": "UTC"}, {"_id": "not-a-real-uuid"})
        check("update returns False on a genuine caught sql.Error (invalid uuid input)", ok is False, str(ok))
        check("a real caught update error DOES log DB_WRITE_FAILURE with op=update",
              "DB_WRITE_FAILURE" in logs.text and "op=update" in logs.text and "table=users" in logs.text,
              logs.text)
    finally:
        cleanup_users(uid)
        db.close()


def test_delete_success_zero_rows_and_failure():
    print("\n=== Tier A: DBManager.delete -- success, zero-rows no-op, and failure (real Postgres) ===")
    db = DBManager()
    uid = str(uuid.uuid4())
    try:
        db.insertion("users", {
            "_id": uid, "username": f"deltest_{uid[:8]}",
            "email": f"deltest_{uid[:8]}@example.com", "hash_pass": "x",
        })

        with _CaptureLogs() as logs:
            ok = db.delete("users", {"_id": uid})
        check("delete returns True when a real row existed and was removed", ok is True, str(ok))
        row = db.lookup("users", {"_id": uid})
        check("the row is actually gone", uid not in row, str(row))
        check("no DB_WRITE_FAILURE logged on the success path", "DB_WRITE_FAILURE" not in logs.text, logs.text)

        with _CaptureLogs() as logs:
            ok = db.delete("users", {"_id": uid})
        check("deleting the same (now-gone) row again returns False (zero rows), not a fake success",
              ok is False, str(ok))
        check("a zero-rows delete no-op does NOT log DB_WRITE_FAILURE",
              "DB_WRITE_FAILURE" not in logs.text, logs.text)

        with _CaptureLogs() as logs:
            ok = db.delete("users", {"_id": "not-a-real-uuid"})
        check("delete returns False on a genuine caught sql.Error (invalid uuid input)", ok is False, str(ok))
        check("a real caught delete error DOES log DB_WRITE_FAILURE with op=delete",
              "DB_WRITE_FAILURE" in logs.text and "op=delete" in logs.text and "table=users" in logs.text,
              logs.text)
    finally:
        cleanup_users(uid)
        db.close()


def test_failing_row_redaction():
    print("\n=== Tier A: NOT NULL violation redacts the whole 'Failing row contains (...)' DETAIL ===")
    db = DBManager()
    try:
        # hash_pass is NOT NULL -- omitting it triggers Postgres's "null
        # value in column ... violates not-null constraint" / "Failing row
        # contains (...)" DETAIL shape, which (per security gate's step-3
        # fix) dumps every column of the attempted row. Go through the real
        # insertion() path (not a raw cursor) so redaction and the
        # DB_WRITE_FAILURE marker are both exercised together.
        uid = str(uuid.uuid4())
        email = f"notnull_{uuid.uuid4().hex[:8]}@example.com"
        with _CaptureLogs() as logs:
            ok = db.insertion("users", {"_id": uid, "username": f"nn_{uid[:8]}", "email": email})
        check("insertion returns False on a NOT NULL violation (missing hash_pass)", ok is False, str(ok))
        check("DB_WRITE_FAILURE logged for the NOT NULL violation", "DB_WRITE_FAILURE" in logs.text, logs.text)
        check("the row's email does not leak into the log via the 'Failing row contains (...)' DETAIL",
              email not in logs.text, logs.text)
    finally:
        # The NOT NULL violation means nothing was ever committed -- rollback
        # already undid it, so there is nothing to clean up here.
        db.close()


# ── Tier B: representative call sites, real app, success + simulated failure ──
#
# All four share ONE TestClient(main_module.app) context (passed in as
# `client`), not one each: main.py's lifespan starts a module-level
# AsyncIOScheduler singleton (backend/interactions/scheduler.py) bound to
# that context's event loop, and a second, separate `with TestClient(...)`
# block after the first has exited tries to re-add jobs to that same
# singleton on an already-closed loop ("RuntimeError: Event loop is
# closed"). One shared client, opened once in `main()`, avoids that.

def test_session_creation_success_and_failure(client):
    print("\n=== Tier B: session creation (SessionManager.create_session via POST /signup) ===")
    # -- success: real Postgres, no patching --
    uid, token = signup(client, f"sesok_{uuid.uuid4().hex[:8]}")
    try:
        check("signup succeeds and issues a session cookie", bool(token), token)
        db = DBManager()
        try:
            db.cur.execute("SELECT 1 FROM sessions WHERE user_id = %s", (uid,))
            check("a real sessions row was persisted for the new user", db.cur.fetchone() is not None)
        finally:
            db.close()
    finally:
        cleanup_users(uid)

    # -- failure: SessionManager.insertion forced to report failure --
    # (persist_new_user() and the free-plan subscription write both run
    # BEFORE issue_session() in main.py's signup handler, so the user row
    # itself does get committed even though signup as a whole must still
    # fail closed here -- the 503 response has no "user_id" key to
    # recover, so cleanup below finds the orphaned row by username.)
    original = SessionManager.insertion
    SessionManager.insertion = lambda self, *a, **kw: False
    fail_username = f"sesfail_{uuid.uuid4().hex[:8]}"
    try:
        r = client.post("/signup", json={
            "username": fail_username,
            "email": f"{fail_username}@example.com",
            "plain_pass": "TestPass123!", "terms_accepted": True,
        }, headers=_spoofed_ip_header())
        check("signup returns 503 (not a fake-success 201) when session creation's write fails",
              r.status_code == 503, f"{r.status_code} {r.text}")
        check("503 body carries the shared 'couldn't be saved' message, not a raw exception",
              "couldn't be saved" in str(r.json().get("detail", "")).lower(), r.text)
        check("no session cookie was set when the write failed",
              r.cookies.get("session") is None, str(dict(r.cookies)))
    finally:
        SessionManager.insertion = original
        db = DBManager()
        try:
            db.cur.execute("SELECT _id FROM users WHERE username = %s", (fail_username,))
            row = db.cur.fetchone()
            uid2 = str(row[0]) if row else None
        finally:
            db.close()
        if uid2:
            cleanup_users(uid2)


def test_note_create_success_and_failure(client):
    print("\n=== Tier B: note CRUD (POST /notes/{user_id}) ===")
    uid, token = signup(client, f"noteok_{uuid.uuid4().hex[:8]}")
    note_body = {
        "user": uid, "title": "T", "text": "B", "public": False,
        "group_id": "", "is_reply": False, "verses": [],
    }
    note_id = None
    try:
        # -- success: real Postgres, no patching --
        r = client.post(f"/notes/{uid}", json=note_body, headers=cookie_header(token))
        check("POST /notes/{user_id} succeeds -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
        note_id = r.json().get("id")
        db = DBManager()
        try:
            db.cur.execute("SELECT 1 FROM notes WHERE _id = %s", (note_id,))
            check("the note was actually persisted", db.cur.fetchone() is not None)
        finally:
            db.close()

        # -- failure: DBManager.insertion forced to fail, scoped to the
        #    "notes" table only, so other writes on the same request
        #    (activity tracking etc.) are unaffected. --
        original = DBManager.insertion

        def fake_insertion(self, table, values, conflict="DO NOTHING"):
            if table == "notes":
                return False
            return original(self, table, values, conflict)

        DBManager.insertion = fake_insertion
        try:
            r = client.post(f"/notes/{uid}", json=note_body, headers=cookie_header(token))
            check("POST /notes/{user_id} returns 503 (not a fake-success 201) when the write fails",
                  r.status_code == 503, f"{r.status_code} {r.text}")
            check("503 body carries the shared 'couldn't be saved' message",
                  "couldn't be saved" in str(r.json().get("detail", "")).lower(), r.text)
        finally:
            DBManager.insertion = original

        r = client.get(f"/notes/{uid}", headers=cookie_header(token))
        notes = r.json()["notes"]
        check("exactly the one successfully-created note exists -- no phantom note "
              "was created by the failed write",
              list(notes.keys()) == [note_id], str(list(notes.keys())))
    finally:
        if note_id:
            db = DBManager()
            try:
                db.cur.execute("DELETE FROM note_verses WHERE note_id = %s", (note_id,))
                db.cur.execute("DELETE FROM notes WHERE _id = %s", (note_id,))
                db.conn.commit()
            finally:
                db.close()
        cleanup_users(uid)


def test_friend_request_success_and_failure(client):
    print("\n=== Tier B: friend op (FriendsManager.send_add_request via POST /friends/{user_id}/request) ===")
    uid_a, token_a = signup(client, f"frok_a_{uuid.uuid4().hex[:8]}")
    uid_b, _ = signup(client, f"frok_b_{uuid.uuid4().hex[:8]}")
    try:
        db = DBManager()
        try:
            username_b = db.lookup("users", {"_id": uid_b})[uid_b]["username"]
        finally:
            db.close()

        # -- success: real Postgres, no patching --
        r = client.post(f"/friends/{uid_a}/request", params={"friend_username": username_b},
                         headers=cookie_header(token_a))
        check("POST /friends/{user_id}/request succeeds -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
        db = DBManager()
        try:
            db.cur.execute(
                "SELECT 1 FROM friend_requests WHERE to_user_id=%s AND from_user_id=%s",
                (uid_b, uid_a),
            )
            check("the friend_requests row was actually persisted", db.cur.fetchone() is not None)
            db.cur.execute(
                "DELETE FROM friend_requests WHERE to_user_id=%s AND from_user_id=%s", (uid_b, uid_a)
            )
            db.conn.commit()
        finally:
            db.close()

        # -- failure: FriendsManager.insertion forced to report failure --
        original = FriendsManager.insertion
        FriendsManager.insertion = lambda self, *a, **kw: False
        try:
            r = client.post(f"/friends/{uid_a}/request", params={"friend_username": username_b},
                             headers=cookie_header(token_a))
            check("POST /friends/{user_id}/request returns 503 (not a fake-success) when the write fails",
                  r.status_code == 503, f"{r.status_code} {r.text}")
            check("503 body carries the shared 'couldn't be saved' message",
                  "couldn't be saved" in str(r.json().get("detail", "")).lower(), r.text)
        finally:
            FriendsManager.insertion = original

        db = DBManager()
        try:
            db.cur.execute(
                "SELECT 1 FROM friend_requests WHERE to_user_id=%s AND from_user_id=%s",
                (uid_b, uid_a),
            )
            check("no phantom friend_requests row was created by the failed write",
                  db.cur.fetchone() is None)
        finally:
            db.close()
    finally:
        cleanup_users(uid_a, uid_b)


def test_subscription_free_plan_success_and_failure(client):
    print("\n=== Tier B: subscription op (SubscriptionsManager.create_free_plan via POST /signup) ===")
    # -- success: real Postgres, no patching --
    uid, _ = signup(client, f"subok_{uuid.uuid4().hex[:8]}")
    try:
        db = DBManager()
        try:
            row = db.lookup("users", {"_id": uid})
            sub_id = row.get(uid, {}).get("subscription_id")
            check("signup's free-plan subscription op actually set users.subscription_id",
                  bool(sub_id), str(row.get(uid)))
            db.cur.execute("SELECT plan_type FROM subscriptions WHERE _id = %s", (sub_id,))
            sub_row = db.cur.fetchone()
            check("a real free-plan subscriptions row was persisted",
                  sub_row is not None and sub_row[0] == "free", str(sub_row))
        finally:
            db.close()
    finally:
        cleanup_users(uid)

    # -- failure: SubscriptionsManager.update forced to report failure, so
    #    create_free_plan's users.subscription_id write fails after the
    #    subscriptions row insert already happened. --
    original = SubscriptionsManager.update
    SubscriptionsManager.update = lambda self, *a, **kw: False
    uid2 = None
    fail_username = f"subfail_{uuid.uuid4().hex[:8]}"
    try:
        r = client.post("/signup", json={
            "username": fail_username,
            "email": f"{fail_username}@example.com",
            "plain_pass": "TestPass123!", "terms_accepted": True,
        }, headers=_spoofed_ip_header())
        check("signup returns 503 (not a fake-success 201) when the subscription-linking write fails",
              r.status_code == 503, f"{r.status_code} {r.text}")
        check("503 body carries the shared 'couldn't be saved' message",
              "couldn't be saved" in str(r.json().get("detail", "")).lower(), r.text)
        check("no session cookie was issued -- the failure happened before issue_session, "
              "so the caller never gets a cookie for a half-created account",
              r.cookies.get("session") is None, str(dict(r.cookies)))
    finally:
        SubscriptionsManager.update = original
        # persist_new_user already committed the base user row before the
        # failing subscription-linking write ran; find and clean it up even
        # though signup itself never returned its user_id.
        db = DBManager()
        try:
            db.cur.execute("SELECT _id FROM users WHERE username = %s", (fail_username,))
            row = db.cur.fetchone()
            uid2 = str(row[0]) if row else None
        finally:
            db.close()
        if uid2:
            db = DBManager()
            try:
                db.cur.execute("DELETE FROM subscriptions WHERE user_id = %s", (uid2,))
                db.conn.commit()
            finally:
                db.close()
            cleanup_users(uid2)


def main():
    test_insertion_success_and_failure()
    test_update_success_zero_rows_and_failure()
    test_delete_success_zero_rows_and_failure()
    test_failing_row_redaction()

    with TestClient(main_module.app) as client:
        test_session_creation_success_and_failure(client)
        test_note_create_success_and_failure(client)
        test_friend_request_success_and_failure(client)
        test_subscription_free_plan_success_and_failure(client)


if __name__ == "__main__":
    main()

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
