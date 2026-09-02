"""Tests that agentic_context rows are linked to the note they were distilled
from, and that deleting the note cascades the context row away too — so a
deleted note stops showing up in the heartbeat's future "previous context"
prompts.

Updated for task 20260902-heartbeat-context-restructure (testing step 4):
`save_context` dropped its old `context_text` middle argument (it's now a
pure heartbeat_id -> note_id link, 2 positional args) and `get_context` no
longer returns a flat list of free-text summary strings -- it returns a
``{"chapters": [...], "verses": [...], "theme": [...]}`` dict built live from
notes + note_verses + notes.theme, joined through that link. Sections 2-4
below are updated to match; section 5 (aggregation across multiple notes)
and 6 (dedup prompt wiring) are new, added by this task.

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

        print("\n=== 2. save_context links to that note_id (2-arg signature) ===")
        manager.save_context(hb_id, note_id)
        db = DBManager()
        db.cur.execute("SELECT note_id FROM agentic_context WHERE heartbeat_id = %s", (hb_id,))
        row = db.cur.fetchone()
        db.close()
        check("agentic_context row stores the note_id", row is not None and str(row[0]) == note_id, str(row))

        print("\n=== 3. get_context returns a CHAPTERS/VERSES/THEME dict, not a flat list ===")
        ctx_before = manager.get_context(hb_id)
        check("get_context returns exactly the three expected keys",
              set(ctx_before.keys()) == {"chapters", "verses", "theme"}, str(ctx_before))
        check("all three values are lists",
              all(isinstance(v, list) for v in ctx_before.values()), str(ctx_before))
        check("the note created in step 1 has no verses, so chapters/verses are empty",
              ctx_before["chapters"] == [] and ctx_before["verses"] == [], str(ctx_before))
        check("the note created in step 1 had no theme, so theme is empty",
              ctx_before["theme"] == [], str(ctx_before))

        print("\n=== 4. deleting the note cascades the context row away ===")
        db = DBManager()
        db.delete("notes", {"_id": note_id})
        db.close()

        db = DBManager()
        db.cur.execute("SELECT 1 FROM agentic_context WHERE note_id = %s", (note_id,))
        check("agentic_context row is gone after note deletion", db.cur.fetchone() is None)
        db.close()

        ctx_after = manager.get_context(hb_id)
        check("get_context returns all-empty categories once the linked note is gone",
              ctx_after == {"chapters": [], "verses": [], "theme": []}, str(ctx_after))

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

        print("\n=== 6. aggregation across multiple past notes for the same heartbeat ===")
        hb_id3 = make_heartbeat(agent_id, uid)

        note_a = manager.note_via_hb({
            "title": "Note A", "text": "First.", "theme": "perseverance",
            "verses": [["Romans", 8, 28], ["Romans", 8, 31]],
        })
        manager.save_context(hb_id3, note_a)
        note_b = manager.note_via_hb({
            "title": "Note B", "text": "Second.", "theme": "grace",
            # Same (book, chapter) as note_a's verses -- CHAPTERS must
            # dedupe this to a single "Romans 8" entry, while VERSES keeps
            # every distinct book/chapter/verse triple (this one is a new
            # verse within that already-seen chapter).
            "verses": [["Romans", 8, 1]],
        })
        manager.save_context(hb_id3, note_b)
        note_c = manager.note_via_hb({
            "title": "Note C", "text": "Third.", "theme": "perseverance",
            # Repeats note_a's exact verse -- VERSES is NOT deduplicated
            # (per get_context's docstring), so "Romans 8:28" should appear
            # twice; THEME dedupes by note, not by text, so "perseverance"
            # legitimately appears twice too (once per note that used it).
            "verses": [["Romans", 8, 28]],
        })
        manager.save_context(hb_id3, note_c)

        agg = manager.get_context(hb_id3)
        check("CHAPTERS is deduplicated to the two distinct (book, chapter) pairs seen",
              sorted(agg["chapters"]) == ["Romans 8"], str(agg))
        check("VERSES contains all four note_verses rows, NOT deduplicated",
              sorted(agg["verses"]) == sorted(
                  ["Romans 8:28", "Romans 8:31", "Romans 8:1", "Romans 8:28"]
              ), str(agg))
        check("THEME lists one entry per note (deduped by note, not by text) "
              "in creation order: perseverance, grace, perseverance",
              agg["theme"] == ["perseverance", "grace", "perseverance"], str(agg))

        print("\n=== 7. prompt no-duplication wiring (_generate_and_save_note) ===")

        class CapturingManager(AgentManager):
            """Captures the exact user-content prompt _generate_and_save_note
            builds, instead of actually calling the LLM, so the test can
            assert on the CHAPTERS/VERSES/THEME record and the STRICT RULE
            wording it feeds the model."""
            captured_prompt = None

            def _call_api(self, agent_role, messages):
                self.captured_prompt = messages[0]["content"]
                return '{"__action": "create_note", "title": "T", "text": "Body.", "theme": "x", "verses": []}'

        hb_id4 = make_heartbeat(agent_id, uid)
        capturing = CapturingManager(uid)
        result_no_ctx = capturing._generate_and_save_note(agent_id, hb_id4, "Reflect.")
        check("first fire (no prior context) reports success",
              result_no_ctx == {"success": "saved note"}, str(result_no_ctx))
        check("first fire's prompt states there is no previous context",
              "No previous context" in capturing.captured_prompt, capturing.captured_prompt)
        check("first fire's prompt has no STRICT RULE (nothing to avoid duplicating yet)",
              "STRICT RULE" not in capturing.captured_prompt, capturing.captured_prompt)

        capturing2 = CapturingManager(uid)
        result_with_ctx = capturing2._generate_and_save_note(agent_id, hb_id4, "Reflect again.")
        check("second fire (now has prior context from fire 1) reports success",
              result_with_ctx == {"success": "saved note"}, str(result_with_ctx))
        check("second fire's prompt includes the explicit hard no-duplication rule",
              "STRICT RULE" in capturing2.captured_prompt and "NEVER duplicate" in capturing2.captured_prompt,
              capturing2.captured_prompt)
        check("second fire's prompt surfaces the prior note's theme under THEMES already used",
              "THEMES already used: x" in capturing2.captured_prompt, capturing2.captured_prompt)

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
