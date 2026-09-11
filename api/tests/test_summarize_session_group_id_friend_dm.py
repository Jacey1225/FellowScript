"""Regression coverage for task 20260911-session-summary-group-id-crash,
backend step: `summarize_session` (POST /agent/{user_id}/{agent_id}/summarize`,
api/routes/agent.py).

Before this fix, `summarize_session` wrote whatever `group_id` the client
sent straight into `notes.group_id` (a FK-constrained `uuid` column) with no
validation. A friend-DM live session's `group_id` is actually the synthetic
"<uidA>|<uidB>" composite room key (`ChatThreadViewModel.roomKey`), not a
real group UUID -- so ending a friend-DM session with `summarize: true`
threw `psycopg2.errors.InvalidTextRepresentation` and 500'd the whole
request. This is the exact bug the user reported.

Covers, against a REAL Postgres DB and the REAL HTTP routes (matching
test_heartbeat_group_id.py / test_compliance_remediation_regressions.py's
established convention for this route family):

  1. THE CORE FIX: a friend-DM composite `group_id` (contains "|") no longer
     500s -- it resolves to `group_id = NULL` and the summary saves as a
     private note.
  2. A real-group session summarize still works and still carries the real
     `group_id` through -- no regression to the legitimate group case.
  3. A real (non-DM-shaped) `group_id` the caller is NOT a member of is
     REJECTED (403) via `_require_group_membership`, not silently passed
     through or guessed -- and no note is persisted for the rejected
     attempt.
  4. Regression: omitting `group_id` entirely still works exactly as before
     (private note, `group_id` NULL).

Run:  cd api && ../.venv/bin/python tests/test_summarize_session_group_id_friend_dm.py
"""
import _pathfix  # noqa: F401,E402

import os
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
# Real S3/GIF config may not be present in every dev environment; this test
# never exercises either subsystem -- it only needs main.app's lifespan
# config validation to pass so the real HTTP routes can boot. Must be set
# before importing _fake_timeline (see test_devotion_summarize_roundtrip.py's
# identical precedent) since that import chain reads S3_BUCKET_NAME/
# S3_REGION into module-level constants at import time.
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

import _fake_timeline  # noqa: F401,E402

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
import backend.interactions.agent as agent_module  # noqa: E402

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
    fake_ip = f"203.0.113.{uuid.uuid4().int % 250 + 1}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def create_group(client, token, owner_id, member_ids):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner_id}", json={
        "group_id": gid, "title": "Summarize Group Test", "users": [owner_id] + member_ids,
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


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


def note_count(user_id: str) -> int:
    db = DBManager()
    try:
        db.cur.execute("SELECT COUNT(*) FROM notes WHERE user_id = %s", (user_id,))
        return db.cur.fetchone()[0]
    finally:
        db.close()


def latest_note_for_user(user_id: str) -> dict | None:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT _id, group_id, title FROM notes WHERE user_id = %s ORDER BY timestamp DESC LIMIT 1",
            (user_id,),
        )
        row = db.cur.fetchone()
        if not row:
            return None
        return {"_id": str(row[0]), "group_id": str(row[1]) if row[1] else None, "title": row[2]}
    finally:
        db.close()


def cleanup(*user_ids, group_ids=()):
    db = DBManager()
    try:
        for gid in group_ids:
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM agents WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def summarize(client, token, uid, agent_id, group_id=None, title="DM Session"):
    payload = {"session": {"title": title, "prompts": ["p1"], "verses": ["Gen 1:1"]}}
    if group_id is not None:
        payload["group_id"] = group_id
    return client.post(f"/agent/{uid}/{agent_id}/summarize", json=payload, headers=cookie_header(token))


def test_friend_dm_composite_group_id_saves_private_note_no_500(client):
    print("\n=== 1. CORE FIX: friend-DM composite group_id ('<uidA>|<uidB>') no "
          "longer 500s -- resolves to group_id=NULL, saves as a private note ===")
    uid_a, token_a = signup(client, f"summdm_a_{uuid.uuid4().hex[:8]}")
    uid_b, _ = signup(client, f"summdm_b_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid_a)
        # Same synthetic composite shape ChatThreadViewModel.roomKey produces
        # for a friend DM -- NOT a real groups._id.
        dm_room_key = f"{uid_a}|{uid_b}"

        r = summarize(client, token_a, uid_a, agent_id, group_id=dm_room_key, title="DM Bible Chat")
        check("friend-DM summarize returns 201, not a 500 InvalidTextRepresentation crash",
              r.status_code == 201, f"{r.status_code} {r.text}")
        check("response includes a note_id", r.status_code == 201 and "note_id" in r.json(), str(r.text))

        note = latest_note_for_user(uid_a)
        check("a note was actually persisted", note is not None, str(note))
        check("the note's group_id is NULL (private note), not the unparseable composite key",
              note is not None and note["group_id"] is None, str(note))
        check("the note title reflects the session title",
              note is not None and note["title"] == "Session Summary — DM Bible Chat", str(note))
    finally:
        cleanup(uid_a, uid_b)


def test_real_group_summarize_still_works(client):
    print("\n=== 2. Regression: a real-group session summarize still saves "
          "the note WITH its real group_id (no regression to the legit case) ===")
    uid_owner, token_owner = signup(client, f"summgrp_owner_{uuid.uuid4().hex[:8]}")
    uid_member, _ = signup(client, f"summgrp_member_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, token_owner, uid_owner, [uid_member])
        agent_id = make_agent(uid_owner)

        r = summarize(client, token_owner, uid_owner, agent_id, group_id=gid, title="Group Study")
        check("real-group summarize returns 201", r.status_code == 201, f"{r.status_code} {r.text}")

        note = latest_note_for_user(uid_owner)
        check("the note carries the real group's group_id, unchanged",
              note is not None and note["group_id"] == gid, str(note))
    finally:
        cleanup(uid_owner, uid_member, group_ids=[gid] if gid else [])


def test_summarize_rejects_non_member_group(client):
    print("\n=== 3. A real group_id the caller is NOT a member of is REJECTED "
          "(403) via _require_group_membership, not silently passed through, "
          "and no note is persisted for the rejected attempt ===")
    uid_owner, token_owner = signup(client, f"summrej_owner_{uuid.uuid4().hex[:8]}")
    uid_outsider, token_outsider = signup(client, f"summrej_outsider_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, token_owner, uid_owner, [])
        agent_id = make_agent(uid_outsider)

        before = note_count(uid_outsider)
        r = summarize(client, token_outsider, uid_outsider, agent_id, group_id=gid, title="Sneaky")
        check("summarize with a non-member group_id is rejected (403)",
              r.status_code == 403, f"{r.status_code} {r.text}")
        check("no note was persisted for the rejected attempt",
              note_count(uid_outsider) == before, str(note_count(uid_outsider)))
    finally:
        cleanup(uid_owner, uid_outsider, group_ids=[gid] if gid else [])


def test_summarize_omitted_group_id_still_works(client):
    print("\n=== 4. Regression: omitting group_id entirely still works exactly "
          "as before this fix (private, group_id NULL) ===")
    uid, token = signup(client, f"summnogrp_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        r = summarize(client, token, uid, agent_id, group_id=None, title="Solo Study")
        check("summarize with group_id omitted still returns 201",
              r.status_code == 201, f"{r.status_code} {r.text}")

        note = latest_note_for_user(uid)
        check("the resulting note has no group_id", note is not None and note["group_id"] is None, str(note))
    finally:
        cleanup(uid)


def main():
    orig_call_api = agent_module.AgentManager._call_api
    agent_module.AgentManager._call_api = lambda self, agent_role, messages: "A generated session summary."
    try:
        with TestClient(main_module.app) as client:
            test_friend_dm_composite_group_id_saves_private_note_no_500(client)
            test_real_group_summarize_still_works(client)
            test_summarize_rejects_non_member_group(client)
            test_summarize_omitted_group_id_still_works(client)
    finally:
        agent_module.AgentManager._call_api = orig_call_api

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
