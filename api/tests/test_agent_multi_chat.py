"""Task 20260906... 20261006-agent-multi-chat: multiple chats per (user, agent).

Covers: list/create, legacy NULL-row adoption (no data loss), chat-scoped
history + live WS send isolation, IDOR (other user's chat id, other agent's
chat id, unknown/malformed id -> 404/4404, never create/fall back), flag-off
legacy behavior, per-send chat switch revalidation, chat cap.

Run (scratch DB only):  cd api && ../.venv/bin/python tests/test_agent_multi_chat.py
"""
import _thr_common as T  # noqa: E402  (also fixes sys.path)
from _thr_common import check, sql, make_user, cookie, set_flag  # noqa: E402

import uuid  # noqa: E402

from fastapi.testclient import TestClient  # noqa: E402
from starlette.websockets import WebSocketDisconnect  # noqa: E402

import main as main_module  # noqa: E402
from backend.interactions.agent import AgentManager  # noqa: E402
from backend.interactions import agent_chats as ac  # noqa: E402
from backend.interactions.agent_chats_config import get_agent_chats_config  # noqa: E402

AgentManager._call_api = lambda self, role, messages: "reply:" + messages[-1]["content"]
AGENTS = []


def make_agent(uid):
    aid = str(uuid.uuid4())
    sql("INSERT INTO agents (_id, user_id, role, name, enabled) VALUES (%s,%s,'r','A',true)", (aid, uid))
    AGENTS.append(aid)
    return aid


def legacy_msg(uid, aid, title, content, ts):
    sql("INSERT INTO agent_messages (title, agent_id, user_id, timestamp, content) VALUES (%s,%s,%s,%s,%s)",
        (title, aid, uid, ts, content))


def contents(body):
    out = []
    for v in body.values() if isinstance(body, dict) else body:
        out.append(v.get("content") if isinstance(v, dict) else v)
    return out


def ws_send(client, uid, aid, hdr, chat_id, text, query=True):
    url = f"/agent/ws/{aid}/{uid}" + (f"?chat_id={chat_id}" if chat_id and query else "")
    with client.websocket_connect(url, headers=hdr) as ws:
        ws.send_json({"content": text})
        return ws.receive_json()


def ws_closed_code(client, uid, aid, hdr, chat_id):
    try:
        with client.websocket_connect(f"/agent/ws/{aid}/{uid}?chat_id={chat_id}", headers=hdr) as ws:
            ws.receive_json()
    except WebSocketDisconnect as e:
        return e.code
    return None


def main():
    T.require_scratch_db()
    u1, u2 = make_user("mc1"), make_user("mc2")
    h1, h2 = cookie(u1), cookie(u2)
    a1, a1b, a2 = make_agent(u1), make_agent(u1), make_agent(u2)
    with TestClient(main_module.app) as client:
        set_flag("agent_chats", "off", u1)

        print("== flag off: legacy behavior unchanged, new routes 404")
        legacy_msg(u1, a1, "user", "old question", "2026-01-01 10:00:00+00")
        legacy_msg(u1, a1, "assistant", "old answer", "2026-01-01 10:00:05+00")
        r = client.get(f"/agent/{u1}/{a1}/chats", headers=h1)
        check("flag off: list chats 404", r.status_code == 404, r.text)
        r = client.post(f"/agent/{u1}/{a1}/chats", headers=h1)
        check("flag off: create chat 404", r.status_code == 404, r.text)
        r = client.get(f"/agent/{u1}/{a1}/messages", headers=h1)
        check("flag off: legacy messages 200 with legacy rows", r.status_code == 200 and len(r.json()) == 2, r.text)
        r = client.get(f"/agent/{u1}/{a1}/messages?chat_id={uuid.uuid4()}", headers=h1)
        check("flag off: supplied chat_id refused (404, not dropped)", r.status_code == 404, r.text)
        check("flag off: ws with chat_id closed 4404",
              ws_closed_code(client, u1, a1, h1, uuid.uuid4()) == 4404)
        reply = ws_send(client, u1, a1, h1, None, "legacy ws")
        check("flag off: ws send works, reply", reply.get("role") == "assistant", str(reply))
        check("flag off: legacy ws row stored with NULL chat_id",
              sql("SELECT COUNT(*) FROM agent_messages WHERE user_id=%s AND agent_id=%s AND chat_id IS NULL", (u1, a1))[0][0] == 4)
        check("flag off: no agent_chats rows created",
              sql("SELECT COUNT(*) FROM agent_chats WHERE user_id=%s", (u1,))[0][0] == 0)

        print("== flag on: legacy rows become the default chat, no data loss")
        set_flag("agent_chats", "on", u1)
        set_flag("agent_chats", "on", u2)
        r = client.get(f"/agent/{u1}/{a1}/chats", headers=h1)
        check("list chats 200", r.status_code == 200, r.text)
        chats = r.json()["chats"]
        check("exactly one default chat materialized", len(chats) == 1, str(chats))
        default = chats[0]["id"]
        check("default chat id deterministic", default == ac.default_chat_id(u1, a1), default)
        check("default chat auto-titled from first user msg", chats[0]["title"] == "old question", chats[0]["title"])
        check("legacy rows adopted (none NULL, 4 rows in default)",
              sql("SELECT COUNT(*) FROM agent_messages WHERE user_id=%s AND agent_id=%s AND chat_id=%s", (u1, a1, default))[0][0] == 4
              and sql("SELECT COUNT(*) FROM agent_messages WHERE user_id=%s AND agent_id=%s AND chat_id IS NULL", (u1, a1))[0][0] == 0)
        r2 = client.get(f"/agent/{u1}/{a1}/chats", headers=h1)
        check("list idempotent (still one chat)", len(r2.json()["chats"]) == 1)
        r = client.get(f"/agent/{u1}/{a1}/messages", headers=h1)
        check("messages without chat_id -> default chat history (4 msgs)", r.status_code == 200 and len(r.json()) == 4, r.text)

        print("== create + isolation")
        r = client.post(f"/agent/{u1}/{a1}/chats", headers=h1)
        check("create -> 201", r.status_code == 201, r.text)
        new = r.json()["id"]
        check("new chat distinct and empty title", new != default and r.json()["title"] == "", r.text)
        r = client.get(f"/agent/{u1}/{a1}/messages?chat_id={new}", headers=h1)
        check("new chat starts empty", r.status_code == 200 and len(r.json()) == 0, r.text)
        reply = ws_send(client, u1, a1, h1, new, "hello new chat")
        check("reply frame carries chat_id of new chat", reply.get("chat_id") == new and reply["content"] == "reply:hello new chat", str(reply))
        r = client.get(f"/agent/{u1}/{a1}/messages?chat_id={new}", headers=h1)
        check("new chat has user+assistant msgs", len(r.json()) == 2, r.text)
        r = client.get(f"/agent/{u1}/{a1}/messages?chat_id={default}", headers=h1)
        check("default chat unchanged by send to new chat (still 4, no leak)",
              len(r.json()) == 4 and not any("hello new chat" in (c or "") for c in contents(r.json())), r.text)
        reply = ws_send(client, u1, a1, h1, default, "back in default")
        check("send to default tagged with default id", reply.get("chat_id") == default, str(reply))
        r = client.get(f"/agent/{u1}/{a1}/messages?chat_id={new}", headers=h1)
        check("new chat did not get default's message", len(r.json()) == 2)
        chats = client.get(f"/agent/{u1}/{a1}/chats", headers=h1).json()["chats"]
        check("list ordered most recent first (default bumped above new)", chats[0]["id"] == default and chats[1]["id"] == new, str([c["id"] for c in chats]))
        check("new chat auto-titled on first message", chats[1]["title"] == "hello new chat", chats[1]["title"])
        check("chats scoped per agent (other agent has own default only)",
              len(client.get(f"/agent/{u1}/{a1b}/chats", headers=h1).json()["chats"]) == 1)

        print("== per-send chat switch + revalidation")
        with client.websocket_connect(f"/agent/ws/{a1}/{u1}?chat_id={default}", headers=h1) as ws:
            ws.send_json({"content": "switch", "chat_id": new})
            fr = ws.receive_json()
            check("per-send switch routes to other owned chat", fr.get("chat_id") == new, str(fr))
            ws.send_json({"content": "evil", "chat_id": str(uuid.uuid4())})
            fr = ws.receive_json()
            check("per-send unknown chat -> error frame, nothing stored",
                  fr.get("role") == "error" and sql("SELECT COUNT(*) FROM agent_messages WHERE content='evil'")[0][0] == 0, str(fr))

        print("== IDOR")
        u2chat = client.post(f"/agent/{u2}/{a2}/chats", headers=h2).json()["id"]
        check("u2 created own chat", bool(u2chat))
        r = client.get(f"/agent/{u1}/{a1}/messages?chat_id={u2chat}", headers=h1)
        check("u1 reading u2's chat id via own path -> 404", r.status_code == 404, r.text)
        r = client.get(f"/agent/{u2}/{a2}/chats", headers=h1)
        check("u1 listing u2's chats -> 403/404", r.status_code in (403, 404), str(r.status_code))
        r = client.post(f"/agent/{u2}/{a2}/chats", headers=h1)
        check("u1 creating chat for u2 -> 403/404", r.status_code in (403, 404), str(r.status_code))
        r = client.get(f"/agent/{u2}/{a2}/messages?chat_id={u2chat}", headers=h1)
        check("u1 reading u2 messages path -> 403/404", r.status_code in (403, 404), str(r.status_code))
        r = client.get(f"/agent/{u1}/{a2}/chats", headers=h1)
        check("u1 listing chats of u2's agent (own user_id) -> 404", r.status_code == 404, str(r.status_code))
        r = client.post(f"/agent/{u1}/{a2}/chats", headers=h1)
        check("u1 creating chat on u2's agent -> 404", r.status_code == 404, str(r.status_code))
        check("no chat created on foreign agent by u1",
              sql("SELECT COUNT(*) FROM agent_chats WHERE user_id=%s AND agent_id=%s", (u1, a2))[0][0] == 0)
        r = client.get(f"/agent/{u1}/{a1b}/messages?chat_id={default}", headers=h1)
        check("own chat id on a different own agent -> 404", r.status_code == 404, r.text)
        r = client.get(f"/agent/{u1}/{a1}/messages?chat_id=not-a-uuid", headers=h1)
        check("malformed chat id -> 404", r.status_code == 404, r.text)
        r = client.get(f"/agent/{u1}/{a1}/messages?chat_id={uuid.uuid4()}", headers=h1)
        check("unknown chat id -> 404 (no fallback)", r.status_code == 404, r.text)
        check("ws other user's chat -> 4404", ws_closed_code(client, u1, a1, h1, u2chat) == 4404)
        check("ws malformed chat -> 4404", ws_closed_code(client, u1, a1, h1, "zzz") == 4404)
        check("ws foreign agent -> 4403", ws_closed_code(client, u1, a2, h1, new) == 4403)
        before = sql("SELECT COUNT(*) FROM agent_messages WHERE chat_id=%s", (u2chat,))[0][0]
        try:
            ws_send(client, u1, a1, h1, u2chat, "intrude")
        except Exception:
            pass
        check("nothing written into u2's chat",
              sql("SELECT COUNT(*) FROM agent_messages WHERE chat_id=%s", (u2chat,))[0][0] == before == 0)
        r = client.get(f"/agent/{u1}/{a1}/chats")
        check("unauthenticated list -> 401/403", r.status_code in (401, 403), str(r.status_code))

        print("== cap")
        cap = get_agent_chats_config().max_chats_per_agent
        sql("INSERT INTO agent_chats (user_id, agent_id) SELECT %s, %s FROM generate_series(1, %s)",
            (u1, a1b, cap - 1))
        # a1b has default (1 after earlier list) + cap-1 = cap
        r = client.post(f"/agent/{u1}/{a1b}/chats", headers=h1)
        check("create at cap -> 409 chat_limit", r.status_code == 409 and "chat_limit" in r.text, r.text)

    for aid in AGENTS:
        sql("DELETE FROM agents WHERE _id=%s", (aid,))
    T.finish(("agent_chats",))


if __name__ == "__main__":
    main()
