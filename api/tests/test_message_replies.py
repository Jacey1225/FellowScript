"""Tests for task 20261010-announcement-location-chat-replies, part B: reply to a
chat message (flag ``chat_replies``).

Scratch database only (asserts SHOW port = 55432 first). Proves:
  * DDL module ``message_replies`` applies twice, adds only a nullable ``reply_to_id``
    (no FK, NO copy of the original's text or author), flag registered, seeded off,
    exposed in capabilities
  * send path (websocket ``send_msg``): the client sends only ``reply_to``; only the id is
    stored; client-supplied label keys are ignored; old clients (no ``reply_to``) send and
    receive exactly as before; flag off ignores the key
  * every refusal (unknown/malformed id, other group, DM vs group, DM of another pair,
    soft-deleted target, author no longer a member, blocked author, non-member sender)
    gives ONE identical ``reply_invalid`` frame and saves nothing
  * read-time label: derived from the original per response (edits show; text capped at
    200; attachment-only gets a label); soft-deleted, hard-deleted, left-the-group or
    blocked original gives ``reply_to_deleted: true`` with no text or author; original
    text is never stored on the reply row (also while content encryption is on)
  * live frames: recipients with the flag on get the label keys, one blocked with the
    original's author gets ``reply_to_deleted``, flag off gets none; the sender ack carries them
  * history: reply keys on the legacy group path, both paged group paths, the legacy DM
    path and both paged DM paths; non-replies unchanged; flag off omits; one batch per request
Run with: cd api && ../.venv/bin/python tests/test_message_replies.py
(locally needs the scratch cluster: FS_SCRATCH_PG_PORT=55432, see fs_scratch_shim)
"""
import _pathfix  # noqa: F401

import asyncio
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
    cookie, cleanup, set_flag, FakeWS,
)
from backend.interactions import flags  # noqa: E402
from backend.interactions import message_replies as mrp  # noqa: E402
from routes.messaging import manager as ws_manager  # noqa: E402
from schema_ddl import message_replies as ddl  # noqa: E402

FLAG = "chat_replies"
ALL_FLAGS = (FLAG, "chat_pagination", "chat_pagination_dm", "content_encryption_write")
REPLY_KEYS = ("reply_to_id", "reply_to_text", "reply_to_author", "reply_to_author_id", "reply_to_deleted")
INVALID = {"type": "error", "reason": "reply_invalid", "detail": "That message can't be replied to."}


def befriend(a, b):
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s) ON CONFLICT DO NOTHING", (a, b, b, a))


def block(blocker, blocked):
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blocker, blocked))


def unblock_all(*uids):
    for u in uids:
        sql("DELETE FROM blocked_users WHERE blocker_id=%s OR blocked_id=%s", (u, u))


def make_dm(author, to, text="dm text"):
    mid = make_msg(author, None, text, group=False)
    sql("INSERT INTO message_recipients (message_id, user_id) VALUES (%s,%s)", (mid, to))
    return mid


def send(sender, to_users, gid, text, **extra):
    if gid and not to_users:
        to_users = [sender]  # ignored for groups (recipients are derived server-side) but must be non-empty
    p = {"from_user": sender, "to_users": to_users, "text": text, "group_id": gid,
         "timestamp": datetime.now(timezone.utc).isoformat()}
    p.update(extra)
    asyncio.run(ws_manager.send_msg(p))


def stored_reply_id(text):
    r = sql("SELECT reply_to_id::text FROM messages WHERE text = %s", (text,))
    return r[0][0] if r else None


def label(viewer, mid):
    """The derived reply keys for message ``mid`` as ``viewer`` sees them."""
    d = DBManager()
    try:
        m = {"id": mid}
        mrp.attach_replies(d, [m], viewer)
        return {k: v for k, v in m.items() if k != "id"}
    finally:
        d.close()


def saved_count(text):
    return sql("SELECT COUNT(*) FROM messages WHERE text = %s", (text,))[0][0]


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


def frames(ws, kind=None):
    return [f for f in ws.sent if kind is None or f.get("type") == kind]


class Sockets:
    def __init__(self, *uids):
        self.ws = {u: FakeWS() for u in uids}
        ws_manager.active_connections.update(self.ws)

    def close(self):
        for u in self.ws:
            ws_manager.active_connections.pop(u, None)


# ---------------------------------------------------------------- 1 DDL / flag / units

def test_ddl_flag_units(client):
    print("DDL module, flag, snippet")
    d = DBManager()
    try:
        ddl.apply(d.cur)
        ddl.apply(d.cur)
        d.conn.commit()
        check("DDL module applies twice without error", True)
        check("registered in DDL_MODULES after chat_pagination", "message_replies" in db_module.DDL_MODULES
              and list(db_module.DDL_MODULES).index("message_replies") > list(db_module.DDL_MODULES).index("chat_pagination"))
        d.cur.execute("SELECT column_name, is_nullable FROM information_schema.columns "
                      "WHERE table_name='messages' AND column_name LIKE 'reply_to%'")
        cols = dict(d.cur.fetchall())
        check("only a nullable reply_to_id column, no stored text/author", cols == {"reply_to_id": "YES"}, str(cols))
        d.cur.execute("SELECT count(*) FROM pg_constraint WHERE conrelid='messages'::regclass AND contype='f' "
                      "AND conkey @> ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid='messages'::regclass AND attname='reply_to_id')]")
        check("reply_to_id has no foreign key (a hard delete retains nothing)", d.cur.fetchone()[0] == 0)
    finally:
        d.close()
    check("flag registered", FLAG in flags._REGISTRY)
    row = sql("SELECT state FROM feature_flags WHERE name=%s", (FLAG,))
    check("flag seeded and off", bool(row) and row[0][0] == "off", str(row))
    from schema_ddl import flags as flags_ddl
    check("flag in SEED_FLAG_NAMES", FLAG in flags_ddl.SEED_FLAG_NAMES)

    check("snippet: whitespace collapsed", mrp.make_snippet("a \n\n b\t c", None) == "a b c")
    long = mrp.make_snippet("x" * 500, None)
    check("snippet: capped at 200 including ellipsis", len(long) == 200 and long.endswith("…"), str(len(long)))
    check("snippet: exactly 200 chars untouched", mrp.make_snippet("y" * 200, None) == "y" * 200)
    check("snippet: attachment-only gets a label", mrp.make_snippet("", "image") == "Photo" and mrp.make_snippet("  ", "gif") == "GIF")
    check("snippet: empty with no attachment is empty", mrp.make_snippet(None, None) == "")

    a = make_user("rpc")
    ck = cookie(a)
    cap = client.get("/app/capabilities", headers=ck).json()
    check("capabilities features has chat_replies false while off", cap["features"].get(FLAG) is False, str(cap["features"]))
    set_flag(FLAG, "on", a)
    cap = client.get("/app/capabilities", headers=ck).json()
    check("capabilities features has chat_replies true when on", cap["features"].get(FLAG) is True)
    set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 2 send path

def test_send_group(client):
    print("send path: group")
    a, b, c, outsider = (make_user(f"rps{i}") for i in range(4))
    gid = make_group([a, b, c])
    other_gid = make_group([a, b])
    target = make_msg(b, gid, "the original words")
    sk = Sockets(a, b, c, outsider)
    try:
        set_flag(FLAG, "on", a)
        send(a, [], gid, "r-ok", reply_to=target)
        uname_b = sql("SELECT username FROM users WHERE _id=%s", (b,))[0][0]
        ok_id = sql("SELECT _id::text FROM messages WHERE text='r-ok'")[0][0]
        check("only the target id is stored", stored_reply_id("r-ok") == target)
        check("derived label for the viewer", label(a, ok_id) == {
            "reply_to_id": target, "reply_to_text": "the original words", "reply_to_author": uname_b, "reply_to_author_id": b}, str(label(a, ok_id)))
        check("sender ack not sent without client_ref", frames(sk.ws[a], "ack") == [])
        got = frames(sk.ws[c], None)
        check("recipient c gets the frame with the four label keys", len(got) == 1 and all(
            k in got[0] for k in REPLY_KEYS[:4]) and "reply_to_deleted" not in got[0], str(got))

        # client-supplied label is ignored
        send(a, [], gid, "r-spoof", reply_to=target, reply_to_text="FORGED", reply_to_author="Mallory", reply_to_author_id=a)
        spoof_id = sql("SELECT _id::text FROM messages WHERE text='r-spoof'")[0][0]
        lab = label(a, spoof_id)
        check("client-supplied label keys are ignored", lab["reply_to_text"] == "the original words"
              and lab["reply_to_author"] == uname_b and lab["reply_to_author_id"] == b, str(lab))
        cols = sql("SELECT column_name FROM information_schema.columns WHERE table_name='messages' AND column_name LIKE 'reply%%'")
        check("no column could hold a copy of the text", [c_[0] for c_ in cols] == ["reply_to_id"], str(cols))

        # long text and attachment label
        long_t = make_msg(b, gid, "L" * 500)
        send(a, [], gid, "r-long", reply_to=long_t)
        lab = label(a, sql("SELECT _id::text FROM messages WHERE text='r-long'")[0][0])
        check("long label capped at 200", len(lab["reply_to_text"]) == 200, str(len(lab["reply_to_text"])))
        att = make_msg(b, gid, "", kind="image", key=f"attachments/{b}/x.jpg")
        send(a, [], gid, "r-att", reply_to=att)
        lab = label(a, sql("SELECT _id::text FROM messages WHERE text='r-att'")[0][0])
        check("attachment-only target labels as Photo", lab["reply_to_text"] == "Photo", str(lab))

        # reply to a reply: one level (label is only the replied message's own text)
        send(b, [], gid, "r-chain", reply_to=ok_id)
        chain_id = sql("SELECT _id::text FROM messages WHERE text='r-chain'")[0][0]
        lab = label(a, chain_id)
        check("reply to a reply allowed, label is the reply's own text", stored_reply_id("r-chain") == ok_id
              and lab["reply_to_text"] == "r-ok" and "reply_to_deleted" not in lab, str(lab))

        # ack carries the label
        send(a, [], gid, "r-ack", reply_to=target, client_ref="ref1")
        acks = frames(sk.ws[a], "ack")
        check("sender ack carries the reply keys", acks and acks[-1]["reply_to_id"] == target
              and acks[-1]["reply_to_text"] == "the original words" and acks[-1]["reply_to_author"] == uname_b, str(acks))

        # --- refusals: one uniform frame, nothing saved
        base_errs = len(frames(sk.ws[a], "error"))

        def refused(label, sender, group, tgt, to=None):
            n = len(frames(sk.ws[sender], "error"))
            send(sender, to or [], group, f"r-bad-{label}", reply_to=tgt)
            errs = frames(sk.ws[sender], "error")
            check(f"refused: {label}: reply_invalid frame and nothing saved",
                  len(errs) == n + 1 and errs[-1] == INVALID and saved_count(f"r-bad-{label}") == 0, str(errs[-1:]))

        refused("unknown id", a, gid, str(uuid.uuid4()))
        refused("malformed id", a, gid, "not-a-uuid")
        refused("non-string id", a, gid, 12345)
        elsewhere = make_msg(b, other_gid, "in another group")
        refused("target in another group", a, gid, elsewhere)
        dm_target = make_dm(b, a, "a dm")
        refused("DM target for a group reply", a, gid, dm_target)
        gone = make_msg(b, gid, "will be deleted")
        sql("UPDATE messages SET deleted_at=NOW(), deleted_by=%s WHERE _id=%s", (b, gone))
        refused("soft-deleted target", a, gid, gone)
        # author no longer a member
        left = make_user("rpleft")
        left_msg = make_msg(left, gid, "from a former member")
        refused("author is not a current member", a, gid, left_msg)
        # blocked author (either direction)
        block(a, c)
        c_msg = make_msg(c, gid, "from c")
        refused("author blocked by sender", a, gid, c_msg)
        unblock_all(a)
        block(c, a)
        refused("sender blocked by author", a, gid, c_msg)
        unblock_all(a)
        send(a, [], gid, "r-after-unblock", reply_to=c_msg)
        check("allowed again once the block is removed", saved_count("r-after-unblock") == 1)
        # a non-member cannot reply into a group (guard) even with a valid id
        n = len(frames(sk.ws[outsider], "error"))
        send(outsider, [], gid, "r-bad-outsider", reply_to=target)
        errs = frames(sk.ws[outsider], "error")
        check("non-member: refused, nothing saved", len(errs) == n + 1 and saved_count("r-bad-outsider") == 0, str(errs[-1:]))
        errs_all = [f for f in frames(sk.ws[a], "error")[base_errs:]]
        check("all refusal frames are byte-identical", all(f == INVALID for f in errs_all), str(errs_all[:2]))

        # --- back-compat and flag off
        n_before = len(frames(sk.ws[c]))
        send(a, [], gid, "plain-old")
        got = frames(sk.ws[c])[n_before:]
        check("old client: plain send saved and delivered with no reply keys",
              saved_count("plain-old") == 1 and len(got) == 1 and not any(k in got[0] for k in REPLY_KEYS))
        check("plain message has NULL reply_to_id", stored_reply_id("plain-old") is None)
        set_flag(FLAG, "off", a)
        send(a, [], gid, "off-reply", reply_to=target)
        check("flag off: reply_to ignored, message sent as plain", saved_count("off-reply") == 1 and stored_reply_id("off-reply") is None)
        send(a, [], gid, "off-reply-bad", reply_to="garbage")
        check("flag off: even an invalid reply_to is ignored (no error)", saved_count("off-reply-bad") == 1)
    finally:
        sk.close()
        unblock_all(a, b, c)
        set_flag(FLAG, "off", a)


def test_send_dm(client):
    print("send path: DM")
    a, b, c = (make_user(f"rpd{i}") for i in range(3))
    befriend(a, b)
    befriend(a, c)
    gid = make_group([a, b])
    sk = Sockets(a, b, c)
    try:
        set_flag(FLAG, "on", a)
        set_flag(FLAG, "on", b)
        mine = make_dm(a, b, "dm from a")
        theirs = make_dm(b, a, "dm from b")
        send(a, [b], None, "dm-r1", reply_to=theirs)
        send(a, [b], None, "dm-r2", reply_to=mine)
        check("DM: reply to the other party's message", stored_reply_id("dm-r1") == theirs)
        check("DM: reply to own message", stored_reply_id("dm-r2") == mine)
        l1 = label(a, sql("SELECT _id::text FROM messages WHERE text='dm-r1'")[0][0])
        check("DM: derived label", l1.get("reply_to_text") == "dm from b" and l1.get("reply_to_author_id") == b, str(l1))
        fr = frames(sk.ws[b])
        check("DM: live frame carries the label keys", fr and fr[0]["reply_to_id"] == theirs and fr[0]["reply_to_text"] == "dm from b"
              and fr[0]["reply_to_author_id"] == b, str(fr[:1]))

        def refused(label, sender, to, tgt):
            n = len(frames(sk.ws[sender], "error"))
            send(sender, to, None, f"dm-bad-{label}", reply_to=tgt)
            errs = frames(sk.ws[sender], "error")
            check(f"DM refused: {label}", len(errs) == n + 1 and errs[-1] == INVALID and saved_count(f"dm-bad-{label}") == 0, str(errs[-1:]))

        other_pair = make_dm(c, a, "dm from c to a")
        refused("target in another pair's DM", a, [b], other_pair)
        group_msg = make_msg(b, gid, "group msg")
        refused("group target for a DM reply", a, [b], group_msg)
        gone = make_dm(b, a, "gone dm")
        sql("UPDATE messages SET deleted_at=NOW(), deleted_by=%s WHERE _id=%s", (b, gone))
        refused("soft-deleted DM target", a, [b], gone)
        undelivered = make_msg(b, None, "never delivered to a", group=False)
        refused("DM target not delivered to this pair", a, [b], undelivered)
        refused("unknown id", a, [b], str(uuid.uuid4()))
        # blocked pair: whole DM dropped silently (existing behaviour), nothing saved
        block(b, a)
        send(a, [b], None, "dm-blocked", reply_to=theirs)
        check("DM blocked pair: dropped silently, nothing saved", saved_count("dm-blocked") == 0)
        unblock_all(a, b)
    finally:
        sk.close()
        unblock_all(a, b, c)
        set_flag(FLAG, "off", a)
        set_flag(FLAG, "off", b)


# ---------------------------------------------------------------- 3 immutability / encryption

def test_immutability_and_encryption(client):
    print("read-time label, edit / delete / block, encryption")
    a, b = make_user("rpi1"), make_user("rpi2")
    befriend(a, b)
    gid = make_group([a, b])
    ck = cookie(a)
    sk = Sockets(a, b)
    try:
        set_flag(FLAG, "on", a)
        target = make_msg(b, gid, "before the edit")
        send(a, [], gid, "imm-reply", reply_to=target)
        rid = sql("SELECT _id::text FROM messages WHERE text='imm-reply'")[0][0]
        check("the reply row has no copy of the original text",
              "before the edit" not in str(sql("SELECT * FROM messages WHERE _id=%s", (rid,))))
        sql("UPDATE messages SET text='after the edit' WHERE _id=%s", (target,))
        check("an edit of the original shows in the label", label(a, rid).get("reply_to_text") == "after the edit", str(label(a, rid)))
        sql("UPDATE messages SET deleted_at=NOW(), deleted_by=%s WHERE _id=%s", (b, target))
        check("soft-deleted original -> reply_to_deleted, no text or author",
              label(a, rid) == {"reply_to_id": target, "reply_to_deleted": True}, str(label(a, rid)))
        m = by_id(all_msgs(client.get(f"/groups/{a}/{gid}", headers=ck).json()), rid)
        check("payload: reply_to_deleted true, no text/author", m is not None and m.get("reply_to_deleted") is True
              and "reply_to_text" not in m and "reply_to_author" not in m, str(m))
        sql("UPDATE messages SET deleted_at=NULL, deleted_by=NULL WHERE _id=%s", (target,))
        check("restore brings the label back", label(a, rid).get("reply_to_text") == "after the edit")
        sql("DELETE FROM messages WHERE _id=%s", (target,))
        check("hard delete: pointer remains, nothing of the original is retained anywhere",
              label(a, rid) == {"reply_to_id": target, "reply_to_deleted": True}
              and "after the edit" not in str(sql("SELECT * FROM messages WHERE _id=%s", (rid,))), str(label(a, rid)))
        m = by_id(all_msgs(client.get(f"/groups/{a}/{gid}", headers=ck).json()), rid)
        check("payload after hard delete: reply_to_deleted", m is not None and m.get("reply_to_deleted") is True, str(m))

        # a viewer blocked with the original's author sees reply_to_deleted, no text
        t3 = make_msg(b, gid, "visible text")
        send(a, [], gid, "blk-reply", reply_to=t3)
        bid = sql("SELECT _id::text FROM messages WHERE text='blk-reply'")[0][0]
        c_ = make_user("rpi3")
        sql("UPDATE groups SET users = users || %s::text WHERE _id=%s", (c_, gid))
        block(c_, b)
        check("viewer blocked with the original's author: reply_to_deleted", label(c_, bid) == {"reply_to_id": t3, "reply_to_deleted": True}, str(label(c_, bid)))
        unblock_all(c_)
        check("unblocked: label shown again", label(c_, bid).get("reply_to_text") == "visible text")
        # original's author left the group: hidden
        sql("UPDATE groups SET users = array_remove(users, %s::text) WHERE _id=%s", (b, gid))
        check("original's author left the group: reply_to_deleted for others", label(a, bid).get("reply_to_deleted") is True, str(label(a, bid)))
        sql("UPDATE groups SET users = users || %s::text WHERE _id=%s", (b, gid))

        # with encryption on, still nothing of the original is stored on the reply row
        set_flag("content_encryption_write", "on", a)
        t2 = make_msg(b, gid, "secret words Zebulun")
        send(a, [], gid, "enc-reply", reply_to=t2)
        eid = sql("SELECT _id::text FROM messages WHERE reply_to_id=%s", (t2,))[0][0]
        check("encryption on: reply row holds no copy of the original", "Zebulun" not in str(sql("SELECT * FROM messages WHERE _id=%s", (eid,))))
        check("encryption on: label still derived", label(a, eid).get("reply_to_text") == "secret words Zebulun")
    finally:
        sk.close()
        set_flag(FLAG, "off", a)
        set_flag("content_encryption_write", "off", a)


# ---------------------------------------------------------------- 4 live frames

def test_frames(client):
    print("live frames")
    a, b, c, d, e = (make_user(f"rpf{i}") for i in range(5))
    gid = make_group([a, b, c, d, e])
    sk = Sockets(a, b, c, d, e)
    try:
        # canary: on for a, b, c, d only; e has the flag off
        flags.set_flag(FLAG, "canary", [a, b, c, d], actor=a)
        flags.invalidate()
        target = make_msg(b, gid, "frame target")
        block(d, b)                      # d is blocked with the original's author b
        send(a, [], gid, "frame-r", reply_to=target)
        mid = sql("SELECT _id::text FROM messages WHERE text='frame-r'")[0][0]
        for name, u, expect in (("b (author, flag on)", b, "label"), ("c (flag on)", c, "label"),
                                ("d (blocked with the author)", d, "deleted"), ("e (flag off)", e, "none")):
            fr = [f for f in sk.ws[u].sent if f.get("id") == mid]
            if expect == "label":
                ok = len(fr) == 1 and all(k in fr[0] for k in REPLY_KEYS[:4]) and "reply_to_deleted" not in fr[0]
            elif expect == "deleted":
                ok = len(fr) == 1 and fr[0].get("reply_to_deleted") is True and fr[0].get("reply_to_id") == target \
                    and "reply_to_text" not in fr[0] and "reply_to_author" not in fr[0]
            else:
                ok = len(fr) == 1 and not any(k in fr[0] for k in REPLY_KEYS)
            check(f"frame to {name}: {expect}", ok, str(fr))
        check("sender gets no echo frame", [f for f in sk.ws[a].sent if f.get("id") == mid] == [])
    finally:
        sk.close()
        unblock_all(a, b, c, d, e)
        set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 5 history paths

def test_history(client):
    print("history paths")
    a, b, c = (make_user(f"rph{i}") for i in range(3))
    befriend(a, b)
    gid = make_group([a, b, c])
    ck = cookie(a)
    t_g = make_msg(b, gid, "group original")
    plain_g = make_msg(a, gid, "just a message")
    reply_g = make_msg(a, gid, "group reply")
    sql("UPDATE messages SET reply_to_id=%s WHERE _id=%s", (t_g, reply_g))
    t_d = make_dm(b, a, "dm original")
    reply_d = make_dm(a, b, "dm reply")
    sql("UPDATE messages SET reply_to_id=%s WHERE _id=%s", (t_d, reply_d))
    bee = sql("SELECT username FROM users WHERE _id=%s", (b,))[0][0]
    plain_d = make_dm(a, b, "dm plain")

    paths = lambda: (
        ("legacy group", client.get(f"/groups/{a}/{gid}", headers=ck), reply_g, plain_g),
        ("legacy DM", client.get(f"/message/messages/{a}/", params={"guest_user": b}, headers=ck), reply_d, plain_d),
    )
    paged = lambda: (
        ("paged group first page", client.get(f"/groups/{a}/{gid}", params={"limit": "20"}, headers=ck), reply_g, plain_g),
        ("paged group endpoint", client.get(f"/groups/{a}/{gid}/messages", params={"limit": "20"}, headers=ck), reply_g, plain_g),
        ("paged DM", client.get(f"/message/messages/{a}/", params={"guest_user": b, "limit": "20"}, headers=ck), reply_d, plain_d),
    )

    def run(label_prefix, getter, expect_reply):
        for label, resp, rid, pid in getter():
            msgs = all_msgs(resp.json())
            r, p = by_id(msgs, rid), by_id(msgs, pid)
            ok_status = resp.status_code == 200 and r is not None and p is not None
            if expect_reply:
                want = (r or {}).get("reply_to_text") in ("group original", "dm original") and (r or {}).get("reply_to_author") == bee \
                    and (r or {}).get("reply_to_id") in (t_g, t_d) and (r or {}).get("reply_to_author_id") == b
                check(f"{label_prefix}{label}: reply carries all four keys", ok_status and want, str(r))
            else:
                check(f"{label_prefix}{label}: reply has NO reply keys", ok_status and not any(k in r for k in REPLY_KEYS), str(r))
            check(f"{label_prefix}{label}: non-reply has no reply keys", ok_status and not any(k in p for k in REPLY_KEYS), str(p))
            # internal columns must never leak on the legacy SELECT * path
            check(f"{label_prefix}{label}: no raw internal columns", ok_status and not any(k in p for k in ("seq", "deleted_at")), str(p))

    set_flag(FLAG, "off", a)
    run("flag off, ", paths, False)
    set_flag(FLAG, "on", a)
    run("flag on, ", paths, True)
    for f in ("chat_pagination", "chat_pagination_dm"):
        set_flag(f, "on", a)
    run("flag off paged, ", lambda: (set_flag(FLAG, "off", a), paged())[1], False)
    run("flag on paged, ", lambda: (set_flag(FLAG, "on", a), paged())[1], True)

    # viewer blocked with the original's author: reply_to_deleted, no text or author (b's content), message still shown
    block(a, b)
    for label, resp, rid, pid in (
        ("paged group", client.get(f"/groups/{a}/{gid}/messages", params={"limit": "20"}, headers=ck), reply_g, plain_g),
        ("legacy group", (set_flag("chat_pagination", "off", a), client.get(f"/groups/{a}/{gid}", headers=ck))[1], reply_g, plain_g),
    ):
        r = by_id(all_msgs(resp.json()), rid)
        check(f"viewer blocked with original's author: {label} reply is reply_to_deleted with no text/author",
              resp.status_code == 200 and r is not None and r.get("reply_to_deleted") is True
              and "reply_to_text" not in r and "reply_to_author" not in r, str(r))
    unblock_all(a, b)

    # one batch query per request
    calls = []
    real = mrp.attach_replies
    import backend.interactions.groups as gmod
    gmod.attach_replies = lambda db, msgs, v: (calls.append(len(msgs)), real(db, msgs, v))[1]
    try:
        set_flag("chat_pagination", "on", a)
        client.get(f"/groups/{a}/{gid}/messages", params={"limit": "20"}, headers=ck)
        check("paged group: attach_replies called once per request", len(calls) == 1, str(calls))
    finally:
        gmod.attach_replies = real
    for f in ("chat_pagination", "chat_pagination_dm", FLAG):
        set_flag(f, "off", a)


def main():
    require_scratch_db()
    client = TestClient(main_module.app)
    try:
        test_ddl_flag_units(client)
        test_send_group(client)
        test_send_dm(client)
        test_immutability_and_encryption(client)
        test_frames(client)
        test_history(client)
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
