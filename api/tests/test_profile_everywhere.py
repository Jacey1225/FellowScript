"""Task 20261030-profile-everywhere, step 14: sender id on paged history rows and
the recipient-only friend-request Decline.

Proves (each would catch a regression of the specific change):
  A. from_user_id (additive, lowercase UUID) is on PAGED group, PAGED DM and thread
     rows for live authors only; absent when the author did not resolve to a live
     users row; a blocked author's rows are still absent from the page (so their id
     is never exposed); no email / bio / hash key rides along; every pre-existing
     key keeps its name; the legacy unpaged group and DM payloads are unchanged.
  B. POST /friends/{user_id}/requests/{sender_id}/decline: 204 with an identical
     empty body for unknown / malformed / blocked / suspended / no-request / repeat;
     recipient-only (path user != session -> 403, nothing deleted; 401 without a
     session); only the caller's pending row from that sender is deleted (the
     caller's outgoing request and other senders' requests are untouched); no
     friendship or block is created; 429 (generic body) on the 61st call in an hour;
     a re-request after decline works; the audit log line names neither the sender
     nor any username; config validation rejects a profile.json without
     friend_decline_hour.

Scratch database only (SHOW port = 55432, or 5432 under GITHUB_ACTIONS).
Run with: cd api && ../.venv/bin/python tests/test_profile_everywhere.py
"""
import _pathfix  # noqa: F401
from _thr_common import (  # noqa: F401
    FAILED, PASSED, LogCapture, add_tmsg, check, cleanup, cookie, finish, make_group, make_msg,
    make_thread, make_user, require_scratch_db, set_flag, sql,
)

import json
import logging
import os
import tempfile
import uuid
from datetime import datetime, timedelta, timezone

os.environ["TRIAL_MONTHS"] = "0"

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from backend.config_loader import ConfigSectionError  # noqa: E402
from backend.interactions import profile_config as pc_mod  # noqa: E402
from backend.interactions import profile_limits as pl  # noqa: E402
from backend.interactions.message_sender_id import dm_sender_id_entry, sender_id_entry  # noqa: E402
from backend.interactions.profile_config import RATE_KEYS  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402

PRIVATE_KEYS = {"email", "bio", "hash_pass", "password", "phone", "profile_photo_url"}
PAGE_KEYS_OLD = ["id", "from_user", "mine", "text", "timestamp", "attachment_kind", "attachment_meta", "attachment_url"]


def reset_limits():
    limiter.limiter.storage.reset()
    pl.reset_for_tests()


def insert_group_msg(author, gid, text, ts):
    mid = str(uuid.uuid4())
    sql("INSERT INTO messages (_id, from_user, group_id, text, timestamp) VALUES (%s,%s,%s,%s,%s)",
        (mid, author, gid, text, ts))
    return mid


def insert_dm(author, to, text, ts):
    mid = str(uuid.uuid4())
    sql("INSERT INTO messages (_id, from_user, group_id, text, timestamp) VALUES (%s,%s,NULL,%s,%s)",
        (mid, author, text, ts))
    sql("INSERT INTO message_recipients (message_id, user_id) VALUES (%s,%s)", (mid, to))
    return mid


def befriend(a, b):
    for x, y in ((a, b), (b, a)):
        sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (x, y))


def block(blocker, blocked):
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (blocker, blocked))


def old_keys_intact(row, base_keys):
    return [k for k in row if k != "from_user_id"] == base_keys


# ---------------------------------------------------------------- A. pure helper

def test_helper():
    print("A0. sender_id_entry / dm_sender_id_entry (pure)")
    u1 = str(uuid.uuid4())
    check("resolved author -> id", sender_id_entry(u1, {u1: "alice"}) == {"from_user_id": u1})
    check("uppercase input is lowercased", sender_id_entry(u1.upper(), {u1.upper(): "alice"}) == {"from_user_id": u1})
    check("author not in lookup -> no key", sender_id_entry(u1, {}) == {})
    check("None author -> no key", sender_id_entry(None, {u1: "a"}) == {})
    check("empty author -> no key", sender_id_entry("", {"": "a"}) == {})
    me, peer = str(uuid.uuid4()), str(uuid.uuid4())
    check("DM mine -> caller id", dm_sender_id_entry(True, me, peer) == {"from_user_id": me})
    check("DM theirs -> peer id", dm_sender_id_entry(False, me, peer) == {"from_user_id": peer})
    check("DM ids lowercased", dm_sender_id_entry(False, me, peer.upper()) == {"from_user_id": peer})


# ---------------------------------------------------------------- A. group

def test_group(client):
    print("A1. paged group rows")
    host, other, blocked, outsider = (make_user(f"pe{i}") for i in range(4))
    gid = make_group([host, other, blocked])
    block(host, blocked)
    ck = cookie(host)
    ts = datetime.now(timezone.utc) - timedelta(hours=1)
    try:
        insert_group_msg(host, gid, "from-host", ts)
        insert_group_msg(other, gid, "from-other", ts + timedelta(seconds=1))
        insert_group_msg(blocked, gid, "from-blocked", ts + timedelta(seconds=2))
        insert_group_msg(outsider, gid, "from-nonmember", ts + timedelta(seconds=3))
        set_flag("chat_pagination", "on", host)
        r = client.get(f"/groups/{host}/{gid}/messages", params={"limit": "10"}, headers=ck)
        rows = r.json().get("messages", []) if r.status_code == 200 else []
        by_text = {m["text"]: m for m in rows}
        check("older-page route 200", r.status_code == 200, r.text[:200])
        check("host row carries own id", by_text.get("from-host", {}).get("from_user_id") == host)
        check("other row carries other's id", by_text.get("from-other", {}).get("from_user_id") == other)
        check("ids are lowercase uuid strings", all(m["from_user_id"] == str(uuid.UUID(m["from_user_id"])) for m in rows))
        check("blocked author's row is absent from the page", "from-blocked" not in by_text)
        check("blocked author's id appears nowhere in the response", blocked not in r.text and blocked.upper() not in r.text)
        check("non-member row is absent", "from-nonmember" not in by_text)
        check("outsider id appears nowhere", outsider not in r.text)
        check("old keys unchanged in name and order", all(old_keys_intact(m, PAGE_KEYS_OLD) for m in rows))
        check("from_user_id sits right after from_user", all(list(m)[:3] == ["id", "from_user", "from_user_id"] for m in rows))
        check("no private user keys on any row", all(not (PRIVATE_KEYS & set(m)) for m in rows))
        check("only the id is added (no extra new key)", all(set(m) - set(PAGE_KEYS_OLD) == {"from_user_id"} for m in rows))
        check("response never contains an email", "@example.com" not in r.text)

        # first page via the group route, flag + limit opt-in
        r1 = client.get(f"/groups/{host}/{gid}", params={"limit": "10"}, headers=ck)
        first = r1.json().get("messages", []) if r1.status_code == 200 else None
        check("group first page rows carry ids", bool(first) and all("from_user_id" in m for m in first), str(first)[:200])

        # legacy unpaged format must not grow the key
        set_flag("chat_pagination", "off", host)
        r2 = client.get(f"/groups/{host}/{gid}", headers=ck)
        b2 = r2.json() if r2.status_code == 200 else {}
        legacy = (b2.get("host_msgs") or []) + (b2.get("other_msgs") or [])
        check("legacy (flag off) group rows are unchanged: no from_user_id",
              bool(legacy) and all("from_user_id" not in m for m in legacy), str(legacy)[:200])
    finally:
        set_flag("chat_pagination", "off", host)


# ---------------------------------------------------------------- A. DM

def test_dm(client):
    print("A2. paged DM rows")
    me, friend, stranger = (make_user(f"pd{i}") for i in range(3))
    befriend(me, friend)
    ck = cookie(me)
    ts = datetime.now(timezone.utc) - timedelta(hours=1)
    try:
        insert_dm(me, friend, "dm-mine", ts)
        insert_dm(friend, me, "dm-theirs", ts + timedelta(seconds=1))
        insert_dm(stranger, me, "dm-stranger", ts + timedelta(seconds=2))
        set_flag("chat_pagination_dm", "on", me)
        r = client.get(f"/friends/{me}/{friend}/messages", params={"limit": "10"}, headers=ck)
        rows = r.json().get("messages", []) if r.status_code == 200 else []
        by_text = {m["text"]: m for m in rows}
        check("DM older-page route 200", r.status_code == 200, r.text[:200])
        check("my DM row carries my id", by_text.get("dm-mine", {}).get("from_user_id") == me)
        check("peer DM row carries the peer id", by_text.get("dm-theirs", {}).get("from_user_id") == friend)
        check("stranger's DM is not on the page and its id is not exposed",
              "dm-stranger" not in by_text and stranger not in r.text)
        check("DM old keys unchanged", all(old_keys_intact(m, PAGE_KEYS_OLD) for m in rows))
        check("DM rows add only from_user_id", all(set(m) - set(PAGE_KEYS_OLD) == {"from_user_id"} for m in rows))
        check("DM rows have no private keys", all(not (PRIVATE_KEYS & set(m)) for m in rows))

        r1 = client.get(f"/friends/{me}/{friend}", params={"limit": "10"}, headers=ck)
        first = r1.json().get("messages", []) if r1.status_code == 200 else None
        check("DM first page rows carry ids", bool(first) and all(m.get("from_user_id") in (me, friend) for m in first),
              str(first)[:200])

        # a blocked friend: the whole DM read is refused, no id leaks
        block(me, friend)
        rb = client.get(f"/friends/{me}/{friend}/messages", params={"limit": "10"}, headers=ck)
        check("blocked peer: 404 and no ids", rb.status_code == 404 and friend not in rb.text, f"{rb.status_code} {rb.text[:120]}")
        sql("DELETE FROM blocked_users WHERE blocker_id=%s AND blocked_id=%s", (me, friend))

        # legacy unpaged DM payload unchanged
        set_flag("chat_pagination_dm", "off", me)
        r2 = client.get(f"/friends/{me}/{friend}", headers=ck)
        body = r2.json() if r2.status_code == 200 else {}
        legacy = (body.get("host_msgs") or []) + (body.get("other_msgs") or [])
        check("legacy DM host_msgs/other_msgs have no from_user_id",
              r2.status_code == 200 and bool(legacy) and all("from_user_id" not in m for m in legacy), str(legacy)[:200])
    finally:
        set_flag("chat_pagination_dm", "off", me)


# ---------------------------------------------------------------- A. thread

def test_thread(client):
    print("A3. thread rows")
    a, b, blocked = (make_user(f"pt{i}") for i in range(3))
    gid = make_group([a, b, blocked], creator=a)
    block(a, blocked)
    root = make_msg(a, gid, "root")
    tid = make_thread(gid, root, a)
    try:
        add_tmsg(tid, a, "t-from-a")
        add_tmsg(tid, b, "t-from-b")
        add_tmsg(tid, blocked, "t-from-blocked")
        set_flag("threads", "on", a)
        r = client.get(f"/groups/{a}/{gid}/threads/{tid}/messages", headers=cookie(a))
        rows = r.json().get("messages", []) if r.status_code == 200 else []
        by_text = {m["text"]: m for m in rows}
        check("thread read 200", r.status_code == 200, r.text[:200])
        check("thread row from a carries a's id", by_text.get("t-from-a", {}).get("from_user_id") == a)
        check("thread row from b carries b's id", by_text.get("t-from-b", {}).get("from_user_id") == b)
        check("blocked author's thread row absent and id not exposed", "t-from-blocked" not in by_text and blocked not in r.text)
        check("thread rows add only from_user_id and no private keys",
              all(not (PRIVATE_KEYS & set(m)) for m in rows) and all("from_user_id" in m for m in rows))
        check("thread row keeps from_user and thread_id", all("from_user" in m and m.get("thread_id") == tid for m in rows))
    finally:
        set_flag("threads", "off", a)


# ---------------------------------------------------------------- B. decline

def decline(client, caller, sender, ck=None, path_user=None):
    return client.post(f"/friends/{path_user or caller}/requests/{sender}/decline",
                       headers=ck if ck is not None else cookie(caller))


def pending(frm, to):
    return sql("SELECT COUNT(*) FROM friend_requests WHERE from_user_id=%s AND to_user_id=%s", (frm, to))[0][0]


def test_decline(client):
    print("B. decline")
    me, s1, s2, blocked_s, outsider = (make_user(f"pk{i}") for i in range(5))
    # suspended sender: make_user(suspended=True) sets suspended_at
    susp = make_user("pks", suspended=True)
    sql("INSERT INTO friend_requests (to_user_id, from_user_id) VALUES (%s,%s)", (me, s1))
    sql("INSERT INTO friend_requests (to_user_id, from_user_id) VALUES (%s,%s)", (me, s2))
    sql("INSERT INTO friend_requests (to_user_id, from_user_id) VALUES (%s,%s)", (s1, me))  # my outgoing to s1
    sql("INSERT INTO friend_requests (to_user_id, from_user_id) VALUES (%s,%s)", (me, blocked_s))
    sql("INSERT INTO friend_requests (to_user_id, from_user_id) VALUES (%s,%s)", (me, susp))
    block(me, blocked_s)
    ck = cookie(me)
    reset_limits()

    print("B1. uniform 204")
    base = decline(client, me, uuid.uuid4())
    check("unknown uuid -> 204 empty body", base.status_code == 204 and base.content == b"", f"{base.status_code} {base.text}")
    outcomes = {
        "malformed id": decline(client, me, "not-a-uuid"),
        "numeric id": decline(client, me, "12345"),
        "uuid-shaped with extra chars": decline(client, me, str(uuid.uuid4()) + "zz"),
        "oversized id": decline(client, me, "a" * 300),
        "no pending request (outsider)": decline(client, me, outsider),
        "blocked sender": decline(client, me, blocked_s),
        "suspended sender": decline(client, me, susp),
        "own id": decline(client, me, me),
    }
    for label, r in outcomes.items():
        check(f"{label} -> identical 204/empty/headers",
              r.status_code == 204 and r.content == b"" and r.headers.get("content-type") == base.headers.get("content-type"),
              f"{r.status_code} {r.text[:80]}")
    check("blocked sender's row addressed to me is simply removed (no oracle, same 204)", pending(blocked_s, me) == 0)
    check("suspended sender's row addressed to me is removed", pending(susp, me) == 0)

    print("B2. effect scope")
    check("precondition: s1 and s2 requests pending", pending(s1, me) == 1 and pending(s2, me) == 1)
    r = decline(client, me, s1)
    check("decline s1 -> 204", r.status_code == 204)
    check("s1's request to me deleted", pending(s1, me) == 0)
    check("my outgoing request to s1 untouched", pending(me, s1) == 1)
    check("s2's request to me untouched", pending(s2, me) == 1)
    check("no friendship created", sql("SELECT COUNT(*) FROM user_friends WHERE (user_id=%s AND friend_id=%s) OR (user_id=%s AND friend_id=%s)", (me, s1, s1, me))[0][0] == 0)
    check("no block created against the sender", sql("SELECT COUNT(*) FROM blocked_users WHERE blocked_id=%s", (s1,))[0][0] == 0)
    r = decline(client, me, s1)
    check("repeat decline -> same 204", r.status_code == 204 and r.content == b"")
    check("repeat leaves outgoing and s2 rows alone", pending(me, s1) == 1 and pending(s2, me) == 1)

    print("B3. recipient-only / auth")
    # s2 (the sender) cannot decline on the recipient's behalf by using the recipient's path id
    r = client.post(f"/friends/{me}/requests/{s2}/decline", headers=cookie(s2))
    check("path user != session -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
    check("403 deleted nothing", pending(s2, me) == 1)
    # sender cannot cancel via the decline route using their own id as caller
    r = client.post(f"/friends/{s2}/requests/{me}/decline", headers=cookie(s2))
    check("sender 'declining' their own outgoing request is a 204 no-op for a different row", r.status_code == 204)
    sql("INSERT INTO friend_requests (to_user_id, from_user_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (s2, me))
    r = client.post(f"/friends/{s2}/requests/{me}/decline", headers=cookie(s2))
    check("recipient can only delete rows addressed to them: s2 declining 'me' removes me->s2, not s2->me",
          r.status_code == 204 and pending(me, s2) == 0 and pending(s2, me) == 1)
    r = TestClient(main_module.app).post(f"/friends/{me}/requests/{s2}/decline")
    check("no session -> 401", r.status_code == 401, str(r.status_code))
    check("401 deleted nothing", pending(s2, me) == 1)

    print("B4. re-request after decline")
    sql("UPDATE users SET terms_accepted_at = NOW() WHERE _id = ANY(%s::uuid[])", ([me, s2],))
    reset_limits()
    r = decline(client, me, s2)
    check("decline s2 -> 204 and row gone", r.status_code == 204 and pending(s2, me) == 0)
    s2name = sql("SELECT username FROM users WHERE _id=%s", (s2,))[0][0]
    mename = sql("SELECT username FROM users WHERE _id=%s", (me,))[0][0]
    rr = client.post(f"/friends/{s2}/request", params={"friend_username": mename}, headers=cookie(s2))
    check("sender can re-request immediately (no cooldown)", rr.status_code == 200 and pending(s2, me) == 1,
          f"{rr.status_code} {rr.text[:150]}")
    reset_limits()
    r = decline(client, me, s2)
    check("and the re-request can be declined again", r.status_code == 204 and pending(s2, me) == 0)

    print("B5. log hygiene")
    cap = LogCapture()
    lg = logging.getLogger()
    lg.addHandler(cap)
    old_level = lg.level
    lg.setLevel(logging.DEBUG)
    sql("INSERT INTO friend_requests (to_user_id, from_user_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (me, s2))
    try:
        decline(client, me, s2)
        decline(client, me, uuid.uuid4())
    finally:
        lg.removeHandler(cap)
        lg.setLevel(old_level)
    msgs = [rec.getMessage() for rec in cap.records if "friend_declin" in rec.getMessage()]
    check("one audit line per call", len(msgs) == 2, str(msgs))
    check("audit line has actor id and no sender id or username",
          all(me in m and s2 not in m and s2name not in m and mename not in m for m in msgs), str(msgs))
    check("audit line identical in shape whether or not a row existed",
          len({m.replace(me, "ME") for m in msgs}) == 1, str(msgs))

    print("B6. rate limit")
    reset_limits()
    codes = [decline(client, me, uuid.uuid4(), ck=ck).status_code for _ in range(61)]
    check("calls 1-60 are 204", codes[:60] == [204] * 60, str(set(codes[:60])))
    check("61st call is 429", codes[60] == 429, str(codes[60]))
    r = decline(client, me, uuid.uuid4(), ck=ck)
    check("429 body is generic (no ids or names)", r.status_code == 429 and me not in r.text and "friend" not in r.text.lower(), r.text[:150])
    reset_limits()
    check("limit is per user: another user is unaffected",
          decline(client, outsider, uuid.uuid4()).status_code == 204)
    reset_limits()


# ---------------------------------------------------------------- B. config

def test_config():
    print("B7. profile config validation")
    check("friend_decline_hour is a required rate key", "friend_decline_hour" in RATE_KEYS)
    cfg = pc_mod.get_profile_config()
    check("shipped config carries friend_decline_hour 60/hour", cfg.rate_limits.get("friend_decline_hour") == "60/hour")
    orig = pc_mod.CONFIG_PATH
    good = json.loads(open(orig).read())

    def load_with(mutator):
        data = json.loads(json.dumps(good))
        mutator(data["profile"])
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(data, f)
        pc_mod.CONFIG_PATH = type(orig)(f.name)
        try:
            pc_mod._load()
            return None
        except ConfigSectionError as e:
            return e
        finally:
            pc_mod.CONFIG_PATH = orig
            os.unlink(f.name)

    check("good config loads", load_with(lambda p: None) is None)
    check("missing friend_decline_hour rejected at startup",
          load_with(lambda p: p["rate_limits"].pop("friend_decline_hour")) is not None)
    check("garbage friend_decline_hour rejected",
          load_with(lambda p: p["rate_limits"].__setitem__("friend_decline_hour", "lots")) is not None)


def main():
    require_scratch_db()
    pc_mod.set_profile_config_for_tests(None)
    client = TestClient(main_module.app)
    try:
        test_helper()
        test_group(client)
        test_dm(client)
        test_thread(client)
        test_decline(client)
        test_config()
    finally:
        finish(("threads", "chat_pagination", "chat_pagination_dm"))


if __name__ == "__main__":
    main()
