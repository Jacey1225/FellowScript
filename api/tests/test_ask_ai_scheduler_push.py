"""Task 20261106-remove-agents-ask-ai (testing step 8): scheduled-devotion push
title / payload under flag ask_ai_default_agent.

Drives the real `_fire_due_heartbeats` job (frozen clock, stubbed LLM, capturing
fake send_push) and asserts:
  flag ON : title is the fixed product string "Scheduled Devotion" (never an
            agent name), body is the fixed devotion copy with no prompt/note
            content, `data.agent_id` is the user's CANONICAL agent even when the
            heartbeat still points at a retired agent (old-client deep links),
            `data.heartbeat_id` is the heartbeat; the heartbeat still fires
            (last_fired set, one note) and canonical lookup failure falls back to
            the heartbeat's real agent id (never fabricated).
  flag OFF: title is the agent's name (or "Scheduled Event"), legacy body,
            `data.agent_id` is the heartbeat's own agent id (unchanged).
  no device token: still fires, no push.

Run (scratch DB only):  cd api && ../.venv/bin/python tests/test_ask_ai_scheduler_push.py
"""
import _thr_common as T  # noqa: E402  (also fixes sys.path)
from _thr_common import check, sql, make_user, set_flag  # noqa: E402
import _fake_timeline  # noqa: E402,F401  (stubs timeline + note-template LLM calls)

import asyncio  # noqa: E402
import json  # noqa: E402
import uuid  # noqa: E402
from datetime import datetime, timezone as tzmod  # noqa: E402

from backend.interactions import flags  # noqa: E402
from backend.interactions.agent import AgentManager  # noqa: E402
import backend.interactions.scheduler as scheduler_module  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402

NOW = datetime(2026, 3, 15, 14, 30, tzinfo=tzmod.utc)
PROMPT = "Write a reflection on today."


class _Push:
    def __init__(self):
        self.calls = []

    async def __call__(self, token, title, body, data=None):
        self.calls.append((token, title, body, data))
        return True

    def for_user(self, uid):
        return next((c for c in self.calls if c[0] == f"tok-{uid}"), None)


class _Frozen(datetime):
    @classmethod
    def now(cls, tz=None):
        return NOW.astimezone(tz) if tz is not None else NOW


def stub_call_api(self, role, messages):
    return '{"__action": "create_note", "title": "Reflection", "text": "Generated content.", "verses": []}'


def make_agent(uid, name):
    aid = str(uuid.uuid4())
    sql("INSERT INTO agents (_id, user_id, role, name, enabled) VALUES (%s,%s,'',%s,TRUE)", (aid, uid, name))
    return aid


def make_hb(uid, aid):
    hid = str(uuid.uuid4())
    slots = [None] * 31
    slots[NOW.day - 1] = "14:00"
    sql("INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt) VALUES (%s,%s,%s,%s::jsonb,%s)",
        (hid, aid, uid, json.dumps(slots), PROMPT))
    return hid


def set_token(uid):
    sql("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) "
        "ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token", (uid, f"tok-{uid}"))


def last_fired(hid):
    return sql("SELECT last_fired FROM agent_heartbeats WHERE _id=%s", (hid,))[0][0]


def run_job(push):
    push_module.send_push = push
    scheduler_module.datetime = _Frozen
    try:
        asyncio.run(scheduler_module._fire_due_heartbeats())
    finally:
        scheduler_module.datetime = datetime


def canonical_of(uid):
    m = AgentManager(uid)
    try:
        return m.ensure_default_agent()
    finally:
        m.close()


def main():
    T.require_scratch_db()
    orig_api, orig_push = AgentManager._call_api, push_module.send_push
    AgentManager._call_api = stub_call_api
    users = []
    try:
        # -------- flag ON: heartbeat attached to a NON-canonical, named agent
        u_on = make_user("aipush_on")
        users.append(u_on)
        canon_src = make_agent(u_on, "Canonical Source")
        sql("INSERT INTO agent_messages (title, agent_id, user_id, timestamp, content) "
            "VALUES ('user',%s,%s,'2026-01-01','a')", (canon_src, u_on))
        retired = make_agent(u_on, "Morning Devotion")  # name must never reach the push
        canon = canonical_of(u_on)
        check("setup: canonical differs from the heartbeat's retired agent", canon != retired, canon)
        hb_on = make_hb(u_on, retired)
        set_token(u_on)

        # -------- flag ON, no device token
        u_nt = make_user("aipush_notoken")
        users.append(u_nt)
        a_nt = make_agent(u_nt, "NoTok")
        hb_nt = make_hb(u_nt, a_nt)

        # -------- flag OFF
        u_off = make_user("aipush_off")
        users.append(u_off)
        a_off = make_agent(u_off, "Faith Tracker")
        hb_off = make_hb(u_off, a_off)
        set_token(u_off)

        u_off2 = make_user("aipush_off_unnamed")
        users.append(u_off2)
        a_off2 = make_agent(u_off2, "")
        make_hb(u_off2, a_off2)
        set_token(u_off2)

        # The flag is global per state; "canary" scopes it to exactly the flag-on users.
        flags.set_flag("ask_ai_default_agent", "canary", [u_on, u_nt], actor=u_on)
        flags.invalidate()
        check("setup: flag on for canary users only",
              flags.is_enabled("ask_ai_default_agent", u_on) and not flags.is_enabled("ask_ai_default_agent", u_off))

        push = _Push()
        run_job(push)

        print("== flag on")
        c = push.for_user(u_on)
        check("flag on: push sent", c is not None, str(push.calls))
        if c:
            _, title, body, data = c
            check("flag on: fixed product title, not the agent name", title == "Scheduled Devotion", title)
            check("flag on: title never leaks the retired agent's name", "Morning Devotion" not in title)
            check("flag on: devotion body", body == "Your scheduled devotion is ready. Check your notes.", body)
            check("flag on: body has no prompt/note content", "reflection" not in body.lower() and "generated" not in body.lower(), body)
            check("flag on: data.agent_id is the CANONICAL agent (not the retired one)",
                  data and data.get("agent_id") == canon, str(data))
            check("flag on: data.heartbeat_id correct", data and data.get("heartbeat_id") == hb_on, str(data))
            check("flag on: payload carries only heartbeat_id/agent_id", data and set(data) == {"heartbeat_id", "agent_id"}, str(data))
        check("flag on: heartbeat still fired against its schedule", last_fired(hb_on) is not None)
        check("flag on: exactly one note created",
              sql("SELECT COUNT(*) FROM notes WHERE user_id=%s", (u_on,))[0][0] == 1)

        print("== flag on, no device token")
        check("no token: heartbeat still fires", last_fired(hb_nt) is not None)
        check("no token: no push attempted", push.for_user(u_nt) is None and
              not any(cc[3] and cc[3].get("heartbeat_id") == hb_nt for cc in push.calls))

        print("== flag off (legacy unchanged)")
        c = push.for_user(u_off)
        check("flag off: push sent", c is not None, str(push.calls))
        if c:
            _, title, body, data = c
            check("flag off: title is the agent name", title == "Faith Tracker", title)
            check("flag off: legacy body", body == "Your agent responded to a scheduled event. Check your notes.", body)
            check("flag off: data.agent_id is the heartbeat's own agent",
                  data and data.get("agent_id") == a_off and data.get("heartbeat_id") == hb_off, str(data))
        c = push.for_user(u_off2)
        check("flag off: unnamed agent keeps 'Scheduled Event'", c is not None and c[1] == "Scheduled Event", str(c))

        print("== flag on, canonical lookup failure falls back to heartbeat's real agent id")
        u_f = make_user("aipush_fail")
        users.append(u_f)
        a_f = make_agent(u_f, "FailAgent")
        canonical_of(u_f)
        hb_f = make_hb(u_f, a_f)
        set_token(u_f)
        flags.set_flag("ask_ai_default_agent", "canary", [u_on, u_nt, u_f], actor=u_on)
        flags.invalidate()
        real_ensure = AgentManager.ensure_default_agent
        calls = {"n": 0}

        def flaky(self, *a, **k):
            calls["n"] += 1
            # let the firing path resolve normally; fail only the push-payload lookup,
            # which is the last ensure_default_agent call of the cycle.
            if getattr(flaky, "fail", False):
                raise RuntimeError("boom")
            return real_ensure(self, *a, **k)

        real_commit = AgentManager.commit_hb_response

        def commit_then_arm(self, *a, **k):
            r = real_commit(self, *a, **k)
            flaky.fail = True
            return r

        AgentManager.ensure_default_agent = flaky
        AgentManager.commit_hb_response = commit_then_arm
        push2 = _Push()
        try:
            run_job(push2)
        finally:
            AgentManager.ensure_default_agent = real_ensure
            AgentManager.commit_hb_response = real_commit
        c = push2.for_user(u_f)
        check("lookup failure: push still sent", c is not None, str(push2.calls))
        if c:
            check("lookup failure: agent_id falls back to the heartbeat's real agent (not fabricated)",
                  c[3].get("agent_id") == a_f, str(c[3]))
            check("lookup failure: title still the fixed product string", c[1] == "Scheduled Devotion", c[1])
    finally:
        AgentManager._call_api = orig_api
        push_module.send_push = orig_push
        scheduler_module.datetime = datetime
        for u in users:
            sql("DELETE FROM notes WHERE user_id=%s", (u,))
        T.finish(("ask_ai_default_agent",))


if __name__ == "__main__":
    main()
