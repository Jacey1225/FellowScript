"""Tests for task 20261010-chat-reactions, step 2: chat message emoji reactions
(flag ``message_reactions``).

Scratch database only (asserts SHOW port = 55432 first). Proves:
  * DDL module ``message_reactions``: applies twice, registered in DDL_MODULES after
    chat_pagination and threads, PK is (message_id, user_id, emoji) so a duplicate is
    refused, hard-deleting a message or a user cascades its rows, soft delete keeps them
  * flag ``message_reactions`` is registered, seeded off, and off means: add/remove are
    the same uniform 404 as an unknown id with NO write, every history/page payload omits
    ``reactions``, capabilities exposes an empty emoji list
  * add/remove: authenticated (401/403 anonymous, 403 path-user mismatch), idempotent (second
    add/remove changes nothing and sends no frame), returns {emoji,count,viewer_reacted},
    emoji outside the allowlist (skin-tone / variation variants, multi-emoji, oversized,
    empty, text) is 422 on both verbs, add needs current terms but remove does not
  * deny-by-default visibility, ONE uniform 404 body for: non-member, ex-member, DM
    non-participant, blocked pair (either direction, group and DM), soft-deleted message,
    unknown and malformed ids; users may react to their own messages
  * caps: 10 distinct per user per message and 20 distinct per message are 409 with the
    cap code; re-adding an existing reaction at the cap is still idempotent 200; joining
    an existing emoji at the message cap is allowed
  * payloads (flag on): aggregated {emoji,count,viewer_reacted} per viewer on the legacy
    group and DM readers, the paged group and DM readers (``chat_pagination``,
    ``chat_pagination_dm`` on); messages without reactions carry ``reactions: []``;
    ONE batch call per request regardless of page size (no N+1); soft-deleted messages
    show no reactions and undo/restore brings them back
  * websocket: ``reaction_updated`` {type,message_id,group_id,emoji,count,actor_id} reaches
    live members only, never the actor, a user blocked with the actor or with the message
    author, or a non-member; carries neither ``from_user`` nor ``text`` (old clients
    ignore it); sent only when state changed; remove sends count 0; DM frames use the
    sorted ``a|b`` room key; a dead socket never fails the request
  * rate limit: per-user shared bucket returns 429 past the configured rate
Run with: cd api && ../.venv/bin/python tests/test_message_reactions.py
(locally needs the scratch cluster: FS_SCRATCH_PG_PORT=55432, see fs_scratch_shim)
"""
import _pathfix  # noqa: F401

import asyncio
import os
import sys
import uuid

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
    cookie, cleanup,
)
from backend.interactions import flags  # noqa: E402
from backend.interactions import message_reactions as mr  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from routes.messaging import manager as ws_manager  # noqa: E402
from schema_ddl import message_reactions as ddl  # noqa: E402

THUMB, HEART, LAUGH = mr.QUICK_EMOJI[0], mr.QUICK_EMOJI[1], mr.QUICK_EMOJI[2]
FLAG = "message_reactions"
ALL_FLAGS = (FLAG, "chat_pagination", "chat_pagination_dm", "message_delete")


class FakeWS:
    def __init__(self, fail=False):
        self.sent = []
        self.fail = fail

    async def send_json(self, payload):
        if self.fail:
            raise RuntimeError("socket gone")
        self.sent.append(payload)


def set_flag(name, state, actor):
    flags.set_flag(name, state, actor=actor)
    flags.invalidate()


def url(u, m):
    return f"/message-reactions/{u}/{m}"


def add(client, u, m, emoji, ck):
    return client.post(url(u, m), json={"emoji": emoji}, headers=ck)


def rem(client, u, m, emoji, ck):
    return client.delete(url(u, m), params={"emoji": emoji}, headers=ck)


def row_count(mid, emoji=None):
    if emoji is None:
        return sql("SELECT COUNT(*) FROM message_reactions WHERE message_id=%s", (mid,))[0][0]
    return sql("SELECT COUNT(*) FROM message_reactions WHERE message_id=%s AND emoji=%s", (mid, emoji))[0][0]


def befriend(a, b):
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s)", (a, b, b, a))


def make_dm(author, to, text="dm text"):
    mid = make_msg(author, None, text, group=False)
    sql("INSERT INTO message_recipients (message_id, user_id) VALUES (%s,%s)", (mid, to))
    return mid


def block(blocker, blocked):
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blocker, blocked))


def unblock_all(*uids):
    for u in uids:
        sql("DELETE FROM blocked_users WHERE blocker_id=%s OR blocked_id=%s", (u, u))


def reactions_of(payload_msgs, mid):
    for m in payload_msgs:
        if m.get("id") == mid:
            return m
    return None


def all_msgs(body):
    """Flatten any history shape into one list of message dicts."""
    p = body.get("payload", body)
    out = []
    for k in ("host_msgs", "other_msgs", "messages"):
        out += p.get(k) or []
    return out


# ---------------------------------------------------------------- 1 DDL / flag

def test_ddl_and_flag():
    print("DDL module and flag")
    d = DBManager()
    try:
        ddl.apply(d.cur)
        ddl.apply(d.cur)
        d.conn.commit()
        check("DDL module applies twice without error", True)
        mods = list(db_module.DDL_MODULES)
        check("registered in DDL_MODULES after chat_pagination and threads",
              "message_reactions" in mods and mods.index("message_reactions") > mods.index("chat_pagination")
              and mods.index("message_reactions") > mods.index("threads"), str(mods))
        d.cur.execute(
            "SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum = ANY(i.indkey) "
            "WHERE i.indrelid='message_reactions'::regclass AND i.indisprimary")
        check("primary key is (message_id, user_id, emoji)",
              {r[0] for r in d.cur.fetchall()} == {"message_id", "user_id", "emoji"})
        d.cur.execute(
            "SELECT confrelid::regclass::text, confdeltype FROM pg_constraint "
            "WHERE conrelid='message_reactions'::regclass AND contype='f' ORDER BY 1")
        fks = d.cur.fetchall()
        check("FKs to messages and users are ON DELETE CASCADE",
              [(a, b) for a, b in fks] == [("messages", "c"), ("users", "c")], str(fks))
        d.cur.execute("SELECT 1 FROM pg_indexes WHERE tablename='message_reactions' AND indexname='idx_message_reactions_user'")
        check("user index exists", d.cur.fetchone() is not None)
    finally:
        d.close()

    u1, u2 = make_user("rxd1"), make_user("rxd2")
    gid = make_group([u1, u2])
    m = make_msg(u1, gid)
    sql("INSERT INTO message_reactions (message_id, user_id, emoji) VALUES (%s,%s,%s)", (m, u1, THUMB))
    dup_refused = False
    try:
        sql("INSERT INTO message_reactions (message_id, user_id, emoji) VALUES (%s,%s,%s)", (m, u1, THUMB))
    except Exception as e:  # noqa: BLE001
        dup_refused = "duplicate key" in str(e)
    check("duplicate (message, user, emoji) refused by the primary key", dup_refused)
    sql("INSERT INTO message_reactions (message_id, user_id, emoji) VALUES (%s,%s,%s), (%s,%s,%s)",
        (m, u1, HEART, m, u2, THUMB))
    check("same emoji by another user and another emoji by same user are separate rows", row_count(m) == 3)
    sql("UPDATE messages SET deleted_at = NOW(), deleted_by = %s WHERE _id=%s", (u1, m))
    check("soft delete keeps reaction rows", row_count(m) == 3)
    sql("DELETE FROM messages WHERE _id=%s", (m,))
    check("hard-deleting the message cascades its reactions", row_count(m) == 0)
    m2 = make_msg(u1, gid)
    sql("INSERT INTO message_reactions (message_id, user_id, emoji) VALUES (%s,%s,%s)", (m2, u2, THUMB))
    sql("DELETE FROM message_reactions WHERE user_id=%s", (u2,))  # control: row-level delete works
    sql("INSERT INTO message_reactions (message_id, user_id, emoji) VALUES (%s,%s,%s)", (m2, u2, THUMB))
    sql("DELETE FROM groups WHERE _id=%s", (gid,))
    sql("DELETE FROM users WHERE _id=%s", (u2,))
    check("deleting a user cascades their reactions", row_count(m2) == 0)

    check("flag registered", FLAG in flags._REGISTRY)
    row = sql("SELECT state FROM feature_flags WHERE name=%s", (FLAG,))
    check("flag row is seeded and off", bool(row) and row[0][0] == "off", str(row))
    flags.invalidate()
    check("flag is off for a user by default", flags.is_enabled(FLAG, u1) is False)


# ---------------------------------------------------------------- 2 flag off

def test_flag_off(client):
    print("flag off")
    a, b = make_user("rxo1"), make_user("rxo2")
    gid = make_group([a, b])
    m = make_msg(b, gid)
    ck = cookie(a)
    set_flag(FLAG, "off", a)
    r = add(client, a, m, THUMB, ck)
    unknown = add(client, a, str(uuid.uuid4()), THUMB, ck)
    check("flag off: add is 404 identical to unknown id", r.status_code == 404 and r.json() == unknown.json(), r.text)
    check("flag off: no row written", row_count(m) == 0)
    r = rem(client, a, m, THUMB, ck)
    check("flag off: remove 404", r.status_code == 404)
    # existing rows must not leak through payloads while the flag is off
    sql("INSERT INTO message_reactions (message_id, user_id, emoji) VALUES (%s,%s,%s)", (m, b, THUMB))
    for f in ("chat_pagination", "chat_pagination_dm"):
        set_flag(f, "on", a)
    for label, resp in (
        ("legacy group history", client.get(f"/groups/{a}/{gid}", headers=ck)),
        ("paged group first page", client.get(f"/groups/{a}/{gid}", params={"limit": "5"}, headers=ck)),
        ("paged group endpoint", client.get(f"/groups/{a}/{gid}/messages", params={"limit": "5"}, headers=ck)),
    ):
        msgs = all_msgs(resp.json())
        found = reactions_of(msgs, m)
        check(f"flag off: {label} 200 with the message but no ``reactions`` key",
              resp.status_code == 200 and found is not None and "reactions" not in found, resp.text[:200])
    cap = client.get("/app/capabilities", headers=ck).json()
    check("flag off: capabilities reaction_emoji is empty lists",
          cap.get("reaction_emoji") == {"quick": [], "more": []}, str(cap.get("reaction_emoji")))
    check("flag off: capabilities features flag false", cap["features"].get(FLAG) is False, str(cap["features"]))
    for f in ("chat_pagination", "chat_pagination_dm"):
        set_flag(f, "off", a)


# ---------------------------------------------------------------- 3 add/remove

def test_add_remove(client):
    print("add / remove")
    a, b, out, exm = (make_user(f"rxa{i}") for i in range(4))
    gid = make_group([a, b, exm])
    m_b = make_msg(b, gid)
    m_a = make_msg(a, gid)
    ck, ck_b, ck_out, ck_ex = cookie(a), cookie(b), cookie(out), cookie(exm)
    set_flag(FLAG, "on", a)
    cap = client.get("/app/capabilities", headers=ck).json()
    check("flag on: capabilities exposes quick + more lists",
          cap["reaction_emoji"] == {"quick": list(mr.QUICK_EMOJI), "more": list(mr.MORE_EMOJI)}
          and cap["features"].get(FLAG) is True, str(cap["reaction_emoji"]))
    check("quick and more sets are disjoint allowlist members",
          not set(mr.QUICK_EMOJI) & set(mr.MORE_EMOJI) and len(mr.ALLOWED_EMOJI) == len(set(mr.ALLOWED_EMOJI)))

    ws_a, ws_b = FakeWS(), FakeWS()
    ws_manager.active_connections[a], ws_manager.active_connections[b] = ws_a, ws_b
    try:
        r = add(client, a, m_b, THUMB, ck)
        check("add 200 {emoji,count,viewer_reacted}", r.status_code == 200
              and r.json() == {"emoji": THUMB, "count": 1, "viewer_reacted": True}, r.text)
        check("row written once", row_count(m_b, THUMB) == 1)
        r2 = add(client, a, m_b, THUMB, ck)
        check("add is idempotent (same body, still one row)", r2.status_code == 200 and r2.json() == r.json()
              and row_count(m_b, THUMB) == 1, r2.text)
        check("idempotent add sent no second frame", len(ws_b.sent) == 1, str(ws_b.sent))
        rb = add(client, b, m_b, THUMB, ck_b)
        check("a second user joins: count 2 and own state", rb.status_code == 200
              and rb.json() == {"emoji": THUMB, "count": 2, "viewer_reacted": True}, rb.text)
        check("own message reaction allowed", add(client, a, m_a, HEART, ck).status_code == 200)
        # remove
        rr = rem(client, a, m_b, THUMB, ck)
        check("remove 200 with count 1 and viewer_reacted false", rr.status_code == 200
              and rr.json() == {"emoji": THUMB, "count": 1, "viewer_reacted": False}, rr.text)
        frames_before = len(ws_b.sent)
        rr2 = rem(client, a, m_b, THUMB, ck)
        check("remove is idempotent (absent reaction is 200, unchanged, no frame)", rr2.status_code == 200
              and rr2.json() == rr.json() and len(ws_b.sent) == frames_before, rr2.text)
        check("removing another user's reaction is impossible (their row stays)", row_count(m_b, THUMB) == 1)
        # emoji validation
        bad = {
            "text": "hi", "not in allowlist": "\U0001F9FF" if "\U0001F9FF" not in mr.ALLOWED_EMOJI else "\U0001F9FE",
            "skin tone variant": "\U0001F44D\U0001F3FD", "multi emoji": THUMB + HEART,
            "oversized": THUMB * 40, "variation selector stripped heart": "❤",
            "zero width joiner": THUMB + "‍",
        }
        for label, e in bad.items():
            before = row_count(m_b)
            rp = add(client, a, m_b, e, ck)
            check(f"add rejects {label} (422), no write", rp.status_code == 422 and row_count(m_b) == before, f"{rp.status_code} {rp.text[:100]}")
            rd = rem(client, a, m_b, e, ck)
            check(f"remove rejects {label} (422)", rd.status_code == 422, f"{rd.status_code} {rd.text[:100]}")
        check("empty emoji add 422", client.post(url(a, m_b), json={"emoji": ""}, headers=ck).status_code == 422)
        check("missing emoji body 422", client.post(url(a, m_b), json={}, headers=ck).status_code == 422)
        check("non-string emoji 422", client.post(url(a, m_b), json={"emoji": 5}, headers=ck).status_code == 422)
        check("empty emoji remove 422", client.delete(url(a, m_b), params={"emoji": ""}, headers=ck).status_code == 422)
        check("remove without emoji param 422", client.delete(url(a, m_b), headers=ck).status_code == 422)
        # auth
        check("anonymous add 401/403", client.post(url(a, m_b), json={"emoji": THUMB}).status_code in (401, 403))
        check("anonymous remove 401/403", client.delete(url(a, m_b), params={"emoji": THUMB}).status_code in (401, 403))
        r = client.post(url(b, m_b), json={"emoji": THUMB}, headers=ck)
        check("path user != session user refused (401/403), no write for b", r.status_code in (401, 403)
              and row_count(m_b, THUMB) == 1, str(r.status_code))
        # uniform denial
        unknown = add(client, a, str(uuid.uuid4()), THUMB, ck)
        check("unknown id is 404 not_found", unknown.status_code == 404 and unknown.json()["detail"]["code"] == "not_found", unknown.text)
        denied = {
            "non-member": add(client, out, m_b, THUMB, ck_out),
            "malformed message id": add(client, a, "not-a-uuid", THUMB, ck),
        }
        sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (exm, gid))
        denied["ex-member"] = add(client, exm, m_b, THUMB, ck_ex)
        for label, rsp in denied.items():
            check(f"{label}: 404 with the unknown-id body", rsp.status_code == 404 and rsp.json() == unknown.json(), f"{rsp.status_code} {rsp.text}")
        check("denied attempts wrote nothing", row_count(m_b) == 1)
        for label, rsp in (("non-member", rem(client, out, m_b, THUMB, ck_out)), ("ex-member", rem(client, exm, m_b, THUMB, ck_ex))):
            check(f"{label} remove: 404", rsp.status_code == 404 and rsp.json() == unknown.json())
        # soft delete
        sql("UPDATE messages SET deleted_at = NOW(), deleted_by = %s WHERE _id=%s", (b, m_b))
        rs = add(client, a, m_b, LAUGH, ck)
        check("soft-deleted message: add 404 same body, no write", rs.status_code == 404 and rs.json() == unknown.json()
              and row_count(m_b, LAUGH) == 0)
        check("soft-deleted message: remove 404", rem(client, a, m_b, THUMB, ck).status_code == 404)
        check("soft delete did not delete existing rows", row_count(m_b, THUMB) == 1)
        sql("UPDATE messages SET deleted_at = NULL, deleted_by = NULL WHERE _id=%s", (m_b,))
        check("after restore, add works again", add(client, a, m_b, LAUGH, ck).status_code == 200)
        # terms
        sql("UPDATE users SET terms_version = NULL WHERE _id=%s", (a,))
        rt = add(client, a, m_b, mr.QUICK_EMOJI[3], ck)
        check("add without current terms refused (403), no write", rt.status_code == 403 and row_count(m_b, mr.QUICK_EMOJI[3]) == 0, f"{rt.status_code} {rt.text}")
        check("remove does not need terms", rem(client, a, m_b, LAUGH, ck).status_code == 200)
    finally:
        ws_manager.active_connections.pop(a, None)
        ws_manager.active_connections.pop(b, None)
        set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 4 blocks / DM

def test_blocks_and_dm(client):
    print("blocks and DMs")
    a, b, c, third = (make_user(f"rxb{i}") for i in range(4))
    gid = make_group([a, b, c])
    ck_a, ck_b, ck_c, ck_t = cookie(a), cookie(b), cookie(c), cookie(third)
    set_flag(FLAG, "on", a)
    try:
        m_b = make_msg(b, gid)
        m_c = make_msg(c, gid)
        unknown = add(client, a, str(uuid.uuid4()), THUMB, ck_a).json()
        block(a, b)
        r = add(client, a, m_b, THUMB, ck_a)
        check("blocker cannot react to the blocked author's group message (uniform 404)", r.status_code == 404 and r.json() == unknown)
        r = add(client, b, make_msg(a, gid), THUMB, ck_b)
        check("blocked user cannot react to the blocker's group message (uniform 404)", r.status_code == 404 and r.json() == unknown)
        r = rem(client, a, m_b, THUMB, ck_a)
        check("remove across a block: 404", r.status_code == 404)
        check("unblocked third message still reactable by blocker", add(client, a, m_c, THUMB, ck_a).status_code == 200)
        check("no row for the blocked pair", row_count(m_b) == 0)
        unblock_all(a, b)
        check("after unblock reaction allowed", add(client, a, m_b, THUMB, ck_a).status_code == 200)
        unblock_all(a, b)

        # DMs
        befriend(a, b)
        dm = make_dm(a, b)
        dm_in = make_dm(b, a)
        r = add(client, b, dm, THUMB, ck_b)
        check("DM recipient can react", r.status_code == 200 and r.json()["count"] == 1, r.text)
        check("DM author can react to own message", add(client, a, dm, HEART, ck_a).status_code == 200)
        check("DM author can react to the reply", add(client, a, dm_in, HEART, ck_a).status_code == 200)
        r = add(client, third, dm, THUMB, ck_t)
        check("DM non-participant: uniform 404, no write", r.status_code == 404 and r.json() == unknown and row_count(dm, THUMB) == 1, r.text)
        check("DM non-participant remove 404", rem(client, third, dm, THUMB, ck_t).status_code == 404)
        block(b, a)
        r = add(client, a, dm, LAUGH, ck_a)
        check("DM blocked (recipient blocked author): author gets 404", r.status_code == 404 and r.json() == unknown, r.text)
        r = add(client, b, dm, LAUGH, ck_b)
        check("DM blocker gets 404", r.status_code == 404 and r.json() == unknown)
        check("DM blocked pair wrote nothing", row_count(dm, LAUGH) == 0)
        unblock_all(a, b)
        block(a, b)
        check("DM blocked in the other direction: 404", add(client, b, dm, LAUGH, ck_b).status_code == 404)
        unblock_all(a, b)
    finally:
        set_flag(FLAG, "off", a)
        unblock_all(a, b, c, third)


# ---------------------------------------------------------------- 5 caps

def test_caps(client):
    print("caps")
    u = [make_user(f"rxc{i}") for i in range(4)]
    gid = make_group(u)
    cks = [cookie(x) for x in u]
    m = make_msg(u[0], gid)
    set_flag(FLAG, "on", u[0])
    try:
        pool = list(mr.ALLOWED_EMOJI)
        check("allowlist is big enough for the cap tests", len(pool) >= 21)
        for e in pool[:mr.MAX_PER_USER_PER_MESSAGE]:
            assert add(client, u[0], m, e, cks[0]).status_code == 200
        r = add(client, u[0], m, pool[10], cks[0])
        check("11th distinct emoji by one user: 409 user_cap, no write", r.status_code == 409
              and r.json()["detail"]["code"] == mr.CAP_USER and row_count(m, pool[10]) == 0, r.text)
        r = add(client, u[0], m, pool[0], cks[0])
        check("re-adding an existing reaction at the user cap stays idempotent 200", r.status_code == 200, r.text)
        check("removing frees the user cap", rem(client, u[0], m, pool[0], cks[0]).status_code == 200
              and add(client, u[0], m, pool[10], cks[0]).status_code == 200)
        # second user fills distinct emoji up to the message cap (20)
        for e in pool[11:21]:
            r = add(client, u[1], m, e, cks[1])
            assert r.status_code == 200, (e, r.text)
        distinct = sql("SELECT COUNT(DISTINCT emoji) FROM message_reactions WHERE message_id=%s", (m,))[0][0]
        check("message holds exactly 20 distinct emoji", distinct == mr.MAX_DISTINCT_PER_MESSAGE, str(distinct))
        r = add(client, u[2], m, pool[21], cks[2])
        check("21st distinct emoji on a message: 409 message_cap, no write", r.status_code == 409
              and r.json()["detail"]["code"] == mr.CAP_MESSAGE and row_count(m, pool[21]) == 0, r.text)
        r = add(client, u[2], m, pool[1], cks[2])
        check("joining an existing emoji at the message cap is allowed", r.status_code == 200 and r.json()["count"] == 2, r.text)
        r = add(client, u[2], m, pool[21], cks[2])
        check("message cap still holds for new emoji after the join", r.status_code == 409)
        # concurrency: two users racing for the last free distinct slot
        rem(client, u[1], m, pool[20], cks[1])
        import threading
        results = []

        def go(uid, ck, e):
            results.append(add(client, uid, m, e, ck).status_code)
        ts = [threading.Thread(target=go, args=(u[2], cks[2], pool[22])),
              threading.Thread(target=go, args=(u[3], cks[3], pool[23]))]
        [t.start() for t in ts]
        [t.join() for t in ts]
        distinct = sql("SELECT COUNT(DISTINCT emoji) FROM message_reactions WHERE message_id=%s", (m,))[0][0]
        check("concurrent adds for the last slot never exceed the message cap",
              distinct <= mr.MAX_DISTINCT_PER_MESSAGE and sorted(results) == [200, 409], f"{distinct} {results}")
    finally:
        set_flag(FLAG, "off", u[0])


# ---------------------------------------------------------------- 6 payloads

def test_payloads(client):
    print("payloads: legacy + paged, aggregation, soft delete, no N+1")
    a, b, c = (make_user(f"rxp{i}") for i in range(3))
    gid = make_group([a, b, c])
    ck_a, ck_b = cookie(a), cookie(b)
    msgs = [make_msg(b if i % 2 else a, gid, f"hist-{i}") for i in range(12)]
    m1, m2, m_none = msgs[0], msgs[1], msgs[2]
    sql("INSERT INTO message_reactions (message_id, user_id, emoji) VALUES "
        "(%s,%s,%s),(%s,%s,%s),(%s,%s,%s),(%s,%s,%s)",
        (m1, a, THUMB, m1, b, THUMB, m1, c, HEART, m2, b, LAUGH))
    # a DM thread for the DM readers
    befriend(a, b)
    dm1, dm2 = make_dm(a, b, "dm-one"), make_dm(b, a, "dm-two")
    sql("INSERT INTO message_reactions (message_id, user_id, emoji) VALUES (%s,%s,%s),(%s,%s,%s)",
        (dm1, b, THUMB, dm1, a, THUMB))

    calls = []
    real = mr.reactions_for_messages

    def counting(cur, ids, viewer):
        calls.append(len(ids))
        return real(cur, ids, viewer)

    import backend.interactions.message_reactions as mod
    mod.reactions_for_messages = counting
    set_flag(FLAG, "on", a)

    def agg(msg):
        return {x["emoji"]: (x["count"], x["viewer_reacted"]) for x in msg["reactions"]}

    try:
        for gflag, dflag, label in (("off", "off", "legacy"), ("on", "on", "paged")):
            set_flag("chat_pagination", gflag, a)
            set_flag("chat_pagination_dm", dflag, a)
            # group history
            calls.clear()
            if gflag == "on":
                r = client.get(f"/groups/{a}/{gid}", params={"limit": "50"}, headers=ck_a)
            else:
                r = client.get(f"/groups/{a}/{gid}", headers=ck_a)
            body = r.json()
            ms = all_msgs(body)
            f1, f2, fn = reactions_of(ms, m1), reactions_of(ms, m2), reactions_of(ms, m_none)
            ok = r.status_code == 200 and f1 and f2 and fn and "reactions" in fn
            check(f"{label} group: messages present with reactions key", bool(ok), r.text[:200])
            if ok:
                check(f"{label} group: aggregated per emoji for viewer a",
                      agg(f1) == {THUMB: (2, True), HEART: (1, False)} and agg(f2) == {LAUGH: (1, False)}, str(f1["reactions"]))
                check(f"{label} group: a message with none has reactions == []", fn["reactions"] == [])
                check(f"{label} group: each reaction has exactly emoji/count/viewer_reacted",
                      all(set(x) == {"emoji", "count", "viewer_reacted"} for x in f1["reactions"]))
            max_calls = 1 if gflag == "on" else 2  # legacy keeps two lists (host/other), one batch each
            check(f"{label} group: <= {max_calls} batch call(s) for {len(ms)} messages (no N+1)",
                  1 <= len(calls) <= max_calls and sum(calls) == len(ms), str(calls))
            # viewer b sees own state
            rb = client.get(f"/groups/{b}/{gid}", params={"limit": "50"} if gflag == "on" else None, headers=ck_b)
            fb = reactions_of(all_msgs(rb.json()), m1)
            check(f"{label} group: viewer b's viewer_reacted differs (HEART false, THUMB true)",
                  fb is not None and agg(fb) == {THUMB: (2, True), HEART: (1, False)}
                  and agg(reactions_of(all_msgs(rb.json()), m2)) == {LAUGH: (1, True)})
            if gflag == "on":
                calls.clear()
                r = client.get(f"/groups/{a}/{gid}/messages", params={"limit": "5"}, headers=ck_a)
                pg = r.json()
                check("paged endpoint: page rows carry reactions key, one batch call",
                      r.status_code == 200 and all("reactions" in x for x in pg["messages"]) and len(calls) == 1, f"{calls} {r.text[:150]}")
                # walk older pages: every row has the key, reactions land on the right rows
                seen = {}
                page, guard = pg["page"], 0
                for x in pg["messages"]:
                    seen[x["id"]] = x
                while page["has_more"] and guard < 10:
                    guard += 1
                    cp = {"cursor_timestamp": page["next_cursor_timestamp"], "cursor_id": page["next_cursor_id"]}
                    if page["next_cursor_seq"] is not None:
                        cp["cursor_seq"] = str(page["next_cursor_seq"])
                    calls.clear()
                    r = client.get(f"/groups/{a}/{gid}/messages", params={"limit": "5", **cp}, headers=ck_a)
                    for x in r.json()["messages"]:
                        seen[x["id"]] = x
                    page = r.json()["page"]
                    assert len(calls) == 1
                check("paged walk: every row has reactions and m1/m2 aggregates are right",
                      len(seen) >= 12 and all("reactions" in x for x in seen.values())
                      and agg(seen[m1]) == {THUMB: (2, True), HEART: (1, False)} and seen[m_none]["reactions"] == [])
            # DM readers
            calls.clear()
            if dflag == "on":
                r = client.get(f"/friends/{a}/{b}", params={"limit": "10"}, headers=ck_a)
            else:
                r = client.get(f"/friends/{a}/{b}", headers=ck_a)
            dms = all_msgs(r.json())
            d1, d2 = reactions_of(dms, dm1), reactions_of(dms, dm2)
            check(f"{label} DM: both messages present with reactions key", r.status_code == 200 and d1 is not None
                  and d2 is not None and "reactions" in d2, r.text[:200])
            if d1 and d2:
                check(f"{label} DM: aggregate and viewer state", agg(d1) == {THUMB: (2, True)} and d2["reactions"] == [])
            check(f"{label} DM: batch calls bounded (<=2, one per list)", 1 <= len(calls) <= 2, str(calls))
            if dflag == "on":
                calls.clear()
                r = client.get(f"/friends/{a}/{b}/messages", params={"limit": "10"}, headers=ck_a)
                dp = reactions_of(r.json()["messages"], dm1)
                check("paged DM endpoint: reactions present and one batch call", r.status_code == 200 and dp is not None
                      and agg(dp) == {THUMB: (2, True)} and len(calls) == 1, f"{calls} {r.text[:150]}")
            lm = client.get(f"/message/messages/{a}/", params={"guest_user": b}, headers=ck_a)
            check(f"{label}: /message/messages legacy reader still 200", lm.status_code == 200, lm.text[:100])

        # soft delete hides, restore re-exposes (via the real delete/undo routes and direct SQL)
        set_flag("chat_pagination", "off", a)
        set_flag("message_delete", "on", a)
        r = client.delete(f"/groups/{a}/{gid}/messages/{m1}", headers=ck_a)
        check("author soft-deletes the reacted message", r.status_code == 200, r.text)
        ms = all_msgs(client.get(f"/groups/{a}/{gid}", headers=ck_a).json())
        check("soft-deleted message is gone from history (and so are its reactions)", reactions_of(ms, m1) is None)
        check("rows are kept while deleted", row_count(m1) == 3)
        check("deleted message: cannot react", add(client, b, m1, HEART, ck_b).status_code == 404)
        r = client.post(f"/groups/{a}/{gid}/messages/{m1}/restore", headers=ck_a)
        check("restore succeeds", r.status_code == 200, r.text)
        ms = all_msgs(client.get(f"/groups/{a}/{gid}", headers=ck_a).json())
        check("restore brings the reactions back", reactions_of(ms, m1) is not None
              and agg(reactions_of(ms, m1)) == {THUMB: (2, True), HEART: (1, False)})
        # reactions helper itself never returns a deleted message
        d = DBManager()
        try:
            sql("UPDATE messages SET deleted_at = NOW(), deleted_by=%s WHERE _id=%s", (a, m2))
            check("reactions_for_messages omits soft-deleted messages", m2 not in real(d.cur, [m1, m2], a))
            sql("UPDATE messages SET deleted_at = NULL, deleted_by=NULL WHERE _id=%s", (m2,))
            out = real(d.cur, [m1, m2, "junk", None], a)
            check("reactions_for_messages ignores junk ids and returns both live messages", set(out) == {m1, m2})
            check("reactions_for_messages with bad viewer returns {}", real(d.cur, [m1], "junk") == {})
            d.conn.rollback()
        finally:
            d.close()
    finally:
        mod.reactions_for_messages = real
        for f in ("chat_pagination", "chat_pagination_dm", "message_delete", FLAG):
            set_flag(f, "off", a)


# ---------------------------------------------------------------- 7 websocket

def test_websocket(client):
    print("websocket frames")
    a, b, c, blocked_actor, blocked_author, outsider = (make_user(f"rxw{i}") for i in range(6))
    gid = make_group([a, b, c, blocked_actor, blocked_author])
    # message authored by blocked_author's peer b; a is the actor
    m = make_msg(b, gid, "ws secret text")
    ck_a, ck_c = cookie(a), cookie(c)
    block(a, blocked_actor)          # blocked with the actor
    block(b, blocked_author)         # blocked with the message author
    set_flag(FLAG, "on", a)
    sockets = {u: FakeWS() for u in (a, b, c, blocked_actor, blocked_author, outsider)}
    ws_manager.active_connections.update(sockets)
    try:
        r = add(client, a, m, THUMB, ck_a)
        check("add 200", r.status_code == 200, r.text)
        frame = sockets[b].sent[0] if sockets[b].sent else None
        check("author b received reaction_updated", frame is not None and frame["type"] == "reaction_updated", str(sockets[b].sent))
        if frame:
            check("frame carries exactly type/message_id/group_id/emoji/count/actor_id",
                  frame == {"type": "reaction_updated", "message_id": m, "group_id": gid, "emoji": THUMB, "count": 1, "actor_id": a}, str(frame))
            check("frame has neither from_user nor text (old clients ignore it)", "from_user" not in frame and "text" not in frame)
        check("other eligible member c received it", len(sockets[c].sent) == 1 and sockets[c].sent[0]["type"] == "reaction_updated")
        check("actor does not receive its own frame", sockets[a].sent == [], str(sockets[a].sent))
        check("user blocked with the actor gets nothing", sockets[blocked_actor].sent == [], str(sockets[blocked_actor].sent))
        check("user blocked with the message author gets nothing", sockets[blocked_author].sent == [], str(sockets[blocked_author].sent))
        check("non-member gets nothing", sockets[outsider].sent == [])
        add(client, a, m, THUMB, ck_a)
        check("idempotent re-add sends no frame", len(sockets[c].sent) == 1)
        add(client, c, m, THUMB, ck_c)
        last = sockets[b].sent[-1]
        check("second reactor: count 2 and actor_id is c", last["count"] == 2 and last["actor_id"] == c, str(last))
        rem(client, a, m, THUMB, ck_a)
        last = sockets[c].sent[-1]
        check("remove sends count 1 frame", last["type"] == "reaction_updated" and last["count"] == 1 and last["actor_id"] == a, str(last))
        n = len(sockets[b].sent)
        rem(client, a, m, THUMB, ck_a)
        check("idempotent remove sends no frame", len(sockets[b].sent) == n)
        rem(client, c, m, THUMB, ck_c)
        check("last remove reports count 0", sockets[b].sent[-1]["count"] == 0, str(sockets[b].sent[-1]))
        n = sum(len(s.sent) for s in sockets.values())
        add(client, outsider, m, THUMB, cookie(outsider))
        sql("UPDATE messages SET deleted_at = NOW(), deleted_by=%s WHERE _id=%s", (b, m))
        add(client, a, m, HEART, ck_a)
        check("denied adds (non-member, deleted message) send no frame", sum(len(s.sent) for s in sockets.values()) == n)
        sql("UPDATE messages SET deleted_at = NULL, deleted_by=NULL WHERE _id=%s", (m,))
        # dead socket must not fail the request
        ws_manager.active_connections[b] = FakeWS(fail=True)
        r = add(client, a, m, LAUGH, ck_a)
        check("dead recipient socket does not fail the write", r.status_code == 200 and row_count(m, LAUGH) == 1, r.text)
        ws_manager.active_connections[b] = sockets[b]

        # DM frame
        befriend(a, c)
        dm = make_dm(a, c)
        sa, sc = FakeWS(), FakeWS()
        ws_manager.active_connections[a], ws_manager.active_connections[c] = sa, sc
        add(client, c, dm, THUMB, ck_c)
        want_room = "|".join(sorted([a, c]))
        check("DM: author receives frame with sorted a|b room key", len(sa.sent) == 1 and sa.sent[0]["group_id"] == want_room
              and sa.sent[0]["type"] == "reaction_updated" and sa.sent[0]["actor_id"] == c, str(sa.sent))
        check("DM: actor does not receive own frame", sc.sent == [])
        block(c, a)
        add(client, a, dm, HEART, ck_a)
        check("DM: blocked pair cannot react, no frame", row_count(dm, HEART) == 0 and sc.sent == [])
        unblock_all(c)
    finally:
        for u in sockets:
            ws_manager.active_connections.pop(u, None)
        unblock_all(a, b, c, blocked_actor, blocked_author)
        set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 8 rate limit

def test_rate_limit(client):
    print("rate limit")
    a, b = make_user("rxr1"), make_user("rxr2")
    gid = make_group([a, b])
    m = make_msg(b, gid)
    ck = cookie(a)
    set_flag(FLAG, "on", a)
    try:
        limiter.reset()
        rate = mr.reaction_rate()
        check("configured rate parses (N/period)", "/" in rate, rate)
        n = int(rate.split("/")[0])
        codes = []
        for i in range(n + 5):
            codes.append(add(client, a, m, THUMB, ck).status_code if i % 2 == 0 else rem(client, a, m, THUMB, ck).status_code)
        check("requests past the limit are 429", 429 in codes and codes[:n].count(429) == 0 and codes[n:].count(429) >= 1, str(codes))
        check("add and remove share one bucket (limit hit within n+5 mixed calls)", len(codes) - codes.count(429) == n, str(codes))
        other = cookie(b)
        check("another user is not throttled by this user's bucket", add(client, b, m, HEART, other).status_code == 200)
    finally:
        limiter.reset()
        set_flag(FLAG, "off", a)


def main():
    require_scratch_db()
    client = TestClient(main_module.app)
    try:
        test_ddl_and_flag()
        test_flag_off(client)
        limiter.reset()
        test_add_remove(client)
        limiter.reset()
        test_blocks_and_dm(client)
        limiter.reset()
        test_caps(client)
        limiter.reset()
        test_payloads(client)
        limiter.reset()
        test_websocket(client)
        limiter.reset()
        test_rate_limit(client)
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
        sys.exit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
