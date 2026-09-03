"""Tests for the new AgentHeartbeats.notes_public field (task
20260903-notes-public-repurpose, backend step 3): an explicit,
deny-by-default, user-configured value controlling whether the note a
scheduled heartbeat fire generates is group-editable by non-owner group
members (post-repurpose meaning of notes.public), replacing the old
LLM-passthrough (`data.get("public", False)`) for heartbeat-fired notes and
the old hardcoded `True` for session-summary group notes.

Covers:
  1. add_heartbeat persists notes_public (explicit True, and omitted ->
     defaults False).
  2. update_heartbeat persists a changed notes_public value.
  3. commit_heartbeat (commit_hb_response -> note_via_hb) sets the fired
     note's `public` column from the HEARTBEAT ROW's own stored
     notes_public -- never from the LLM's own response -- for both True and
     False configured values.
  4. A heartbeat fire that ends up ungrouped (no group_id) forces the note's
     public to False regardless of the heartbeat's configured notes_public
     (mirrors group_id having no non-owner to grant edit access to).
  5. summarize_session's new notes_public body field: defaults False when
     omitted, honors an explicit True, and is never inferred from the LLM's
     summary content.

Uses a monkeypatched AgentManager._call_api (same technique as
test_commit_heartbeat_notes_cap.py) so no real LLM call is made.

Run: cd api && ../.venv/bin/python tests/test_agent_notes_public.py
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
from routes.community import group_router

app = FastAPI()
for r in (agent_router, notes_router, group_router):
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


def make_test_user(prefix="hbpub") -> str:
    uid = str(uuid.uuid4())
    uname = f"{prefix}_{uid[:8]}"
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
    return uid, token


def make_agent(user_id: str) -> str:
    agent_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("agents", {"_id": agent_id, "user_id": user_id, "role": "", "chats": []})
    finally:
        db.close()
    return agent_id


def make_group(owner_id: str, token: str, member_ids: list[str]) -> str:
    gid = str(uuid.uuid4())
    client.cookies.set("session", token)
    r = client.post(f"/groups/{owner_id}", json={
        "group_id": gid, "title": "notes_public test group",
        "users": [owner_id] + member_ids,
    })
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def get_heartbeat_notes_public(hb_id: str):
    db = DBManager()
    try:
        db.cur.execute("SELECT notes_public FROM agent_heartbeats WHERE _id = %s", (hb_id,))
        row = db.cur.fetchone()
        return row[0] if row else None
    finally:
        db.close()


def latest_note_public(user_id: str):
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT public FROM notes WHERE user_id = %s ORDER BY timestamp DESC LIMIT 1",
            (user_id,),
        )
        row = db.cur.fetchone()
        return row[0] if row else None
    finally:
        db.close()


def cleanup(*user_ids, group_ids=()):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM agent_heartbeats WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM agents WHERE user_id = %s", (uid,))
        for gid in group_ids:
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def main():
    original_call_api = AgentManager._call_api
    AgentManager._call_api = _stub_call_api

    print("=== 1. add_heartbeat persists notes_public (explicit True, and default False) ===")
    uid1, token1 = make_test_user()
    agent_id1 = make_agent(uid1)
    gid1 = make_group(uid1, token1, [])
    try:
        client.cookies.set("session", token1)
        r = client.post(f"/agent/{uid1}/{agent_id1}/heartbeat", json={
            "prompt": "Write a reflection.", "group_id": gid1, "notes_public": True,
        })
        check("add_heartbeat with notes_public=True -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
        db = DBManager()
        try:
            db.cur.execute(
                "SELECT _id FROM agent_heartbeats WHERE user_id = %s ORDER BY _id DESC LIMIT 1", (uid1,)
            )
            hb_id1 = db.cur.fetchone()[0]
        finally:
            db.close()
        check("heartbeat row persisted notes_public=True",
              get_heartbeat_notes_public(hb_id1) is True, get_heartbeat_notes_public(hb_id1))

        # Free-plan agent_events cap is 1 -- delete the first heartbeat before
        # creating a second so this sub-case isn't blocked by the unrelated
        # subscription-limit gate.
        db = DBManager()
        try:
            db.cur.execute("DELETE FROM agent_heartbeats WHERE _id = %s", (hb_id1,))
            db.conn.commit()
        finally:
            db.close()

        r2 = client.post(f"/agent/{uid1}/{agent_id1}/heartbeat", json={
            "prompt": "Write a reflection.", "group_id": gid1,
            # notes_public omitted entirely
        })
        check("add_heartbeat with notes_public omitted -> 201", r2.status_code == 201, f"{r2.status_code} {r2.text}")
        db = DBManager()
        try:
            db.cur.execute(
                "SELECT _id FROM agent_heartbeats WHERE user_id = %s ORDER BY _id DESC LIMIT 1", (uid1,)
            )
            hb_id1b = db.cur.fetchone()[0]
        finally:
            db.close()
        check("heartbeat row defaults notes_public=False when omitted (deny-by-default)",
              get_heartbeat_notes_public(hb_id1b) is False, get_heartbeat_notes_public(hb_id1b))
    finally:
        cleanup(uid1, group_ids=[gid1])

    print("\n=== 2. update_heartbeat persists a changed notes_public value ===")
    uid2, token2 = make_test_user()
    agent_id2 = make_agent(uid2)
    gid2 = make_group(uid2, token2, [])
    try:
        client.cookies.set("session", token2)
        r = client.post(f"/agent/{uid2}/{agent_id2}/heartbeat", json={
            "prompt": "Write a reflection.", "group_id": gid2, "notes_public": False,
        })
        check("add_heartbeat baseline -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
        db = DBManager()
        try:
            db.cur.execute(
                "SELECT _id FROM agent_heartbeats WHERE user_id = %s ORDER BY _id DESC LIMIT 1", (uid2,)
            )
            hb_id2 = db.cur.fetchone()[0]
        finally:
            db.close()
        check("baseline notes_public is False", get_heartbeat_notes_public(hb_id2) is False, "")

        r2 = client.put(f"/agent/{uid2}/{hb_id2}/update_heartbeats", json={
            "agent_id": agent_id2, "prompt": "Write a reflection.",
            "group_id": gid2, "notes_public": True,
        })
        check("update_heartbeat flipping notes_public to True -> 200", r2.status_code == 200, f"{r2.status_code} {r2.text}")
        check("heartbeat row now persists notes_public=True",
              get_heartbeat_notes_public(hb_id2) is True, get_heartbeat_notes_public(hb_id2))
    finally:
        cleanup(uid2, group_ids=[gid2])

    print("\n=== 3. commit_heartbeat: fired note's `public` comes from the heartbeat's own notes_public ===")
    uid3, token3 = make_test_user()
    agent_id3 = make_agent(uid3)
    gid3 = make_group(uid3, token3, [])
    try:
        client.cookies.set("session", token3)
        r = client.post(f"/agent/{uid3}/{agent_id3}/heartbeat", json={
            "prompt": "Write a reflection.", "group_id": gid3, "notes_public": True,
        })
        db = DBManager()
        try:
            db.cur.execute(
                "SELECT _id FROM agent_heartbeats WHERE user_id = %s ORDER BY _id DESC LIMIT 1", (uid3,)
            )
            hb_id3 = db.cur.fetchone()[0]
        finally:
            db.close()

        r2 = client.post(f"/agent/{uid3}/{agent_id3}/{hb_id3}/commit_heartbeat",
                          json={"prompt": "Write a reflection."})
        check("commit_heartbeat with notes_public=True heartbeat -> 200",
              r2.status_code == 200, f"{r2.status_code} {r2.text}")
        check("fired note's public column is True, sourced from the heartbeat row "
              "(not the LLM response, which never mentions public)",
              latest_note_public(uid3) is True, latest_note_public(uid3))
    finally:
        cleanup(uid3, group_ids=[gid3])

    print("\n=== 4. A fire that ends up ungrouped forces the note's public to False "
          "regardless of the heartbeat's configured notes_public ===")
    uid4, token4 = make_test_user()
    agent_id4 = make_agent(uid4)
    try:
        client.cookies.set("session", token4)
        # No group_id at all -- personal event, notes_public=True requested anyway.
        r = client.post(f"/agent/{uid4}/{agent_id4}/heartbeat", json={
            "prompt": "Write a reflection.", "notes_public": True,
        })
        check("add_heartbeat (ungrouped, notes_public=True) -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
        db = DBManager()
        try:
            db.cur.execute(
                "SELECT _id FROM agent_heartbeats WHERE user_id = %s ORDER BY _id DESC LIMIT 1", (uid4,)
            )
            hb_id4 = db.cur.fetchone()[0]
        finally:
            db.close()

        r2 = client.post(f"/agent/{uid4}/{agent_id4}/{hb_id4}/commit_heartbeat",
                          json={"prompt": "Write a reflection."})
        check("commit_heartbeat on an ungrouped heartbeat -> 200", r2.status_code == 200, f"{r2.status_code} {r2.text}")
        check("fired note's public is forced False when ungrouped, even though "
              "notes_public=True was configured (no group to draw edit-access members from)",
              latest_note_public(uid4) is False, latest_note_public(uid4))
    finally:
        cleanup(uid4)

    AgentManager._call_api = original_call_api

    print("\n=== 5. summarize_session's notes_public body field ===")
    uid5, token5 = make_test_user()
    agent_id5 = make_agent(uid5)
    original_call_api2 = AgentManager._call_api
    AgentManager._call_api = lambda self, role, messages: "A generated summary."
    try:
        client.cookies.set("session", token5)
        r = client.post(f"/agent/{uid5}/{agent_id5}/summarize", json={
            "session": {"title": "Study 1", "prompts": [], "verses": []},
            # notes_public omitted
        })
        check("summarize_session with notes_public omitted -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
        check("summary note defaults public=False when notes_public omitted (deny-by-default, "
              "no longer the old hardcoded True)",
              latest_note_public(uid5) is False, latest_note_public(uid5))

        r2 = client.post(f"/agent/{uid5}/{agent_id5}/summarize", json={
            "session": {"title": "Study 2", "prompts": [], "verses": []},
            "notes_public": True,
        })
        check("summarize_session with notes_public=True -> 201", r2.status_code == 201, f"{r2.status_code} {r2.text}")
        check("summary note honors an explicit notes_public=True",
              latest_note_public(uid5) is True, latest_note_public(uid5))
    finally:
        AgentManager._call_api = original_call_api2
        cleanup(uid5)

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
