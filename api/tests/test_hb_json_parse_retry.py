"""Task 20260902-hb-json-parse-retry (backend gate, Lightweight spec — no
separate testing gate for this task, so this test is written by the backend
gate itself per pipeline convention).

Covers _generate_and_save_note's bounded retry loop around the JSON-parse-
failure branches (malformed braces / JSONDecodeError / ValueError), added so
an intermittent LLM output-formatting glitch doesn't immediately surface as
a user-visible failure:

  1. A response that fails to parse on early attempts but parses on a later
     attempt (still within the cap) succeeds and saves the note.
  2. A response that never parses is retried exactly _HB_JSON_PARSE_MAX_ATTEMPTS
     times (a fixed, bounded cap — never unbounded), then returns the same
     {"error": "invalid response"} shape as before, with no note saved.
  3. The "no JSON braces at all" branch is retried the same way as the
     JSONDecodeError branch.
  4. The retry-context note ("your previous attempt was invalid JSON") is
     appended to the prompt starting on attempt 2 only — the first attempt's
     prompt is byte-for-byte unchanged.
  5. The connection-error path (_call_api raising) is completely unaffected:
     still exactly one call, on_llm_error still invoked, no retry loop
     applies to it.

Run with: cd api && ../.venv/bin/python tests/test_hb_json_parse_retry.py
"""
import _pathfix  # noqa: F401

import uuid

from db import DBManager
from backend.interactions.agent import AgentManager, _HB_JSON_PARSE_MAX_ATTEMPTS

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
        db.insertion("users", {"_id": uid, "username": f"hbretry_{uid[:8]}",
                               "email": f"hbretry_{uid[:8]}@example.com", "hash_pass": "x"})
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


def _total_notes_for_user(user_id: str) -> int:
    db = DBManager()
    try:
        db.cur.execute("SELECT count(*) FROM notes WHERE user_id = %s", (user_id,))
        return db.cur.fetchone()[0]
    finally:
        db.close()


def cleanup(user_id: str):
    db = DBManager()
    try:
        db.delete("notes", {"user_id": user_id})
        db.delete("users", {"_id": user_id})  # cascades agents/heartbeats/context
    finally:
        db.close()


def main():
    check("_HB_JSON_PARSE_MAX_ATTEMPTS is a small, finite, positive cap",
          isinstance(_HB_JSON_PARSE_MAX_ATTEMPTS, int) and 1 < _HB_JSON_PARSE_MAX_ATTEMPTS <= 5,
          str(_HB_JSON_PARSE_MAX_ATTEMPTS))

    uid = make_user()
    agent_id = make_agent(uid)

    try:
        print("=== 1. Succeeds on a later attempt, within the cap ===")
        hb1 = make_heartbeat(agent_id, uid)

        class EventuallyValidManager(AgentManager):
            calls = 0
            prompts = []

            def _call_api(self, agent_role, messages):
                type(self).calls += 1
                type(self).prompts.append(messages[0]["content"])
                if type(self).calls < _HB_JSON_PARSE_MAX_ATTEMPTS:
                    return "not json at all, oops"
                return '{"__action": "create_note", "title": "T", "text": "Body.", "verses": []}'

        result = EventuallyValidManager(uid)._generate_and_save_note(agent_id, hb1, "Reflect.")
        check("succeeds once a within-cap attempt returns valid JSON",
              result == {"success": "saved note"}, str(result))
        check("took exactly _HB_JSON_PARSE_MAX_ATTEMPTS calls to succeed (last attempt in the cap)",
              EventuallyValidManager.calls == _HB_JSON_PARSE_MAX_ATTEMPTS, str(EventuallyValidManager.calls))
        check("first attempt's prompt has no 'previous attempt' retry note",
              "previous attempt" not in EventuallyValidManager.prompts[0].lower(),
              EventuallyValidManager.prompts[0])
        if len(EventuallyValidManager.prompts) > 1:
            check("second attempt's prompt DOES mention the previous invalid-JSON attempt",
                  "previous attempt" in EventuallyValidManager.prompts[1].lower(),
                  EventuallyValidManager.prompts[1])
            check("retry note is appended, not replacing, the original prompt content",
                  "Reflect." in EventuallyValidManager.prompts[1], EventuallyValidManager.prompts[1])

        print("\n=== 2. Never parses (JSONDecodeError branch) -> bounded retries, then explicit error ===")
        hb2 = make_heartbeat(agent_id, uid)

        class AlwaysInvalidManager(AgentManager):
            calls = 0

            def _call_api(self, agent_role, messages):
                type(self).calls += 1
                return '{"__action": "create_note", "title": broken}'  # has braces, fails json.loads

        notes_before_hb2 = _total_notes_for_user(uid)
        result2 = AlwaysInvalidManager(uid)._generate_and_save_note(agent_id, hb2, "Reflect.")
        check("gives up with the original error shape after exhausting the cap",
              result2 == {"error": "invalid response"}, str(result2))
        check("called _call_api exactly _HB_JSON_PARSE_MAX_ATTEMPTS times -- never more, never fewer",
              AlwaysInvalidManager.calls == _HB_JSON_PARSE_MAX_ATTEMPTS, str(AlwaysInvalidManager.calls))

        # Task 20260906-heartbeat-timeline-instructions removed
        # `agentic_context` (the old heartbeat_id -> note_id link this used
        # to query) -- no direct DB link from a heartbeat to its notes
        # exists anymore, so "no note was linked" is now "the user's total
        # note count didn't grow" (hb1's earlier success already put one
        # note in the table, so this must be a delta, not a bare-zero check).
        check("no note was created for the exhausted-retry heartbeat",
              _total_notes_for_user(uid) == notes_before_hb2, str(_total_notes_for_user(uid)))

        print("\n=== 3. Never has JSON braces at all (malformed-braces branch) -> same bounded retry ===")
        hb3 = make_heartbeat(agent_id, uid)

        class NoBracesManager(AgentManager):
            calls = 0

            def _call_api(self, agent_role, messages):
                type(self).calls += 1
                return "Sorry, I cannot help with that request."

        result3 = NoBracesManager(uid)._generate_and_save_note(agent_id, hb3, "Reflect.")
        check("no-braces case also gives up with the same error shape",
              result3 == {"error": "invalid response"}, str(result3))
        check("no-braces case is also capped at exactly _HB_JSON_PARSE_MAX_ATTEMPTS calls",
              NoBracesManager.calls == _HB_JSON_PARSE_MAX_ATTEMPTS, str(NoBracesManager.calls))

        print("\n=== 4. Connection error path is completely unaffected by the retry loop ===")
        hb4 = make_heartbeat(agent_id, uid)

        class ConnectionErrorManager(AgentManager):
            calls = 0

            def _call_api(self, agent_role, messages):
                type(self).calls += 1
                raise RuntimeError("simulated network failure")

        unwind_calls = []
        result4 = ConnectionErrorManager(uid)._generate_and_save_note(
            agent_id, hb4, "Reflect.", on_llm_error=lambda: unwind_calls.append(1),
        )
        check("connection error still returns the original friendly error message",
              result4 == {"error": "I'm having trouble connecting right now. Please try again in a moment."},
              str(result4))
        check("connection error is NOT retried -- exactly one _call_api call",
              ConnectionErrorManager.calls == 1, str(ConnectionErrorManager.calls))
        check("on_llm_error unwind still fires exactly once, same as before this change",
              unwind_calls == [1], str(unwind_calls))

        print("\n=== 5. Valid JSON but wrong/missing __action is NOT retried (out of scope for this task) ===")
        hb5 = make_heartbeat(agent_id, uid)

        class WrongActionManager(AgentManager):
            calls = 0

            def _call_api(self, agent_role, messages):
                type(self).calls += 1
                return '{"__action": "not_create_note"}'

        result5 = WrongActionManager(uid)._generate_and_save_note(agent_id, hb5, "Reflect.")
        check("wrong-action valid JSON returns 'cannot find action' unchanged",
              result5 == {"error": "cannot find action"}, str(result5))
        check("wrong-action valid JSON is NOT retried -- exactly one call (unrelated failure mode)",
              WrongActionManager.calls == 1, str(WrongActionManager.calls))

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
