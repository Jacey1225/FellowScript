"""Tests that agentic_context rows are linked to the note they were distilled
from, and that deleting the note cascades the context row away too — so a
deleted note stops showing up in the heartbeat's future "previous context"
prompts.

Run with: cd api && ../.venv/bin/python tests/test_agent_context.py
"""
import _pathfix  # noqa: F401

import uuid

from db import DBManager
from backend.interactions.agent import AgentManager

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def make_user() -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"actx_{uid[:8]}",
                               "email": f"actx_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()
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


def cleanup(user_id: str):
    db = DBManager()
    try:
        # notes.user_id has no ON DELETE CASCADE (by design — see delete_user
        # in main.py), so it must be cleared before the user row itself.
        db.delete("notes", {"user_id": user_id})
        db.delete("users", {"_id": user_id})  # cascades agents/heartbeats/context
    finally:
        db.close()


def main():
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    manager = AgentManager(uid)

    try:
        print("=== 1. note_via_hb returns the created note_id ===")
        note_id = manager.note_via_hb({"title": "Reflection", "text": "A note.", "verses": []})
        check("note_via_hb returns a note id", bool(note_id), str(note_id))

        db = DBManager()
        db.cur.execute("SELECT 1 FROM notes WHERE _id = %s", (note_id,))
        check("note actually exists", db.cur.fetchone() is not None)
        db.close()

        print("\n=== 2. save_context links to that note_id ===")
        manager.save_context(hb_id, "Reflection: A note.", note_id)
        db = DBManager()
        db.cur.execute("SELECT note_id FROM agentic_context WHERE heartbeat_id = %s", (hb_id,))
        row = db.cur.fetchone()
        db.close()
        check("agentic_context row stores the note_id", row is not None and str(row[0]) == note_id, str(row))

        print("\n=== 3. get_context returns the summary before deletion ===")
        ctx_before = manager.get_context(hb_id)
        check("context includes the saved summary", any("A note." in c for c in ctx_before), str(ctx_before))

        print("\n=== 4. deleting the note cascades the context row away ===")
        db = DBManager()
        db.delete("notes", {"_id": note_id})
        db.close()

        db = DBManager()
        db.cur.execute("SELECT 1 FROM agentic_context WHERE note_id = %s", (note_id,))
        check("agentic_context row is gone after note deletion", db.cur.fetchone() is None)
        db.close()

        ctx_after = manager.get_context(hb_id)
        check("get_context no longer returns the deleted note's summary",
              not any("A note." in c for c in ctx_after), str(ctx_after))

        print("\n=== 5. full commit_hb_response flow links context to the note it created ===")
        hb_id2 = make_heartbeat(agent_id, uid)

        class FakeManager(AgentManager):
            def _call_api(self, agent_role, messages):
                return '{"__action": "create_note", "title": "Fake", "text": "Generated content.", "verses": []}'

        fake = FakeManager(uid)
        result = fake.commit_hb_response(agent_id, hb_id2, "Write something.")
        check("commit_hb_response reports success", result == {"success": "saved note"}, str(result))

        db = DBManager()
        db.cur.execute(
            "SELECT n._id FROM notes n JOIN agentic_context ac ON ac.note_id = n._id "
            "WHERE ac.heartbeat_id = %s", (hb_id2,)
        )
        linked = db.cur.fetchone()
        db.close()
        check("commit_hb_response's saved context links to the real created note", linked is not None, str(linked))

    finally:
        cleanup(uid)

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
