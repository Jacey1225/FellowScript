"""Regression coverage for task 20260915-session-summary-note-fixes,
backend step: `summarize_session` (`POST /agent/{user_id}/{agent_id}/summarize`,
api/routes/agent.py).

Two bugs fixed here:

  1. LEAKED ACTION JSON: `AgentManager._call_api` shares agent_prompt.txt's
     system prompt with every other caller, which instructs the model to
     respond with a `create_note` JSON action block whenever it interprets
     the request as "create/save a note" -- and summarize_session's own
     prompt literally says "Format it as a readable study note," which can
     trigger exactly that. Before this fix, that raw JSON block got saved
     verbatim into `notes.text`. Now `detect_leaked_action_json`
     (backend/interactions/agent.py) detects it: if the leaked block carries
     a salvageable "text" field, that becomes the summary; otherwise the
     request fails loudly (502) with no note persisted.

  2. NO-CONTENT SESSIONS: a scheduled call session can legitimately reach
     this endpoint with `summarize: true` but only a title -- empty
     `prompts` AND empty `verses`. Before this fix, the endpoint called the
     LLM anyway and persisted whatever confused non-answer came back as a
     genuine summary. Now it raises `NoSummarizableContentError` (422) up
     front and never calls the LLM at all. Having just ONE of prompts/verses
     is still treated as real content worth summarizing.

Covers, against a REAL Postgres DB and the REAL HTTP routes (matching
test_summarize_session_group_id_friend_dm.py's established convention for
this route family):

  1. A leaked create_note JSON block with a salvageable "text" field is
     unwrapped -- the saved note's text is the salvaged prose, never raw
     JSON.
  2. A leaked action block with nothing salvageable (a create_notification
     block) fails loudly (502) and persists no note.
  3. A title-only session (empty prompts AND empty verses) is rejected
     (422) without ever invoking the LLM, and persists no note.
  4. A session with only verses (no prompts) -- i.e. only ONE of the two --
     still summarizes normally, calling the LLM and saving its (clean)
     response.
  5. Regression: a normal prose response with real content is saved
     unchanged, exactly as before this fix.

Run:  cd api && ../.venv/bin/python tests/test_summarize_session_content_fixes.py
"""
import _pathfix  # noqa: F401,E402

import json
import os
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
# Real S3/GIF config may not be present in every dev environment; this test
# never exercises either subsystem -- it only needs main.app's lifespan
# config validation to pass so the real HTTP routes can boot. Must be set
# before importing _fake_timeline (see test_summarize_session_group_id_friend_dm.py's
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


def latest_note_text(user_id: str) -> str | None:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT text FROM notes WHERE user_id = %s ORDER BY timestamp DESC LIMIT 1",
            (user_id,),
        )
        row = db.cur.fetchone()
        return row[0] if row else None
    finally:
        db.close()


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM agents WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def summarize(client, token, uid, agent_id, session: dict):
    return client.post(
        f"/agent/{uid}/{agent_id}/summarize",
        json={"session": session},
        headers=cookie_header(token),
    )


class _CallCounter:
    """Wraps a stub `_call_api` implementation to also record how many
    times it was invoked, so the no-content test can assert the LLM was
    never actually called.

    Assigned directly as `AgentManager._call_api = counter` (a plain
    callable instance, not a function) -- unlike a lambda/def assigned the
    same way, a non-function callable object is NOT bound as a method via
    the descriptor protocol, so the manager instance ("self" from
    `_call_api`'s own perspective) is never passed here; `__call__` only
    ever receives the (agent_role, messages) args `db._call_api(...)` is
    actually invoked with.
    """
    def __init__(self, impl):
        self.impl = impl
        self.calls = 0

    def __call__(self, agent_role, messages):
        self.calls += 1
        return self.impl(agent_role, messages)


def test_leaked_create_note_json_is_salvaged(client):
    print("\n=== 1. A leaked create_note JSON block with a salvageable "
          "'text' field is unwrapped -- the saved note is the salvaged "
          "prose, never raw JSON ===")
    uid, token = signup(client, f"summsalv_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        leaked = json.dumps({
            "__action": "create_note",
            "title": "Should be ignored",
            "text": "This is the real summary content the model intended to save.",
            "public": False,
            "group_id": "",
            "theme": "n/a",
            "verses": [],
        })
        counter = _CallCounter(lambda role, msgs: leaked)
        agent_module.AgentManager._call_api = counter

        r = summarize(client, token, uid, agent_id, {
            "title": "Salvage Test", "prompts": ["What did we learn?"], "verses": [],
        })
        check("returns 201 (salvaged, not a hard failure)", r.status_code == 201, f"{r.status_code} {r.text}")

        text = latest_note_text(uid)
        check("saved note text is the salvaged prose, not raw JSON",
              text == "This is the real summary content the model intended to save.", str(text))
        check("saved note text does not contain the raw JSON action wrapper",
              text is not None and "__action" not in text, str(text))
    finally:
        cleanup(uid)


def test_leaked_action_with_nothing_salvageable_fails_loudly(client):
    print("\n=== 2. A leaked action block with nothing salvageable (a "
          "create_notification block) fails loudly (502) and persists no "
          "note ===")
    uid, token = signup(client, f"summnosalv_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        leaked = json.dumps({
            "__action": "create_notification",
            "body": "A reminder, not a summary.",
            "scheduled_for": "",
        })
        agent_module.AgentManager._call_api = lambda self, role, msgs: leaked

        before = note_count(uid)
        r = summarize(client, token, uid, agent_id, {
            "title": "No Salvage Test", "prompts": ["p"], "verses": [],
        })
        check("returns 502 (no salvageable content, fails loudly)",
              r.status_code == 502, f"{r.status_code} {r.text}")
        check("no note was persisted for the failed attempt",
              note_count(uid) == before, str(note_count(uid)))
    finally:
        cleanup(uid)


def test_title_only_session_rejected_without_calling_llm(client):
    print("\n=== 3. A title-only session (empty prompts AND empty verses) "
          "is rejected (422) without ever invoking the LLM, and persists "
          "no note ===")
    uid, token = signup(client, f"summempty_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        counter = _CallCounter(lambda role, msgs: "should never be reached")
        agent_module.AgentManager._call_api = counter

        before = note_count(uid)
        r = summarize(client, token, uid, agent_id, {
            "title": "Empty Session", "prompts": [], "verses": [],
        })
        check("returns 422 for a title-only session",
              r.status_code == 422, f"{r.status_code} {r.text}")
        check("the LLM was never called", counter.calls == 0, str(counter.calls))
        check("no note was persisted", note_count(uid) == before, str(note_count(uid)))
    finally:
        cleanup(uid)


def test_verses_only_session_still_summarizes(client):
    print("\n=== 4. A session with only verses (no prompts) -- just ONE of "
          "the two -- still summarizes normally ===")
    uid, token = signup(client, f"summverses_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        counter = _CallCounter(lambda role, msgs: "A real summary of the referenced scripture.")
        agent_module.AgentManager._call_api = counter

        r = summarize(client, token, uid, agent_id, {
            "title": "Verses Only", "prompts": [], "verses": ["John 3:16"],
        })
        check("returns 201 for a verses-only session", r.status_code == 201, f"{r.status_code} {r.text}")
        check("the LLM was called", counter.calls == 1, str(counter.calls))
        check("the real summary was saved",
              latest_note_text(uid) == "A real summary of the referenced scripture.",
              str(latest_note_text(uid)))
    finally:
        cleanup(uid)


def test_clean_prose_response_unchanged(client):
    print("\n=== 5. Regression: a normal prose response with real content "
          "is saved unchanged, exactly as before this fix ===")
    uid, token = signup(client, f"summclean_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        agent_module.AgentManager._call_api = lambda self, role, msgs: "A perfectly ordinary summary."

        r = summarize(client, token, uid, agent_id, {
            "title": "Clean Test", "prompts": ["p1"], "verses": ["Gen 1:1"],
        })
        check("returns 201", r.status_code == 201, f"{r.status_code} {r.text}")
        check("note text is exactly the model's prose, untouched",
              latest_note_text(uid) == "A perfectly ordinary summary.", str(latest_note_text(uid)))
    finally:
        cleanup(uid)


def main():
    orig_call_api = agent_module.AgentManager._call_api
    try:
        with TestClient(main_module.app) as client:
            test_leaked_create_note_json_is_salvaged(client)
            test_leaked_action_with_nothing_salvageable_fails_loudly(client)
            test_title_only_session_rejected_without_calling_llm(client)
            test_verses_only_session_still_summarizes(client)
            test_clean_prose_response_unchanged(client)
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
