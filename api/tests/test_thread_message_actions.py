"""Tests for task 20261122-app-fixes-threads-widget step 2: reactions, pins, replies and reports
on THREAD messages (separate ``thread_messages`` table).

Scratch database only (asserts SHOW port = 55432 first). Proves:
  * reactions: add / remove idempotent, aggregate on the thread read (``reactions`` with
    viewer_reacted), allowlist 422, caps 409, live ``thread_reaction_updated`` frame to the other
    members only (not the actor, not a blocked member), flag off / non-member / thread of another
    group / message of another thread / soft-deleted / blocked author: the uniform 404
  * pins: scoped to ONE thread (list shows only that thread's pins, not another thread's),
    idempotent, ``pinned`` on the read, ``thread_pin_updated`` frame, unpin, authz as above
  * replies via the WS frame ``reply_to``: stored as ``thread_messages.reply_to_id``; target must
    be a live message of the SAME thread (other thread, group message, deleted, blocked author:
    ``reply_invalid``, nothing stored); read returns reply keys, ``reply_to_deleted`` once the
    original is soft-deleted; the live frame carries the reply keys and ``from_user_id``
  * reports: ``content_type=thread_message`` resolves the thread message author server-side
  * block: the read row carries ``from_user_id`` (what the client passes to /blocks)
Run with: cd api && ../.venv/bin/python tests/test_thread_message_actions.py
"""
import _pathfix  # noqa: F401
import base64
import os

os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ["CONTENT_ENCRYPTION_KEYS"] = "1:" + base64.b64encode(b"A" * 32).decode()

from _thr_common import (  # noqa: E402,F401
    FAILED, FakeWS, add_tmsg, check, cookie, finish, make_group, make_msg, make_thread, make_user,
    require_scratch_db, set_flag, sql,
)

import asyncio  # noqa: E402
import uuid  # noqa: E402
from unittest import mock  # noqa: E402

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from backend.interactions import thread_send  # noqa: E402
from backend.interactions.thread_send import send_thread_message  # noqa: E402
from backend.interactions.websockets import ConnectionManager  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from routes import threads as threads_routes  # noqa: E402

NOT_FOUND = {"code": "not_found", "message": "Not found"}
THUMBS, HEART = "\U0001F44D", "❤️"


def base(uid, gid, tid, mid, tail):
    return f"/groups/{uid}/{gid}/threads/{tid}/messages/{mid}/{tail}"


def read(client, uid, gid, tid):
    limiter.reset()
    r = client.get(f"/groups/{uid}/{gid}/threads/{tid}/messages", headers=cookie(uid))
    assert r.status_code == 200, r.text
    return {m["id"]: m for m in r.json()["messages"]}


def enable():
    for f in ("threads", "message_reactions", "message_pins", "chat_replies"):
        set_flag(f, "on", USER0[0])


USER0 = []


def test_reactions(client):
    print("reactions")
    a, b, blk, outsider = (make_user("thra") for _ in range(4))
    USER0[:] = [a]
    gid, gid2 = make_group([a, b, blk]), make_group([a])
    enable()
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blk, a))
    tid = make_thread(gid, make_msg(b, gid), b)
    tid2 = make_thread(gid, make_msg(b, gid), b)
    m = add_tmsg(tid, b, "hello")
    frames = []
    with mock.patch.object(threads_routes, "_push_frame", lambda rec, fr: frames.append((rec, fr))):
        limiter.reset()
        r = client.post(base(a, gid, tid, m, "reactions"), json={"emoji": THUMBS}, headers=cookie(a))
        check("add 200 {emoji,count,viewer_reacted}", r.status_code == 200 and r.json() == {"emoji": THUMBS, "count": 1, "viewer_reacted": True}, r.text)
        check("frame: thread_reaction_updated to others only", len(frames) == 1 and frames[0][1]["type"] == "thread_reaction_updated"
              and frames[0][1]["thread_id"] == tid and frames[0][1]["message_id"] == m
              and a not in frames[0][0] and b in frames[0][0] and blk not in frames[0][0], frames)
        check("frame has neither from_user nor text", "from_user" not in frames[0][1] and "text" not in frames[0][1])
        limiter.reset()
        r = client.post(base(a, gid, tid, m, "reactions"), json={"emoji": THUMBS}, headers=cookie(a))
        check("idempotent add: count stays 1, no second frame", r.json()["count"] == 1 and len(frames) == 1)
    check("read aggregates reactions with viewer_reacted",
          read(client, a, gid, tid)[m]["reactions"] == [{"emoji": THUMBS, "count": 1, "viewer_reacted": True}])
    check("other viewer sees viewer_reacted false",
          read(client, b, gid, tid)[m]["reactions"] == [{"emoji": THUMBS, "count": 1, "viewer_reacted": False}])
    check("no row in the main-chat table", sql("SELECT COUNT(*) FROM message_reactions WHERE message_id=%s", (m,))[0][0] == 0)
    limiter.reset()
    check("bad emoji 422", client.post(base(a, gid, tid, m, "reactions"), json={"emoji": "x"}, headers=cookie(a)).status_code == 422)
    limiter.reset()
    r = client.delete(base(a, gid, tid, m, "reactions"), params={"emoji": THUMBS}, headers=cookie(a))
    check("remove 200 count 0", r.status_code == 200 and r.json() == {"emoji": THUMBS, "count": 0, "viewer_reacted": False}, r.text)

    denials = {}
    limiter.reset()
    denials["non-member"] = client.post(base(outsider, gid, tid, m, "reactions"), json={"emoji": HEART}, headers=cookie(outsider))
    limiter.reset()
    denials["thread of another group"] = client.post(base(a, gid2, tid, m, "reactions"), json={"emoji": HEART}, headers=cookie(a))
    limiter.reset()
    denials["message of another thread"] = client.post(base(a, gid, tid2, m, "reactions"), json={"emoji": HEART}, headers=cookie(a))
    limiter.reset()
    denials["unknown message"] = client.post(base(a, gid, tid, str(uuid.uuid4()), "reactions"), json={"emoji": HEART}, headers=cookie(a))
    gone = add_tmsg(tid, b, "gone", deleted=True)
    limiter.reset()
    denials["soft-deleted"] = client.post(base(a, gid, tid, gone, "reactions"), json={"emoji": HEART}, headers=cookie(a))
    bm = add_tmsg(tid, blk, "from blocked")
    limiter.reset()
    denials["blocked author"] = client.post(base(a, gid, tid, bm, "reactions"), json={"emoji": HEART}, headers=cookie(a))
    for name, r in denials.items():
        check(f"{name}: uniform 404", r.status_code == 404 and r.json()["detail"] == NOT_FOUND, (r.status_code, r.text))
    check("denials wrote nothing", sql("SELECT COUNT(*) FROM thread_message_reactions WHERE message_id = ANY(%s)", ([m, gone, bm],))[0][0] == 0)
    set_flag("message_reactions", "off", a)
    limiter.reset()
    check("reactions flag off: uniform 404", client.post(base(a, gid, tid, m, "reactions"), json={"emoji": HEART}, headers=cookie(a)).status_code == 404)
    set_flag("message_reactions", "on", a)
    # caps
    from backend.interactions.message_reactions import MAX_PER_USER_PER_MESSAGE, ALLOWED_EMOJI
    for e in ALLOWED_EMOJI[:MAX_PER_USER_PER_MESSAGE]:
        limiter.reset()
        client.post(base(a, gid, tid, m, "reactions"), json={"emoji": e}, headers=cookie(a))
    limiter.reset()
    r = client.post(base(a, gid, tid, m, "reactions"), json={"emoji": ALLOWED_EMOJI[MAX_PER_USER_PER_MESSAGE]}, headers=cookie(a))
    check("per-user cap 409 user_cap", r.status_code == 409 and r.json()["detail"] == {"code": "user_cap"}, r.text)


def test_pins(client):
    print("pins")
    a, b, outsider = (make_user("thra") for _ in range(3))
    USER0[:] = [a]
    gid = make_group([a, b])
    enable()
    tid = make_thread(gid, make_msg(b, gid), b)
    tid2 = make_thread(gid, make_msg(b, gid), b)
    m, m2 = add_tmsg(tid, b, "pin me"), add_tmsg(tid2, b, "other thread")
    frames = []
    with mock.patch.object(threads_routes, "_push_frame", lambda rec, fr: frames.append((rec, fr))):
        limiter.reset()
        r = client.post(base(a, gid, tid, m, "pin"), headers=cookie(a))
        check("pin 200", r.status_code == 200 and r.json() == {"message_id": m, "thread_id": tid, "pinned": True}, r.text)
        check("frame thread_pin_updated", frames and frames[0][1]["type"] == "thread_pin_updated" and frames[0][1]["pinned"] is True)
        limiter.reset()
        client.post(base(a, gid, tid, m, "pin"), headers=cookie(a))
        check("idempotent pin: one row, one frame", sql("SELECT COUNT(*) FROM thread_message_pins WHERE message_id=%s", (m,))[0][0] == 1 and len(frames) == 1)
    limiter.reset()
    client.post(base(b, gid, tid2, m2, "pin"), headers=cookie(b))
    check("read marks pinned", read(client, a, gid, tid)[m]["pinned"] is True)
    limiter.reset()
    j = client.get(f"/groups/{a}/{gid}/threads/{tid}/pins", headers=cookie(a)).json()
    check("pin list is scoped to the thread", j["count"] == 1 and j["pins"][0]["message_id"] == m
          and j["pins"][0]["message"]["thread_id"] == tid and not j["has_more"], j)
    check("no row in the main-chat pin table and no system line", sql("SELECT COUNT(*) FROM message_pins WHERE message_id=%s", (m,))[0][0] == 0)
    limiter.reset()
    r = client.post(base(a, gid, tid, m2, "pin"), headers=cookie(a))
    check("pinning a message of another thread: uniform 404", r.status_code == 404 and r.json()["detail"] == NOT_FOUND)
    limiter.reset()
    r = client.get(f"/groups/{outsider}/{gid}/threads/{tid}/pins", headers=cookie(outsider))
    check("non-member list: uniform 404", r.status_code == 404 and r.json()["detail"] == NOT_FOUND)
    limiter.reset()
    r = client.delete(base(a, gid, tid, m, "pin"), headers=cookie(a))
    check("unpin 200", r.status_code == 200 and r.json()["pinned"] is False)
    check("unpinned in the read", read(client, a, gid, tid)[m]["pinned"] is False)


class Env:
    def __init__(self, *uids):
        self.manager = ConnectionManager()
        self.ws = {}
        for u in uids:
            self.ws[u] = FakeWS()
            self.manager.active_connections[u] = self.ws[u]

        async def fake_push(*a, **k):
            return True

        self._orig = thread_send.send_push
        thread_send.send_push = fake_push

    async def send(self, sender, **fields):
        await send_thread_message(self.manager, {"from_user": sender, "type": "thread_message", **fields})

    def errors(self, uid):
        return [f for f in self.ws[uid].sent if f.get("type") == "error"]

    def frames(self, uid):
        return [f for f in self.ws[uid].sent if f.get("type") == "thread_message"]

    def close(self):
        thread_send.send_push = self._orig
        self.manager.close()


async def run_replies(client):
    print("replies, live frame, reports, block id")
    a, b, blk = (make_user("thra") for _ in range(3))
    USER0[:] = [a]
    gid = make_group([a, b, blk])
    enable()
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blk, a))
    tid = make_thread(gid, make_msg(b, gid), b)
    tid2 = make_thread(gid, make_msg(b, gid), b)
    orig = add_tmsg(tid, b, "the original")
    other_thread = add_tmsg(tid2, b, "elsewhere")
    group_msg = make_msg(b, gid, "group level")
    gone = add_tmsg(tid, b, "gone", deleted=True)
    from_blocked = add_tmsg(tid, blk, "blocked")
    env = Env(a, b, blk)
    limiter.reset()
    try:
        await env.send(a, thread_id=tid, text="my reply", reply_to=orig)
        row = sql("SELECT _id::text, reply_to_id::text FROM thread_messages WHERE thread_id=%s AND from_user=%s", (tid, a))
        check("reply stored with reply_to_id only", len(row) == 1 and row[0][1] == orig, row)
        fr = env.frames(b)
        check("live frame has reply keys + from_user_id", fr and fr[0]["reply_to_id"] == orig and fr[0]["reply_to_text"] == "the original"
              and fr[0]["reply_to_author_id"] == b and fr[0]["from_user_id"] == a, fr)
        for name, target in (("other thread", other_thread), ("group-chat message", group_msg), ("deleted", gone),
                             ("blocked author", from_blocked), ("unknown", str(uuid.uuid4()))):
            limiter.reset()
            n = sql("SELECT COUNT(*) FROM thread_messages WHERE thread_id=%s", (tid,))[0][0]
            await env.send(a, thread_id=tid, text=f"bad {name}", reply_to=target)
            check(f"reply to {name}: reply_invalid, nothing stored",
                  any(e["reason"] == "reply_invalid" for e in env.errors(a))
                  and sql("SELECT COUNT(*) FROM thread_messages WHERE thread_id=%s", (tid,))[0][0] == n)
            env.ws[a].sent.clear()
        msgs = read(client, a, gid, tid)
        mine = next(m for m in msgs.values() if m["text"] == "my reply")
        check("read returns reply keys", mine["reply_to_id"] == orig and mine["reply_to_text"] == "the original" and mine["reply_to_author_id"] == b, mine)
        check("read row exposes from_user_id for block", mine["from_user_id"] == a)
        sql("UPDATE thread_messages SET deleted_at = NOW() WHERE _id=%s", (orig,))
        mine = next(m for m in read(client, a, gid, tid).values() if m["text"] == "my reply")
        check("original soft-deleted: reply_to_deleted, no text", mine.get("reply_to_deleted") is True and "reply_to_text" not in mine, mine)
        set_flag("chat_replies", "off", a)
        limiter.reset()
        await env.send(a, thread_id=tid, text="flag off reply", reply_to=other_thread)
        check("chat_replies off: key ignored, plain message saved",
              sql("SELECT reply_to_id FROM thread_messages WHERE thread_id=%s AND text='flag off reply'", (tid,))[0][0] is None)
        set_flag("chat_replies", "on", a)
    finally:
        env.close()
    # reports
    m = add_tmsg(tid, b, "report me")
    with mock.patch("backend.interactions.reports.send_email"):
        limiter.reset()
        r = client.post("/reports/", json={"content_type": "thread_message", "content_id": m, "reason": "spam"}, headers=cookie(a))
    check("thread_message report accepted", r.status_code == 201, r.text)
    row = sql("SELECT reported_user_id::text, content_type FROM content_reports WHERE content_id=%s", (m,))
    check("report resolved author server-side", row and row[0][0] == b and row[0][1] == "thread_message", row)


def main():
    require_scratch_db()
    client = TestClient(main_module.app)
    try:
        test_reactions(client)
        test_pins(client)
        asyncio.run(run_replies(client))
    except BaseException as e:
        FAILED.append(("unexpected exception", repr(e)))
        raise
    finally:
        limiter.reset()
        finish(("threads", "message_reactions", "message_pins", "chat_replies"))


if __name__ == "__main__":
    main()
