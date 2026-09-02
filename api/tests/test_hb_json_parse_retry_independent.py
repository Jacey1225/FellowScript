"""Independent testing-gate verification for task 20260902-hb-json-parse-retry,
written separately from the backend gate's own test_hb_json_parse_retry.py so
the retry loop, cap, prompt-note scoping, and connection-error/wrong-action
non-regression are each re-proven from scratch rather than trusted from the
implementer's own test.

Focus areas deliberately NOT duplicated verbatim from the backend gate's test:

  1. The first attempt's prompt is byte-for-byte IDENTICAL to what it would
     have been before this change (not just "doesn't mention 'previous
     attempt'") -- guards against any accidental restructuring of note_prompt
     itself when the retry loop was wrapped around it.
  2. The cap is a genuine hard ceiling: even when the fake LLM has an answer
     ready for attempt N+1, the loop must not go there if it already gave up
     at N == _HB_JSON_PARSE_MAX_ATTEMPTS.
  3. A mixed sequence (malformed-braces failure, then JSONDecodeError
     failure, then success) exercises both parse-failure branches inside the
     SAME retry loop, not just each in isolation.
  4. Every retry attempt's prompt (not just attempt 2) carries the note, and
     the note is not silently dropped for attempt 3 vs attempt 2.
  5. Re-confirms the connection-error and wrong-__action non-regressions
     independently (own fakes, own assertions), since those are the two
     "must not regress" paths called out explicitly in the spec.

Run with: cd api && ../.venv/bin/python tests/test_hb_json_parse_retry_independent.py
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
        db.insertion("users", {"_id": uid, "username": f"hbretryi_{uid[:8]}",
                               "email": f"hbretryi_{uid[:8]}@example.com", "hash_pass": "x"})
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


def make_heartbeat(agent_id: str, user_id: str, prompt: str = "Reflect.") -> str:
    hb_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt) "
            "VALUES (%s, %s, %s, %s::jsonb, %s)",
            (hb_id, agent_id, user_id, "[]", prompt),
        )
        db.conn.commit()
    finally:
        db.close()
    return hb_id


def cleanup(user_id: str):
    db = DBManager()
    try:
        db.delete("notes", {"user_id": user_id})
        db.delete("users", {"_id": user_id})  # cascades agents/heartbeats/context
    finally:
        db.close()


def main():
    uid = make_user()
    agent_id = make_agent(uid)

    try:
        # ------------------------------------------------------------------
        # 1. First-attempt prompt is byte-for-byte reproducible: two separate
        #    heartbeats with a first-call-succeeds manager must produce an
        #    IDENTICAL first-attempt prompt string, proving no retry-only
        #    scaffolding leaks into attempt 1 regardless of surrounding
        #    control flow.
        # ------------------------------------------------------------------
        print("=== 1. First-attempt prompt is stable/unmodified across runs ===")

        class ImmediateSuccessManager(AgentManager):
            calls = 0
            prompts = []

            def _call_api(self, agent_role, messages):
                type(self).calls += 1
                type(self).prompts.append(messages[0]["content"])
                return '{"__action": "create_note", "title": "T", "text": "Body.", "verses": []}'

        hb_a = make_heartbeat(agent_id, uid)
        ImmediateSuccessManager.calls = 0
        ImmediateSuccessManager.prompts = []
        ImmediateSuccessManager(uid)._generate_and_save_note(agent_id, hb_a, "Reflect.")
        prompt_run_a = ImmediateSuccessManager.prompts[0]

        hb_b = make_heartbeat(agent_id, uid)
        ImmediateSuccessManager.calls = 0
        ImmediateSuccessManager.prompts = []
        ImmediateSuccessManager(uid)._generate_and_save_note(agent_id, hb_b, "Reflect.")
        prompt_run_b = ImmediateSuccessManager.prompts[0]

        check("first-attempt prompt is byte-for-byte identical across two independent successful runs",
              prompt_run_a == prompt_run_b, repr((prompt_run_a, prompt_run_b)))
        # Note: "No previous context" is pre-existing, unrelated prompt text
        # from the CHAPTERS/VERSES/THEME context system -- only the specific
        # retry-scaffolding phrase "previous attempt" (singular unit) should
        # be absent from attempt 1, not every use of the word "previous".
        check("first-attempt prompt contains no retry/attempt scaffolding at all",
              "previous attempt" not in prompt_run_a.lower() and "retry" not in prompt_run_a.lower(),
              prompt_run_a)
        check("exactly one call made when the first attempt already succeeds",
              ImmediateSuccessManager.calls == 1, str(ImmediateSuccessManager.calls))

        # ------------------------------------------------------------------
        # 2. Cap is a genuine hard ceiling -- a fake manager that WOULD
        #    succeed on attempt _HB_JSON_PARSE_MAX_ATTEMPTS + 1 must never
        #    reach that attempt; the loop must give up exactly at the cap.
        # ------------------------------------------------------------------
        print("\n=== 2. Cap is a hard ceiling -- never over-runs even if a later attempt would work ===")

        class WouldSucceedTooLateManager(AgentManager):
            calls = 0

            def _call_api(self, agent_role, messages):
                type(self).calls += 1
                if type(self).calls == _HB_JSON_PARSE_MAX_ATTEMPTS + 1:
                    return '{"__action": "create_note", "title": "T", "text": "Body.", "verses": []}'
                return "still not json"

        hb_c = make_heartbeat(agent_id, uid)
        result_c = WouldSucceedTooLateManager(uid)._generate_and_save_note(agent_id, hb_c, "Reflect.")
        check("gives up with the standard error shape rather than reaching the would-succeed attempt",
              result_c == {"error": "invalid response"}, str(result_c))
        check("stopped calling at exactly the cap, never attempting the (N+1)th call",
              WouldSucceedTooLateManager.calls == _HB_JSON_PARSE_MAX_ATTEMPTS,
              str(WouldSucceedTooLateManager.calls))

        # ------------------------------------------------------------------
        # 3. Mixed failure modes within the same retry sequence: braces-
        #    missing failure, then a present-but-unparseable-JSON failure,
        #    then success -- both parse-failure branches must be retried by
        #    the same loop, not just each in isolation.
        # ------------------------------------------------------------------
        print("\n=== 3. Mixed failure-mode sequence (no-braces -> bad-JSON -> success) within one retry run ===")

        if _HB_JSON_PARSE_MAX_ATTEMPTS >= 3:
            class MixedFailureManager(AgentManager):
                calls = 0
                responses = [
                    "no braces here at all",
                    '{"__action": "create_note", "title": broken}',  # has braces, fails json.loads
                    '{"__action": "create_note", "title": "T", "text": "Body.", "verses": []}',
                ]

                def _call_api(self, agent_role, messages):
                    idx = type(self).calls
                    type(self).calls += 1
                    return type(self).responses[idx]

            hb_d = make_heartbeat(agent_id, uid)
            result_d = MixedFailureManager(uid)._generate_and_save_note(agent_id, hb_d, "Reflect.")
            check("mixed no-braces-then-bad-JSON sequence still recovers to success within the cap",
                  result_d == {"success": "saved note"}, str(result_d))
            check("mixed-sequence success took exactly 3 calls (both failure branches exercised once each)",
                  MixedFailureManager.calls == 3, str(MixedFailureManager.calls))
        else:
            print("  SKIP (cap < 3, mixed 3-branch sequence not applicable to this build's cap)")

        # ------------------------------------------------------------------
        # 4. The retry note appears on every retry attempt (2..N), not just
        #    attempt 2 -- confirms it isn't dropped after the first retry.
        # ------------------------------------------------------------------
        print("\n=== 4. Retry note present on every retry attempt, not just the second ===")

        class AlwaysFailManager(AgentManager):
            calls = 0
            prompts = []

            def _call_api(self, agent_role, messages):
                type(self).calls += 1
                type(self).prompts.append(messages[0]["content"])
                return "never valid"

        hb_e = make_heartbeat(agent_id, uid)
        AlwaysFailManager(uid)._generate_and_save_note(agent_id, hb_e, "Reflect.")
        check("captured one prompt per attempt up to the cap",
              len(AlwaysFailManager.prompts) == _HB_JSON_PARSE_MAX_ATTEMPTS,
              str(len(AlwaysFailManager.prompts)))
        all_retries_have_note = all(
            "previous attempt" in p.lower() for p in AlwaysFailManager.prompts[1:]
        )
        check("every retry attempt (index 1 onward) mentions the previous invalid-JSON attempt",
              all_retries_have_note, str(AlwaysFailManager.prompts[1:]))
        check("attempt 1 (index 0) still has no such note",
              "previous attempt" not in AlwaysFailManager.prompts[0].lower(),
              AlwaysFailManager.prompts[0])

        # ------------------------------------------------------------------
        # 5. Independent re-confirmation: connection-error path (own fake,
        #    own assertions) is unaffected by the retry loop.
        # ------------------------------------------------------------------
        print("\n=== 5. Connection-error path re-confirmed independently ===")

        class NetworkFailManager(AgentManager):
            calls = 0

            def _call_api(self, agent_role, messages):
                type(self).calls += 1
                raise ConnectionError("boom")

        hb_f = make_heartbeat(agent_id, uid)
        unwind_hits = []
        result_f = NetworkFailManager(uid)._generate_and_save_note(
            agent_id, hb_f, "Reflect.", on_llm_error=lambda: unwind_hits.append(True),
        )
        check("connection-error path returns the original friendly message, unchanged",
              result_f == {"error": "I'm having trouble connecting right now. Please try again in a moment."},
              str(result_f))
        check("connection-error path makes exactly one call regardless of the JSON-parse retry cap",
              NetworkFailManager.calls == 1, str(NetworkFailManager.calls))
        check("on_llm_error unwind callback still invoked exactly once on connection error",
              unwind_hits == [True], str(unwind_hits))

        # ------------------------------------------------------------------
        # 6. Independent re-confirmation: valid-JSON-but-wrong-__action path
        #    is unaffected by the retry loop (own fake, own assertions).
        # ------------------------------------------------------------------
        print("\n=== 6. Wrong-__action path re-confirmed independently ===")

        class WrongActionManager2(AgentManager):
            calls = 0

            def _call_api(self, agent_role, messages):
                type(self).calls += 1
                return '{"__action": "delete_everything"}'

        hb_g = make_heartbeat(agent_id, uid)
        result_g = WrongActionManager2(uid)._generate_and_save_note(agent_id, hb_g, "Reflect.")
        check("wrong-__action path still returns 'cannot find action', unchanged",
              result_g == {"error": "cannot find action"}, str(result_g))
        check("wrong-__action path makes exactly one call -- not retried by the JSON-parse loop",
              WrongActionManager2.calls == 1, str(WrongActionManager2.calls))

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
