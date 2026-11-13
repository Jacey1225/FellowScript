"""Task 20261112-verse-ask-ai: end-to-end WS path for per-verse Ask AI (verse_context).

Covers: reply is a single ephemeral frame, verse reference + text reach the model call
(same _call_api path, no second AI path), nothing persisted (no agent_messages, no chats),
flag off fails closed (error frame, model never called), invalid/over-limit context is a
visible error frame and never reaches the model, normal frames without verse_context are
unchanged (regression guard), auth unchanged (other user's id closed 4401).

Run (scratch DB only):  cd api && ../.venv/bin/python tests/test_verse_ask_ws.py
"""
import _thr_common as T  # noqa: E402  (also fixes sys.path)
from _thr_common import check, sql, make_user, cookie, set_flag  # noqa: E402

from fastapi.testclient import TestClient  # noqa: E402
from starlette.websockets import WebSocketDisconnect  # noqa: E402

import main as main_module  # noqa: E402
from backend.interactions.agent import AgentManager  # noqa: E402

CALLS = []


def fake_call(self, role, messages):
    CALLS.append(messages)
    return "stub-answer"


AgentManager._call_api = fake_call

VERSE = {"reference": "John 3:16", "translation": "WEB", "text": "For God so loved the world"}


def ask(client, uid, hdr, frame):
    with client.websocket_connect(f"/ask-ai/ws/{uid}", headers=hdr) as ws:
        ws.send_json(frame)
        return ws.receive_json()


def main():
    T.require_scratch_db()
    u1, u2 = make_user("va1"), make_user("va2")
    h1 = cookie(u1)
    with TestClient(main_module.app) as client:
        set_flag("ask_ai_default_agent", "on", u1)
        set_flag("ask_ai_default_agent", "on", u2)

        print("== happy path")
        # Connecting materialises the user's canonical agent/default chat (existing behaviour);
        # warm up first so the baseline below isolates what the verse ask itself does.
        with client.websocket_connect(f"/ask-ai/ws/{u1}", headers=h1):
            pass
        before = sql("SELECT COUNT(*) FROM agent_messages WHERE user_id=%s", (u1,))[0][0]
        chats_before = sql("SELECT COUNT(*) FROM agent_chats WHERE user_id=%s", (u1,))[0][0]
        fr = ask(client, u1, h1, {"content": "What does loved mean here?", "verse_context": VERSE})
        check("assistant frame", fr.get("role") == "assistant" and fr.get("content") == "stub-answer", str(fr))
        check("frame is ephemeral with empty chat_id", fr.get("ephemeral") is True and fr.get("chat_id") == "", str(fr))
        sent = CALLS[-1][-1]["content"] if CALLS else ""
        check("model got reference + verse text + question",
              "John 3:16" in sent and "For God so loved the world" in sent and "What does loved mean here?" in sent, sent)
        check("exactly one model call", len(CALLS) == 1, str(len(CALLS)))
        check("nothing persisted to agent_messages",
              sql("SELECT COUNT(*) FROM agent_messages WHERE user_id=%s", (u1,))[0][0] == before)
        check("no new chat created by the verse ask",
              sql("SELECT COUNT(*) FROM agent_chats WHERE user_id=%s", (u1,))[0][0] == chats_before)

        print("== invalid context never reaches the model")
        n = len(CALLS)
        bad = [
            {"reference": "J 1:1", "text": "x" * 2001},
            {"reference": "", "text": "hi"},
            {"reference": "J 1:1"},
            "not-a-dict",
        ]
        for b in bad:
            fr = ask(client, u1, h1, {"content": "q?", "verse_context": b})
            check(f"bad context -> error frame ({str(b)[:30]})", fr.get("role") == "error" and fr.get("ephemeral") is True, str(fr))
        fr = ask(client, u1, h1, {"content": "q" * 501, "verse_context": VERSE})
        check("over-long question -> error frame", fr.get("role") == "error", str(fr))
        check("model never called for invalid input", len(CALLS) == n, str(len(CALLS) - n))

        print("== model failure -> warm error frame, not a crash")
        def boom(self, role, messages):
            raise RuntimeError("secret-internal-detail")
        AgentManager._call_api = boom
        fr = ask(client, u1, h1, {"content": "q?", "verse_context": VERSE})
        check("api failure -> error frame", fr.get("role") == "error", str(fr))
        check("no internals leaked", "secret-internal-detail" not in str(fr), str(fr))
        AgentManager._call_api = fake_call

        print("== flag off fails closed")
        n = len(CALLS)
        set_flag("ask_ai_default_agent", "off", u1)
        try:
            fr = ask(client, u1, h1, {"content": "q?", "verse_context": VERSE})
            check("flag off: error frame or refusal", fr.get("role") == "error", str(fr))
        except WebSocketDisconnect:
            check("flag off: socket refused (fail closed)", True)
        check("flag off: model never called", len(CALLS) == n, str(len(CALLS) - n))
        set_flag("ask_ai_default_agent", "on", u1)

        print("== regression: normal frame without verse_context unchanged")
        fr = ask(client, u1, h1, {"content": "plain chat"})
        check("plain frame still answered and persisted-style (non-ephemeral)",
              fr.get("role") == "assistant" and not fr.get("ephemeral"), str(fr))

        print("== auth unchanged")
        code = None
        try:
            with client.websocket_connect(f"/ask-ai/ws/{u2}", headers=h1) as ws:
                ws.send_json({"content": "x", "verse_context": VERSE})
                ws.receive_json()
        except WebSocketDisconnect as e:
            code = e.code
        check("other user's id closed 4401", code == 4401, str(code))
        code = None
        try:
            with client.websocket_connect(f"/ask-ai/ws/{u1}", headers={}) as ws:
                ws.send_json({"content": "x", "verse_context": VERSE})
                ws.receive_json()
        except WebSocketDisconnect as e:
            code = e.code
        check("no cookie closed 4401", code == 4401, str(code))

    sql("DELETE FROM agent_messages WHERE user_id IN (%s,%s)", (u1, u2))
    sql("DELETE FROM agent_chats WHERE user_id IN (%s,%s)", (u1, u2))
    sql("DELETE FROM agents WHERE user_id IN (%s,%s)", (u1, u2))
    T.finish(("ask_ai_default_agent",))


if __name__ == "__main__":
    main()
