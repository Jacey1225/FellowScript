"""Regression coverage for task 20260825-heartbeat-notes-limit-bypass:
routes/agent.py's commit_heartbeat previously saved a note on every fired
heartbeat with no call to check_limit(user_id, "notes"), so a free-plan user
who had already exhausted their weekly notes cap could keep minting notes
indefinitely just by letting their scheduled agent events fire — the one
note-creating path that had no cap gate (create_note and summarize_session
already had it).

This test proves, against the REAL route via TestClient (not a manager method
in isolation, and not the already-covered denial case in
test_free_limits.py's COMMIT_HEARTBEAT block):

  1. A user UNDER their notes cap still gets a real note saved when their
     heartbeat fires through the full route (gate -> commit_hb_response ->
     note_via_hb) -- the fix must not accidentally block legitimate traffic.
  2. The gate is checked BEFORE commit_hb_response's once-per-day claim, so a
     denied request does not burn that day's fire slot: the heartbeat's
     last_fired stays untouched (NULL) after a 403, and the SAME heartbeat can
     still legitimately fire and succeed later the same day once the user
     drops back under the cap -- proving the spec's preferred ordering
     (check before claim, not claim-then-deny) is actually in effect, not
     just documented in a comment.

Uses a monkeypatched AgentManager._call_api (same technique as
test_commit_heartbeat_idempotency.py's FakeManager, but patched at the class
level since the route constructs AgentManager directly, not a subclass) so no
real LLM call is made and the test is deterministic.

Run:  cd api && ../.venv/bin/python tests/test_commit_heartbeat_notes_cap.py
"""
import _pathfix  # noqa: F401
import _fake_timeline  # noqa: F401

import uuid

from fastapi import FastAPI
from fastapi.testclient import TestClient

from db import DBManager
from backend.auth.sessions import SessionManager
from backend.interactions.agent import AgentManager
from routes.agent import agent_router
from routes.notes import notes_router
from routes.subscription import subscription_router

app = FastAPI()
for r in (agent_router, notes_router, subscription_router):
    app.include_router(r)
client = TestClient(app)

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def _stub_call_api(self, agent_role, messages):
    return (
        '{"__action": "create_note", "title": "Reflection", '
        '"text": "Generated content.", "verses": []}'
    )


def make_test_user() -> str:
    uid = str(uuid.uuid4())
    uname = f"hbcap_{uid[:8]}"
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


def insert_notes(user_id: str, count: int):
    db = DBManager()
    try:
        for i in range(count):
            db.insertion("notes", {
                "_id": str(uuid.uuid4()), "user_id": user_id,
                "title": f"n{i}", "text": "body", "public": False,
                "is_reply": False,
            })
    finally:
        db.close()


def delete_notes(user_id: str, count: int):
    """Delete `count` of the user's notes (frees up cap headroom mid-test)."""
    db = DBManager()
    try:
        db.cur.execute(
            "DELETE FROM notes WHERE _id IN "
            "(SELECT _id FROM notes WHERE user_id = %s LIMIT %s)",
            (user_id, count),
        )
        db.conn.commit()
    finally:
        db.close()


def notes_count(user_id: str) -> int:
    db = DBManager()
    try:
        db.cur.execute("SELECT count(*) FROM notes WHERE user_id = %s", (user_id,))
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


def cleanup(user_id: str):
    db = DBManager()
    try:
        db.delete("notes", {"user_id": user_id})
        db.delete("agent_heartbeats", {"user_id": user_id})
        db.delete("agents", {"user_id": user_id})
        db.delete("users", {"_id": user_id})
    finally:
        db.close()


def main():
    original_call_api = AgentManager._call_api
    AgentManager._call_api = _stub_call_api

    print("=== 1. Under-cap user: commit_heartbeat succeeds through the real route ===")
    uid1 = make_test_user()
    agent_id1 = make_agent(uid1)
    hb_id1 = make_heartbeat(agent_id1, uid1)
    try:
        insert_notes(uid1, 9)  # one slot left under the limit of 10
        before = notes_count(uid1)
        r = client.post(
            f"/agent/{uid1}/{agent_id1}/{hb_id1}/commit_heartbeat",
            json={"prompt": "Write a reflection."},
        )
        check("under-cap heartbeat commit returns 200", r.status_code == 200, f"{r.status_code} {r.text}")
        check("under-cap heartbeat commit reports success", r.json() == {"success": "saved note"}, r.text)
        after = notes_count(uid1)
        check("exactly one new note was created", after == before + 1, f"before={before} after={after}")
    finally:
        cleanup(uid1)

    print("\n=== 2. Ordering: a denial does not burn the day's fire slot ===")
    uid2 = make_test_user()
    agent_id2 = make_agent(uid2)
    hb_id2 = make_heartbeat(agent_id2, uid2)
    try:
        insert_notes(uid2, 10)  # exactly at the free-plan cap
        check("last_fired starts NULL (never fired)", get_last_fired(hb_id2) is None, str(get_last_fired(hb_id2)))

        r_denied = client.post(
            f"/agent/{uid2}/{agent_id2}/{hb_id2}/commit_heartbeat",
            json={"prompt": "Write a reflection."},
        )
        check("at-cap heartbeat commit is denied (403)", r_denied.status_code == 403, f"{r_denied.status_code} {r_denied.text}")
        check(
            "last_fired is STILL NULL after the denial -- the once-per-day claim was never burned",
            get_last_fired(hb_id2) is None, str(get_last_fired(hb_id2)),
        )
        check("no note was created by the denied attempt", notes_count(uid2) == 10, str(notes_count(uid2)))

        # User drops back under the cap later the same day (e.g. deleted a note).
        delete_notes(uid2, 1)
        check("user now has 9 notes (one under the cap)", notes_count(uid2) == 9, str(notes_count(uid2)))

        r_retry = client.post(
            f"/agent/{uid2}/{agent_id2}/{hb_id2}/commit_heartbeat",
            json={"prompt": "Write a reflection."},
        )
        check(
            "the SAME heartbeat can still legitimately fire later the same day "
            "once back under the cap (denial didn't burn the slot)",
            r_retry.status_code == 200 and r_retry.json() == {"success": "saved note"},
            f"{r_retry.status_code} {r_retry.text}",
        )
        check("exactly one note created by the retry", notes_count(uid2) == 10, str(notes_count(uid2)))

        # And now the once-per-day guard applies normally: a second same-day
        # attempt (still under cap, since the earlier note didn't push over)
        # is skipped by commit_hb_response's own idempotency claim -- not by
        # the notes-cap gate, which is a distinct guard.
        insert_notes(uid2, 0)  # no-op, just documents the notes count is 10 again after the retry
    finally:
        cleanup(uid2)

    AgentManager._call_api = original_call_api

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
