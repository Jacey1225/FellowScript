"""Integration test for the free-tier usage gateway (LimitsManager).

Builds a minimal FastAPI app with only the notes / agent / subscription routers
(avoids the Chime-heavy modules in main.py), creates a throwaway free-plan user
directly in the local DB, then hammers each gated endpoint past its cap and
asserts the 403s land exactly where expected. Cleans up the user at the end.

The former `agent_notifications` gated resource (a cap on user-authored
"agentic" notifications, tested here via `notification_router`) was removed
along with that subsystem — see
.claude/pipeline/20260826-activity-based-notifications.

Run:  cd api && ../.venv/bin/python tests/test_free_limits.py
"""

import _pathfix  # noqa: F401
import _fake_timeline  # noqa: F401

import uuid
from fastapi import FastAPI
from fastapi.testclient import TestClient

from db import DBManager
from backend.auth.sessions import SessionManager
from routes.notes import notes_router
from routes.agent import agent_router
from routes.subscription import subscription_router

app = FastAPI()
for r in (notes_router, agent_router, subscription_router):
    app.include_router(r)
client = TestClient(app)

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []

def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got}, want {want}")


def make_test_user() -> tuple[str, str]:
    uid = str(uuid.uuid4())
    uname = f"limits_test_{uid[:8]}"
    db = DBManager()
    try:
        db.insertion("users", {
            "_id": uid, "username": uname,
            "email": f"{uname}@example.com", "hash_pass": "x",
        })
    finally:
        db.close()
    # Every gated route requires an authenticated session matching the path
    # user_id, so mint a real session for this user and attach it to the client.
    sm = SessionManager()
    try:
        token = sm.create_session(uid)
    finally:
        sm.close()
    client.cookies.set("session", token)
    return uid, uname


def cleanup(uid: str):
    db = DBManager()
    try:
        # notes FK has no ON DELETE CASCADE, so remove children explicitly first.
        db.delete("notes", {"user_id": uid})
        db.delete("agent_heartbeats", {"user_id": uid})
        db.delete("agents", {"user_id": uid})
        db.delete("users", {"_id": uid})
    finally:
        db.close()


def main():
    uid, uname = make_test_user()
    print(f"\nCreated free-plan test user: {uname} ({uid})\n")
    try:
        # ── Usage snapshot starts empty ──────────────────────────────────────
        usage = client.get(f"/subscriptions/user/{uid}/usage").json()
        print("Initial usage:", usage["resources"])
        check("subscribed flag", usage["subscribed"], False)

        # ── Notes: 10 allowed, 11th & 12th blocked ───────────────────────────
        print("\nNOTES (limit 10 / 7 days):")
        note_codes = []
        for i in range(12):
            r = client.post(f"/notes/{uid}", json={"title": f"n{i}", "text": "body"})
            note_codes.append(r.status_code)
        check("first 10 notes accepted", note_codes[:10], [201] * 10)
        check("11th note blocked (403)", note_codes[10], 403)
        check("12th note blocked (403)", note_codes[11], 403)
        # Inspect the 403 body shape the clients rely on.
        blocked = client.post(f"/notes/{uid}", json={"title": "x", "text": "y"})
        detail = blocked.json()["detail"]
        check("403 detail resource", detail.get("resource"), "notes")
        check("403 detail used", detail.get("used"), 10)
        check("403 detail limit", detail.get("limit"), 10)

        # summarize_session persists its output as a note, so it must honour the
        # same notes cap. Its gate runs before the AI call, so a capped user is
        # rejected without the model ever being invoked (safe to assert here).
        summ = client.post(
            f"/agent/{uid}/{uuid.uuid4()}/summarize",
            json={"session": {"title": "t", "prompts": [], "verses": []}},
        )
        check("summarize blocked when notes cap reached (403)", summ.status_code, 403)

        # ── Agent events (heartbeats): 1 allowed, 2nd blocked ────────────────
        print("\nAGENT EVENTS (limit 1):")
        # Insert the agent directly (the create route writes name/enabled columns
        # this legacy local DB lacks); we only need a valid FK target here.
        agent_id = str(uuid.uuid4())
        _db = DBManager()
        try:
            _db.insertion("agents", {"_id": agent_id, "user_id": uid, "role": "", "chats": []})
        finally:
            _db.close()
        hb_body = {"timestamps": [None] * 31, "prompt": "p"}
        ev_codes = [client.post(f"/agent/{uid}/{agent_id}/heartbeat", json=hb_body).status_code
                    for _ in range(3)]
        check("1st event accepted", ev_codes[0], 201)
        check("2nd event blocked (403)", ev_codes[1], 403)
        check("3rd event blocked (403)", ev_codes[2], 403)

        # ── commit_heartbeat must also honour the notes cap ──────────────────
        # Regression coverage for 20260825-heartbeat-notes-limit-bypass: a
        # fired heartbeat persists its output as a note, so a user already at
        # the notes cap (exhausted above) must be denied here too, instead of
        # silently getting another note saved through this side door.
        print("\nCOMMIT_HEARTBEAT (notes cap already exhausted above):")
        _db = DBManager()
        try:
            hb_rows = _db.lookup("agent_heartbeats", {"agent_id": agent_id, "user_id": uid})
        finally:
            _db.close()
        hb_id = next(iter(hb_rows))
        notes_before = client.get(f"/subscriptions/user/{uid}/usage").json()["resources"]["notes"]["used"]
        hb_commit = client.post(
            f"/agent/{uid}/{agent_id}/{hb_id}/commit_heartbeat",
            json={"prompt": "Write a reflection."},
        )
        check("commit_heartbeat blocked when notes cap reached (403)", hb_commit.status_code, 403)
        hb_detail = hb_commit.json()["detail"]
        check("commit_heartbeat 403 detail resource", hb_detail.get("resource"), "notes")
        notes_after = client.get(f"/subscriptions/user/{uid}/usage").json()["resources"]["notes"]["used"]
        check("no new note created by the denied heartbeat commit", notes_after, notes_before)

        # ── Final usage snapshot reflects the caps ───────────────────────────
        print("\nFINAL usage snapshot:")
        final = client.get(f"/subscriptions/user/{uid}/usage").json()["resources"]
        print("  ", final)
        check("notes used == 10", final["notes"]["used"], 10)
        check("events used == 1", final["agent_events"]["used"], 1)
        check("notes remaining == 0", final["notes"]["remaining"], 0)

        # ── Subscribed user bypasses all caps ────────────────────────────────
        print("\nSUBSCRIBED USER (should be unlimited):")
        sub_id = str(uuid.uuid4())
        db = DBManager()
        try:
            db.insertion("subscriptions", {
                "_id": sub_id, "user_id": uid, "plan_type": "group",
                "provider": "stripe", "status": "active",
            })
            db.update("users", {"subscription_id": sub_id}, {"_id": uid})
        finally:
            db.close()
        sub_usage = client.get(f"/subscriptions/user/{uid}/usage").json()
        check("now subscribed", sub_usage["subscribed"], True)
        check("notes unlimited", sub_usage["resources"]["notes"]["unlimited"], True)
        # An 11th-plus note is now allowed despite 10 already existing this week.
        extra = client.post(f"/notes/{uid}", json={"title": "extra", "text": "b"})
        check("note accepted past free cap when subscribed", extra.status_code, 201)

    finally:
        db2 = DBManager()
        try:
            db2.delete("subscriptions", {"user_id": uid})
        finally:
            db2.close()
        cleanup(uid)
        print(f"\nCleaned up test user {uname}.")

    total, passed = len(results), sum(results)
    print(f"\n{'='*46}\n  {passed}/{total} checks passed"
          f"  {'✅ ALL GOOD' if passed == total else '❌ FAILURES'}\n{'='*46}")
    raise SystemExit(0 if passed == total else 1)


if __name__ == "__main__":
    main()
