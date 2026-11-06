"""Task 20261106-remove-agents-ask-ai: flag ask_ai_default_agent routes + canonical agent.

Covers: ensure_default_agent (create, idempotent, promote-existing selection,
never deletes), /ask-ai/* uniform 404 with flag off, flag-on happy path through
the agent-id-free surface, legacy shim IDOR (guessed ids 404, never substituted),
legacy create/update/delete non-destructive, GET /agent/{user} single agent,
user-wide heartbeat list, WS auth, cross-user IDOR on /ask-ai.

Run (scratch DB only):  cd api && ../.venv/bin/python tests/test_ask_ai_default_agent.py
"""
import _thr_common as T  # noqa: E402  (also fixes sys.path)
from _thr_common import check, sql, make_user, cookie, set_flag  # noqa: E402

import uuid  # noqa: E402

from fastapi.testclient import TestClient  # noqa: E402
from starlette.websockets import WebSocketDisconnect  # noqa: E402

import main as main_module  # noqa: E402
from backend.interactions.agent import AgentManager  # noqa: E402

AgentManager._call_api = lambda self, role, messages: "reply:" + messages[-1]["content"]
AGENTS = []


def make_agent(uid, name="A", enabled=True):
    aid = str(uuid.uuid4())
    sql("INSERT INTO agents (_id, user_id, role, name, enabled) VALUES (%s,%s,'custom role',%s,%s)",
        (aid, uid, name, enabled))
    AGENTS.append(aid)
    return aid


def make_hb(uid, aid, key=None):
    hid = str(uuid.uuid4())
    sql("INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt, idempotency_key) "
        "VALUES (%s,%s,%s,'[]','p',%s)", (hid, aid, uid, key))
    return hid


def ensure(uid):
    m = AgentManager(uid)
    try:
        return m.ensure_default_agent()
    finally:
        m.close()


def ws_code(client, path, hdr):
    try:
        with client.websocket_connect(path, headers=hdr) as ws:
            ws.send_json({"content": "x"})
            ws.receive_json()
    except WebSocketDisconnect as e:
        return e.code
    return None


def main():
    T.require_scratch_db()
    u1, u2, u3, u4 = make_user("aa1"), make_user("aa2"), make_user("aa3"), make_user("aa4")
    h1, h2 = cookie(u1), cookie(u2)

    print("== ensure_default_agent")
    d3 = ensure(u3)
    check("no agents -> deterministic row inserted", d3 == AgentManager.default_agent_id(u3), d3)
    check("inserted row is_default", sql("SELECT is_default FROM agents WHERE _id=%s", (d3,))[0][0] is True)
    check("idempotent", ensure(u3) == d3)
    check("still one row", sql("SELECT COUNT(*) FROM agents WHERE user_id=%s", (u3,))[0][0] == 1)

    x_dis = make_agent(u4, "disabled", enabled=False)
    x_en_late = make_agent(u4, "late")
    x_en_early = make_agent(u4, "early")
    sql("INSERT INTO agent_messages (title, agent_id, user_id, timestamp, content) VALUES ('user',%s,%s,'2026-01-01','a')", (x_dis, u4))
    sql("INSERT INTO agent_messages (title, agent_id, user_id, timestamp, content) VALUES ('user',%s,%s,'2026-02-01','a')", (x_en_late, u4))
    sql("INSERT INTO agent_messages (title, agent_id, user_id, timestamp, content) VALUES ('user',%s,%s,'2026-01-15','a')", (x_en_early, u4))
    c4 = ensure(u4)
    check("promotes enabled-first then earliest message (not the disabled one)", c4 == x_en_early, c4)
    check("exactly one is_default", sql("SELECT COUNT(*) FROM agents WHERE user_id=%s AND is_default", (u4,))[0][0] == 1)
    check("no agent rows deleted", sql("SELECT COUNT(*) FROM agents WHERE user_id=%s", (u4,))[0][0] == 3)
    check("stable on repeat", ensure(u4) == c4)
    try:
        sql("UPDATE agents SET is_default = TRUE WHERE _id=%s", (x_en_late,))
        check("DB forbids a second default per user", False, "second default accepted")
    except Exception:
        check("DB forbids a second default per user (partial unique index)", True)

    a1, a1b, a2 = make_agent(u1, "One"), make_agent(u1, "Two"), make_agent(u2, "Other")
    with TestClient(main_module.app) as client:
        set_flag("ask_ai_default_agent", "off", u1)
        set_flag("ask_ai_default_agent", "off", u2)

        print("== flag off: /ask-ai uniformly 404, legacy unchanged")
        paths = [("get", f"/ask-ai/{u1}/chats"), ("post", f"/ask-ai/{u1}/chats"), ("get", f"/ask-ai/{u1}/messages"),
                 ("delete", f"/ask-ai/{u1}/messages/{uuid.uuid4()}"), ("get", f"/ask-ai/{u1}/heartbeats"),
                 ("delete", f"/ask-ai/{u1}/heartbeat/{uuid.uuid4()}")]
        for m, p in paths:
            r = getattr(client, m)(p, headers=h1)
            check(f"off: {m.upper()} {p.split(u1)[1]} 404", r.status_code == 404, f"{r.status_code} {r.text}")
        for m, p, b in [("post", f"/ask-ai/{u1}/heartbeat", {}), ("post", f"/ask-ai/{u1}/summarize", {}),
                        ("post", f"/ask-ai/{u1}/heartbeats/{uuid.uuid4()}/commit", {})]:
            r = getattr(client, m)(p, headers=h1, json=b)
            check(f"off: {m.upper()} {p.split(u1)[1].split('/')[1]} 404", r.status_code == 404, f"{r.status_code} {r.text}")
        check("off: ws closed 4404", ws_code(client, f"/ask-ai/ws/{u1}", h1) == 4404)
        r = client.get(f"/agent/{u1}", headers=h1)
        check("off: legacy GET /agent returns both agents", r.status_code == 200 and len(r.json()) == 2, r.text)
        check("off: no default materialized by 404s",
              sql("SELECT COUNT(*) FROM agents WHERE user_id=%s AND is_default", (u1,))[0][0] == 0)

        print("== flag on")
        set_flag("ask_ai_default_agent", "on", u1)
        set_flag("ask_ai_default_agent", "on", u2)
        hb_a = make_hb(u1, a1)
        hb_b = make_hb(u1, a1b)
        r = client.get(f"/ask-ai/{u1}/chats", headers=h1)
        check("list chats 200", r.status_code == 200, r.text)
        canon = ensure(u1)
        check("canonical is one of u1's own agents", canon in (a1, a1b), canon)
        r = client.post(f"/ask-ai/{u1}/chats", headers=h1)
        check("create chat 201", r.status_code == 201, r.text)
        chat = r.json()["id"]
        with client.websocket_connect(f"/ask-ai/ws/{u1}?chat_id={chat}", headers=h1) as ws:
            ws.send_json({"content": "hi there"})
            fr = ws.receive_json()
        check("ws reply via canonical agent, chat tagged", fr.get("role") == "assistant" and fr.get("chat_id") == chat, str(fr))
        check("message stored on canonical agent",
              sql("SELECT COUNT(*) FROM agent_messages WHERE user_id=%s AND agent_id=%s AND chat_id=%s", (u1, canon, chat))[0][0] == 2)
        r = client.get(f"/ask-ai/{u1}/messages?chat_id={chat}", headers=h1)
        check("messages endpoint returns the thread", r.status_code == 200 and len(r.json()) == 2, r.text)
        r = client.get(f"/ask-ai/{u1}/heartbeats", headers=h1)
        ids = {x["_id"] for x in r.json()} if r.status_code == 200 else set()
        check("heartbeat list is user-wide (both legacy-agent heartbeats)", ids == {hb_a, hb_b}, r.text)
        r = client.delete(f"/ask-ai/{u1}/heartbeat/{hb_b}", headers=h1)
        check("delete heartbeat 204", r.status_code == 204, r.text)
        check("deleted only that heartbeat", sql("SELECT COUNT(*) FROM agent_heartbeats WHERE user_id=%s", (u1,))[0][0] == 1)

        print("== cross-user + auth")
        for m, p in [("get", f"/ask-ai/{u2}/chats"), ("post", f"/ask-ai/{u2}/chats"), ("get", f"/ask-ai/{u2}/messages"),
                     ("get", f"/ask-ai/{u2}/heartbeats")]:
            r = getattr(client, m)(p, headers=h1)
            check(f"u1 -> u2 {m.upper()} {p.split(u2)[1]} denied", r.status_code in (403, 404), str(r.status_code))
        check("no chat created for u2 by u1", sql("SELECT COUNT(*) FROM agent_chats WHERE user_id=%s", (u2,))[0][0] == 0)
        r = client.get(f"/ask-ai/{u1}/chats")
        check("unauthenticated -> 401/403", r.status_code in (401, 403), str(r.status_code))
        check("ws as other user's id closed 4401", ws_code(client, f"/ask-ai/ws/{u2}", h1) == 4401)
        check("ws no cookie closed 4401", ws_code(client, f"/ask-ai/ws/{u1}", {}) == 4401)
        check("ws foreign chat_id -> 4404", ws_code(client, f"/ask-ai/ws/{u1}?chat_id={uuid.uuid4()}", h1) == 4404)
        r = client.get(f"/ask-ai/{u1}/messages?chat_id=not-a-uuid", headers=h1)
        check("malformed chat_id 404", r.status_code == 404, r.text)

        print("== legacy shims with flag on")
        other = a1 if canon == a1b else a1b
        r = client.get(f"/agent/{u1}/{other}/chats", headers=h1)
        check("owned non-canonical id maps to canonical (200)", r.status_code == 200, r.text)
        r = client.get(f"/agent/{u1}/{a2}/chats", headers=h1)
        check("guessed foreign agent id 404 (no default substitution)", r.status_code == 404, r.text)
        r = client.get(f"/agent/{u1}/{uuid.uuid4()}/messages", headers=h1)
        check("random agent id messages 404", r.status_code == 404, r.text)
        r = client.get(f"/agent/{u1}/{a2}/heartbeats", headers=h1)
        check("foreign agent id heartbeats 404", r.status_code == 404, r.text)
        r = client.delete(f"/agent/{u1}/{a2}/heartbeat/{hb_a}", headers=h1)
        check("foreign agent id heartbeat delete fails closed", r.status_code in (403, 404), str(r.status_code))
        check("heartbeat survived", sql("SELECT COUNT(*) FROM agent_heartbeats WHERE _id=%s", (hb_a,))[0][0] == 1)
        r = client.post(f"/agent/{u1}/{a2}/summarize", headers=h1, json={})
        check("foreign agent id summarize fails closed", r.status_code in (403, 404), str(r.status_code))
        check("legacy ws foreign agent closed 4403", ws_code(client, f"/agent/ws/{a2}/{u1}", h1) == 4403)
        r = client.get(f"/agent/{u1}", headers=h1)
        check("GET /agent/{user} returns only canonical", r.status_code == 200 and (
            r.json().get("_id") == canon or list(r.json().keys()) == [canon] or canon in r.text) and a2 not in r.text, r.text)
        r = client.post(f"/agent/{u1}", headers=h1, json={"name": "new"})
        check("legacy create returns canonical id, creates nothing",
              r.status_code == 201 and r.json()["id"] == canon
              and sql("SELECT COUNT(*) FROM agents WHERE user_id=%s", (u1,))[0][0] == 2, r.text)
        r = client.put(f"/agent/{u1}/{canon}", headers=h1, json={"role": "evil", "name": "x", "enabled": False})
        check("legacy update no-op", r.status_code == 200 and sql(
            "SELECT role, name, enabled FROM agents WHERE _id=%s", (canon,))[0][2] is True
              and sql("SELECT role FROM agents WHERE _id=%s", (canon,))[0][0] == "custom role")
        r = client.put(f"/agent/{u1}/{a2}", headers=h1, json={"role": "evil"})
        check("legacy update foreign agent 404", r.status_code == 404, r.text)
        n_before = [sql("SELECT COUNT(*) FROM %s WHERE user_id='%s'" % (t, u1))[0][0] for t in ("agent_chats", "agent_messages", "agent_heartbeats")]
        r = client.delete(f"/agent/{u1}/{canon}", headers=h1)
        n_after = [sql("SELECT COUNT(*) FROM %s WHERE user_id='%s'" % (t, u1))[0][0] for t in ("agent_chats", "agent_messages", "agent_heartbeats")]
        check("legacy delete is a no-op (agent + dependents intact, no cascade)",
              r.status_code == 204 and n_before == n_after
              and sql("SELECT COUNT(*) FROM agents WHERE _id=%s", (canon,))[0][0] == 1, f"{n_before} {n_after}")

        print("== role comes from prompt file (stored role ignored)")
        m = AgentManager(u1)
        try:
            check("flag on: _agent_role ignores stored role", m._agent_role(canon) == "")
        finally:
            m.close()
        set_flag("ask_ai_default_agent", "off", u1)
        m = AgentManager(u1)
        try:
            check("flag off: stored role used", m._agent_role(canon) == "custom role")
        finally:
            m.close()

    for aid in AGENTS + [d3]:
        sql("DELETE FROM agents WHERE _id=%s", (aid,))
    T.finish(("ask_ai_default_agent",))


if __name__ == "__main__":
    main()
