"""Tests for task 20261012-notification-settings (testing step 4): the generalized
per-user ``push_preferences`` store, its GET/PUT API, and per-type enforcement in
every toggleable push sender. Essential pushes (join-request approval to the
requester) must stay unaffected.

  A. DDL: module registered, applies twice, columns default TRUE.
  B. API: defaults (9 keys), subset PUT leaves others untouched, persistence,
     legacy {friend_highlight} body, strict bool, unknown/empty/extra keys 422,
     auth + ownership (anon / other user refused, nothing written).
  C. Helper: disabled_user_ids / is_push_enabled semantics, unknown type,
     malformed ids, fail-open on DB error with PII-free log.
  D. Sender enforcement, one block per type: messages (chat + thread), pins,
     reactions, friend_highlight (existing), announcements, session_reminders
     (creation push + reminder job), reminders (guilt job), friend_activity
     (went-active job + nudge), join_requests (owner push; approval push is
     essential and still sent). Each proves opted-out user gets nothing while
     an opted-in peer still does, and that re-enabling restores delivery.

Scratch database only (asserts SHOW port = 55432). APNs is faked everywhere.
Not covered here: the heartbeat-fired push (scheduler L517, "reminders") needs a
live LLM call to reach the check; its helper is covered in C and the same
async_is_push_enabled("reminders") is exercised through the guilt job.

Run: cd api && ../.venv/bin/python tests/test_notification_preferences.py
"""
import _pathfix  # noqa: F401

import os

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ["NUDGE_FEATURE_ENABLED"] = "true"
os.environ["NUDGE_RATE_LIMIT_HOURS"] = "24"
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

import asyncio  # noqa: E402
import logging  # noqa: E402
import uuid  # noqa: E402
from datetime import datetime, timedelta, timezone  # noqa: E402

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from _thr_common import (  # noqa: E402
    FAILED, FakeWS, LogCapture, USERS, GROUPS, check, cookie, finish, make_group, make_msg, make_thread,
    make_user, require_scratch_db, set_flag, sql,
)
import backend.interactions.announcement_notifier as ann_notifier  # noqa: E402
import backend.interactions.join_request_notifier as jrn  # noqa: E402
import backend.interactions.pin_push as pin_push  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402
import backend.interactions.push_preferences as pp  # noqa: E402
import backend.interactions.reaction_highlight_push as rhp  # noqa: E402
import backend.interactions.scheduler as scheduler_module  # noqa: E402
import backend.interactions.thread_send as thread_send  # noqa: E402
import backend.interactions.websockets as ws_module  # noqa: E402
import routes.community as community_module  # noqa: E402
from backend.interactions.activity import INACTIVITY_THRESHOLD  # noqa: E402
from backend.interactions.websockets import ConnectionManager  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from db import DBManager  # noqa: E402

TYPES = ["messages", "pins", "reactions", "friend_highlight", "announcements",
         "session_reminders", "reminders", "friend_activity", "announcement_reminder",
         "prayer_reminder", "check_in_reminder", "deep_question_reminder"]
DEFAULT_OFF = ["prayer_reminder", "check_in_reminder", "deep_question_reminder"]
TIME_KEYS = ["prayer_reminder_time", "check_in_reminder_time", "deep_question_reminder_time"]
# Exactly what GET returns for a user with no row. join_requests is the legacy
# key kept (always true) so the shipped iOS parser, which requires it, still decodes.
DEFAULTS = {**{t: t not in DEFAULT_OFF for t in TYPES},
            "prayer_reminder_time": "08:00", "check_in_reminder_time": "18:00",
            "deep_question_reminder_time": "20:00", "join_requests": True}

SENT: list[dict] = []


async def fake_send_push(token, title, body, data=None):
    SENT.append({"token": token, "title": title, "body": body, "data": data})
    return True


def tokens_sent():
    return {s["token"] for s in SENT}


def token_for(uid):
    tok = f"tok-{uid}"
    sql("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) "
        "ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token", (uid, tok))
    return tok


def opt_out(uid, ptype, value=False):
    sql(f"INSERT INTO push_preferences (user_id, {ptype}) VALUES (%s, %s) "
        f"ON CONFLICT (user_id) DO UPDATE SET {ptype} = EXCLUDED.{ptype}", (uid, value))


def befriend(a, b):
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s) ON CONFLICT DO NOTHING",
        (a, b, b, a))


# ------------------------------------------------------------------ A. DDL

def test_ddl():
    print("A. DDL")
    import db as db_module
    import schema_ddl
    check("notification_preferences registered in DDL_MODULES", "notification_preferences" in db_module.DDL_MODULES)
    c = DBManager()
    try:
        schema_ddl.apply_modules(c.cur, ["reaction_highlight_push", "notification_preferences"])
        schema_ddl.apply_modules(c.cur, ["reaction_highlight_push", "notification_preferences"])
        c.conn.commit()
        ok = True
    except Exception as e:  # noqa: BLE001
        c.conn.rollback()
        ok, _ = False, print(e)
    finally:
        c.close()
    check("module applies twice (idempotent)", ok)
    cols = sql("SELECT column_name, column_default, is_nullable FROM information_schema.columns "
               "WHERE table_name='push_preferences'")
    by = {r[0]: r for r in cols}
    check("all 12 type columns exist", all(t in by for t in TYPES), sorted(by))
    check("legacy join_requests column still exists (rows kept, value ignored)", "join_requests" in by)
    check("every default-ON type column defaults TRUE and is NOT NULL",
          all(by[t][1] == "true" and by[t][2] == "NO" for t in TYPES if t not in DEFAULT_OFF),
          [(t, by[t][1:]) for t in TYPES if t in by])
    check("prayer/check-in/deep-question columns default FALSE and are NOT NULL",
          all(by[t][1] == "false" and by[t][2] == "NO" for t in DEFAULT_OFF), [(t, by[t][1:]) for t in DEFAULT_OFF])
    check("time columns exist with the 08:00/18:00/20:00 defaults",
          all(k in by for k in TIME_KEYS) and "08:00" in by["prayer_reminder_time"][1]
          and "18:00" in by["check_in_reminder_time"][1] and "20:00" in by["deep_question_reminder_time"][1],
          [(k, by.get(k)) for k in TIME_KEYS])
    check("per-type *_sent_date dedup columns exist",
          all(f"{t}_sent_date" in by for t in DEFAULT_OFF), sorted(by))
    ann = sql("SELECT column_name FROM information_schema.columns WHERE table_name='group_announcements' "
              "AND column_name='reminder_push_sent_at'")
    check("group_announcements.reminder_push_sent_at exists", len(ann) == 1)
    check("PUSH_TYPES constant matches the expected 12 types", list(pp.PUSH_TYPES) == TYPES, pp.PUSH_TYPES)
    check("DEFAULT_OFF_TYPES is exactly the three reminders", set(pp.DEFAULT_OFF_TYPES) == set(DEFAULT_OFF))


# ------------------------------------------------------------------ B. API

def test_api(client):
    print("B. API")
    a, b = make_user("np_a"), make_user("np_b")
    ck_a, ck_b = cookie(a), cookie(b)
    url = f"/notification/{a}/push-preferences"
    all_on = dict(DEFAULTS)

    r = client.get(url, headers=ck_a)
    check("GET defaults: 200, on-types true, 3 reminders false, times, legacy join_requests (no row)", r.status_code == 200 and r.json() == all_on, r.text)
    check("GET does not create a row", sql("SELECT COUNT(*) FROM push_preferences WHERE user_id=%s", (a,))[0][0] == 0)

    r = client.put(url, json={"pins": False}, headers=ck_a)
    exp = {**all_on, "pins": False}
    check("PUT subset returns full map with only that key changed", r.status_code == 200 and r.json() == exp, r.text)
    check("GET reflects the change", client.get(url, headers=ck_a).json() == exp)

    r = client.put(url, json={"messages": False, "announcements": False}, headers=ck_a)
    exp = {**all_on, "pins": False, "messages": False, "announcements": False}
    check("second PUT keeps earlier opt-out (pins) and adds new ones", r.status_code == 200 and r.json() == exp, r.text)

    r = client.put(url, json={"pins": True}, headers=ck_a)
    exp["pins"] = True
    check("PUT true flips back, others untouched", r.status_code == 200 and r.json() == exp, r.text)

    for t in TYPES:
        r = client.put(url, json={t: False}, headers=ck_a)
        check(f"PUT {t}=false accepted and stored",
              r.status_code == 200 and r.json()[t] is False
              and sql(f"SELECT {t} FROM push_preferences WHERE user_id=%s", (a,))[0][0] is False, r.text)
        client.put(url, json={t: True}, headers=ck_a)
    r = client.put(url, json={t: True for t in TYPES}, headers=ck_a)
    check("PUT all 12 keys at once", r.status_code == 200 and r.json() == {**DEFAULTS, **{t: True for t in TYPES}}, r.text)
    for t in DEFAULT_OFF:
        client.put(url, json={t: False}, headers=ck_a)
    check("reminders back to default off", client.get(url, headers=ck_a).json() == all_on)

    # legacy join_requests: accepted, ignored, always reported true
    r = client.put(url, json={"join_requests": False}, headers=ck_a)
    check("PUT join_requests=false accepted (200) but ignored", r.status_code == 200 and r.json()["join_requests"] is True, r.text)
    check("legacy-only PUT wrote nothing", sql("SELECT join_requests FROM push_preferences WHERE user_id=%s", (a,))[0][0] is True)
    r = client.put(url, json={"join_requests": False, "pins": False}, headers=ck_a)
    check("join_requests mixed with a real key: real key applied, join_requests stays true",
          r.status_code == 200 and r.json()["pins"] is False and r.json()["join_requests"] is True, r.text)
    client.put(url, json={"pins": True}, headers=ck_a)
    check("non-bool join_requests -> 422", client.put(url, json={"join_requests": "no"}, headers=ck_a).status_code == 422)

    # reminder times
    r = client.put(url, json={"prayer_reminder": True, "prayer_reminder_time": "06:45"}, headers=ck_a)
    check("PUT reminder + time stored and returned as HH:MM",
          r.status_code == 200 and r.json()["prayer_reminder"] is True and r.json()["prayer_reminder_time"] == "06:45", r.text)
    check("time-only PUT works", client.put(url, json={"check_in_reminder_time": "23:59"}, headers=ck_a).json()["check_in_reminder_time"] == "23:59")
    check("midnight 00:00 valid", client.put(url, json={"deep_question_reminder_time": "00:00"}, headers=ck_a).json()["deep_question_reminder_time"] == "00:00")
    for bad in ("24:00", "7:30", "12:60", "ab:cd", "08:00:00", "", "8am", 800, None, True, "12:5"):
        r = client.put(url, json={"prayer_reminder_time": bad}, headers=ck_a)
        check(f"bad time {bad!r} -> 422", r.status_code == 422, r.status_code)
    check("rejected times left stored time intact", client.get(url, headers=ck_a).json()["prayer_reminder_time"] == "06:45")
    for bad in ("true", 1, None):
        check(f"non-boolean prayer_reminder {bad!r} -> 422",
              client.put(url, json={"prayer_reminder": bad}, headers=ck_a).status_code == 422)
    for t in DEFAULT_OFF:
        client.put(url, json={t: False}, headers=ck_a)
    client.put(url, json={"prayer_reminder_time": "08:00", "check_in_reminder_time": "18:00",
                          "deep_question_reminder_time": "20:00"}, headers=ck_a)

    # backward compat with the shipped iOS client (reads obj["friend_highlight"], sends only that key)
    r = client.put(url, json={"friend_highlight": False}, headers=ck_a)
    check("legacy iOS body {friend_highlight:false} still works", r.status_code == 200 and r.json()["friend_highlight"] is False, r.text)
    g = client.get(url, headers=ck_a).json()
    check("legacy GET still exposes friend_highlight as a top-level bool", g.get("friend_highlight") is False)
    client.put(url, json={"friend_highlight": True}, headers=ck_a)

    n_before = sql("SELECT COUNT(*) FROM push_preferences")[0][0]
    for bad in ("false", 0, 1, None, "yes", [], {}):
        r = client.put(url, json={"messages": bad}, headers=ck_a)
        check(f"non-boolean {bad!r} -> 422", r.status_code == 422, r.status_code)
    check("unknown key -> 422", client.put(url, json={"bogus": True}, headers=ck_a).status_code == 422)
    check("unknown key mixed with a valid one -> 422 and valid one not applied",
          client.put(url, json={"messages": False, "bogus": True}, headers=ck_a).status_code == 422
          and client.get(url, headers=ck_a).json()["messages"] is True)
    check("empty body -> 422", client.put(url, json={}, headers=ck_a).status_code == 422)
    check("injection-style key -> 422",
          client.put(url, json={"messages = TRUE; DROP TABLE users; --": True}, headers=ck_a).status_code == 422)
    check("users table survives", sql("SELECT COUNT(*) FROM users")[0][0] > 0)
    check("rejected PUTs created no rows", sql("SELECT COUNT(*) FROM push_preferences")[0][0] == n_before)

    check("anonymous GET refused", client.get(url).status_code in (401, 403))
    check("anonymous PUT refused", client.put(url, json={"pins": False}).status_code in (401, 403))
    check("other user GET refused", client.get(url, headers=ck_b).status_code in (401, 403))
    r = client.put(url, json={"pins": False}, headers=ck_b)
    check("other user PUT refused", r.status_code in (401, 403), r.status_code)
    check("other user PUT wrote nothing", client.get(url, headers=ck_a).json()["pins"] is True)
    other = f"/notification/{b}/push-preferences"
    check("user B has own default map, unaffected by A", client.get(other, headers=ck_b).json() == DEFAULTS)
    check("non-uuid user id in path refused", client.get("/notification/not-a-uuid/push-preferences", headers=ck_a).status_code in (401, 403, 404, 422))

    # server error is generic, no leak
    orig = pp.get_preferences
    pp.get_preferences = lambda uid: (_ for _ in ()).throw(RuntimeError(f"boom {uid} secret"))
    try:
        r = client.get(url, headers=ck_a)
        check("GET failure -> 500 with generic detail (no id / exception text)",
              r.status_code == 500 and a not in r.text and "boom" not in r.text, r.text)
    finally:
        pp.get_preferences = orig


# ------------------------------------------------------------------ C. helper

def test_helper():
    print("C. helper")
    u1, u2, u3 = make_user("np_h1"), make_user("np_h2"), make_user("np_h3")
    opt_out(u1, "pins")
    opt_out(u2, "pins", True)
    opt_out(u3, "messages")
    ids = [u1, u2, u3]
    check("disabled_user_ids returns only the opted-out user for that type", pp.disabled_user_ids(ids, "pins") == {u1})
    check("opt-out is per type (u3 off messages only)", pp.disabled_user_ids(ids, "messages") == {u3})
    check("a type nobody disabled yields empty set", pp.disabled_user_ids(ids, "reminders") == set())
    check("missing row (no row at all) = enabled", pp.is_push_enabled(make_user("np_h4"), "pins") is True)
    check("is_push_enabled false for opted-out", pp.is_push_enabled(u1, "pins") is False)
    check("is_push_enabled true for other type of same user", pp.is_push_enabled(u1, "messages") is True)
    check("upper-case uuid still matches", pp.disabled_user_ids([u1.upper()], "pins") == {u1})
    check("malformed ids ignored (fail open, no raise)",
          pp.disabled_user_ids(["nope", "", None, "1; DROP"], "pins") == set() and pp.is_push_enabled("nope", "pins") is True)
    check("empty list -> empty set", pp.disabled_user_ids([], "pins") == set())
    for bad in ("bogus", "pins; DROP TABLE users", ""):
        try:
            pp.disabled_user_ids([u1], bad)
            ok = False
        except ValueError:
            ok = True
        check(f"unknown push type {bad!r} raises ValueError (no SQL built)", ok)
    check("async wrappers agree", asyncio.run(pp.async_disabled_user_ids(ids, "pins")) == {u1}
          and asyncio.run(pp.async_is_push_enabled(u1, "pins")) is False)
    try:
        pp.set_preferences(u1, {"bogus": True})
        ok = False
    except ValueError:
        ok = True
    check("set_preferences rejects unknown key at the module level", ok)
    n0 = sql("SELECT COUNT(*) FROM push_preferences")[0][0]
    res = pp.set_preferences(make_user("np_h5"), {})
    res2 = pp.set_preferences(make_user("np_h6"), {"join_requests": False})
    check("set_preferences with nothing real to write returns the map and writes no row (the API still 422s an empty body)",
          res == pp.defaults() and res2 == pp.defaults() and sql("SELECT COUNT(*) FROM push_preferences")[0][0] == n0)
    for bad in ({"prayer_reminder_time": "25:00"}, {"prayer_reminder": "true"}, {"prayer_reminder_time": 5}):
        try:
            pp.set_preferences(u1, bad)
            ok = False
        except ValueError:
            ok = True
        check(f"set_preferences rejects {bad}", ok)

    # default-OFF types: missing row = disabled, only explicit TRUE enables; fail CLOSED
    d1, d2, d3 = make_user("np_d1"), make_user("np_d2"), make_user("np_d3")
    opt_out(d2, "prayer_reminder", True)
    opt_out(d3, "pins", False)  # row exists but reminder column left at its FALSE default
    ids = [d1, d2, d3]
    for t in DEFAULT_OFF:
        check(f"{t}: user with no row is disabled", d1 in pp.disabled_user_ids(ids, t))
    check("prayer_reminder: only the explicit opt-in is enabled", pp.disabled_user_ids(ids, "prayer_reminder") == {d1, d3})
    check("check_in_reminder not enabled by enabling prayer_reminder", pp.disabled_user_ids(ids, "check_in_reminder") == set(ids))
    check("is_push_enabled default-off: no row False, opted-in True",
          pp.is_push_enabled(d1, "prayer_reminder") is False and pp.is_push_enabled(d2, "prayer_reminder") is True)
    check("default-off with malformed id is not enabled; default-on malformed id still enabled",
          pp.is_push_enabled("nope", "prayer_reminder") is False and pp.is_push_enabled("nope", "pins") is True)
    check("announcement_reminder defaults ON (no row)", pp.is_push_enabled(d1, "announcement_reminder") is True)
    opt_out(d2, "announcement_reminder", False)
    check("announcement_reminder opt-out respected", pp.disabled_user_ids(ids, "announcement_reminder") == {d2})

    real = pp.DBManager
    class Boom2:
        def __init__(self, *a, **k):
            raise RuntimeError("db down")
    pp.DBManager = Boom2
    try:
        closed = pp.disabled_user_ids([d2], "prayer_reminder")
        enabled = pp.is_push_enabled(d2, "prayer_reminder")
        open_ = pp.disabled_user_ids([d2], "pins")
    finally:
        pp.DBManager = real
    check("default-off type FAILS CLOSED on DB connect error (opted-in user not pushed on error)",
          closed == {d2} and enabled is False)
    check("default-on type still fails open on the same error", open_ == set())

    class BadCur:
        def __init__(self):
            self._db = real()
            self.conn = self._db.conn
            class Cur:
                def execute(self_, *a, **k):
                    raise RuntimeError("x")
            self.cur = Cur()
        def close(self):
            self._db.close()
    pp.DBManager = BadCur
    try:
        closed = pp.disabled_user_ids([d2], "deep_question_reminder")
    finally:
        pp.DBManager = real
    check("default-off type FAILS CLOSED on query error", closed == {d2})

    # fail open + PII-free log
    cap = LogCapture()
    lg = logging.getLogger(pp.__name__)
    lg.addHandler(cap)
    real = pp.DBManager

    class Boom:
        def __init__(self, *a, **k):
            raise RuntimeError(f"db down for {u1}")

    pp.DBManager = Boom
    try:
        res = pp.disabled_user_ids([u1], "pins")
        enabled = pp.is_push_enabled(u1, "pins")
    finally:
        pp.DBManager = real
        lg.removeHandler(cap)
    text = " ".join(r.getMessage() for r in cap.records)
    check("DB connect failure fails open (opt-out cannot be read -> send)", res == set() and enabled is True)
    check("failure logged with class name only, no user id / message", "RuntimeError" in text and u1 not in text and "db down" not in text, text)

    class BadCursor:
        def __init__(self):
            real_db = real()
            self.conn = real_db.conn
            self._db = real_db

            class Cur:
                def execute(self_, *a, **k):
                    raise RuntimeError("query exploded")
            self.cur = Cur()

        def close(self):
            self._db.close()

    pp.DBManager = BadCursor
    try:
        res = pp.disabled_user_ids([u1], "pins")
    finally:
        pp.DBManager = real
    check("query failure fails open too", res == set())


# ------------------------------------------------------------------ D. senders

def test_chat_push():
    print("D1. messages: chat push")
    s, off, on = make_user("np_cs"), make_user("np_co"), make_user("np_cn")
    gid = make_group([s, off, on])
    t_off, t_on = token_for(off), token_for(on)
    opt_out(off, "messages")
    mgr = ConnectionManager()
    orig = ws_module.send_push
    ws_module.send_push = fake_send_push
    try:
        async def send(text):
            await mgr.send_msg({"from_user": s, "to_users": [s, off, on], "text": text, "group_id": gid,
                                "timestamp": datetime.now(timezone.utc).isoformat()})
        SENT.clear()
        asyncio.run(send("hi"))
        check("opted-out recipient gets no chat push; opted-in peer does", tokens_sent() == {t_on}, SENT)
        opt_out(off, "messages", True)
        SENT.clear()
        asyncio.run(send("hi again"))
        check("re-enabling restores the chat push", tokens_sent() == {t_on, t_off}, SENT)
        # opting out of a different type must not suppress chat
        opt_out(off, "pins")
        SENT.clear()
        asyncio.run(send("third"))
        check("opt-out of another type does not suppress chat push", t_off in tokens_sent(), SENT)
        # message still persisted/delivered via WS for opted-out user
        opt_out(off, "messages")
        ws = FakeWS()
        mgr.active_connections[off] = ws
        SENT.clear()
        asyncio.run(send("online"))
        check("opted-out user still receives the message live over WS (only offline push suppressed)",
              any(f.get("text") == "online" for f in ws.sent), ws.sent)
        mgr.active_connections.pop(off, None)
        check("message was persisted for the opted-out recipient", sql("SELECT COUNT(*) FROM messages WHERE group_id=%s", (gid,))[0][0] >= 4)
    finally:
        ws_module.send_push = orig
        mgr.close()


def test_thread_push():
    print("D2. messages: thread reply push")
    a, off, on = make_user("np_ta"), make_user("np_to"), make_user("np_tn")
    gid = make_group([a, off, on])
    set_flag("threads", "on", a)
    root = make_msg(off, gid, "root")
    tid = make_thread(gid, root, off, title="t")
    t_off, t_on = token_for(off), token_for(on)
    for u in (off, on):
        sql("INSERT INTO thread_followers (thread_id, user_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (tid, u))
    opt_out(off, "messages")
    mgr = ConnectionManager()
    orig = thread_send.send_push
    thread_send.send_push = fake_send_push
    try:
        async def send(text):
            await thread_send.send_thread_message(mgr, {"from_user": a, "type": "thread_message", "thread_id": tid, "text": text})
        SENT.clear()
        asyncio.run(send("reply 1"))
        check("opted-out follower gets no thread push; opted-in follower does", tokens_sent() == {t_on}, SENT)
        check("thread reply itself was stored", sql("SELECT COUNT(*) FROM thread_messages WHERE thread_id=%s", (tid,))[0][0] == 1)
        opt_out(off, "messages", True)
        SENT.clear()
        asyncio.run(send("reply 2"))
        check("re-enabled follower gets thread push again", tokens_sent() == {t_on, t_off}, SENT)
    finally:
        thread_send.send_push = orig
        mgr.close()


def test_pin_push():
    print("D3. pins")
    pinner, off, on = make_user("np_pp"), make_user("np_po"), make_user("np_pn")
    gid = make_group([pinner, off, on])
    mid = make_msg(pinner, gid, "pin me")
    t_off, t_on = token_for(off), token_for(on)
    set_flag("message_pins", "on", pinner)
    opt_out(off, "pins")
    batch = pin_push._prepare(gid, pinner, mid, [off, on])
    check("pin push batch excludes the opted-out recipient only", [b["token"] for b in batch] == [t_on], batch)
    opt_out(off, "pins", True)
    batch = pin_push._prepare(gid, pinner, mid, [off, on])
    check("re-enabled recipient is back in the batch", {b["token"] for b in batch} == {t_on, t_off}, batch)
    opt_out(off, "messages")
    batch = pin_push._prepare(gid, pinner, mid, [off, on])
    check("opting out of messages does not suppress pins", {b["token"] for b in batch} == {t_on, t_off}, batch)
    set_flag("message_pins", "off", pinner)


def test_reaction_push():
    print("D4. reactions + friend_highlight")
    author, reactor = make_user("np_ra"), make_user("np_rr")
    gid = make_group([author, reactor])
    t_author = token_for(author)
    set_flag(rhp.REACTION_FLAG, "on", author)
    set_flag("message_reactions", "on", author)
    mids = [make_msg(author, gid, f"m{i}") for i in range(3)]
    check("default: reaction push prepared", rhp._prepare_reaction(mids[0], reactor, "👍", gid) is not None)
    opt_out(author, "reactions")
    res = rhp._prepare_reaction(mids[1], reactor, "👍", gid)
    check("opted-out author: no reaction push prepared", res is None, res)
    check("opted-out author: no claim row consumed",
          sql("SELECT COUNT(*) FROM message_reaction_push_claims WHERE message_id=%s", (mids[1],))[0][0] == 0)
    opt_out(author, "reactions", True)
    res = rhp._prepare_reaction(mids[2], reactor, "👍", gid)
    check("re-enabled: push prepared to the author's token", res is not None and res["token"] == t_author, res)
    set_flag(rhp.REACTION_FLAG, "off", author)

    # friend_highlight: existing fail-closed query keyed on the same column
    h, f_off, f_on = make_user("np_hh"), make_user("np_hf"), make_user("np_hn")
    befriend(h, f_off)
    befriend(h, f_on)
    toks = {u: token_for(u) for u in (f_off, f_on)}
    opt_out(f_off, "friend_highlight")
    flags_mod = rhp.flags
    flags_mod.set_flag(rhp.HIGHLIGHT_FLAG, "on", actor=h)
    flags_mod.invalidate()
    push_module.send_push = fake_send_push
    SENT.clear()
    asyncio.run(rhp.notify_friend_highlight(h, "John", 3, 16))
    check("friend_highlight opt-out via the new column honored; peer still pushed", tokens_sent() & set(toks.values()) == {toks[f_on]}, SENT)
    flags_mod.set_flag(rhp.HIGHLIGHT_FLAG, "off", actor=h)
    flags_mod.invalidate()


def test_announcement_recipients():
    print("D5. announcements")
    creator, off, on = make_user("np_ac"), make_user("np_ao"), make_user("np_an")
    gid = make_group([creator, off, on], creator=creator)
    t_off, t_on, t_c = token_for(off), token_for(on), token_for(creator)
    opt_out(off, "announcements")
    db = DBManager()
    try:
        _, targets = ann_notifier._recipients(db, gid, creator)
        got = {t for _, t in targets}
        check("opted-out member excluded from announcement targets; others (incl. author) kept", got == {t_on, t_c}, got)
        opt_out(off, "announcements", True)
        _, targets = ann_notifier._recipients(db, gid, creator)
        check("re-enabled member is a target again", t_off in {t for _, t in targets})
    finally:
        db.close()
    # end to end: scheduled heads-up path through the real notifier entry point
    opt_out(off, "announcements")
    push_module.send_push = fake_send_push
    ann_id = str(uuid.uuid4())
    sql("INSERT INTO group_announcements (_id, group_id, creator_id, title, description, publish_at) "
        "VALUES (%s,%s,%s,%s,%s,NOW())", (ann_id, gid, creator, "Hello all", "desc"))
    SENT.clear()
    db = DBManager()
    try:
        row = (ann_id, gid, creator, "Hello all", datetime.now(timezone.utc))
        prepared = ann_notifier._prepare(db, row, ann_notifier.KIND_PUBLISH)
        asyncio.run(ann_notifier._send(prepared)) if prepared else None
    finally:
        db.close()
    check("announcement publish push skips opted-out member, reaches others", t_off not in tokens_sent() and t_on in tokens_sent(), SENT)


def test_session_reminders(client):
    print("D6. session_reminders (creation push + reminder job)")
    creator, off, on = make_user("np_sc"), make_user("np_so"), make_user("np_sn")
    gid = make_group([creator, off, on])
    t_off, t_on, t_c = token_for(off), token_for(on), token_for(creator)
    opt_out(off, "session_reminders")
    push_module.send_push = fake_send_push

    # reminder job
    past = datetime.now(timezone.utc) - timedelta(minutes=1)
    sid = str(uuid.uuid4())
    sql("INSERT INTO devotions (_id, title, time_start, group_id, creator_id, participants, verses, prompts) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s,%s)", (sid, "Due", past, gid, creator, [], [], []))
    SENT.clear()
    asyncio.run(scheduler_module._fire_due_session_reminders())
    mine = {s["token"] for s in SENT} & {t_off, t_on, t_c}
    check("reminder job: opted-out member skipped, others (incl. creator) pushed", mine == {t_on, t_c}, SENT)
    check("reminder was still claimed (reminder_sent_at set)",
          sql("SELECT reminder_sent_at FROM devotions WHERE _id=%s", (sid,))[0][0] is not None)

    # creation push via the real route (free plan: one active session at a time)
    sql("DELETE FROM devotions WHERE _id=%s", (sid,))
    from routes import devotion as devotion_route  # noqa: F401
    if True:
        devo_id = str(uuid.uuid4())
        payload = {"devotion_id": devo_id, "user_id": creator,
                   "devotion": {"id": devo_id, "title": "Morning", "creator_id": creator,
                                "group_id": gid, "prompts": [], "verses": []}}
        SENT.clear()
        r = client.post("/devotions/", json=payload, headers=cookie(creator))
        check("create session -> 201 for creator", r.status_code == 201, r.text)
        mine = {s["token"] for s in SENT} & {t_off, t_on, t_c}
        check("creation push: opted-out member skipped, opted-in pushed, creator not pushed", mine == {t_on}, SENT)
        opt_out(off, "session_reminders", True)
        devo2 = str(uuid.uuid4())
        payload["devotion_id"] = devo2
        payload["devotion"]["id"] = devo2
        payload["devotion"]["title"] = "Second"
        limiter.reset()
        sql("DELETE FROM devotions WHERE creator_id=%s", (creator,))
        SENT.clear()
        client.post("/devotions/", json=payload, headers=cookie(creator))
        mine = {s["token"] for s in SENT} & {t_off, t_on, t_c}
        check("re-enabled member gets the creation push", mine == {t_on, t_off}, SENT)


def test_reminders_job():
    print("D7. reminders (guilt job)")
    off, on = make_user("np_gO"), make_user("np_gN")
    t_off, t_on = token_for(off), token_for(on)
    old = datetime.now(timezone.utc) - INACTIVITY_THRESHOLD - timedelta(hours=2)
    for u in (off, on):
        sql("INSERT INTO user_activity (user_id, last_activity_at) VALUES (%s,%s) "
            "ON CONFLICT (user_id) DO UPDATE SET last_activity_at=EXCLUDED.last_activity_at, guilt_reminder_sent_at=NULL", (u, old))
    opt_out(off, "reminders")
    push_module.send_push = fake_send_push
    SENT.clear()
    asyncio.run(scheduler_module._guilt_no_activity_reminder())
    mine = {s["token"] for s in SENT} & {t_off, t_on}
    check("guilt reminder: opted-out user skipped, opted-in user pushed", mine == {t_on}, SENT)
    check("opted-out user was not marked sent (no dedupe consumed)",
          sql("SELECT guilt_reminder_sent_at FROM user_activity WHERE user_id=%s", (off,))[0][0] is None)
    opt_out(off, "reminders", True)
    SENT.clear()
    asyncio.run(scheduler_module._guilt_no_activity_reminder())
    mine = {s["token"] for s in SENT} & {t_off, t_on}
    check("re-enabled: user gets the reminder on the next run", t_off in mine, SENT)


def test_friend_activity(client):
    print("D8. friend_activity (went-active job + nudge)")
    active, f_off, f_on = make_user("np_fa"), make_user("np_ff"), make_user("np_fn")
    befriend(active, f_off)
    befriend(active, f_on)
    t_off, t_on = token_for(f_off), token_for(f_on)
    opt_out(f_off, "friend_activity")
    sql("INSERT INTO user_activity (user_id, last_activity_at, became_active_at, friend_notified_at, last_activity_type) "
        "VALUES (%s, NOW(), NOW(), NULL, 'note_created') ON CONFLICT (user_id) DO UPDATE SET "
        "became_active_at=NOW(), friend_notified_at=NULL, last_activity_at=NOW()", (active,))
    push_module.send_push = fake_send_push
    scheduler_send_orig = push_module.send_push
    SENT.clear()
    asyncio.run(scheduler_module._friend_went_active_notify())
    mine = {s["token"] for s in SENT} & {t_off, t_on}
    check("went-active: opted-out friend skipped, opted-in friend pushed", mine == {t_on}, SENT)
    check("went-active batch still marked notified", sql("SELECT friend_notified_at FROM user_activity WHERE user_id=%s", (active,))[0][0] is not None)
    push_module.send_push = scheduler_send_orig

    # nudge
    sender = make_user("np_ns")
    befriend(sender, f_off)
    befriend(sender, f_on)
    orig = community_module.send_push
    community_module.send_push = fake_send_push
    try:
        if True:
            limiter.reset()
            SENT.clear()
            r_off = client.post(f"/friends/{sender}/{f_off}/nudge", headers=cookie(sender))
            check("nudge to opted-out friend -> 404, nothing sent", r_off.status_code == 404 and t_off not in tokens_sent(), (r_off.status_code, r_off.text))
            # indistinguishable from an unreachable friend (no settings leak)
            stranger_no_token = make_user("np_nt")
            befriend(sender, stranger_no_token)
            r_unr = client.post(f"/friends/{sender}/{stranger_no_token}/nudge", headers=cookie(sender))
            check("opted-out response is identical to unreachable-friend response (no settings leak)",
                  r_unr.status_code == r_off.status_code and r_unr.text == r_off.text, (r_unr.text, r_off.text))
            check("opted-out nudge consumed no rate-limit claim",
                  sql("SELECT COUNT(*) FROM friend_nudges WHERE sender_id=%s AND recipient_id=%s", (sender, f_off))[0][0] == 0)
            r_on = client.post(f"/friends/{sender}/{f_on}/nudge", headers=cookie(sender))
            check("nudge to opted-in friend -> 204 and pushed", r_on.status_code == 204 and t_on in tokens_sent() and t_off not in tokens_sent(), (r_on.status_code, SENT))
            opt_out(f_off, "friend_activity", True)
            SENT.clear()
            r2 = client.post(f"/friends/{sender}/{f_off}/nudge", headers=cookie(sender))
            check("re-enabled friend can be nudged", r2.status_code == 204 and t_off in tokens_sent(), (r2.status_code, r2.text))
    finally:
        community_module.send_push = orig


def test_join_requests():
    print("D9. join_requests (owner push now ESSENTIAL; approval push essential)")
    owner, applicant = make_user("np_jo"), make_user("np_ja")
    gid = make_group([owner], creator=owner)
    t_owner, t_app = token_for(owner), token_for(applicant)
    from backend.interactions import join_requests_config as jrc
    jrc.reset_for_tests()

    def new_request(status="pending"):
        sql("DELETE FROM group_join_requests WHERE group_id=%s AND user_id=%s", (gid, applicant))
        return sql("INSERT INTO group_join_requests (group_id, user_id, status) VALUES (%s,%s,%s) RETURNING id::text",
                   (gid, applicant, status))[0][0]

    # essential: owner push ignores preferences (stored legacy opt-out AND every type off) and the flag
    for flag_state in ("off", "on"):
        set_flag("join_request_push", flag_state, owner)
        for t in TYPES:
            opt_out(owner, t, False)
        opt_out(owner, "join_requests", False)
        rid = new_request()
        res = jrn._prepare_owner_push(rid)
        check(f"owner push still prepared with join_request_push flag {flag_state} and every preference off",
              res is not None and res["token"] == t_owner, res)
    check("owner push prepare never consults preferences or the flag",
          not ({"is_push_enabled", "disabled_user_ids"} & set(jrn._prepare_owner_push.__code__.co_names)))

    # essential: approval to the requester ignores preferences, even if every type is off for them
    for t in TYPES:
        opt_out(applicant, t, False)
    rid2 = new_request("approved")
    res = jrn._prepare_approved_push(rid2)
    check("approval push to requester is essential: still sent when every type is opted out",
          res is not None and res["token"] == t_app, res)
    check("approved push path never consults preferences",
          "is_push_enabled" not in jrn._prepare_approved_push.__code__.co_names)
    set_flag("join_request_push", "off", owner)


def test_essential_call_push_untouched():
    print("D10. essential call/VoIP push does not consult preferences")
    import inspect
    import routes.devotion as dev
    src = inspect.getsource(dev)
    ring_idx = src.find("send_voip_push")
    check("ring/VoIP code exists in routes/devotion.py", ring_idx >= 0)
    # the only preference lookup in routes/devotion.py is the session_reminders one
    uses = [l.strip() for l in src.splitlines() if "async_disabled_user_ids(" in l and "import" not in l]
    check("devotion route consults preferences only for session_reminders",
          len(uses) == 1 and '"session_reminders"' in uses[0], uses)
    ring_funcs = [n for n in dir(dev) if "ring" in n.lower()]
    for n in ring_funcs:
        f = getattr(dev, n)
        if callable(f) and hasattr(f, "__code__"):
            check(f"{n} does not reference the preference helpers",
                  not ({"async_disabled_user_ids", "async_is_push_enabled", "is_push_enabled", "disabled_user_ids"} & set(f.__code__.co_names)))


def main():
    require_scratch_db()
    push_module.send_push = fake_send_push
    try:
        test_ddl()
        with TestClient(main_module.app) as client:  # one lifespan: the scheduler is a process singleton
            test_api(client)
            test_helper()
            test_chat_push()
            test_thread_push()
            test_pin_push()
            test_reaction_push()
            test_announcement_recipients()
            test_session_reminders(client)
            test_reminders_job()
            test_friend_activity(client)
            test_join_requests()
            test_essential_call_push_untouched()
    finally:
        for gid in GROUPS:
            try:
                sql("DELETE FROM group_announcements WHERE group_id=%s", (gid,))
                sql("DELETE FROM group_join_requests WHERE group_id=%s", (gid,))
                sql("DELETE FROM devotions WHERE group_id=%s", (gid,))
            except Exception:  # noqa: BLE001
                pass
        for u in USERS:
            try:
                sql("DELETE FROM devotions WHERE creator_id=%s", (u,))
                sql("DELETE FROM user_activity WHERE user_id=%s", (u,))
                sql("DELETE FROM friend_nudges WHERE sender_id=%s OR recipient_id=%s", (u, u))
                sql("DELETE FROM push_preferences WHERE user_id=%s", (u,))
                sql("DELETE FROM group_join_requests WHERE user_id=%s", (u,))
            except Exception:  # noqa: BLE001
                pass
        finish(("threads", "message_pins", "message_reactions", "join_request_push",
                rhp.REACTION_FLAG, rhp.HIGHLIGHT_FLAG))


if __name__ == "__main__":
    main()
