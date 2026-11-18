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
from _thr_common import require_scratch_db  # scratch 55432 locally, CI 5432 under GITHUB_ACTIONS

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
    require_scratch_db()
    uid, uname = make_test_user()
    print(f"\nCreated free-plan test user: {uname} ({uid})\n")
    try:
        # ── Usage snapshot starts empty ──────────────────────────────────────
        usage = client.get(f"/subscriptions/user/{uid}/usage").json()
        print("Initial usage:", usage["resources"])
        check("subscribed flag", usage["subscribed"], False)

        # ── Notes: 5 allowed, 6th & 7th blocked (free limit tightened 10 -> 5) ─
        print("\nNOTES (limit 5 / 7 days):")
        check("usage reports notes limit 5", usage["resources"]["notes"]["limit"], 5)
        note_codes = []
        for i in range(12):
            r = client.post(f"/notes/{uid}", json={"title": f"n{i}", "text": "body"})
            note_codes.append(r.status_code)
        check("first 5 notes accepted", note_codes[:5], [201] * 5)
        check("6th note blocked (403)", note_codes[5], 403)
        check("7th note blocked (403)", note_codes[6], 403)
        check("every later note blocked (403)", note_codes[5:], [403] * 7)
        # Inspect the 403 body shape the clients rely on.
        blocked = client.post(f"/notes/{uid}", json={"title": "x", "text": "y"})
        detail = blocked.json()["detail"]
        check("403 detail resource", detail.get("resource"), "notes")
        check("403 detail used", detail.get("used"), 5)
        check("403 detail limit", detail.get("limit"), 5)

        # summarize_session is paid-only for free users (task
        # 20261002-free-plan-limits-ui); its gates run before the AI call, so a
        # free user is rejected without the model ever being invoked.
        summ = client.post(
            f"/agent/{uid}/{uuid.uuid4()}/summarize",
            json={"session": {"title": "t", "prompts": [], "verses": []}},
        )
        check("summarize blocked for a free user (403)", summ.status_code, 403)
        check("summarize 403 resource is session_summaries (paid-only gate first)",
              summ.json()["detail"].get("resource"), "session_summaries")

        # ── Agent events (scheduled devotions): paid-only, 0 allowed ─────────
        print("\nAGENT EVENTS (paid-only, limit 0):")
        # Insert the agent directly (the create route writes name/enabled columns
        # this legacy local DB lacks); we only need a valid FK target here.
        agent_id = str(uuid.uuid4())
        _db = DBManager()
        try:
            _db.insertion("agents", {"_id": agent_id, "user_id": uid, "role": "", "chats": []})
        finally:
            _db.close()
        hb_body = {"timestamps": [None] * 31, "prompt": "p"}
        ev_resps = [client.post(f"/agent/{uid}/{agent_id}/heartbeat", json=hb_body)
                    for _ in range(3)]
        check("every create blocked for a free user (403)",
              [r.status_code for r in ev_resps], [403] * 3)
        check("403 detail resource is agent_events",
              ev_resps[0].json()["detail"].get("resource"), "agent_events")
        check("403 detail limit is 0", ev_resps[0].json()["detail"].get("limit"), 0)
        _db = DBManager()
        try:
            hb_rows = _db.lookup("agent_heartbeats", {"agent_id": agent_id, "user_id": uid})
        finally:
            _db.close()
        check("no heartbeat row was written by the denied creates", len(hb_rows or {}), 0)

        # ── commit_heartbeat is gated for free users too ─────────────────────
        # (A row can only exist from before the feature became paid-only; the
        # manual/forced fire must not run it. Gate order: agent_events, then notes.
        # The notes-cap-bypass regression 20260825-heartbeat-notes-limit-bypass is
        # covered for subscribed-then-lapsed rows in test_commit_heartbeat_notes_cap.)
        print("\nCOMMIT_HEARTBEAT (free user, legacy row):")
        hb_id = str(uuid.uuid4())
        _db = DBManager()
        try:
            _db.cur.execute(
                "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt) "
                "VALUES (%s, %s, %s, %s::jsonb, %s)", (hb_id, agent_id, uid, "[]", "p"))
            _db.conn.commit()
        finally:
            _db.close()
        notes_before = client.get(f"/subscriptions/user/{uid}/usage").json()["resources"]["notes"]["used"]
        hb_commit = client.post(
            f"/agent/{uid}/{agent_id}/{hb_id}/commit_heartbeat",
            json={"prompt": "Write a reflection."},
        )
        check("commit_heartbeat blocked for a free user (403)", hb_commit.status_code, 403)
        check("commit_heartbeat 403 detail resource", hb_commit.json()["detail"].get("resource"), "agent_events")
        notes_after = client.get(f"/subscriptions/user/{uid}/usage").json()["resources"]["notes"]["used"]
        check("no new note created by the denied heartbeat commit", notes_after, notes_before)

        # ── Final usage snapshot reflects the caps ───────────────────────────
        print("\nFINAL usage snapshot:")
        final = client.get(f"/subscriptions/user/{uid}/usage").json()["resources"]
        print("  ", final)
        check("notes used == 5", final["notes"]["used"], 5)
        check("events limit == 0 (legacy row counted, none added)", (final["agent_events"]["used"], final["agent_events"]["limit"]), (1, 0))
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
        # A 6th-plus note is now allowed despite 5 already existing this week.
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
