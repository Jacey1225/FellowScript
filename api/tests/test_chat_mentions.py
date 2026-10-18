"""Tests for task 20261017-chat-mentions: @mentions in chat (flag ``chat_mentions``).

Scratch database only (asserts SHOW port = 55432, or 5432 under GITHUB_ACTIONS). Proves:
  * DDL module ``message_mentions`` applies twice, adds only nullable JSONB ``mentions`` on
    ``messages`` and ``thread_messages``, no FK; flag registered, seeded off, in capabilities
  * validation on send (group, DM, thread): range, overlap, order, duplicates, non-member,
    unknown, blocked (both directions), suspended, self, >10 (own reason), bad types/keys,
    shared-object kinds, UTF-16 offsets with emoji and accents, a range splitting a surrogate
    pair; every failure saves nothing and gives the uniform frame
  * flag off ignores the key (plain message, no bypass push, malformed value tolerated)
  * ack and live frames carry ``mentions`` with CURRENT usernames, only for flag-on recipients
  * reads: legacy and paged group, legacy and paged DM, thread read, pins (clipped to the
    preview); rename shows the new name; deleted message never emitted; raw column never leaks
  * push matrix: muted group + mention pushes, ordinary message stays muted, online recipient
    still pushed, global messages preference off => none, blocked => none, no token => none,
    deleted before sending => none, one push per mentioned user, title/body/data; thread path
    (non-follower and muted still pushed)
  * GET /groups/{u}/{g}/mention-members: 404 flag off, 403 non-member, blocked/suspended/self
    excluded, sorted, canonical ids
  * purge sweeper clears ``mentions``; restore frame carries them per recipient flag
Run with: cd api && ../.venv/bin/python tests/test_chat_mentions.py
(locally needs the scratch cluster on 55432, see the other scratch-DB tests)
"""
import _pathfix  # noqa: F401

import asyncio
import json
import logging
import os
import sys
import uuid
from datetime import datetime, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import db as db_module  # noqa: E402
from db import DBManager  # noqa: E402
from _thr_common import (  # noqa: E402
    PASSED, FAILED, USERS, check, require_scratch_db, sql, make_user, make_group, make_msg,
    make_thread, cookie, cleanup, set_flag, FakeWS,
)
from backend.interactions import flags, message_mentions as mm, message_delete as md  # noqa: E402
from backend.interactions import thread_send  # noqa: E402
import backend.interactions.websockets as ws_module  # noqa: E402
from backend.interactions.websockets import ConnectionManager  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from schema_ddl import message_mentions as ddl  # noqa: E402

FLAG = "chat_mentions"
ALL_FLAGS = (FLAG, "threads", "chat_pagination", "chat_pagination_dm", "message_pins", "message_delete")
INVALID = {"type": "error", "reason": "mention_invalid",
           "detail": "Couldn't send your message. Check the people you mentioned and try again."}
TOO_MANY = {"type": "error", "reason": "mentions_too_many",
            "detail": "You can mention up to 10 people in one message."}


def u16(s):
    return len(s.encode("utf-16-le")) // 2


def name_of(uid):
    return sql("SELECT username FROM users WHERE _id=%s", (uid,))[0][0]


def ment(uid, text, name=None, nth=0):
    """Mention entry for the nth occurrence of ``@name`` in ``text`` (UTF-16 offsets)."""
    token = "@" + (name or name_of(uid))
    idx = -1
    for _ in range(nth + 1):
        idx = text.index(token, idx + 1)
    return {"user_id": uid, "start": u16(text[:idx]), "length": u16(token)}


def befriend(a, b):
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s) ON CONFLICT DO NOTHING", (a, b, b, a))


def block(blocker, blocked):
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (blocker, blocked))


def unblock_all(*uids):
    for u in uids:
        sql("DELETE FROM blocked_users WHERE blocker_id=%s OR blocked_id=%s", (u, u))


def token_for(uid):
    sql("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) ON CONFLICT (user_id) DO UPDATE SET token=EXCLUDED.token",
        (uid, "tok-" + uid[:8]))
    return "tok-" + uid[:8]


def mute(uid, gid):
    sql("INSERT INTO group_mutes (user_id, group_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (uid, gid))


def set_messages_pref(uid, on):
    sql("INSERT INTO push_preferences (user_id, messages) VALUES (%s,%s) "
        "ON CONFLICT (user_id) DO UPDATE SET messages=EXCLUDED.messages", (uid, on))


def stored(text):
    r = sql("SELECT _id::text, mentions FROM messages WHERE text=%s", (text,))
    return r[0] if r else None


def saved_count(text):
    return sql("SELECT COUNT(*) FROM messages WHERE text=%s", (text,))[0][0]


class Env:
    """One ConnectionManager with fake sockets and a recording fake send_push (both send paths)."""

    def __init__(self, *online):
        self.manager = ConnectionManager()
        self.ws = {u: FakeWS() for u in online}
        self.manager.active_connections.update(self.ws)
        self.pushed = []
        self.keep_limit = False  # tests of the push limiter itself set this

        async def fake_push(token, title, body, data=None):
            self.pushed.append({"token": token, "title": title, "body": body, "data": data})
            return True

        self._o1, self._o2 = ws_module.send_push, thread_send.send_push
        ws_module.send_push = fake_push
        thread_send.send_push = fake_push

    def add_online(self, uid):
        self.ws[uid] = FakeWS()
        self.manager.active_connections[uid] = self.ws[uid]

    def set_offline(self, uid):
        self.manager.active_connections.pop(uid, None)

    def send(self, sender, gid, text, to=None, **extra):
        if not self.keep_limit:
            mm.push_limiter.reset()
        p = {"from_user": sender, "to_users": to or [sender], "text": text, "group_id": gid,
             "timestamp": datetime.now(timezone.utc).isoformat()}
        p.update(extra)
        asyncio.run(self.manager.send_msg(p))

    def send_thread(self, sender, tid, text, **extra):
        if not self.keep_limit:
            mm.push_limiter.reset()
        asyncio.run(thread_send.send_thread_message(
            self.manager, {"from_user": sender, "type": "thread_message", "thread_id": tid, "text": text, **extra}))

    def frames(self, uid, kind=None):
        if uid not in self.ws:
            return []
        return [f for f in self.ws[uid].sent if kind is None or f.get("type") == kind]

    def errors(self, uid):
        return self.frames(uid, "error")

    def clear(self):
        for w in self.ws.values():
            w.sent.clear()
        self.pushed.clear()

    def pushes_to(self, uid):
        t = "tok-" + uid[:8]
        return [p for p in self.pushed if p["token"] == t]

    def close(self):
        ws_module.send_push, thread_send.send_push = self._o1, self._o2
        self.manager.close()


def all_msgs(body):
    p = body.get("payload", body)
    out = []
    for k in ("host_msgs", "other_msgs", "messages"):
        out += p.get(k) or []
    return out


def by_id(msgs, mid):
    for m in msgs:
        if m.get("id") == mid:
            return m
    return None


# ---------------------------------------------------------------- 1 DDL / flag / unit

def test_ddl_flag_units(client):
    print("DDL module, flag, validator units")
    d = DBManager()
    try:
        ddl.apply(d.cur)
        ddl.apply(d.cur)
        d.conn.commit()
        check("DDL module applies twice without error", True)
        mods = list(db_module.DDL_MODULES)
        check("registered after threads", "message_mentions" in mods and mods.index("message_mentions") > mods.index("threads"))
        for table in ("messages", "thread_messages"):
            d.cur.execute("SELECT data_type, is_nullable, column_default FROM information_schema.columns "
                          "WHERE table_name=%s AND column_name='mentions'", (table,))
            r = d.cur.fetchone()
            check(f"{table}.mentions is nullable jsonb with no default", r == ("jsonb", "YES", None), str(r))
            d.cur.execute("SELECT count(*) FROM pg_constraint WHERE conrelid=%s::regclass AND contype='f' "
                          "AND conkey @> ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid=%s::regclass AND attname='mentions')]",
                          (table, table))
            check(f"{table}.mentions has no foreign key", d.cur.fetchone()[0] == 0)
    finally:
        d.close()
    check("flag registered (canary allowed, exposed in capabilities)",
          FLAG in flags._REGISTRY and not flags._REGISTRY[FLAG].no_canary and flags._REGISTRY[FLAG].exposed_in_capabilities)
    row = sql("SELECT state FROM feature_flags WHERE name=%s", (FLAG,))
    check("flag seeded", bool(row), str(row))
    from schema_ddl import flags as flags_ddl
    check("flag in SEED_FLAG_NAMES", FLAG in flags_ddl.SEED_FLAG_NAMES)
    a = make_user("mnt")
    ck = cookie(a)
    set_flag(FLAG, "off", a)
    cap = client.get("/app/capabilities", headers=ck).json()
    check("capabilities features.chat_mentions false while off", cap["features"].get(FLAG) is False, str(cap["features"]))
    set_flag(FLAG, "on", a)
    cap = client.get("/app/capabilities", headers=ck).json()
    check("capabilities features.chat_mentions true when on", cap["features"].get(FLAG) is True)
    set_flag(FLAG, "off", a)
    check("MAX_MENTIONS is 10", mm.MAX_MENTIONS == 10)
    check("utf16_len counts an emoji as 2 units", mm.utf16_len("a😀é") == 4)
    check("clip_for_preview drops a clipped mention", mm.clip_for_preview(
        [{"start": 0, "length": 3}, {"start": 8, "length": 4}], "x" * 10, ellipsis=False) == [{"start": 0, "length": 3}])


# ---------------------------------------------------------------- 2 validation (group + DM)

def test_validation_group(client):
    print("validation: group main chat")
    a, b, c, outsider, blocked_u, susp, blocked_me = (make_user(f"mv{i}") for i in range(7))
    gid = make_group([a, b, c, blocked_u, susp, blocked_me])
    block(a, blocked_u)
    block(blocked_me, a)
    sql("UPDATE users SET suspended_at=NOW() WHERE _id=%s", (susp,))
    env = Env(a, b, c)
    try:
        set_flag(FLAG, "on", a)
        nb, nc = name_of(b), name_of(c)

        def good(label, text, ments, **extra):
            n = len(env.errors(a))
            env.send(a, gid, text, mentions=ments, **extra)
            st = stored(text)
            check(f"accepted: {label}", st is not None and len(env.errors(a)) == n, str(env.errors(a)[-1:]))
            return st

        def refused(label, text, ments, frame=INVALID, **extra):
            n = len(env.errors(a))
            env.send(a, gid, text, mentions=ments, **extra)
            errs = env.errors(a)
            check(f"refused: {label}", len(errs) == n + 1 and errs[-1] == frame and saved_count(text) == 0, str(errs[-1:]))

        t = f"hi @{nb} and @{nc}!"
        st = good("two valid mentions", t, [ment(b, t), ment(c, t)])
        check("stored canonical list, ids and offsets only (no username)",
              st[1] == [{**ment(b, t), "user_id": b}, {**ment(c, t), "user_id": c}]
              and all(set(e) == {"user_id", "start", "length"} for e in st[1]), str(st[1]))
        t = f"@{nb.upper()} case"
        refused("case-different text slice", t, [{"user_id": b, "start": 0, "length": 1 + u16(nb)}])
        t = f"hi @{nb}"
        good("uppercase user id accepted and canonicalized", t, [{**ment(b, t), "user_id": b.upper()}])
        check("stored id is lowercase", stored(t)[1][0]["user_id"] == b)
        good("absent mentions is a plain message", "plain-1", None)
        good("empty list is a plain message", "plain-2", [])
        check("plain messages store NULL (never [])", stored("plain-1")[1] is None and stored("plain-2")[1] is None)

        t = f"x @{nb}"
        refused("start negative", t, [{"user_id": b, "start": -1, "length": 1 + u16(nb)}])
        refused("length below 2", f"v @{nb}", [{"user_id": b, "start": 2, "length": 1}])
        refused("past end of text", f"w @{nb}", [{"user_id": b, "start": 2, "length": 1 + u16(nb) + 1}])
        refused("wrong slice", f"y @{nb}", [{"user_id": b, "start": 1, "length": 1 + u16(nb)}])
        refused("float start", f"f @{nb}", [{"user_id": b, "start": 2.0, "length": 1 + u16(nb)}])
        refused("bool length", f"g @{nb}", [{"user_id": b, "start": 2, "length": True}])
        refused("string number", f"h @{nb}", [{"user_id": b, "start": "2", "length": 1 + u16(nb)}])
        refused("extra key", f"i @{nb}", [{**ment(b, f"i @{nb}"), "username": nb}])
        refused("missing key", f"j @{nb}", [{"user_id": b, "start": 2}])
        refused("non-object entry", f"k @{nb}", ["x"])
        refused("not a list", f"l @{nb}", {"user_id": b})
        refused("bad uuid", f"m @{nb}", [{**ment(b, f"m @{nb}"), "user_id": "nope"}])
        refused("non-string user id", f"n @{nb}", [{**ment(b, f"n @{nb}"), "user_id": 5}])
        t = f"o @{nb} @{nb}"
        refused("duplicate user", t, [ment(b, t, nth=0), ment(b, t, nth=1)])
        t = f"p @{nb} @{nc}"
        refused("unsorted", t, [ment(c, t), ment(b, t)])
        refused("overlap", f"q @{nb}", [{"user_id": b, "start": 2, "length": 1 + u16(nb)}, {"user_id": c, "start": 3, "length": 4}])
        t = f"r @{name_of(outsider)}"
        refused("non-member", t, [ment(outsider, t)])
        refused("unknown user", f"s @ghost", [{"user_id": str(uuid.uuid4()), "start": 2, "length": 6}])
        t = f"u @{name_of(a)}"
        refused("self", t, [ment(a, t)])
        t = f"v @{name_of(blocked_u)}"
        refused("blocked by sender", t, [ment(blocked_u, t)])
        t = f"w @{name_of(blocked_me)}"
        refused("sender blocked by them", t, [ment(blocked_me, t)])
        t = f"x @{name_of(susp)}"
        refused("suspended user", t, [ment(susp, t)])
        t = f"y @{nb}"
        for kind in ("shared_verse", "shared_note"):
            try:
                mm.validate(None, a, [a, b], t, kind, [ment(b, t)])
                check(f"validator refuses mentions on {kind}", False, "no exception")
            except mm.MentionInvalid:
                check(f"validator refuses mentions on {kind}", True)

        # more than 10 -> own reason, even when the entries are otherwise nonsense
        refused(">10 entries", "z many", [{"user_id": b, "start": 0, "length": 2}] * 11, frame=TOO_MANY)
        extras = [make_user("mvx") for _ in range(11)]
        sql("UPDATE groups SET users=%s WHERE _id=%s", (sql("SELECT users FROM groups WHERE _id=%s", (gid,))[0][0] + extras, gid))
        t = " ".join("@" + name_of(u) for u in extras[:10])
        good("exactly 10 mentions accepted", t, [ment(u, t) for u in extras[:10]])
        t = " ".join("@" + name_of(u) for u in extras)
        refused("11 distinct mentions", t, [ment(u, t) for u in extras], frame=TOO_MANY)

        # attachment caption (non-shared kind) may carry mentions
        t = f"cap @{nb}"
        good("image caption mention", t, [ment(b, t)], attachment_kind="image", attachment_key=f"attachments/{a}/x.jpg")
    finally:
        env.close()
        set_flag(FLAG, "off", a)


def test_utf16(client):
    print("validation: UTF-16 offsets")
    a, b, e1 = make_user("mu"), make_user("mu"), None
    gid = make_group([a, b])
    env = Env(a, b)
    try:
        set_flag(FLAG, "on", a)
        # accents and an emoji in the username itself
        accent = make_user("mu")
        sql("UPDATE users SET username=%s WHERE _id=%s", ("Zoë😀Ünï", accent))
        sql("UPDATE groups SET users=%s WHERE _id=%s", ([a, b, accent], gid))
        text = "😀 héllo 👨‍👩‍👧 @Zoë😀Ünï ok"
        m = ment(accent, text, "Zoë😀Ünï")
        check("offset is UTF-16 (not code points / graphemes)", m["start"] != text.index("@Zoë😀Ünï") and m["length"] == u16("@Zoë😀Ünï"))
        env.send(a, gid, text, mentions=[m])
        st = stored(text)
        check("emoji and accents: accepted and stored with UTF-16 offsets", st is not None and st[1] == [{**m, "user_id": accent}], str(st))
        # code-point offsets (what a naive client sends) are rejected
        t2 = "😀 😀 @Zoë😀Ünï"
        env.send(a, gid, t2, mentions=[{"user_id": accent, "start": t2.index("@"), "length": len("@Zoë😀Ünï")}])
        check("code-point offsets rejected", stored(t2) is None and env.errors(a)[-1] == INVALID, str(env.errors(a)[-1:]))
        # range splitting the surrogate pair of the emoji in the name
        t3 = "s @Zoë😀Ünï"
        good = ment(accent, t3, "Zoë😀Ünï")
        env.send(a, gid, t3, mentions=[{**good, "length": good["length"] - 4}])
        check("range splitting a surrogate pair rejected", stored(t3) is None and env.errors(a)[-1] == INVALID)
        # lone surrogate in text cannot be encoded: rejected, not crashed
        t4 = "lone \ud800 @" + name_of(b)
        env.send(a, gid, t4, mentions=[{"user_id": b, "start": 8, "length": 1 + u16(name_of(b))}])
        check("lone surrogate in text: rejected without crashing", env.errors(a)[-1] == INVALID)
        # text with mention that starts after emoji only
        t5 = f"👍 @{name_of(b)}"
        env.send(a, gid, t5, mentions=[ment(b, t5)])
        check("mention after an emoji", stored(t5) is not None and stored(t5)[1][0]["start"] == 3, str(stored(t5)))
    finally:
        env.close()
        set_flag(FLAG, "off", a)


def test_validation_dm(client):
    print("validation: DM")
    a, b, c = (make_user("md") for _ in range(3))
    befriend(a, b)
    env = Env(a, b)
    try:
        set_flag(FLAG, "on", a)
        t = f"yo @{name_of(b)}"
        env.send(a, None, t, to=[b], mentions=[ment(b, t)])
        check("DM: mention of the other party accepted", stored(t) is not None and stored(t)[1][0]["user_id"] == b)
        t = f"yo @{name_of(c)}"
        env.send(a, None, t, to=[b], mentions=[ment(c, t)])
        check("DM: mention of a third user refused", stored(t) is None and env.errors(a)[-1] == INVALID)
        t = f"me @{name_of(a)}"
        env.send(a, None, t, to=[b], mentions=[ment(a, t)])
        check("DM: self mention refused", stored(t) is None and env.errors(a)[-1] == INVALID)
    finally:
        env.close()
        set_flag(FLAG, "off", a)


def test_flag_off(client):
    print("flag off")
    a, b = make_user("mf"), make_user("mf")
    gid = make_group([a, b])
    env = Env(a, b)
    try:
        set_flag(FLAG, "off", a)
        t = f"off @{name_of(b)}"
        env.send(a, gid, t, mentions=[ment(b, t)])
        st = stored(t)
        check("flag off: message delivered and stored plain", st is not None and st[1] is None, str(st))
        check("flag off: no mentions key in the recipient frame", "mentions" not in env.frames(b)[-1])
        t = "off2"
        env.send(a, gid, t, mentions="garbage")
        check("flag off: even a malformed value is ignored, message delivered", stored(t) is not None and not env.errors(a))
        token_for(b)
        env.set_offline(b)
        env.clear()
        mute(b, gid)
        env.send(a, gid, f"off3 @{name_of(b)}", mentions=[ment(b, f"off3 @{name_of(b)}")])
        check("flag off: muted recipient gets no bypass push", env.pushes_to(b) == [])
    finally:
        env.close()


# ---------------------------------------------------------------- 3 frames / ack

def test_frames(client):
    print("ack and live frames")
    a, b, c = (make_user("mfr") for _ in range(3))
    gid = make_group([a, b, c])
    env = Env(a, b, c)
    try:
        # canary: sender and b have the flag, c does not
        flags.set_flag(FLAG, "canary", [a, b], actor=a)
        flags.invalidate()
        t = f"hey @{name_of(b)} and @{name_of(c)}"
        ments = [ment(b, t), ment(c, t)]
        env.send(a, gid, t, mentions=ments, client_ref="ref-1")
        pub = [{**ments[0], "user_id": b, "username": name_of(b)}, {**ments[1], "user_id": c, "username": name_of(c)}]
        ack = env.frames(a, "ack")[-1]
        check("ack carries mentions with usernames", ack.get("mentions") == pub, str(ack))
        fb = [f for f in env.frames(b) if f.get("text") == t][-1]
        check("flag-on recipient frame carries mentions with usernames", fb.get("mentions") == pub, str(fb))
        check("text stays the literal @Name", fb["text"] == t)
        fc = [f for f in env.frames(c) if f.get("text") == t][-1]
        check("flag-off recipient frame omits mentions", "mentions" not in fc)
        env.send(a, gid, "plain msg", client_ref="ref-2")
        check("message without mentions: ack and frame omit the key",
              "mentions" not in env.frames(a, "ack")[-1] and "mentions" not in env.frames(b)[-1])
        set_flag(FLAG, "off", a)
    finally:
        env.close()


# ---------------------------------------------------------------- 4 reads

def test_reads(client):
    print("reads: legacy and paged, group and DM, thread, pins, rename, deleted, no leak")
    a, b, c = (make_user("mr") for _ in range(3))
    befriend(a, b)
    gid = make_group([a, b, c])
    ck = cookie(a)
    env = Env()
    try:
        set_flag(FLAG, "on", a)
        for f in ("chat_pagination", "chat_pagination_dm", "message_pins", "threads"):
            set_flag(f, "on", a)
        tg = f"group @{name_of(b)} hi"
        env.send(a, gid, tg, mentions=[ment(b, tg)])
        td = f"dm @{name_of(b)} hi"
        env.send(a, None, td, to=[b], mentions=[ment(b, td)])
        gm, dm = stored(tg)[0], stored(td)[0]
        env.send(a, gid, "no mention here")
        plain = stored("no mention here")[0]
        want_g = [{**ment(b, tg), "user_id": b, "username": name_of(b)}]
        want_d = [{**ment(b, td), "user_id": b, "username": name_of(b)}]

        def paths(prefix):
            return (
                (f"{prefix}group paged first page", client.get(f"/groups/{a}/{gid}", params={"limit": "20"}, headers=ck), gm, want_g),
                (f"{prefix}group paged endpoint", client.get(f"/groups/{a}/{gid}/messages", params={"limit": "20"}, headers=ck), gm, want_g),
                (f"{prefix}DM paged", client.get(f"/message/messages/{a}/", params={"guest_user": b, "limit": "20"}, headers=ck), dm, want_d),
            )

        def legacy(prefix):
            return (
                (f"{prefix}group legacy", client.get(f"/groups/{a}/{gid}", headers=ck), gm, want_g),
                (f"{prefix}DM legacy", client.get(f"/message/messages/{a}/", params={"guest_user": b}, headers=ck), dm, want_d),
            )

        def verify(items):
            for label, resp, mid, want in items:
                msgs = all_msgs(resp.json())
                m = by_id(msgs, mid)
                check(f"{label}: mentions with current username", resp.status_code == 200 and m is not None and m.get("mentions") == want, str(m))
                pm = by_id(msgs, plain)
                check(f"{label}: message without mentions has no key", pm is None or "mentions" not in pm)

        for f in ("chat_pagination", "chat_pagination_dm"):
            set_flag(f, "off", a)
        verify(legacy("flag on, "))
        for f in ("chat_pagination", "chat_pagination_dm"):
            set_flag(f, "on", a)
        verify(paths("flag on, "))

        # no raw column leak on any path, flag on or off
        for flag_state in ("on", "off"):
            set_flag(FLAG, flag_state, a)
            set_flag("chat_pagination", "off", a)
            r = client.get(f"/groups/{a}/{gid}", headers=ck).json()
            raw_ok = all(("mentions" not in m) or (flag_state == "on" and m["mentions"] and "username" in m["mentions"][0])
                         for m in all_msgs(r))
            check(f"legacy group read ({flag_state}): raw JSONB never leaks", raw_ok, str(r)[:300])
            set_flag("chat_pagination", "on", a)
            if flag_state == "off":
                verify_off = [m for _, resp, _, _ in paths("") for m in all_msgs(resp.json())]
                check("flag off: no mentions key on any paged path", all("mentions" not in m for m in verify_off))
                verify_off = [m for _, resp, _, _ in legacy("") for m in all_msgs(resp.json())]
                check("flag off: no mentions key on any legacy path", all("mentions" not in m for m in verify_off))
        set_flag(FLAG, "on", a)

        # rename shows the new name (offsets unchanged)
        sql("UPDATE users SET username=%s WHERE _id=%s", ("Renamed" + b[:4], b))
        m = by_id(all_msgs(client.get(f"/groups/{a}/{gid}/messages", params={"limit": "20"}, headers=ck).json()), gm)
        check("rename: current username returned, offsets stored", m["mentions"][0]["username"] == "Renamed" + b[:4]
              and m["mentions"][0]["start"] == want_g[0]["start"], str(m))

        # deleted user: entry kept without username
        gone = make_user("mgone")
        sql("UPDATE groups SET users=%s WHERE _id=%s", ([a, b, c, gone], gid))
        tx = f"bye @{name_of(gone)}"
        env.send(a, gid, tx, mentions=[ment(gone, tx)])
        sql("DELETE FROM users WHERE _id=%s", (gone,))
        USERS.remove(gone)
        m = by_id(all_msgs(client.get(f"/groups/{a}/{gid}/messages", params={"limit": "20"}, headers=ck).json()), stored(tx)[0])
        check("deleted account: entry kept, username omitted", m["mentions"][0]["user_id"] == gone
              and "username" not in m["mentions"][0], str(m))

        # deleted message: never emitted
        sql("UPDATE messages SET deleted_at=NOW(), deleted_by=from_user WHERE _id=%s", (gm,))
        msgs = all_msgs(client.get(f"/groups/{a}/{gid}/messages", params={"limit": "20"}, headers=ck).json())
        check("soft-deleted message is not returned (its mentions are never rendered)", by_id(msgs, gm) is None)
        sql("UPDATE messages SET deleted_at=NULL, deleted_by=NULL WHERE _id=%s", (gm,))

        # pins: clipped to the 280 char preview
        long_t = "z" * 270 + f" @{name_of(b)}"
        env.send(a, gid, long_t, mentions=[ment(b, long_t)])
        short_t = f"pin @{name_of(c)}"
        env.send(a, gid, short_t, mentions=[ment(c, short_t)])
        for mid in (stored(long_t)[0], stored(short_t)[0]):
            r = client.post(f"/message-pins/{a}/{mid}", headers=ck)
            check("pin created", r.status_code in (200, 201), r.text)
        pins = client.get(f"/message-pins/{a}/group/{gid}", headers=ck).json()["pins"]
        pm = {p["message"]["id"]: p["message"] for p in pins}
        s = pm[stored(short_t)[0]]
        check("pin: nested message carries mentions with username", s.get("mentions") == [
            {**ment(c, short_t), "user_id": c, "username": name_of(c)}], str(s))
        lg = pm[stored(long_t)[0]]
        check("pin: mention clipped by the 280 char preview is dropped", "mentions" not in lg and lg["text"].endswith("…"), str(lg)[:200])
        set_flag(FLAG, "off", a)
        pins = client.get(f"/message-pins/{a}/group/{gid}", headers=ck).json()["pins"]
        check("pin: flag off omits mentions", all("mentions" not in p["message"] for p in pins))
        set_flag(FLAG, "on", a)

        # thread read
        root = make_msg(a, gid, "root")
        tid = make_thread(gid, root, a)
        limiter.reset()
        tt = f"in thread @{name_of(c)}"
        env.send_thread(a, tid, tt, mentions=[ment(c, tt)])
        r = client.get(f"/groups/{a}/{gid}/threads/{tid}/messages", headers=ck)
        tm = [m for m in r.json().get("messages", []) if m["text"] == tt]
        check("thread read: mentions with current username", r.status_code == 200 and tm
              and tm[0].get("mentions") == [{**ment(c, tt), "user_id": c, "username": name_of(c)}], r.text[:300])
        raw = sql("SELECT mentions FROM thread_messages WHERE thread_id=%s AND text=%s", (tid, tt))
        check("thread row stores ids and offsets only", raw and raw[0][0] == [{**ment(c, tt), "user_id": c}], str(raw))
        set_flag(FLAG, "off", a)
        r = client.get(f"/groups/{a}/{gid}/threads/{tid}/messages", headers=ck)
        check("thread read: flag off omits mentions", all("mentions" not in m for m in r.json().get("messages", [])))
        set_flag(FLAG, "on", a)
    finally:
        env.close()
        for f in ALL_FLAGS:
            set_flag(f, "off", a)


# ---------------------------------------------------------------- 5 push matrix

def test_push_group(client):
    print("push matrix: group")
    a, b, c, d, e, g = (make_user("mp") for _ in range(6))
    gid = make_group([a, b, c, d, e, g])
    for u in (b, c, d, e, g):
        token_for(u)
    env = Env(a)  # everyone else offline
    try:
        set_flag(FLAG, "on", a)
        mute(b, gid)
        mute(c, gid)
        nb = name_of(b)
        t = f"hello @{nb}"
        env.send(a, gid, t, mentions=[ment(b, t)])
        pb = env.pushes_to(b)
        check("muted group + mention => push", len(pb) == 1, str(env.pushed))
        check("title is '<sender> mentioned you'", pb and pb[0]["title"] == f"{name_of(a)} mentioned you", str(pb))
        check("body is the message preview", pb and pb[0]["body"] == t, str(pb))
        check("data: group_id, action message, mention true", pb and pb[0]["data"] == {
            "group_id": gid, "action": "message", "mention": True}, str(pb))
        check("ordinary message still muted for the muted, unmentioned member", env.pushes_to(c) == [])
        check("unmentioned unmuted members get the ordinary push (unchanged title)",
              all(p["title"] == name_of(a) and "mention" not in (p["data"] or {}) for p in env.pushed if p["token"] != pb[0]["token"]) and len(env.pushes_to(d)) == 1)
        check("mentioned user gets exactly one push (no ordinary duplicate)", len(env.pushes_to(b)) == 1)

        env.clear()
        long_t = "L" * 120 + f" @{nb}"
        env.send(a, gid, long_t, mentions=[ment(b, long_t)])
        check("long body truncated like ordinary pushes (100 chars, ellipsis)", env.pushes_to(b)[0]["body"] == long_t[:97] + "…")
        env.clear()

        # online recipient still gets the push and the frame
        env.add_online(b)
        t = f"online @{nb}"
        env.send(a, gid, t, mentions=[ment(b, t)])
        check("online recipient + mention => frame and push",
              any(f.get("text") == t for f in env.frames(b)) and len(env.pushes_to(b)) == 1, str(env.pushed))
        env.clear()
        env.set_offline(b)

        # global messages preference still suppresses (also for an online mentioned user)
        set_messages_pref(b, False)
        t = f"pref @{nb}"
        env.send(a, gid, t, mentions=[ment(b, t)])
        check("global 'messages' preference off => no mention push", env.pushes_to(b) == [])
        env.add_online(b)
        t2 = f"pref2 @{nb}"
        env.send(a, gid, t2, mentions=[ment(b, t2)])
        check("global preference off + online => still no push", env.pushes_to(b) == [])
        env.set_offline(b)
        set_messages_pref(b, True)
        env.clear()

        # blocked in either direction: send is rejected (validation) so nothing is pushed
        block(a, e)
        t = f"blk @{name_of(e)}"
        env.send(a, gid, t, mentions=[ment(e, t)])
        check("blocked mentioned user: send refused, no push", saved_count(t) == 0 and env.pushes_to(e) == [])
        # ordinary message in the same group: blocked member is still skipped (unchanged)
        env.send(a, gid, "ordinary")
        check("ordinary delivery still skips the blocked member", env.pushes_to(e) == [] and len(env.pushes_to(d)) == 1)
        unblock_all(a)
        env.clear()

        # no device token => silent no-op
        sql("DELETE FROM device_tokens WHERE user_id=%s", (g,))
        t = f"nt @{name_of(g)}"
        env.send(a, gid, t, mentions=[ment(g, t)])
        check("no device token: message saved, no push, no error", saved_count(t) == 1 and env.pushes_to(g) == [] and not env.errors(a))
        token_for(g)

        # non-member rejected
        outsider = make_user("mpo")
        token_for(outsider)
        t = f"out @{name_of(outsider)}"
        env.send(a, gid, t, mentions=[ment(outsider, t)])
        check("non-member mention rejected, nothing pushed", saved_count(t) == 0 and env.pushes_to(outsider) == [])

        # message deleted before the push is sent: skipped
        env.clear()
        orig = env.manager.save_message

        def save_then_delete(msg, *args, **kw):
            res = orig(msg, *args, **kw)
            sql("UPDATE messages SET deleted_at=NOW(), deleted_by=from_user WHERE _id=%s", (res[0],))
            return res

        env.manager.save_message = save_then_delete
        t = f"del @{nb}"
        env.send(a, gid, t, mentions=[ment(b, t)])
        env.manager.save_message = orig
        check("message deleted before sending: mention push skipped", env.pushes_to(b) == [] and saved_count(t) == 1, str(env.pushed))

        # log hygiene: ids only
        cap = []

        class H(logging.Handler):
            def emit(self, record):
                cap.append(record.getMessage())

        h = H()
        logging.getLogger().addHandler(h)
        logging.getLogger().setLevel(logging.DEBUG)
        t = "SECRET-LOG-CANARY @" + nb
        env.send(a, gid, t, mentions=[ment(b, t)])
        env.send(a, gid, "SECRET-LOG-CANARY2 @" + nb, mentions=[{"user_id": b, "start": 0, "length": 3}])
        logging.getLogger().removeHandler(h)
        check("logs never contain message text", not any("SECRET-LOG-CANARY" in m for m in cap), [m for m in cap if "CANARY" in m][:2])
    finally:
        env.close()
        set_flag(FLAG, "off", a)


def test_push_dm(client):
    print("push matrix: DM")
    a, b = make_user("mpd"), make_user("mpd")
    befriend(a, b)
    token_for(b)
    env = Env(a)
    try:
        set_flag(FLAG, "on", a)
        t = f"dm @{name_of(b)}"
        env.send(a, None, t, to=[b], mentions=[ment(b, t)])
        pb = env.pushes_to(b)
        room = "|".join(sorted([b, a]))
        check("DM mention push: title, body, room-key data", len(pb) == 1 and pb[0]["title"] == f"{name_of(a)} mentioned you"
              and pb[0]["body"] == t and pb[0]["data"] == {"group_id": room, "action": "message", "mention": True}, str(pb))
        env.clear()
        block(b, a)
        t = f"dm2 @{name_of(b)}"
        env.send(a, None, t, to=[b], mentions=[ment(b, t)])
        check("DM blocked: dropped, no push", env.pushes_to(b) == [] and saved_count(t) == 0)
    finally:
        env.close()
        unblock_all(a, b)
        set_flag(FLAG, "off", a)


def test_push_thread(client):
    print("push matrix: thread")
    a, b, c, d, outsider = (make_user("mpt") for _ in range(5))
    gid = make_group([a, b, c, d])
    root = make_msg(a, gid, "root")
    tid = make_thread(gid, root, a)
    for u in (b, c, d):
        token_for(u)
    env = Env(a)
    try:
        set_flag("threads", "on", a)
        set_flag(FLAG, "on", a)
        limiter.reset()
        # b is a non-follower and the group is muted for b; c follows; d is the unmentioned non-follower
        mute(b, gid)
        sql("INSERT INTO thread_followers (thread_id, user_id) VALUES (%s,%s)", (tid, c))
        t = f"thr @{name_of(b)}"
        env.send_thread(a, tid, t, mentions=[ment(b, t)])
        pb = env.pushes_to(b)
        check("thread: non-follower + muted group mentioned => push", len(pb) == 1, str(env.pushed))
        check("thread push: title/body/data", pb and pb[0]["title"] == f"{name_of(a)} mentioned you" and pb[0]["body"] == t
              and pb[0]["data"] == {"action": "thread_message", "group_id": gid, "thread_id": tid, "mention": True}, str(pb))
        check("thread: follower (unmentioned) gets the ordinary push, non-follower unmentioned none",
              len(env.pushes_to(c)) == 1 and "mention" not in env.pushes_to(c)[0]["data"] and env.pushes_to(d) == [])
        env.clear()
        # online mentioned user: frame and push
        env.add_online(b)
        t = f"thr2 @{name_of(b)}"
        env.send_thread(a, tid, t, mentions=[ment(b, t)])
        fr = [f for f in env.frames(b, "thread_message") if f["body"] == t]
        check("thread: online mentioned user gets the frame with mentions and the push",
              len(fr) == 1 and fr[0].get("mentions") == [{**ment(b, t), "user_id": b, "username": name_of(b)}]
              and len(env.pushes_to(b)) == 1, str(fr) + str(env.pushed))
        env.set_offline(b)
        env.clear()
        set_messages_pref(b, False)
        t = f"thr3 @{name_of(b)}"
        env.send_thread(a, tid, t, mentions=[ment(b, t)])
        check("thread: global messages preference off => no push", env.pushes_to(b) == [])
        set_messages_pref(b, True)
        env.clear()
        block(a, c)
        t = f"thr4 @{name_of(c)}"
        env.send_thread(a, tid, t, mentions=[ment(c, t)])
        check("thread: blocked mention rejected, nothing saved or pushed", env.errors(a)[-1] == INVALID and env.pushes_to(c) == []
              and sql("SELECT COUNT(*) FROM thread_messages WHERE text=%s", (t,))[0][0] == 0)
        unblock_all(a)
        t = f"thr5 @{name_of(outsider)}"
        env.send_thread(a, tid, t, mentions=[ment(outsider, t)])
        check("thread: non-member rejected", env.errors(a)[-1] == INVALID)
        t = "thr6"
        env.send_thread(a, tid, t, mentions=[{"user_id": b, "start": 0, "length": 2}] * 11)
        check("thread: >10 gives mentions_too_many", env.errors(a)[-1] == TOO_MANY)
        t = f"thr7 @{name_of(b)}"
        set_flag(FLAG, "off", a)
        env.clear()
        env.send_thread(a, tid, t, mentions=[ment(b, t)])
        check("thread: flag off ignores mentions (plain message, ordinary push rules)",
              sql("SELECT mentions FROM thread_messages WHERE text=%s", (t,))[0][0] is None and env.pushes_to(b) == [])
        set_flag(FLAG, "on", a)
        # deleted before push
        env.clear()
        t = f"thr8 @{name_of(b)}"
        env.send_thread(a, tid, t, mentions=[ment(b, t)])
        mid = sql("SELECT _id::text FROM thread_messages WHERE text=%s", (t,))[0][0]
        env.clear()
        sql("UPDATE thread_messages SET deleted_at=NOW() WHERE _id=%s", (mid,))
        asyncio.run(thread_send._mention_push(env.manager, b, "tok-" + b[:8], name_of(a), "x", gid, tid, mid, a))
        check("thread: message deleted before the push => skipped", env.pushed == [])
    finally:
        env.close()
        for f in ("threads", FLAG):
            set_flag(f, "off", a)


# ---------------------------------------------------------------- 5b mention push limiter

class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def test_push_limiter(client):
    print("mention push limiter")
    check("constants: 1 per 10s per pair, 20 per 60s per sender",
          (mm.PAIR_MAX_PUSHES, mm.PAIR_WINDOW_SECONDS, mm.SENDER_MAX_PUSHES, mm.SENDER_WINDOW_SECONDS) == (1, 10.0, 20, 60.0))
    clk = Clock()
    lim = mm.MentionPushLimiter(clock=clk)
    s1, s2, r1, r2 = (str(uuid.uuid4()) for _ in range(4))
    check("first mention push allowed", lim.allow(s1, r1))
    check("second within 10s to the same recipient suppressed", not lim.allow(s1, r1))
    check("same recipient, different case of ids, still the same pair", not lim.allow(s1.upper(), r1.upper()))
    check("different recipient allowed (pair limit is per pair)", lim.allow(s1, r2))
    check("a different sender to the same recipient is unaffected", lim.allow(s2, r1))
    clk.t += 9.9
    check("still suppressed just before the window ends", not lim.allow(s1, r1))
    clk.t += 0.2
    check("allowed again after 10s (window expiry)", lim.allow(s1, r1))
    # sender cap: 20 per 60s across recipients
    lim = mm.MentionPushLimiter(clock=clk)
    rs = [str(uuid.uuid4()) for _ in range(25)]
    got = [lim.allow(s1, r) for r in rs]
    check("sender cap: 20 allowed, the rest suppressed", got == [True] * 20 + [False] * 5, str(got))
    check("sender cap does not touch another sender", lim.allow(s2, rs[0]))
    clk.t += 30
    check("sender cap still applies inside 60s", not lim.allow(s1, rs[0]))
    clk.t += 31
    check("sender cap clears after 60s", lim.allow(s1, rs[20]))
    # suppressed pushes are not recorded (do not extend the window)
    lim = mm.MentionPushLimiter(clock=clk)
    lim.allow(s1, r1)
    clk.t += 6
    lim.allow(s1, r1)
    clk.t += 5
    check("a suppressed attempt does not extend the window", lim.allow(s1, r1))
    # memory bounded: many one-off keys are evicted by the periodic sweep
    lim = mm.MentionPushLimiter(clock=clk)
    for i in range(1000):
        lim.allow(f"s{i}", f"r{i}")
    big = lim.size()
    clk.t += 120
    for i in range(mm._SWEEP_EVERY):
        lim.allow("sx", f"rx{i % 2}")
    check("expired keys are evicted (memory bounded)", big == 2000 and lim.size() <= 6, f"{big} -> {lim.size()}")

    # integration: the message always delivers, only the mention push is suppressed
    print("mention push limiter: send paths")
    a, b, c, d = (make_user("ml") for _ in range(4))
    gid = make_group([a, b, c, d])
    for u in (b, c, d):
        token_for(u)
    mute(b, gid)
    env = Env(a)
    env.keep_limit = True
    mm.push_limiter.reset()
    try:
        set_flag(FLAG, "on", a)
        t1 = f"one @{name_of(b)} @{name_of(c)}"
        env.send(a, gid, t1, mentions=[ment(b, t1), ment(c, t1)])
        check("first mention pushes (muted b and offline c)", len(env.pushes_to(b)) == 1 and len(env.pushes_to(c)) == 1
              and env.pushes_to(b)[0]["data"].get("mention") is True)
        env.clear()
        t2 = f"two @{name_of(b)} @{name_of(c)}"
        env.send(a, gid, t2, mentions=[ment(b, t2), ment(c, t2)])
        check("second within 10s: message still stored", stored(t2) is not None and stored(t2)[1] is not None and not env.errors(a))
        check("limited + muted recipient: no push at all (ordinary mute applies)", env.pushes_to(b) == [])
        pc = env.pushes_to(c)
        check("limited + unmuted offline recipient: ordinary push (not a mention)",
              len(pc) == 1 and pc[0]["title"] == name_of(a) and "mention" not in pc[0]["data"], str(pc))
        env.add_online(b)
        env.clear()
        t3 = f"three @{name_of(b)}"
        env.send(a, gid, t3, mentions=[ment(b, t3)])
        fr = [f for f in env.frames(b) if f.get("text") == t3]
        check("limited + online recipient: frame delivered with mentions, no push",
              len(fr) == 1 and fr[0].get("mentions") and env.pushes_to(b) == [], str(env.pushed))
        env.set_offline(b)
        # a different sender is unaffected
        mm.push_limiter.reset()
        env.send(a, gid, f"x @{name_of(b)}", mentions=[ment(b, f"x @{name_of(b)}")])
        env.clear()
        env.send(d, gid, f"from d @{name_of(b)}", mentions=[ment(b, f"from d @{name_of(b)}")])
        check("a different sender's mention push still goes out", len(env.pushes_to(b)) == 1)
        # DM path
        befriend(a, c)
        mm.push_limiter.reset()
        env.clear()
        td = f"dm1 @{name_of(c)}"
        env.send(a, None, td, to=[c], mentions=[ment(c, td)])
        td2 = f"dm2 @{name_of(c)}"
        env.send(a, None, td2, to=[c], mentions=[ment(c, td2)])
        pcs = env.pushes_to(c)
        check("DM: first is a mention push, second (limited) is delivered and pushed as ordinary",
              saved_count(td2) == 1 and len(pcs) == 2 and pcs[0]["data"].get("mention") is True
              and "mention" not in pcs[1]["data"], str(pcs))

        # thread path (additive to the existing thread send rate limit)
        root = make_msg(a, gid, "root")
        tid = make_thread(gid, root, a)
        set_flag("threads", "on", a)
        sql("INSERT INTO thread_followers (thread_id, user_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (tid, c))
        limiter.reset()
        mm.push_limiter.reset()
        env.clear()
        tt1 = f"t1 @{name_of(b)} @{name_of(c)}"
        env.send_thread(a, tid, tt1, mentions=[ment(b, tt1), ment(c, tt1)])
        check("thread: first mention pushes (muted non-follower b and follower c)",
              len(env.pushes_to(b)) == 1 and len(env.pushes_to(c)) == 1)
        env.clear()
        tt2 = f"t2 @{name_of(b)} @{name_of(c)}"
        env.send_thread(a, tid, tt2, mentions=[ment(b, tt2), ment(c, tt2)])
        check("thread: limited message still stored",
              sql("SELECT mentions IS NOT NULL FROM thread_messages WHERE text=%s", (tt2,))[0][0] is True)
        check("thread: limited non-follower gets no push", env.pushes_to(b) == [])
        pc = env.pushes_to(c)
        check("thread: limited follower gets the ordinary push", len(pc) == 1 and pc[0]["title"] == name_of(a)
              and "mention" not in pc[0]["data"], str(pc))
        env.clear()
        env.add_online(c)
        tt3 = f"t3 @{name_of(c)}"
        env.send_thread(a, tid, tt3, mentions=[ment(c, tt3)])
        check("thread: limited online recipient gets the frame and no push",
              any(f.get("body") == tt3 for f in env.frames(c, "thread_message")) and env.pushes_to(c) == [])
    finally:
        env.close()
        mm.push_limiter.reset()
        for f in ("threads", FLAG):
            set_flag(f, "off", a)


# ---------------------------------------------------------------- 6 member list endpoint

def test_mention_members(client):
    print("GET mention-members")
    a, b, c, blk, blk2, susp, outsider = (make_user("mm") for _ in range(7))
    sql("UPDATE users SET username=%s WHERE _id=%s", ("bravo_" + b[:4], b))
    sql("UPDATE users SET username=%s WHERE _id=%s", ("Alpha_" + c[:4], c))
    gid = make_group([a, b, c, blk, blk2, susp, str(uuid.uuid4())])
    block(a, blk)
    block(blk2, a)
    sql("UPDATE users SET suspended_at=NOW() WHERE _id=%s", (susp,))
    ck = cookie(a)
    url = f"/groups/{a}/{gid}/mention-members"
    set_flag(FLAG, "off", a)
    r = client.get(url, headers=ck)
    check("flag off: 404", r.status_code == 404, r.text)
    set_flag(FLAG, "on", a)
    r = client.get(url, headers=ck)
    members = r.json().get("members")
    check("200 with members sorted by lowercase username, canonical ids",
          r.status_code == 200 and [m["user_id"] for m in members] == [c, b]
          and members[0]["username"] == "Alpha_" + c[:4], r.text)
    check("excludes self, blocked either way, suspended, dead ids", all(m["user_id"] not in (a, blk, blk2, susp) for m in members))
    check("each entry is exactly user_id and username", all(set(m) == {"user_id", "username"} for m in members))
    r = client.get(f"/groups/{outsider}/{gid}/mention-members", headers=cookie(outsider))
    check("non-member: 403", r.status_code == 403 and r.json()["detail"] == "Not a member of this group", r.text)
    r = client.get(f"/groups/{a}/{gid}/mention-members", headers=cookie(b))
    check("path user must match the session", r.status_code in (401, 403), r.text)
    r = client.get(f"/groups/{a}/not-a-uuid/mention-members", headers=ck)
    check("malformed group id: 404", r.status_code == 404, r.text)
    r = client.get(f"/groups/{a}/{uuid.uuid4()}/mention-members", headers=ck)
    check("unknown group: no data (403/404)", r.status_code in (403, 404) and "members" not in r.json(), r.text)
    solo = make_group([a])
    r = client.get(f"/groups/{a}/{solo}/mention-members", headers=ck)
    check("alone in the group: empty array", r.status_code == 200 and r.json() == {"members": []}, r.text)
    # same set the validator accepts
    env = Env(a, b)
    try:
        t = f"ok @{name_of(c)}"
        env.send(a, gid, t, mentions=[ment(c, t)])
        check("every listed member is accepted by send validation", stored(t) is not None)
    finally:
        env.close()
        set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 7 purge / restore

def test_purge_restore(client):
    print("purge sweeper and restore frame")
    a, b, c = (make_user("mpr") for _ in range(3))
    gid = make_group([a, b, c])
    env = Env(a)
    from routes.messaging import manager as rest_manager
    fws = {u: FakeWS() for u in (b, c)}
    rest_manager.active_connections.update(fws)
    env.ws.update(fws)
    try:
        flags.set_flag(FLAG, "canary", [a, b], actor=a)
        set_flag("message_delete", "on", a)
        t = f"purge @{name_of(b)}"
        env.send(a, gid, t, mentions=[ment(b, t)])
        mid = stored(t)[0]
        ck = cookie(a)
        r = client.delete(f"/groups/{a}/{gid}/messages/{mid}", headers=ck)
        check("delete ok", r.status_code == 200, r.text)
        check("mentions retained through the undo window", stored(t)[1] is not None)
        env.clear()
        r = client.post(f"/groups/{a}/{gid}/messages/{mid}/restore", headers=ck)
        check("restore ok", r.status_code == 200, r.text)
        fb = [f for f in env.frames(b, "message_restored")]
        fc = [f for f in env.frames(c, "message_restored")]
        check("restore frame carries mentions for a flag-on recipient", fb and fb[0].get("mentions") == [
            {**ment(b, t), "user_id": b, "username": name_of(b)}], str(fb))
        check("restore frame omits mentions for a flag-off recipient", fc and "mentions" not in fc[0], str(fc))
        for u in fws:
            rest_manager.active_connections.pop(u, None)
        sql("UPDATE messages SET deleted_at=NOW()-interval '400 days', deleted_by=from_user WHERE _id=%s", (mid,))
        counts = md.purge_once(batch_size=1000)
        row = sql("SELECT text, mentions FROM messages WHERE _id=%s", (mid,))[0]
        check("purge sweeper clears text and mentions together", row == ("", None) and counts["purged"] >= 1, str((row, counts)))
    finally:
        env.close()
        for f in (FLAG, "message_delete"):
            set_flag(f, "off", a)


def main():
    require_scratch_db()
    client = TestClient(main_module.app)
    try:
        test_ddl_flag_units(client)
        test_validation_group(client)
        test_utf16(client)
        test_validation_dm(client)
        test_flag_off(client)
        test_frames(client)
        test_reads(client)
        test_push_group(client)
        test_push_dm(client)
        test_push_thread(client)
        test_push_limiter(client)
        test_mention_members(client)
        test_purge_restore(client)
    finally:
        for f in ALL_FLAGS:
            try:
                set_flag(f, "off", USERS[0] if USERS else "test")
            except Exception:
                pass
        cleanup()
    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
