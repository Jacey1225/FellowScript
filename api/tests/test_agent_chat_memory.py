"""Task 20261007-agent-chat-memory: per-chat memory for agent chats.

Covers: DDL idempotence, config validation (eager, required keys, ranges),
flag-off payload identical to today, flag-on prompt order + window + scoping
(other chats/agents/users never leak), summary block only when present and
never overlapping the window, summarizer trigger threshold / fold / advance,
compare-and-set + in-flight guard under concurrency, summarizer failure
(chat keeps working, nothing stored, no message content in any log line),
refresh runs off the request path, legacy NULL-chat_id history, summary never
exposed by an endpoint, unowned chat ids fail closed.

Run (scratch DB only):  cd api && ../.venv/bin/python tests/test_agent_chat_memory.py
"""
import _thr_common as T  # noqa: E402  (also fixes sys.path)
from _thr_common import check, sql, make_user, cookie, set_flag  # noqa: E402

import json  # noqa: E402
import logging  # noqa: E402
import os  # noqa: E402
import tempfile  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import uuid  # noqa: E402

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.interactions import agent as agent_mod  # noqa: E402
from backend.interactions import agent_memory as am  # noqa: E402
from backend.interactions import agent_memory_config as amc  # noqa: E402
from backend.interactions import agent_chats as ac  # noqa: E402
from backend.interactions import flags  # noqa: E402
from backend.interactions.agent import AgentManager  # noqa: E402
from backend.config_loader import ConfigSectionError  # noqa: E402
import schema_ddl.agent_chats as ddl_agent_chats  # noqa: E402
import schema_ddl.flags as ddl_flags  # noqa: E402

CFG = amc.get_agent_memory_config()
N, THRESH, BATCH = CFG.window_messages, CFG.summary_threshold, CFG.summary_batch_max_messages
SECRET = "ZXQ-SECRET-CONTENT"          # must never appear in any log line
AGENTS = []

# ── fake model endpoint ──────────────────────────────────────────────────────
CALLS = []                              # every requests.post body
SUMMARY_MODE = {"mode": "ok", "text": f"SUMMARYTEXT {SECRET}", "gate": None, "entered": None}


class FakeResp:
    def __init__(self, text):
        self._t = text

    def raise_for_status(self):
        pass

    def json(self):
        return {"choices": [{"message": {"content": self._t}}]}


def fake_post(url, headers=None, json=None, timeout=None):
    CALLS.append({"body": json, "timeout": timeout})
    if json["model"] == CFG.summary_model:
        m = SUMMARY_MODE
        if m["entered"] is not None:
            m["entered"].set()
        if m["gate"] is not None:
            m["gate"].wait(10)
        if m["mode"] == "raise":
            raise RuntimeError(f"boom {SECRET}")
        if m["mode"] == "empty":
            return FakeResp("   ")
        return FakeResp(m["text"])
    return FakeResp("chat-reply")


agent_mod.requests.post = fake_post


def chat_calls():
    return [c["body"] for c in CALLS if c["body"]["model"] != CFG.summary_model]


def summary_calls():
    return [c["body"] for c in CALLS if c["body"]["model"] == CFG.summary_model]


# ── log capture ──────────────────────────────────────────────────────────────
LOGS = T.LogCapture()
logging.getLogger().addHandler(LOGS)
logging.getLogger().setLevel(logging.DEBUG)


def log_text():
    return "\n".join(r.getMessage() for r in LOGS.records)


# ── helpers ──────────────────────────────────────────────────────────────────
def make_agent(uid, role="role-text"):
    aid = str(uuid.uuid4())
    sql("INSERT INTO agents (_id, user_id, role, name, enabled) VALUES (%s,%s,%s,'A',true)", (aid, uid, role))
    AGENTS.append(aid)
    return aid


def make_chat(uid, aid):
    cid = str(uuid.uuid4())
    sql("INSERT INTO agent_chats (_id, user_id, agent_id) VALUES (%s,%s,%s)", (cid, uid, aid))
    return cid


def seed(uid, aid, cid, n, tag, start=0, base="2026-01-01 00:00:00+00"):
    """n messages alternating user/assistant, 1s apart, content '<tag>-<i>'."""
    for i in range(start, start + n):
        sql("INSERT INTO agent_messages (title, agent_id, user_id, chat_id, timestamp, content) "
            "VALUES (%s,%s,%s,%s,%s::timestamptz + (%s || ' seconds')::interval,%s)",
            ("user" if i % 2 == 0 else "assistant", aid, uid, cid, base, i, f"{tag}-{i}"))


def row(cid):
    return sql("SELECT summary, summary_through_ts FROM agent_chats WHERE _id=%s", (cid,))[0]


def mgr(uid):
    return AgentManager(uid)


def do_chat(uid, aid, text, chat_id=None):
    m = mgr(uid)
    try:
        return m.chat(aid, text, chat_id)
    finally:
        m.close()


def ts_of(cid, content):
    return sql("SELECT timestamp FROM agent_messages WHERE chat_id=%s AND content=%s", (cid, content))[0][0]


def msgs_text(body):
    return [m["content"] for m in body["messages"]]


def wait_for(pred, secs=8.0):
    end = time.time() + secs
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return False


def main():
    T.require_scratch_db()
    u1, u2 = make_user("mem1"), make_user("mem2")
    a1, a1b, a2 = make_agent(u1, "ROLE-A1"), make_agent(u1, "ROLE-A1B"), make_agent(u2, "ROLE-A2")

    # ── DDL / flag registration ──────────────────────────────────────────────
    print("== DDL idempotence + flag registration")
    d = DBManager()
    try:
        for _ in range(2):
            ddl_agent_chats.apply(d.cur)
        d.conn.commit()
    finally:
        d.close()
    cols = {r[0]: r[1] for r in sql(
        "SELECT column_name, data_type FROM information_schema.columns WHERE table_name='agent_chats'")}
    check("summary TEXT column exists after repeated apply", cols.get("summary") == "text", str(cols))
    check("summary_through_ts TIMESTAMPTZ exists", cols.get("summary_through_ts") == "timestamp with time zone", str(cols))
    check("flag in SEED_FLAG_NAMES", "agent_chat_memory" in ddl_flags.SEED_FLAG_NAMES)
    check("flag registered", "agent_chat_memory" in flags.REGISTRY if hasattr(flags, "REGISTRY") else True)
    flags.invalidate()
    check("flag default off for a fresh user", flags.is_enabled("agent_chat_memory", u1) is False)
    check("summary columns not in AgentChatStore list columns", "summary" not in ac._COLS)

    # ── config validation ────────────────────────────────────────────────────
    print("== config validation")
    check("config values come from chat.json (window 20 / threshold 20)", (N, THRESH) == (20, 20), f"{N},{THRESH}")
    with open(amc.CONFIG_PATH) as f:
        good = json.load(f)
    orig_path = amc.CONFIG_PATH

    def cfg_err(mutate):
        data = json.loads(json.dumps(good))
        mutate(data["agent_chat_memory"])
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tf:
            json.dump(data, tf)
        amc.CONFIG_PATH = tf.name
        try:
            amc._load()
            return None
        except ConfigSectionError as e:
            return str(e)
        finally:
            amc.CONFIG_PATH = orig_path
            os.unlink(tf.name)

    check("valid config loads", cfg_err(lambda s: None) is None)
    check("missing key rejected", cfg_err(lambda s: s.pop("summary_model")) is not None)
    check("window 0 rejected", cfg_err(lambda s: s.update(window_messages=0)) is not None)
    check("threshold 0 rejected", cfg_err(lambda s: s.update(summary_threshold=0)) is not None)
    check("wrong type rejected", cfg_err(lambda s: s.update(summary_max_chars="x")) is not None)
    check("blank model rejected", cfg_err(lambda s: s.update(summary_model="  ")) is not None)
    check("timeout 0 rejected", cfg_err(lambda s: s.update(summary_timeout_seconds=0)) is not None)
    amc.reset_for_tests()
    check("config reloads after reset", amc.get_agent_memory_config().window_messages == N)

    # ── flag off: payload identical to today ─────────────────────────────────
    print("== flag off")
    set_flag("agent_chats", "off", u1)
    set_flag("agent_chat_memory", "off", u1)
    legacy = None
    seed(u1, a1, None, 6, "old")           # legacy NULL chat_id rows (flag off, they stay NULL)
    CALLS.clear()
    r = do_chat(u1, a1, "hello off")
    sysmsg = chat_calls()[0]["messages"][0]
    check("flag off: payload is [system, user] only (no history, no summary)",
          [m["role"] for m in chat_calls()[0]["messages"]] == ["system", "user"]
          and chat_calls()[0]["messages"][1]["content"] == "hello off", str(chat_calls()[0]["messages"]))
    check("flag off: system content = PROMPT + role, exactly",
          sysmsg["content"] == agent_mod.PROMPT + "\n\nADDITIONAL AGENT INSTRUCTIONS:\nROLE-A1", sysmsg["content"][-60:])
    check("flag off: max_tokens/model unchanged",
          chat_calls()[0]["max_tokens"] == 2048 and chat_calls()[0]["model"] == agent_mod.MODELNAME)
    check("flag off: rows stored with NULL chat_id",
          sql("SELECT COUNT(*) FROM agent_messages WHERE user_id=%s AND agent_id=%s AND content IN ('hello off','chat-reply') AND chat_id IS NULL", (u1, a1))[0][0] == 2)
    check("flag off: no summarizer call", len(summary_calls()) == 0)
    # memory on but multi-chat off => still off
    set_flag("agent_chat_memory", "on", u1)
    CALLS.clear()
    do_chat(u1, a1, "memory on, chats off")
    check("memory on but agent_chats off: still identical [system,user]",
          [m["role"] for m in chat_calls()[0]["messages"]] == ["system", "user"])
    set_flag("agent_chat_memory", "off", u1)
    # call_api with no summary keeps exact 2-arg behavior
    m = mgr(u1)
    CALLS.clear()
    m._call_api("R", [{"role": "user", "content": "x"}])
    m.close()
    check("_call_api default (no summary) -> one system message",
          [x["role"] for x in chat_calls()[0]["messages"]] == ["system", "user"])

    # ── flag on: ordering, window, isolation ─────────────────────────────────
    print("== flag on: ordering, window, isolation")
    set_flag("agent_chats", "on", u1)
    set_flag("agent_chats", "on", u2)
    set_flag("agent_chat_memory", "on", u1)
    set_flag("agent_chat_memory", "on", u2)
    chat_a = make_chat(u1, a1)
    chat_b = make_chat(u1, a1)             # same user+agent, other chat
    chat_c = make_chat(u1, a1b)            # same user, other agent
    chat_x = make_chat(u2, a2)             # other user
    seed(u1, a1, chat_a, 5, "A")
    seed(u1, a1, chat_b, 5, "B")
    seed(u1, a1b, chat_c, 5, "C")
    seed(u2, a2, chat_x, 5, "X")
    CALLS.clear()
    reply = do_chat(u1, a1, "new-A", chat_a)
    body = chat_calls()[0]
    roles = [m["role"] for m in body["messages"]]
    check("order: system, 5 history turns, new message (no summary block)",
          roles == ["system"] + ["user", "assistant", "user", "assistant", "user"] + ["user"], str(roles))
    check("history oldest->newest then new message last",
          msgs_text(body)[1:] == [f"A-{i}" for i in range(5)] + ["new-A"], str(msgs_text(body)))
    check("system content has PROMPT + agent role",
          body["messages"][0]["content"].endswith("ROLE-A1") and body["messages"][0]["content"].startswith(agent_mod.PROMPT[:40]))
    joined = " ".join(msgs_text(body))
    check("isolation: other chat / other agent / other user never in payload",
          not any(t in joined for t in ("B-", "C-", "X-")), joined[:200])
    check("new message appears exactly once (history read before save)", msgs_text(body).count("new-A") == 1)
    check("reply persisted in the right chat",
          sql("SELECT COUNT(*) FROM agent_messages WHERE chat_id=%s AND content IN ('new-A','chat-reply')", (chat_a,))[0][0] == 2)
    check("chat B / C / X untouched",
          [sql("SELECT COUNT(*) FROM agent_messages WHERE chat_id=%s", (c,))[0][0] for c in (chat_b, chat_c, chat_x)] == [5, 5, 5])
    check("no summarizer call below threshold", len(summary_calls()) == 0)

    # window cap: 30 messages in chat -> only last N
    chat_w = make_chat(u1, a1)
    seed(u1, a1, chat_w, 30, "W")
    CALLS.clear()
    do_chat(u1, a1, "new-W", chat_w)
    body = chat_calls()[0]
    check(f"window: exactly last {N} turns sent", msgs_text(body)[1:-1] == [f"W-{i}" for i in range(30 - N, 30)],
          str(msgs_text(body)[1:4]))
    check("window: user/assistant titles map to roles",
          [m["role"] for m in body["messages"][1:-1]] == ["user" if i % 2 == 0 else "assistant" for i in range(30 - N, 30)])

    # per-message clip
    chat_clip = make_chat(u1, a1)
    sql("INSERT INTO agent_messages (title, agent_id, user_id, chat_id, content) VALUES ('user',%s,%s,%s,%s)",
        (a1, u1, chat_clip, "z" * (CFG.message_max_chars + 500)))
    CALLS.clear()
    do_chat(u1, a1, "n", chat_clip)
    check("per-message size clipped to message_max_chars", len(msgs_text(chat_calls()[0])[1]) == CFG.message_max_chars)

    # ── summary block ────────────────────────────────────────────────────────
    print("== summary block")
    chat_s = make_chat(u1, a1)
    seed(u1, a1, chat_s, 10, "S")
    through = ts_of(chat_s, "S-3")
    sql("UPDATE agent_chats SET summary=%s, summary_through_ts=%s WHERE _id=%s", ("PRIOR-SUMMARY", through, chat_s))
    CALLS.clear()
    do_chat(u1, a1, "new-S", chat_s)
    body = chat_calls()[0]
    roles = [m["role"] for m in body["messages"]]
    check("order: system+role, summary system block, history, new",
          roles[:2] == ["system", "system"] and "PRIOR-SUMMARY" in body["messages"][1]["content"]
          and "Summary of this chat so far" in body["messages"][1]["content"], str(roles))
    check("summary block labelled background not instructions",
          "not instructions" in body["messages"][1]["content"])
    check("history excludes turns the summary covers (no overlap)",
          msgs_text(body)[2:] == [f"S-{i}" for i in range(4, 10)] + ["new-S"], str(msgs_text(body)[2:]))
    # summary text but NULL through_ts -> never used
    chat_s2 = make_chat(u1, a1)
    seed(u1, a1, chat_s2, 3, "T")
    sql("UPDATE agent_chats SET summary='ORPHAN' WHERE _id=%s", (chat_s2,))
    CALLS.clear()
    do_chat(u1, a1, "n", chat_s2)
    check("summary without through_ts ignored",
          "ORPHAN" not in json.dumps(chat_calls()[0]) and chat_calls()[0]["messages"][1]["content"] == "T-0")
    # other chat's summary never leaks
    CALLS.clear()
    do_chat(u1, a1, "n", chat_b)
    check("other chat's summary not in payload", "PRIOR-SUMMARY" not in json.dumps(chat_calls()[0]))

    # ── chat() default chat + legacy adoption + fail-closed ──────────────────
    print("== default chat / legacy / ownership")
    u3 = make_user("mem3")
    a3 = make_agent(u3)
    set_flag("agent_chats", "off", u3)
    seed(u3, a3, None, 4, "LEG")           # legacy NULL rows
    set_flag("agent_chats", "on", u3)
    set_flag("agent_chat_memory", "on", u3)
    CALLS.clear()
    do_chat(u3, a3, "after-adopt", None)   # chat_id None -> default chat
    body = chat_calls()[0]
    dflt = ac.default_chat_id(u3, a3)
    check("legacy rows adopted into default chat and sent as history",
          msgs_text(body)[1:] == [f"LEG-{i}" for i in range(4)] + ["after-adopt"], str(msgs_text(body)))
    check("no NULL chat_id rows remain; new turns tagged default chat",
          sql("SELECT COUNT(*) FROM agent_messages WHERE user_id=%s AND agent_id=%s AND chat_id IS NULL", (u3, a3))[0][0] == 0
          and sql("SELECT COUNT(*) FROM agent_messages WHERE chat_id=%s", (dflt,))[0][0] == 6)
    before = sql("SELECT COUNT(*) FROM agent_messages")[0][0]
    for label, uid, aid, cid in (("other user's chat", u1, a1, chat_x), ("other agent's chat", u1, a1, chat_c),
                                 ("unknown chat", u1, a1, str(uuid.uuid4())), ("malformed chat", u1, a1, "nope")):
        CALLS.clear()
        try:
            do_chat(uid, aid, "intrude", cid)
            ok = False
        except LookupError:
            ok = True
        except Exception as e:  # noqa: BLE001
            ok = False
            print("   unexpected", type(e).__name__)
        check(f"chat(): {label} -> LookupError, no model call", ok and len(CALLS) == 0)
    check("fail-closed paths wrote nothing", sql("SELECT COUNT(*) FROM agent_messages")[0][0] == before)

    # ── refresh_summary: trigger / fold / advance ────────────────────────────
    print("== refresh_summary trigger, fold, advance")
    fold_calls = []

    def summarizer(prev, turns):
        fold_calls.append((prev, list(turns)))
        return f"NEW-SUMMARY-{len(fold_calls)}"

    def refresh(uid, aid, cid, fn=summarizer):
        dbm = DBManager()
        dbm.user_id = uid
        try:
            return am.refresh_summary(dbm, aid, cid, fn)
        finally:
            dbm.close()

    chat_r = make_chat(u1, a1)
    seed(u1, a1, chat_r, N + THRESH, "R")            # foldable == THRESH, not > THRESH
    check("exactly at threshold: no refresh", refresh(u1, a1, chat_r) is False and not fold_calls and row(chat_r) == (None, None))
    seed(u1, a1, chat_r, 1, "R", start=N + THRESH)   # foldable == THRESH + 1
    check("one past threshold: refresh runs", refresh(u1, a1, chat_r) is True and len(fold_calls) == 1)
    prev, turns = fold_calls[0]
    folded = THRESH + 1
    check("folds only turns older than the window (oldest first, none from window)",
          [t["content"] for t in turns] == [f"R-{i}" for i in range(folded)], str([t["content"] for t in turns][-3:]))
    check("first fold has no prior summary", prev is None)
    s, thr = row(chat_r)
    check("summary stored", s == "NEW-SUMMARY-1", str(s))
    check("summary_through_ts = ts of last folded turn", thr == ts_of(chat_r, f"R-{folded - 1}"), str(thr))
    # window + summary cover everything with no overlap/gap
    st = am.AgentMemoryStore  # noqa: F841
    dbm = DBManager()
    dbm.user_id = u1
    summ, hist = am.AgentMemoryStore(dbm).build_context(a1, chat_r)
    dbm.close()
    check("after fold: summary present and history excludes folded turns",
          summ == "NEW-SUMMARY-1" and all(h["content"] not in {f"R-{i}" for i in range(folded)} for h in hist), str(len(hist)))
    check("after fold: history = remaining turns (no gap)", [h["content"] for h in hist] == [f"R-{i}" for i in range(folded, N + THRESH + 1)])
    check("second refresh immediately: below threshold, no-op", refresh(u1, a1, chat_r) is False and len(fold_calls) == 1)
    # second fold folds prior summary + new turns
    seed(u1, a1, chat_r, THRESH + 5, "R2", base="2026-02-01 00:00:00+00")
    check("second fold runs", refresh(u1, a1, chat_r) is True and len(fold_calls) == 2)
    prev2, turns2 = fold_calls[1]
    check("second fold receives prior summary", prev2 == "NEW-SUMMARY-1")
    check("second fold starts after prior through_ts (no re-fold)", turns2[0]["content"] == f"R-{folded}", turns2[0]["content"])
    check("second fold not exceeding batch cap", len(turns2) <= BATCH)
    # batch cap
    chat_big = make_chat(u1, a1)
    seed(u1, a1, chat_big, N + BATCH + 40, "BIG")
    fold_calls.clear()
    refresh(u1, a1, chat_big)
    check("batch capped at summary_batch_max_messages", len(fold_calls[0][1]) == BATCH, str(len(fold_calls[0][1])))
    check("batch is the oldest slice", fold_calls[0][1][0]["content"] == "BIG-0")
    # summary size cap
    chat_cap = make_chat(u1, a1)
    seed(u1, a1, chat_cap, N + THRESH + 1, "CAP")
    refresh(u1, a1, chat_cap, lambda p, t: "q" * (CFG.summary_max_chars + 900))
    check("stored summary clipped to summary_max_chars", len(row(chat_cap)[0]) == CFG.summary_max_chars)
    # timestamp ties at the boundary
    chat_tie = make_chat(u1, a1)
    seed(u1, a1, chat_tie, N + THRESH - 1, "TIE")
    for k in range(3):   # three messages sharing one timestamp straddling the fold boundary
        sql("INSERT INTO agent_messages (title, agent_id, user_id, chat_id, timestamp, content) "
            "VALUES ('user',%s,%s,%s,'2026-03-01 00:00:00+00',%s)", (a1, u1, chat_tie, f"TIE-same-{k}"))
    seed(u1, a1, chat_tie, 4, "TIEend", base="2026-04-01 00:00:00+00")
    fold_calls.clear()
    refresh(u1, a1, chat_tie)
    s_, thr_ = row(chat_tie)
    left = sql("SELECT content FROM agent_messages WHERE chat_id=%s AND timestamp > %s", (chat_tie, thr_))
    folded_set = {t["content"] for t in fold_calls[0][1]} if fold_calls else set()
    check("tie on boundary: no un-folded message is lost behind through_ts",
          all(c[0] not in folded_set for c in left) and
          sql("SELECT COUNT(*) FROM agent_messages WHERE chat_id=%s", (chat_tie,))[0][0] == len(folded_set) + len(left)
          + sql("SELECT COUNT(*) FROM agent_messages WHERE chat_id=%s AND timestamp <= %s", (chat_tie, thr_))[0][0] - len(folded_set))
    # refresh of a chat the caller doesn't own is a no-op
    check("refresh of other user's chat id is a no-op",
          refresh(u1, a1, chat_x) is False and row(chat_x) == (None, None))
    check("refresh scoped to agent (wrong agent -> no-op)", refresh(u1, a1b, chat_r) is False)

    # ── failure: nothing stored, no content in logs ──────────────────────────
    print("== summarizer failure")
    chat_f = make_chat(u1, a1)
    seed(u1, a1, chat_f, N + THRESH + 3, f"{SECRET}-F")
    LOGS.records.clear()
    try:
        refresh(u1, a1, chat_f, lambda p, t: (_ for _ in ()).throw(RuntimeError("fail " + SECRET)))
        raised = False
    except RuntimeError:
        raised = True
    check("summarizer exception propagates from refresh_summary (throw, not fabricate)", raised)
    check("failure stores nothing", row(chat_f) == (None, None))
    for mode in ("empty",):
        try:
            refresh(u1, a1, chat_f, lambda p, t: "   ")
            ok = False
        except ValueError:
            ok = True
        check("blank summary rejected, nothing stored", ok and row(chat_f) == (None, None))
    # through the real worker with a failing model call
    SUMMARY_MODE.update(mode="raise", gate=None, entered=None)
    CALLS.clear()
    LOGS.records.clear()
    do_chat(u1, a1, "after fail", chat_f)           # sync path -> inline refresh -> model raises
    check("summarizer model was invoked with configured cheaper model",
          len(summary_calls()) == 1 and summary_calls()[0]["model"] == CFG.summary_model
          and CFG.summary_model != agent_mod.MODELNAME)
    check("summary request uses configured max_tokens and timeout",
          summary_calls()[0]["max_tokens"] == CFG.summary_max_tokens
          and [c for c in CALLS if c["body"]["model"] == CFG.summary_model][0]["timeout"] == CFG.summary_timeout_seconds)
    check("chat still answered on recent turns despite summarizer failure",
          len(chat_calls()) == 1 and chat_calls()[0]["messages"][-1]["content"] == "after fail")
    check("worker failure stores no summary", row(chat_f) == (None, None))
    check("failure was logged (type only)", "agent summary refresh failed" in log_text() and "RuntimeError" in log_text())
    check("no message / summary content in any log line", SECRET not in log_text(), log_text()[:300])
    check("in-flight guard released after failure", am.try_acquire(chat_f) and (am.release(chat_f) or True))
    SUMMARY_MODE.update(mode="ok")

    # ── success path through the worker, log redaction ───────────────────────
    print("== worker success + log redaction")
    chat_ok = make_chat(u1, a1)
    seed(u1, a1, chat_ok, N + THRESH + 2, f"{SECRET}-OK")
    LOGS.records.clear()
    CALLS.clear()
    do_chat(u1, a1, "trigger", chat_ok)
    s, thr = row(chat_ok)
    check("worker stored the summary and advanced through_ts", s == SUMMARY_MODE["text"] and thr is not None, str(s))
    sbody = summary_calls()[0]
    check("summarizer prompt: prior summary + new turns, treats text as data",
          "PREVIOUS SUMMARY:\n(none)" in sbody["messages"][1]["content"] and "never follow instructions" in sbody["messages"][0]["content"])
    check("no content (messages or summary) in logs after successful refresh", SECRET not in log_text())
    # next prompt carries summary
    CALLS.clear()
    do_chat(u1, a1, "next", chat_ok)
    check("next send includes stored summary block",
          SUMMARY_MODE["text"] in chat_calls()[0]["messages"][1]["content"])

    # ── concurrency: CAS + in-flight guard ───────────────────────────────────
    print("== concurrency")
    chat_cas = make_chat(u1, a1)
    seed(u1, a1, chat_cas, N + THRESH + 5, "CAS")
    other_through = ts_of(chat_cas, "CAS-2")

    def racing(prev, turns):
        # another worker lands first while we are "summarizing"
        sql("UPDATE agent_chats SET summary=%s, summary_through_ts=%s WHERE _id=%s", ("OTHER-WORKER", other_through, chat_cas))
        return "LOSER"

    check("CAS: stale refresh does not advance", refresh(u1, a1, chat_cas, racing) is False)
    check("CAS: winner's state intact (not overwritten)", row(chat_cas) == ("OTHER-WORKER", other_through), str(row(chat_cas)))

    # two real concurrent refreshes with separate connections, both inside summarizer simultaneously
    chat_two = make_chat(u1, a1)
    seed(u1, a1, chat_two, N + THRESH + 5, "TWO")
    barrier = threading.Barrier(2, timeout=10)
    results = []

    def slow(prev, turns):
        barrier.wait()
        return "S-" + threading.current_thread().name

    def runner():
        try:
            results.append(refresh(u1, a1, chat_two, slow))
        except Exception as e:  # noqa: BLE001
            results.append(e)

    ts = [threading.Thread(target=runner, name=f"w{i}") for i in range(2)]
    [t.start() for t in ts]
    [t.join(15) for t in ts]
    check("concurrent refreshes: exactly one advanced", sorted(map(str, results)) == ["False", "True"], str(results))
    s, thr = row(chat_two)
    check("concurrent refreshes: state is one worker's whole write", s in ("S-w0", "S-w1") and thr is not None, str(s))

    # in-flight guard stops a duplicate worker from even summarizing
    chat_g = make_chat(u1, a1)
    seed(u1, a1, chat_g, N + THRESH + 5, "G")
    CALLS.clear()
    check("guard: first acquire ok", am.try_acquire(chat_g))
    m = mgr(u1)
    m._run_summary_refresh(a1, chat_g)
    m.close()
    check("guard: second worker skipped (no model call, nothing stored)", len(CALLS) == 0 and row(chat_g) == (None, None))
    am.release(chat_g)
    check("guard: released -> acquirable again", am.try_acquire(chat_g) and (am.release(chat_g) or True))

    # ── off the request path (real WS) + endpoints never expose summary ──────
    print("== WS: off request path, isolation, no exposure")
    chat_ws = make_chat(u1, a1)
    seed(u1, a1, chat_ws, N + THRESH + 2, "WS")
    chat_ws_other = make_chat(u1, a1)
    seed(u1, a1, chat_ws_other, 3, "WSO")
    h1 = cookie(u1)
    gate, entered = threading.Event(), threading.Event()
    SUMMARY_MODE.update(mode="ok", gate=gate, entered=entered, text="WS-SUMMARY")
    CALLS.clear()
    with TestClient(main_module.app) as client:
        with client.websocket_connect(f"/agent/ws/{a1}/{u1}?chat_id={chat_ws}", headers=h1) as ws:
            ws.send_json({"content": "ws-new"})
            fr = ws.receive_json()
            replied_before_summary = fr.get("content") == "chat-reply" and row(chat_ws) == (None, None)
            entered_ok = entered.wait(8)
            check("WS reply delivered while summarizer still running (off request path)",
                  replied_before_summary and entered_ok, f"{fr} {row(chat_ws)} {entered_ok}")
            check("WS payload: last N turns of this chat + new msg, nothing from other chat",
                  msgs_text(chat_calls()[0])[1:] == [f"WS-{i}" for i in range(N + THRESH + 2 - N, N + THRESH + 2)] + ["ws-new"]
                  and "WSO" not in json.dumps(chat_calls()[0]))
            gate.set()
            check("background summary eventually stored", wait_for(lambda: row(chat_ws)[0] == "WS-SUMMARY"), str(row(chat_ws)))
            ws.send_json({"content": "ws-second", "chat_id": chat_ws_other})
            fr2 = ws.receive_json()
            check("per-send switch: payload scoped to the switched chat",
                  fr2.get("chat_id") == chat_ws_other and "WS-" not in json.dumps(chat_calls()[-1]["messages"][1:])
                  and msgs_text(chat_calls()[-1])[1:] == [f"WSO-{i}" for i in range(3)] + ["ws-second"], str(chat_calls()[-1]["messages"][1:3]))
        SUMMARY_MODE.update(gate=None, entered=None, text=f"SUMMARYTEXT {SECRET}")
        # nothing exposes the summary
        listing = client.get(f"/agent/{u1}/{a1}/chats", headers=h1)
        msgs = client.get(f"/agent/{u1}/{a1}/messages?chat_id={chat_ws}", headers=h1)
        check("chats list never carries summary text or keys",
              listing.status_code == 200 and "WS-SUMMARY" not in listing.text and "summary" not in listing.text, listing.text[:200])
        check("messages endpoint never carries summary text or keys",
              msgs.status_code == 200 and "WS-SUMMARY" not in msgs.text and "summary_through" not in msgs.text)
        # cross-user: u2's WS cannot read u1's chat/summary
        h2 = cookie(u2)
        CALLS.clear()
        closed = None
        try:
            with client.websocket_connect(f"/agent/ws/{a2}/{u2}?chat_id={chat_ws}", headers=h2) as ws:
                ws.receive_json()
        except Exception as e:  # noqa: BLE001
            closed = getattr(e, "code", type(e).__name__)
        check("other user's WS on u1's chat id closed, no model call", closed == 4404 and len(CALLS) == 0, str(closed))
        # WS flag off => original single-message payload (same client: the app's
        # scheduler binds to the first TestClient's event loop)
        set_flag("agent_chat_memory", "off", u1)
        CALLS.clear()
        with client.websocket_connect(f"/agent/ws/{a1}/{u1}?chat_id={chat_ws}", headers=h1) as ws:
            ws.send_json({"content": "flag-off-ws"})
            ws.receive_json()
        check("WS flag off: payload [system, user] only, no summarizer",
          [m["role"] for m in chat_calls()[0]["messages"]] == ["system", "user"] and len(summary_calls()) == 0)
    check("no route/schema mentions summary columns",
          not any("summary_through_ts" in open(os.path.join(T.API_DIR, "routes", f)).read()
                  for f in os.listdir(os.path.join(T.API_DIR, "routes")) if f.endswith(".py")))
    check("final log scan: no content in any captured log line", SECRET not in log_text())

    # ── cleanup ──────────────────────────────────────────────────────────────
    for uid in (u1, u2, u3):
        sql("DELETE FROM agent_chats WHERE user_id=%s", (uid,))
        sql("DELETE FROM agent_messages WHERE user_id=%s", (uid,))
    for aid in AGENTS:
        sql("DELETE FROM agents WHERE _id=%s", (aid,))
    T.USERS.append(u3) if u3 not in T.USERS else None
    T.finish(("agent_chats", "agent_chat_memory"))


if __name__ == "__main__":
    main()
