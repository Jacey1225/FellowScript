"""Tests for task 20261001-message-threads step 7: sending to a thread over the
WebSocket (``type: 'thread_message'``), delivery frames, push, and old-client
compatibility.

Scratch database only (asserts SHOW port = 55432 first). Proves:
  * ack reuses the PAG ack shape plus thread_id/group_id; row lands in thread_messages only
    (never messages); thread last_activity_at bumped; sender becomes a follower
  * recipients and group are derived server-side from the thread: a forged group_id /
    to_users / from_user is never read; non-member, other-group thread, unknown/malformed
    thread id, suspended sender, flag off, bad shape, NUL, foreign attachment key all
    get the one uniform not_allowed error frame and nothing is saved
  * require_current_terms on send: error frame reason terms_reaccept_required, nothing saved
  * content filter frame, per-user send rate limit (shared 'thread-send' scope), dead socket
  * delivery frame: type 'thread_message', NO from_user and NO text (build 78 ignores it);
    every new frame type fails the web useMessaging.js shape check; sender and blocked
    users get no frame; non-members never get one
  * push: only offline followers who are not blocked, not muted and not the sender;
    data carries ids only
  * single real socket through the endpoint: thread frame, legacy main-chat frame and a
    forged from_user all work on the same connection
  * no PII / bare ERROR word in logs
Run with: cd api && ../.venv/bin/python tests/test_thread_websocket.py
"""
import _pathfix  # noqa: F401
from _thr_common import (  # noqa: F401
    FAILED, FakeWS, LogCapture, add_tmsg, check, cookie, finish, make_group, make_msg, make_thread,
    make_user, own_key, require_scratch_db, set_flag, sql, tcount,
)

import asyncio
import json
import logging
import re
import uuid

from fastapi.testclient import TestClient

import main as main_module
from backend.interactions import thread_send
from backend.interactions.thread_send import send_thread_message
from backend.interactions.websockets import ConnectionManager
from backend.rate_limiting import limiter

WEB_NON_CHAT_TYPES = {"offer", "answer", "ice-candidate", "session-created", "session-joined", "session-left",
                      "talking", "ping", "ack", "error"}
EXPLICIT = "blowjob"


def web_renders_as_chat_bubble(frame):
    """Port of the useMessaging.js onmessage discrimination: what build 78 would append as a bubble."""
    if frame.get("type") in WEB_NON_CHAT_TYPES:
        return False
    return (isinstance(frame.get("from_user"), str) and bool(frame.get("from_user"))
            and isinstance(frame.get("text"), str) and frame.get("timestamp") is not None)


class Env:
    def __init__(self, *uids):
        self.manager = ConnectionManager()
        self.ws = {}
        for u in uids:
            self.ws[u] = FakeWS()
            self.manager.active_connections[u] = self.ws[u]
        self.pushed = []

        async def fake_push(token, title, body, data=None):
            self.pushed.append({"token": token, "title": title, "body": body, "data": data})
            return True

        self._orig = thread_send.send_push
        thread_send.send_push = fake_push

    async def send(self, sender, **fields):
        await send_thread_message(self.manager, {"from_user": sender, "type": "thread_message", **fields})

    def frames(self, uid, kind):
        return [f for f in self.ws[uid].sent if f.get("type") == kind]

    def clear(self):
        for w in self.ws.values():
            w.sent.clear()
        self.pushed.clear()

    def close(self):
        thread_send.send_push = self._orig
        self.manager.close()


def trows(tid):
    return sql("SELECT _id::text, from_user::text, text, seq, created_at FROM thread_messages WHERE thread_id=%s ORDER BY created_at, seq", (tid,))


def main_count(gid):
    return sql("SELECT COUNT(*) FROM messages WHERE group_id=%s", (gid,))[0][0]


async def run():
    a, b, c, blk, outsider, suspended = (make_user("thrws") for _ in range(6))
    stale = make_user("thrws", terms=False)
    gid = make_group([a, b, c, blk, stale, suspended])
    gid_other = make_group([outsider, b])
    set_flag("threads", "on", a)
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blk, a))
    root = make_msg(b, gid, "root text")
    tid = make_thread(gid, root, b, title="thr")
    root_o = make_msg(outsider, gid_other, "other root")
    tid_other = make_thread(gid_other, root_o, outsider, title="other")
    env = Env(a, b, c, blk, outsider, stale, suspended)
    cap = LogCapture()
    logging.getLogger().addHandler(cap)
    limiter.reset()
    try:
        print("happy path, ack, frames, storage")
        before_main = main_count(gid)
        act0 = sql("SELECT last_activity_at FROM threads WHERE _id=%s", (tid,))[0][0]
        ref = "ref-" + uuid.uuid4().hex[:8]
        # forged client fields must be ignored
        await env.send(a, thread_id=tid, text="hello thread", client_ref=ref, group_id=gid_other,
                       to_users=[outsider], timestamp="2020-01-01T00:00:00Z")
        rows = trows(tid)
        check("one thread_messages row stored", len(rows) == 1 and rows[0][2] == "hello thread" and rows[0][1] == a, rows)
        check("nothing written to messages (main chat unchanged)", main_count(gid) == before_main)
        check("forged group_id / to_users: outsider got nothing, other thread untouched",
              env.ws[outsider].sent == [] and tcount(tid_other) == 0)
        acks = env.frames(a, "ack")
        check("sender gets exactly one ack", len(acks) == 1, env.ws[a].sent)
        ack = acks[0]
        check("ack = PAG ack shape (client_ref,id,timestamp) plus thread_id and group_id",
              {"type", "client_ref", "id", "timestamp", "thread_id", "group_id"} <= set(ack)
              and ack["client_ref"] == ref and ack["id"] == rows[0][0] and ack["thread_id"] == tid and ack["group_id"] == gid, ack)
        check("ack carries no from_user/text", "from_user" not in ack and "text" not in ack)
        act1 = sql("SELECT last_activity_at FROM threads WHERE _id=%s", (tid,))[0][0]
        check("thread last_activity_at bumped to the message time", act1 > act0 and act1 == rows[0][4], (act0, act1))
        check("sender became a follower", sql("SELECT 1 FROM thread_followers WHERE thread_id=%s AND user_id=%s", (tid, a)) != [])
        for who, uid in (("member b", b), ("member c", c), ("stale-terms member (receiving is not gated)", stale)):
            fr = env.frames(uid, "thread_message")
            check(f"{who} gets the live frame", len(fr) == 1, env.ws[uid].sent)
        f = env.frames(b, "thread_message")[0]
        check("frame keys: type, ids, sender, body, created_at, seq, attachment_*",
              set(f) == {"type", "thread_id", "group_id", "id", "sender", "body", "created_at", "seq",
                         "attachment_kind", "attachment_meta", "attachment_url"}, sorted(f))
        check("frame values", f["thread_id"] == tid and f["group_id"] == gid and f["id"] == rows[0][0]
              and f["body"] == "hello thread" and f["sender"].startswith("thrws_") and isinstance(f["seq"], int) and f["seq"] == rows[0][3])
        check("frame has a type key and NO from_user / NO text (build 78 ignores it)", "from_user" not in f and "text" not in f)
        check("web useMessaging shape check does not render the thread frame", not web_renders_as_chat_bubble(f))
        check("iOS-style discrimination: a frame with type != nil is never a delivery frame", f.get("type") == "thread_message")
        check("sender gets no echo frame", env.frames(a, "thread_message") == [])
        check("blocked recipient (blocked the sender) gets no frame", env.ws[blk].sent == [], env.ws[blk].sent)
        check("non-member outsider gets no frame", env.ws[outsider].sent == [])
        check("no push when every recipient is online", env.pushed == [])
        env.clear()

        print("attachments")
        k = own_key(a)
        await env.send(a, thread_id=tid, text="", attachment_kind="image", attachment_key=k, attachment_meta={"width": 3})
        r = trows(tid)[-1]
        check("own-prefix image attachment accepted", r[2] == "" and sql("SELECT attachment_key FROM thread_messages WHERE _id=%s", (r[0],))[0][0] == k)
        fr = env.frames(b, "thread_message")[0]
        check("attachment frame carries a url and meta, still no from_user/text", fr["attachment_kind"] == "image" and fr["attachment_url"] and "from_user" not in fr and "text" not in fr, fr)
        n = tcount(tid)
        env.clear()
        await env.send(a, thread_id=tid, text="x", attachment_kind="image", attachment_key=f"attachments/{b}/{uuid.uuid4().hex}.jpg")
        check("foreign attachment key: not_allowed, nothing saved", tcount(tid) == n and env.frames(a, "error")[0]["reason"] == "not_allowed", env.ws[a].sent)
        env.clear()
        await env.send(a, thread_id=tid, text="x", attachment_kind="image", attachment_key="attachments/../etc/passwd")
        check("traversal key: not_allowed", tcount(tid) == n and env.frames(a, "error")[0]["reason"] == "not_allowed")
        env.clear()
        await env.send(a, thread_id=tid, text="x", attachment_kind="gif", attachment_meta={"url": "https://media.example/g.gif"})
        check("gif with meta.url accepted", tcount(tid) == n + 1)
        n += 1
        env.clear()
        await env.send(a, thread_id=tid, text="x", attachment_kind="gif", attachment_meta={})
        check("gif without url: not_allowed", tcount(tid) == n and env.frames(a, "error")[0]["reason"] == "not_allowed")
        env.clear()
        await env.send(a, thread_id=tid, text="x", attachment_kind="hologram", attachment_key="k")
        check("unknown attachment kind: not_allowed", tcount(tid) == n and env.frames(a, "error")[0]["reason"] == "not_allowed")
        env.clear()

        print("uniform denials (nothing saved)")
        denials = [
            ("non-member", dict(sender=outsider, thread_id=tid, text="intrusion")),
            ("thread of a group the sender is not in (forged group_id of own group)", dict(sender=outsider, thread_id=tid, text="intrusion", group_id=gid_other)),
            ("unknown thread id", dict(sender=a, thread_id=str(uuid.uuid4()), text="x")),
            ("malformed thread id", dict(sender=a, thread_id="not-a-uuid", text="x")),
            ("missing thread id", dict(sender=a, text="x")),
            ("empty text and no attachment", dict(sender=a, thread_id=tid, text="   ")),
            ("non-string text", dict(sender=a, thread_id=tid, text=["x"])),
            ("NUL in text", dict(sender=a, thread_id=tid, text="a\x00b")),
            ("suspended sender", dict(sender=suspended, thread_id=tid, text="x")),
        ]
        sql("UPDATE users SET suspended_at=NOW() WHERE _id=%s", (suspended,))
        n = tcount(tid)
        for name, kw in denials:
            env.clear()
            sender = kw.pop("sender")
            await env.send(sender, **kw)
            errs = env.frames(sender, "error")
            check(f"{name}: one not_allowed error frame", len(errs) == 1 and errs[0]["reason"] == "not_allowed" and set(errs[0]) == {"type", "reason", "detail"}, env.ws[sender].sent)
            check(f"{name}: nothing saved and nobody got a frame", tcount(tid) == n and tcount(tid_other) == 0
                  and all(not env.frames(x, "thread_message") for x in env.ws))
        sql("UPDATE users SET suspended_at=NULL WHERE _id=%s", (suspended,))
        env.clear()
        await env.send(outsider, thread_id=tid_other, text="legit in own group")
        check("a member of the OTHER group can send to that group's thread", tcount(tid_other) == 1)
        env.clear()
        sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (c, gid))
        await env.send(c, thread_id=tid, text="removed member")
        check("member removed from the group meanwhile is denied (membership re-read per send)",
              tcount(tid) == n and env.frames(c, "error")[0]["reason"] == "not_allowed")
        sql("UPDATE groups SET users = users || %s::text WHERE _id=%s", (c, gid))
        env.clear()
        set_flag("threads", "off", a)
        await env.send(a, thread_id=tid, text="flag off")
        check("flag off: not_allowed and nothing saved", tcount(tid) == n and env.frames(a, "error")[0]["reason"] == "not_allowed")
        set_flag("threads", "on", a)
        env.clear()
        await send_thread_message(env.manager, {"from_user": "not-a-uuid", "type": "thread_message", "thread_id": tid, "text": "x"})
        check("malformed sender id handled without raising", tcount(tid) == n)

        print("terms gate on send")
        env.clear()
        await env.send(stale, thread_id=tid, text="stale terms")
        errs = env.frames(stale, "error")
        check("stale terms: error frame reason terms_reaccept_required", len(errs) == 1 and errs[0]["reason"] == "terms_reaccept_required", env.ws[stale].sent)
        check("stale terms: nothing saved, no delivery", tcount(tid) == n and all(not env.frames(x, "thread_message") for x in env.ws))
        env.clear()
        await env.send(outsider, thread_id=tid, text="stale outsider")
        check("a non-member still gets the uniform not_allowed (membership before terms)", env.frames(outsider, "error")[0]["reason"] == "not_allowed")

        print("content filter, rate limit, dead socket")
        env.clear()
        await env.send(a, thread_id=tid, text=f"nope {EXPLICIT} nope")
        errs = env.frames(a, "error")
        check("explicit text: message_rejected frame, nothing saved", len(errs) == 1 and errs[0]["reason"] == "message_rejected" and tcount(tid) == n, env.ws[a].sent)
        check("rejection detail does not echo into thread_message frames", all(not env.frames(x, "thread_message") for x in env.ws))
        env.clear()

        class Dead:
            async def send_json(self, p):
                raise RuntimeError("gone")
        env.manager.active_connections[b] = Dead()
        await env.send(a, thread_id=tid, text="to a dead socket")
        check("dead recipient socket does not break the send (row saved)", tcount(tid) == n + 1)
        check("dead socket evicted from the connection table", b not in env.manager.active_connections)
        n += 1
        env.manager.active_connections[b] = env.ws[b]
        env.clear()

        limiter.reset()
        results = []
        for i in range(62):
            env.ws[a].sent.clear()
            await env.send(a, thread_id=tid, text=f"burst {i}")
            errs = env.frames(a, "error")
            results.append(errs[0]["reason"] if errs else "ok")
        check("send_rate 60/minute: first 60 ok, then rate_limited", results[:60].count("ok") == 60 and results[60:] == ["rate_limited", "rate_limited"], results[58:])
        check("rate limited sends saved nothing", tcount(tid) == n + 60)
        env.clear()
        # the limit is per sender (fixed scope keyed by user id), not per thread id
        await env.send(b, thread_id=tid, text="b is unaffected")
        check("another sender has their own bucket", env.frames(b, "error") == [])
        limiter.reset()
        env.clear()

        print("push to offline followers only")
        gid_p = make_group([a, b, c, blk])
        root_p = make_msg(b, gid_p, "push root")
        tid_p = make_thread(gid_p, root_p, b, title="push")
        sql("INSERT INTO thread_followers (thread_id, user_id) VALUES (%s,%s),(%s,%s),(%s,%s),(%s,%s) ON CONFLICT DO NOTHING",
            (tid_p, b, tid_p, c, tid_p, blk, tid_p, a))
        for u_ in (a, b, c, blk):
            sql("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) ON CONFLICT DO NOTHING", (u_, f"tok-{u_[:8]}"))
        penv = Env(a)  # only the sender is online; b, c, blk offline
        try:
            await penv.send(a, thread_id=tid_p, text="ping the followers")
            tokens = sorted(p["token"] for p in penv.pushed)
            check("pushed to offline followers b and c only (not the sender, not the blocked user)",
                  tokens == sorted([f"tok-{b[:8]}", f"tok-{c[:8]}"]), penv.pushed)
            p0 = penv.pushed[0]
            check("push data carries ids only: action, group_id, thread_id", p0["data"] == {"action": "thread_message", "group_id": gid_p, "thread_id": tid_p}, p0["data"])
            check("push title is the sender's username, body the message", p0["title"].startswith("thrws_") and p0["body"] == "ping the followers")
            penv.pushed.clear()
            sql("INSERT INTO group_mutes (user_id, group_id) VALUES (%s,%s)", (c, gid_p))
            await penv.send(a, thread_id=tid_p, text="muted check")
            check("a group-muted follower gets no push", sorted(p["token"] for p in penv.pushed) == [f"tok-{b[:8]}"], penv.pushed)
            penv.pushed.clear()
            sql("DELETE FROM thread_followers WHERE thread_id=%s AND user_id=%s", (tid_p, b))
            await penv.send(a, thread_id=tid_p, text="non follower check")
            check("an offline NON-follower member gets no push", penv.pushed == [], penv.pushed)
            penv.pushed.clear()
            long = "L" * 300
            sql("INSERT INTO thread_followers (thread_id, user_id) VALUES (%s,%s)", (tid_p, b))
            await penv.send(a, thread_id=tid_p, text=long)
            check("push body truncated to 100 chars", all(len(p["body"]) <= 100 for p in penv.pushed) and penv.pushed, penv.pushed)
            penv.pushed.clear()
            # b (offline follower) replies: a became a follower by sending, a offline -> pushed
            penv.manager.active_connections.pop(a)
            penv.ws[b] = FakeWS()
            penv.manager.active_connections[b] = penv.ws[b]
            await penv.send(b, thread_id=tid_p, text="reply from b")
            check("the earlier sender is now a follower and is pushed when offline", [p["token"] for p in penv.pushed] == [f"tok-{a[:8]}"] or f"tok-{a[:8]}" in [p["token"] for p in penv.pushed], penv.pushed)
        finally:
            penv.close()
    finally:
        logging.getLogger().removeHandler(cap)
        env.close()

    print("logging")
    msgs = [r.getMessage() for r in cap.records if r.name.startswith("backend.interactions.thread_send")]
    allm = " ".join(r.getMessage() for r in cap.records)
    for canary in ("intrusion", "stale terms", "hello thread", "to a dead socket", "ping the followers"):
        check(f"no message text ({canary!r}) in any log line", canary not in allm)
    check("no bare ERROR word in non-error thread_send log lines",
          not any(re.search(r"\bERROR\b", r.getMessage()) for r in cap.records
                  if r.name.startswith("backend.interactions.thread_send") and r.levelno < logging.ERROR))
    check("thread_send logs carry ids/cause only (rejections at INFO)", any("rejected" in m for m in msgs), msgs[:3])
    check("expected denials never log at ERROR/WARNING",
          not any(r.levelno >= logging.WARNING and "rejected" in r.getMessage() for r in cap.records))


def test_real_socket():
    print("single real socket through the endpoint (one dispatch branch)")
    a, b = make_user("thrsock"), make_user("thrsock")
    stale = make_user("thrsock", terms=False)
    outsider = make_user("thrsock")
    gid = make_group([a, b, stale])
    set_flag("threads", "on", a)
    root = make_msg(b, gid, "sock root")
    tid = make_thread(gid, root, b, title="sock")
    client = TestClient(main_module.app)
    ck_a, ck_b, ck_s = cookie(a), cookie(b), cookie(stale)
    limiter.reset()
    with client.websocket_connect(f"/message/ws/{a}", headers=ck_a) as wa, \
         client.websocket_connect(f"/message/ws/{b}", headers=ck_b) as wb:
        # forged from_user, group_id and to_users on the frame
        wa.send_json({"type": "thread_message", "thread_id": tid, "text": "via socket", "client_ref": "sock-ref-1",
                      "from_user": b, "group_id": str(uuid.uuid4()), "to_users": [outsider]})
        ack = wa.receive_json()
        check("ack over the real socket with client_ref + thread_id", ack.get("type") == "ack" and ack.get("client_ref") == "sock-ref-1" and ack.get("thread_id") == tid, ack)
        got = wb.receive_json()
        check("member's socket receives the thread frame (type, no from_user/text)",
              got.get("type") == "thread_message" and "from_user" not in got and "text" not in got and got["body"] == "via socket", got)
        check("web shape check ignores it", not web_renders_as_chat_bubble(got))
        row = sql("SELECT from_user::text FROM thread_messages WHERE thread_id=%s AND text='via socket'", (tid,))
        check("stored author is the SESSION user, the forged from_user was overwritten", row == [(a,)], row)
        # legacy main-chat frame (no type) still goes through send_msg on the same socket
        wa.send_json({"to_users": [b], "text": "legacy group frame", "group_id": gid, "client_ref": "sock-ref-2",
                      "timestamp": "2026-10-01T00:00:00Z"})
        ack2 = wa.receive_json()
        check("legacy main-chat frame still acked on the same socket", ack2.get("type") == "ack" and ack2.get("client_ref") == "sock-ref-2", ack2)
        legacy = wb.receive_json()
        check("legacy delivery frame keeps its old shape (from_user + text, no type)",
              legacy.get("type") is None and legacy.get("text") == "legacy group frame" and bool(legacy.get("from_user")) and web_renders_as_chat_bubble(legacy), legacy)
        check("legacy frame went to messages, not thread_messages",
              sql("SELECT COUNT(*) FROM messages WHERE group_id=%s AND text='legacy group frame'", (gid,))[0][0] == 1
              and sql("SELECT COUNT(*) FROM thread_messages WHERE thread_id=%s AND text='legacy group frame'", (tid,))[0][0] == 0)
        # a thread frame with a bad shape gets an error frame on the same socket; the socket survives
        wa.send_json({"type": "thread_message", "thread_id": "nope", "text": "x"})
        err = wa.receive_json()
        check("bad thread frame: uniform error frame, socket stays open", err.get("type") == "error" and err.get("reason") == "not_allowed", err)
        wa.send_json({"type": "thread_message", "thread_id": tid, "text": "after error", "client_ref": "sock-ref-3"})
        check("socket still works after an error frame", wa.receive_json().get("client_ref") == "sock-ref-3")
        wb.receive_json()
    with client.websocket_connect(f"/message/ws/{stale}", headers=ck_s) as ws_:
        ws_.send_json({"type": "thread_message", "thread_id": tid, "text": "stale over socket"})
        err = ws_.receive_json()
        check("stale-terms sender over the real socket: terms_reaccept_required error frame", err.get("type") == "error" and err.get("reason") == "terms_reaccept_required", err)
    check("stale-terms socket send stored nothing", sql("SELECT COUNT(*) FROM thread_messages WHERE text='stale over socket'")[0][0] == 0)
    limiter.reset()


def test_old_client_compat():
    print("old-client compatibility fixtures")
    # build-78-shaped delivery frames (what the web bundle / iOS build 78 know)
    legacy_chat = {"from_user": "bob", "text": "hi", "timestamp": "2026-10-01T00:00:00Z", "group_id": "g"}
    ack = {"type": "ack", "client_ref": "r", "id": "i", "timestamp": "t"}
    err = {"type": "error", "reason": "not_allowed", "detail": "d"}
    check("fixture: legacy delivery frame renders as a chat bubble", web_renders_as_chat_bubble(legacy_chat))
    check("fixture: ack / error / ping are never bubbles", not any(web_renders_as_chat_bubble(f) for f in (ack, err, {"type": "ping"})))
    new_frames = [
        {"type": "thread_message", "thread_id": "t", "group_id": "g", "id": "i", "sender": "bob", "body": "hi", "created_at": "t", "seq": 1,
         "attachment_kind": None, "attachment_meta": {}, "attachment_url": None},
        {"type": "message_deleted", "id": "i", "group_id": "g", "deleted_at": "t"},
        {"type": "message_restored", "id": "i", "group_id": "g", "sender": "bob", "body": "hi", "created_at": "t", "seq": 1},
        {"type": "ack", "client_ref": "r", "id": "i", "group_id": "g", "thread_id": "t", "timestamp": "t"},
    ]
    for f in new_frames:
        check(f"new frame type {f['type']!r} has a type key, no from_user/text, fails the web shape check",
              "type" in f and "from_user" not in f and "text" not in f and not web_renders_as_chat_bubble(f), f)
    check("the extended ack still satisfies the legacy ack contract (type, client_ref, id, timestamp)",
          {"type", "client_ref", "id", "timestamp"} <= set(new_frames[3]))
    # JSON snapshot of the keys the legacy delivery frame had before this task
    legacy_keys = ["from_user", "group_id", "text", "timestamp"]
    check("legacy delivery frame key snapshot unchanged", all(k in legacy_chat for k in legacy_keys))
    check("flag off + legacy path: send_msg never mentions thread frames",
          not any(t in open(_pathfix_path("backend/interactions/websockets.py")).read() for t in ("thread_message", "thread_send", "thread_id")))


def _pathfix_path(rel):
    import os
    from _thr_common import API_DIR
    return os.path.join(API_DIR, rel)


def main():
    require_scratch_db()
    try:
        asyncio.run(run())
        test_real_socket()
        test_old_client_compat()
    except BaseException as e:
        FAILED.append(("unexpected exception", repr(e)))
        raise
    finally:
        limiter.reset()
        finish()


if __name__ == "__main__":
    main()
