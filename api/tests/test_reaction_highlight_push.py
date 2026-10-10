"""Tests for task 20261010-reaction-highlight-push: reaction push to a chat message's
author (flag ``message_reaction_push``) and friend-highlight push (flag
``friend_highlight_push``) plus the per-user ``push-preferences`` setting.

Scratch database only (asserts SHOW port = 55432 first). APNs is replaced by a fake
``send_push`` that records (token, title, body, data); nothing leaves the machine.

Run with: cd api && ../.venv/bin/python tests/test_reaction_highlight_push.py
(locally needs the scratch cluster: FS_SCRATCH_PG_PORT=55432, see fs_scratch_shim)
"""
import _pathfix  # noqa: F401

import asyncio
import logging
import os
import sys
import threading
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from _thr_common import (  # noqa: E402
    PASSED, FAILED, USERS, LogCapture, check, require_scratch_db, sql, make_user, make_group,
    make_msg, cookie, cleanup,
)
from backend.interactions import flags  # noqa: E402
from backend.interactions import message_reactions as mr  # noqa: E402
from backend.interactions import push as push_module  # noqa: E402
from backend.interactions import reaction_highlight_push as rhp  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from schema_ddl.flags import SEED_FLAG_NAMES  # noqa: E402

RFLAG, HFLAG = rhp.REACTION_FLAG, rhp.HIGHLIGHT_FLAG
THUMB, HEART = mr.QUICK_EMOJI[0], mr.QUICK_EMOJI[1]

SENT: list[dict] = []
FAIL_SEND = {"mode": None}  # None | "raise" | "false"


async def fake_send_push(token, title, body, data=None):
    if FAIL_SEND["mode"] == "raise":
        raise RuntimeError("apns down")
    if FAIL_SEND["mode"] == "false":
        return False
    SENT.append({"token": token, "title": title, "body": body, "data": data})
    return True


push_module.send_push = fake_send_push


def set_flag(name, state, actor):
    flags.set_flag(name, state, actor=actor)
    flags.invalidate()


def set_all(state, actor):
    for f in (RFLAG, HFLAG, "message_reactions"):
        set_flag(f, state, actor)


def befriend(a, b):
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s)", (a, b, b, a))


def block(blocker, blocked):
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blocker, blocked))


def token_for(uid):
    tok = f"tok-{uid}"
    sql("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) "
        "ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token", (uid, tok))
    return tok


def react(client, u, m, emoji, ck):
    return client.post(f"/message-reactions/{u}/{m}", json={"emoji": emoji}, headers=ck)


def unreact(client, u, m, emoji, ck):
    return client.delete(f"/message-reactions/{u}/{m}", params={"emoji": emoji}, headers=ck)


def highlight(client, u, ck, verse=16, chapter=3, book="John"):
    return client.post(f"/notes/highlight/{u}", json={
        "book": book, "chapter": chapter, "verse": verse, "color": "yellow"}, headers=ck)


def age_reaction_claim(mid):
    sql("UPDATE message_reaction_push_claims SET last_pushed_at = NOW() - interval '2 minutes' "
        "WHERE message_id=%s", (mid,))


def age_highlight_claims(hid):
    sql("UPDATE friend_highlight_push_claims SET last_pushed_at = NOW() - interval '2 hours' "
        "WHERE highlighter_id=%s", (hid,))


def run_in_threads(n, fn):
    barrier = threading.Barrier(n)
    out, errs = [], []

    def go():
        barrier.wait()
        try:
            out.append(fn())
        except Exception as e:  # noqa: BLE001
            errs.append(e)

    ts = [threading.Thread(target=go) for _ in range(n)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    return out, errs


# --------------------------------------------------------------- 1 flags + ddl

def test_flags_and_ddl(client):
    print("flags / ddl")
    u = make_user("rhp_f")
    ck = cookie(u)
    check("both flags registered", RFLAG in flags.registry() and HFLAG in flags.registry())
    check("both flags in SEED_FLAG_NAMES", RFLAG in SEED_FLAG_NAMES and HFLAG in SEED_FLAG_NAMES)
    rows = dict(sql("SELECT name, state FROM feature_flags WHERE name = ANY(%s)", ([RFLAG, HFLAG],)))
    check("both flags seeded off in the DB", rows.get(RFLAG) == "off" and rows.get(HFLAG) == "off", rows)
    check("flags off for a user by default", not flags.is_enabled(RFLAG, u) and not flags.is_enabled(HFLAG, u))
    feats = client.get("/app/capabilities", headers=ck).json()["features"]
    check("capabilities advertises both flags as false when off",
          feats.get(RFLAG) is False and feats.get(HFLAG) is False, str(feats))
    set_flag(HFLAG, "on", u)
    feats = client.get("/app/capabilities", headers=ck).json()["features"]
    check("capabilities advertises friend_highlight_push true when on", feats.get(HFLAG) is True)
    set_flag(HFLAG, "off", u)
    from db import DBManager
    import db as db_module
    check("DDL module registered", "reaction_highlight_push" in db_module.DDL_MODULES)
    import schema_ddl
    c = DBManager()
    try:
        schema_ddl.apply_modules(c.cur, ["reaction_highlight_push"])
        schema_ddl.apply_modules(c.cur, ["reaction_highlight_push"])
        c.conn.commit()
        ok = True
    except Exception as e:  # noqa: BLE001
        ok = False
        c.conn.rollback()
        print(e)
    finally:
        c.close()
    check("DDL module applies twice (idempotent)", ok)


# --------------------------------------------------------------- 2 reaction push

def test_reaction_push(client):
    print("reaction push")
    a, b, c = make_user("rhp_a"), make_user("rhp_b"), make_user("rhp_c")
    gid = make_group([a, b, c])
    tok_a = token_for(a)
    ck_a, ck_b, ck_c = cookie(a), cookie(b), cookie(c)
    m = make_msg(a, gid)

    # flag off for the author: reaction itself works, no push
    set_flag("message_reactions", "on", a)
    set_flag(RFLAG, "off", a)
    SENT.clear()
    r = react(client, b, m, THUMB, ck_b)
    check("flag off: reaction still succeeds", r.status_code == 200, r.text)
    check("flag off: no push", SENT == [], SENT)
    check("flag off: no claim row consumed", sql("SELECT COUNT(*) FROM message_reaction_push_claims WHERE message_id=%s", (m,))[0][0] == 0)
    unreact(client, b, m, THUMB, ck_b)

    # flag on: push to author
    set_flag(RFLAG, "on", a)
    SENT.clear()
    r = react(client, b, m, HEART, ck_b)
    check("flag on: add succeeds", r.status_code == 200, r.text)
    check("flag on: exactly one push", len(SENT) == 1, SENT)
    if SENT:
        p = SENT[0]
        name_b = sql("SELECT username FROM users WHERE _id=%s", (b,))[0][0]
        check("push goes to the author's token", p["token"] == tok_a)
        check("body is '[Name] reacted <emoji> to your message'",
              p["body"] == f"{name_b} reacted {HEART} to your message", p["body"])
        check("deep link payload action/group_id/message_id",
              p["data"] == {"action": "message_reaction", "group_id": gid, "message_id": m}, p["data"])

    # coalescing: other reactions inside the window stay silent
    SENT.clear()
    react(client, c, m, HEART, ck_c)
    react(client, c, m, THUMB, ck_c)
    react(client, b, m, THUMB, ck_b)
    check("rapid reactions inside the window yield no further push", SENT == [], SENT)
    age_reaction_claim(m)
    SENT.clear()
    unreact(client, c, m, THUMB, ck_c)
    react(client, c, m, THUMB, ck_c)
    check("after the window a new reaction pushes again", len(SENT) == 1, SENT)

    # removal never pushes
    age_reaction_claim(m)
    SENT.clear()
    unreact(client, c, m, THUMB, ck_c)
    unreact(client, b, m, THUMB, ck_b)
    check("removing a reaction sends nothing", SENT == [], SENT)

    # idempotent re-add (changed = false) sends nothing
    age_reaction_claim(m)
    SENT.clear()
    react(client, b, m, HEART, ck_b)  # b already has HEART
    check("idempotent re-add sends nothing", SENT == [], SENT)

    # self reaction
    m2 = make_msg(a, gid)
    SENT.clear()
    r = react(client, a, m2, THUMB, ck_a)
    check("self reaction succeeds", r.status_code == 200, r.text)
    check("self reaction sends no push", SENT == [], SENT)

    # blocked pair, both directions (direct call: the HTTP path 404s a blocked pair)
    d1, d2 = make_user("rhp_d1"), make_user("rhp_d2")
    token_for(d1), token_for(d2)
    g2 = make_group([d1, d2])
    m3, m4 = make_msg(d1, g2), make_msg(d2, g2)
    block(d1, d2)
    SENT.clear()
    asyncio.run(rhp.notify_message_reaction(m3, d2, THUMB, g2))
    asyncio.run(rhp.notify_message_reaction(m4, d1, THUMB, g2))
    check("blocked pair (either direction) sends nothing", SENT == [], SENT)
    check("blocked pair consumed no claim",
          sql("SELECT COUNT(*) FROM message_reaction_push_claims WHERE message_id = ANY(%s::uuid[])", ([m3, m4],))[0][0] == 0)

    # soft-deleted message
    m5 = make_msg(a, gid)
    sql("UPDATE messages SET deleted_at = NOW() WHERE _id=%s", (m5,))
    SENT.clear()
    asyncio.run(rhp.notify_message_reaction(m5, b, THUMB, gid))
    check("soft-deleted message sends nothing", SENT == [], SENT)

    # author with no device token / suspended
    e = make_user("rhp_e")  # no token
    g3 = make_group([e, b])
    m6 = make_msg(e, g3)
    SENT.clear()
    asyncio.run(rhp.notify_message_reaction(m6, b, THUMB, g3))
    check("author without a device token: no push", SENT == [], SENT)
    s = make_user("rhp_s", suspended=True)
    token_for(s)
    g4 = make_group([s, b])
    m7 = make_msg(s, g4)
    SENT.clear()
    asyncio.run(rhp.notify_message_reaction(m7, b, THUMB, g4))
    check("suspended author: no push", SENT == [], SENT)

    # malformed ids fail closed
    SENT.clear()
    asyncio.run(rhp.notify_message_reaction("not-a-uuid", b, THUMB, gid))
    asyncio.run(rhp.notify_message_reaction(m, "nope", THUMB, gid))
    asyncio.run(rhp.notify_message_reaction(m, b, "", gid))
    check("malformed ids / empty emoji: no push, no raise", SENT == [])

    # DM room key payload
    x, y = make_user("rhp_x"), make_user("rhp_y")
    token_for(x)
    mdm = make_msg(x, None, "dm", group=False)
    sql("INSERT INTO message_recipients (message_id, user_id) VALUES (%s,%s)", (mdm, y))
    set_flag("message_reactions", "on", x)
    SENT.clear()
    r = react(client, y, mdm, THUMB, cookie(y))
    check("DM reaction succeeds", r.status_code == 200, r.text)
    check("DM push carries the sorted room key",
          len(SENT) == 1 and SENT[0]["data"]["group_id"] == "|".join(sorted([x, y])), SENT)

    # concurrency: N racers on one fresh message yield exactly one push
    m8 = make_msg(a, gid)
    SENT.clear()
    out, errs = run_in_threads(8, lambda: rhp._prepare_reaction(m8, b, THUMB, gid))
    winners = [o for o in out if o]
    check("8 concurrent reactions claim exactly once", len(winners) == 1 and not errs, (len(winners), errs))

    # send failures never fail the request, and are logged without PII
    m9 = make_msg(a, gid)
    cap = LogCapture()
    logging.getLogger(rhp.__name__).addHandler(cap)
    try:
        for mode in ("raise", "false"):
            FAIL_SEND["mode"] = mode
            sql("DELETE FROM message_reaction_push_claims WHERE message_id=%s", (m9,))
            sql("DELETE FROM message_reactions WHERE message_id=%s", (m9,))
            r = react(client, b, m9, THUMB, ck_b)
            check(f"send_push {mode}: reaction request still 200", r.status_code == 200, r.text)
    finally:
        FAIL_SEND["mode"] = None
        logging.getLogger(rhp.__name__).removeHandler(cap)
    text = " ".join(rec.getMessage() for rec in cap.records)
    name_b = sql("SELECT username FROM users WHERE _id=%s", (b,))[0][0]
    check("failure logs were emitted", "REACTION_PUSH" in text, text)
    check("failure logs carry no names, ids, emoji or tokens",
          not any(s in text for s in (name_b, a, b, m9, THUMB, tok_a)), text)

    # per-recipient flag: author off => nothing, even if flag is on for someone else
    set_flag(RFLAG, "off", a)
    m10 = make_msg(a, gid)
    SENT.clear()
    react(client, b, m10, THUMB, ck_b)
    check("flag off for author again: no push", SENT == [])
    set_flag(RFLAG, "off", a)


# --------------------------------------------------------------- 3 setting API

def test_setting(client):
    print("push-preferences setting")
    a, b = make_user("rhp_pa"), make_user("rhp_pb")
    ck_a, ck_b = cookie(a), cookie(b)
    url = f"/notification/{a}/push-preferences"
    r = client.get(url, headers=ck_a)
    check("default is on (no row)", r.status_code == 200 and r.json() == {"friend_highlight": True}, r.text)
    r = client.put(url, json={"friend_highlight": False}, headers=ck_a)
    check("PUT false persists", r.status_code == 200 and r.json() == {"friend_highlight": False}, r.text)
    check("GET reads false", client.get(url, headers=ck_a).json() == {"friend_highlight": False})
    check("row is stored", sql("SELECT friend_highlight FROM push_preferences WHERE user_id=%s", (a,))[0][0] is False)
    r = client.put(url, json={"friend_highlight": True}, headers=ck_a)
    check("PUT true flips back", r.status_code == 200 and client.get(url, headers=ck_a).json() == {"friend_highlight": True})
    check("anonymous GET refused", client.get(url).status_code in (401, 403))
    check("anonymous PUT refused", client.put(url, json={"friend_highlight": False}).status_code in (401, 403))
    check("other user GET refused", client.get(url, headers=ck_b).status_code in (401, 403))
    r = client.put(url, json={"friend_highlight": False}, headers=ck_b)
    check("other user PUT refused", r.status_code in (401, 403), r.status_code)
    check("other user PUT wrote nothing",
          sql("SELECT friend_highlight FROM push_preferences WHERE user_id=%s", (a,))[0][0] is True)
    for bad in ("false", 0, 1, None, "yes"):
        r = client.put(url, json={"friend_highlight": bad}, headers=ck_a)
        check(f"non-boolean {bad!r} is 422", r.status_code == 422, r.status_code)
    check("missing field is 422", client.put(url, json={}, headers=ck_a).status_code == 422)


# --------------------------------------------------------------- 4 highlight push

def test_highlight_push(client):
    print("friend highlight push")
    h, f1, f2, stranger, blk, blk2, optout, noflag = (
        make_user(p) for p in ("rhp_h", "rhp_f1", "rhp_f2", "rhp_st", "rhp_bl", "rhp_bl2", "rhp_oo", "rhp_nf"))
    ck_h = cookie(h)
    toks = {u: token_for(u) for u in (f1, f2, stranger, blk, blk2, optout, noflag)}
    for u in (f1, f2, blk, blk2, optout, noflag):
        befriend(h, u)
    # a block row left behind with the friendship rows still in place (defense in depth)
    block(blk, h)
    block(h, blk2)
    sql("INSERT INTO push_preferences (user_id, friend_highlight) VALUES (%s, FALSE)", (optout,))
    name_h = sql("SELECT username FROM users WHERE _id=%s", (h,))[0][0]

    # flag off for everyone: no push
    set_flag(HFLAG, "off", h)
    SENT.clear()
    r = highlight(client, h, ck_h)
    check("flag off: highlight succeeds", r.status_code == 200, r.text)
    check("flag off: no push", SENT == [], SENT)
    check("flag off: no claims consumed",
          sql("SELECT COUNT(*) FROM friend_highlight_push_claims WHERE highlighter_id=%s", (h,))[0][0] == 0)

    # canary on for f1 and f2 only: per-recipient evaluation
    flags.set_flag(HFLAG, "canary", canary_user_ids=[f1, f2, blk, blk2, optout, stranger], actor=h)
    flags.invalidate()
    SENT.clear()
    r = highlight(client, h, ck_h)
    check("flag canary: highlight succeeds", r.status_code == 200, r.text)
    got = {s["token"] for s in SENT}
    check("pushes go to exactly the two eligible friends", got == {toks[f1], toks[f2]}, got)
    check("non-friend gets nothing", toks[stranger] not in got)
    check("blocker (block row present) gets nothing", toks[blk] not in got)
    check("blocked-by-highlighter gets nothing", toks[blk2] not in got)
    check("opted-out friend gets nothing", toks[optout] not in got)
    check("friend outside the canary gets nothing", toks[noflag] not in got)
    check("highlighter does not push self", not any(s["token"] == token_for(h) for s in SENT))
    if SENT:
        p = SENT[0]
        check("body is '[Name] highlighted <reference>'", p["body"] == f"{name_h} highlighted John 3:16", p["body"])
        check("deep link payload", p["data"] == {"action": "friend_highlight", "friend_id": h,
                                                 "book": "John", "chapter": 3, "verse": 16}, p["data"])

    # hourly limiter per (highlighter, recipient)
    SENT.clear()
    highlight(client, h, ck_h, verse=17)
    highlight(client, h, ck_h, verse=18)
    check("further highlights within the hour send nothing", SENT == [], SENT)
    age_highlight_claims(h)
    SENT.clear()
    highlight(client, h, ck_h, verse=19)
    check("after the hour each eligible friend is pushed again", len(SENT) == 2, SENT)

    # a second highlighter is limited independently
    h2 = make_user("rhp_h2")
    befriend(h2, f1)
    SENT.clear()
    highlight(client, h2, cookie(h2), verse=1, chapter=1, book="Genesis")
    check("limiter is per highlighter: another highlighter still pushes f1",
          [s["token"] for s in SENT] == [toks[f1]], SENT)

    # opt-out via API then opt back in
    f3 = make_user("rhp_f3")
    t3 = token_for(f3)
    befriend(h, f3)
    flags.set_flag(HFLAG, "canary", canary_user_ids=[f1, f2, f3], actor=h)
    flags.invalidate()
    ck_f3 = cookie(f3)
    r = client.put(f"/notification/{f3}/push-preferences", json={"friend_highlight": False}, headers=ck_f3)
    check("friend opts out via API", r.status_code == 200)
    age_highlight_claims(h)
    SENT.clear()
    highlight(client, h, ck_h, verse=20)
    check("opted-out via API: no push to f3", t3 not in {s["token"] for s in SENT}, SENT)
    client.put(f"/notification/{f3}/push-preferences", json={"friend_highlight": True}, headers=ck_f3)
    age_highlight_claims(h)
    SENT.clear()
    highlight(client, h, ck_h, verse=21)
    check("opted back in: f3 pushed", t3 in {s["token"] for s in SENT}, SENT)

    # invalid reference: 400 and no push
    age_highlight_claims(h)
    SENT.clear()
    r = highlight(client, h, ck_h, book="Notabook", chapter=1, verse=1)
    check("invalid reference is 400", r.status_code == 400, r.text)
    check("invalid reference sends nothing", SENT == [], SENT)

    # highlighter removed/suspended: nothing
    sus = make_user("rhp_sus", suspended=True)
    befriend(sus, f1)
    SENT.clear()
    asyncio.run(rhp.notify_friend_highlight(sus, "John", 3, 16))
    check("suspended highlighter pushes nothing", SENT == [], SENT)
    SENT.clear()
    asyncio.run(rhp.notify_friend_highlight("garbage", "John", 3, 16))
    check("malformed highlighter id: no push, no raise", SENT == [])

    # concurrency: racing fan-outs claim each pair once
    h3 = make_user("rhp_h3")
    race = [make_user(f"rhp_r{i}") for i in range(3)]
    for r_ in race:
        token_for(r_)
        befriend(h3, r_)
    flags.set_flag(HFLAG, "canary", canary_user_ids=race, actor=h3)
    flags.invalidate()
    out, errs = run_in_threads(6, lambda: rhp._prepare_highlights(h3, "John", 3, 16))
    total = sum(len(o) for o in out)
    check("6 concurrent fan-outs deliver exactly one push per recipient", total == 3 and not errs, (total, errs))

    # fan-out cap
    h4 = make_user("rhp_h4")
    many = [make_user(f"rhp_m{i}") for i in range(5)]
    for m_ in many:
        token_for(m_)
        befriend(h4, m_)
    flags.set_flag(HFLAG, "canary", canary_user_ids=many, actor=h4)
    flags.invalidate()
    old = rhp.MAX_FRIEND_RECIPIENTS
    rhp.MAX_FRIEND_RECIPIENTS = 2
    try:
        batch = rhp._prepare_highlights(h4, "John", 3, 16)
    finally:
        rhp.MAX_FRIEND_RECIPIENTS = old
    check("fan-out is capped at MAX_FRIEND_RECIPIENTS", len(batch) == 2, len(batch))

    # send failures never fail the request; logs carry no PII
    for mode in ("raise", "false"):
        FAIL_SEND["mode"] = mode
        age_highlight_claims(h)
        cap = LogCapture()
        logging.getLogger(rhp.__name__).addHandler(cap)
        try:
            flags.set_flag(HFLAG, "canary", canary_user_ids=[f1, f2], actor=h)
            flags.invalidate()
            r = highlight(client, h, ck_h, verse=22)
        finally:
            FAIL_SEND["mode"] = None
            logging.getLogger(rhp.__name__).removeHandler(cap)
        text = " ".join(rec.getMessage() for rec in cap.records)
        check(f"send_push {mode}: highlight request still 200", r.status_code == 200, r.text)
        check(f"send_push {mode}: logs have no names/ids/reference/tokens",
              not any(s in text for s in (name_h, h, f1, f2, "John", toks[f1])), text)

    set_flag(HFLAG, "off", h)


def main():
    require_scratch_db()
    client = TestClient(main_module.app)
    actor = make_user("rhp_actor")
    try:
        test_flags_and_ddl(client)
        for fn in (test_reaction_push, test_setting, test_highlight_push):
            limiter.reset()
            fn(client)
    finally:
        for f in (RFLAG, HFLAG, "message_reactions"):
            try:
                set_flag(f, "off", actor)
            except Exception:
                pass
        cleanup()
    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        sys.exit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
