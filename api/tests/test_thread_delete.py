"""Tests for task 20261008-thread-rename-delete: DELETE a thread, and rename sealing.

Scratch database only (asserts SHOW port = 55432 first). Proves:
  * authorization matrix for DELETE /groups/{u}/{g}/threads/{t}: thread creator -> 204,
    group owner (groups.creator_id) -> 204, plain member / non-member / thread of another
    group / unknown / malformed id / removed member / flag off / anonymous -> the identical
    uniform 404 body and NOTHING deleted; ownerless group (NULL creator_id): a non-creator
    cannot delete, the thread creator can; a blocked-creator thread can still be deleted by
    the owner
  * hard delete: no row left in threads, thread_messages, thread_followers; the root
    message in the group chat remains; a second thread in the group is untouched
  * repeat delete -> the same uniform 404 (no existence oracle, idempotent)
  * attachments: author-owned unreferenced keys land in the pending_s3_deletes outbox in
    the same transaction; a key shared with the main chat, a key shared with another
    thread, and a foreign-prefix key are never queued; the request path never calls S3
  * WS fan-out: every live member's socket (actor included) gets
    {type: thread_deleted, thread_id, group_id} and nothing else (no from_user, no text);
    non-members get nothing; a dead socket never fails the 204
  * a send racing a delete (insert blocked on the row lock) fails closed with the
    uniform not_allowed reply and nothing resurrects
  * rate limit: scope thread_delete is per-user, fixed scope, separate from rename
  * audit: THREAD_DELETE with ids only, no title/message text anywhere in the logs
  * rename seals via content_store and delete works, with content_encryption_write both
    OFF (plaintext at rest) and ON (enc:v1: at rest, no plaintext in the row dump)
Run with: cd api && ../.venv/bin/python tests/test_thread_delete.py
"""
import _pathfix  # noqa: F401
import base64
import os

os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ["CONTENT_ENCRYPTION_KEYS"] = "1:" + base64.b64encode(b"A" * 32).decode()

from _thr_common import (  # noqa: E402,F401
    FAILED, FakeWS, LogCapture, add_tmsg, check, cookie, finish, make_group, make_msg, make_thread,
    make_user, own_key, require_scratch_db, set_flag, sql,
)

import asyncio  # noqa: E402
import json  # noqa: E402
import logging  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import uuid  # noqa: E402
from unittest import mock  # noqa: E402

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from backend.interactions import attachments, flags, thread_send  # noqa: E402
from backend.interactions.websockets import ConnectionManager  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from db import DBManager  # noqa: E402
from routes.messaging import manager as ws_manager  # noqa: E402

NOT_FOUND = {"code": "not_found", "message": "Not found"}
SECRET_TITLE = "zq-secret-title-7731"
SECRET_BODY = "zq-secret-body-9902"


def u(uid, gid, tail=""):
    return f"/groups/{uid}/{gid}/threads{tail}"


def exists(tid):
    return {
        "threads": sql("SELECT COUNT(*) FROM threads WHERE _id=%s", (tid,))[0][0],
        "msgs": sql("SELECT COUNT(*) FROM thread_messages WHERE thread_id=%s", (tid,))[0][0],
        "followers": sql("SELECT COUNT(*) FROM thread_followers WHERE thread_id=%s", (tid,))[0][0],
    }


def follow(tid, uid):
    sql("INSERT INTO thread_followers (thread_id, user_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (tid, uid))


def outbox(keys):
    return {r[0] for r in sql("SELECT key FROM pending_s3_deletes WHERE key = ANY(%s)", (list(keys),))}


def test_flag_and_anon(client):
    print("flag off / anonymous")
    a = make_user()
    gid = make_group([a], creator=a)
    t = make_thread(gid, make_msg(a, gid), a)
    set_flag("threads", "off", a)
    limiter.reset()
    r = client.delete(u(a, gid, f"/{t}"), headers=cookie(a))
    check("flag off: uniform 404", r.status_code == 404 and r.json()["detail"] == NOT_FOUND, (r.status_code, r.text))
    check("flag off: thread untouched", exists(t)["threads"] == 1)
    set_flag("threads", "on", a)
    limiter.reset()
    check("anonymous delete denied", client.delete(u(a, gid, f"/{t}")).status_code in (401, 403, 404))
    check("anonymous delete: thread untouched", exists(t)["threads"] == 1)
    other = make_user()
    limiter.reset()
    r = client.delete(u(a, gid, f"/{t}"), headers=cookie(other))
    check("session of another user on someone's path id (require_match): denied", r.status_code in (401, 403, 404), r.status_code)
    check("... and thread untouched", exists(t)["threads"] == 1)


def test_authz_and_cascade(client):
    print("authorization matrix + hard delete + cascade")
    creator, owner, member, outsider = make_user(), make_user(), make_user(), make_user()
    gid = make_group([creator, owner, member], creator=owner)
    gid2 = make_group([creator, owner], creator=owner)
    set_flag("threads", "on", owner)
    root1, root2 = make_msg(creator, gid), make_msg(creator, gid)
    t_creator = make_thread(gid, root1, creator, title=SECRET_TITLE)
    t_owner = make_thread(gid, root2, creator, title="for owner")
    t_keep = make_thread(gid, make_msg(owner, gid), owner, title="keep me")
    t_other_group = make_thread(gid2, make_msg(owner, gid2), owner, title="other group")
    for t in (t_creator, t_owner, t_keep):
        add_tmsg(t, creator, SECRET_BODY)
        add_tmsg(t, member, "second")
        follow(t, creator)
        follow(t, member)
    limiter.reset()
    ref = client.delete(u(owner, gid, f"/{uuid.uuid4()}"), headers=cookie(owner))
    check("unknown thread: uniform 404", ref.status_code == 404 and ref.json()["detail"] == NOT_FOUND, ref.text)
    denials = {
        "plain member": (member, gid, t_creator),
        "non-member": (outsider, gid, t_creator),
        "thread of another group (owner of both)": (owner, gid, t_other_group),
        "creator of thread in group B using group A path": (owner, gid, t_other_group),
        "malformed thread id": (owner, gid, "nope"),
        "malformed group id": (owner, "nope", t_creator),
    }
    for name, (who, g, t) in denials.items():
        limiter.reset()
        resp = client.delete(u(who, g, f"/{t}"), headers=cookie(who))
        check(f"denial: {name}: identical 404", resp.status_code == 404 and resp.json() == ref.json(), (resp.status_code, resp.text))
    check("denials deleted nothing", all(exists(t)["threads"] == 1 for t in (t_creator, t_owner, t_keep, t_other_group)))
    check("denials kept messages and followers", exists(t_creator) == {"threads": 1, "msgs": 2, "followers": 2})

    limiter.reset()
    r = client.delete(u(creator, gid, f"/{t_creator}"), headers=cookie(creator))
    check("thread creator: 204 empty body", r.status_code == 204 and r.content == b"", (r.status_code, r.text))
    check("creator delete: no row left in threads/thread_messages/thread_followers", exists(t_creator) == {"threads": 0, "msgs": 0, "followers": 0}, exists(t_creator))
    check("root message remains in the group chat", sql("SELECT COUNT(*) FROM messages WHERE _id=%s", (root1,))[0][0] == 1)
    check("another thread in the same group untouched", exists(t_keep) == {"threads": 1, "msgs": 2, "followers": 2})
    check("thread in another group untouched", exists(t_other_group)["threads"] == 1)

    limiter.reset()
    r = client.delete(u(owner, gid, f"/{t_owner}"), headers=cookie(owner))
    check("group owner (not the thread creator): 204", r.status_code == 204, (r.status_code, r.text))
    check("owner delete: nothing left", exists(t_owner) == {"threads": 0, "msgs": 0, "followers": 0})
    check("owner delete: root message remains", sql("SELECT COUNT(*) FROM messages WHERE _id=%s", (root2,))[0][0] == 1)

    limiter.reset()
    again = client.delete(u(owner, gid, f"/{t_owner}"), headers=cookie(owner))
    check("repeat delete: identical uniform 404", again.status_code == 404 and again.json() == ref.json(), (again.status_code, again.text))
    limiter.reset()
    again2 = client.delete(u(creator, gid, f"/{t_creator}"), headers=cookie(creator))
    check("repeat delete by creator: identical uniform 404", again2.status_code == 404 and again2.json() == ref.json())
    lst = client.get(u(owner, gid), headers=cookie(owner)).json()
    ids = {i["id"] for i in lst["threads"]}
    check("deleted threads are gone from the list, survivor remains", t_creator not in ids and t_owner not in ids and t_keep in ids, ids)
    gone = client.get(u(owner, gid, f"/{t_creator}/messages"), headers=cookie(owner))
    check("reading a deleted thread's messages: uniform 404", gone.status_code == 404 and gone.json()["detail"] == NOT_FOUND)

    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (creator, gid))
    limiter.reset()
    r = client.delete(u(creator, gid, f"/{t_keep}"), headers=cookie(creator))
    check("removed member cannot delete (404)", r.status_code == 404 and r.json() == ref.json(), r.status_code)
    # a former member who is still the creator_id (owner left): membership is required first
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (owner, gid))
    limiter.reset()
    r = client.delete(u(owner, gid, f"/{t_keep}"), headers=cookie(owner))
    check("owner who is no longer a member cannot delete (404)", r.status_code == 404 and r.json() == ref.json(), r.status_code)
    check("survivor still exists after all those denials", exists(t_keep)["threads"] == 1)


def test_ownerless_and_blocked(client):
    print("ownerless group (NULL creator_id) and blocked creator")
    c, m = make_user(), make_user()
    gid = make_group([c, m], creator=None)
    set_flag("threads", "on", c)
    t = make_thread(gid, make_msg(c, gid), c)
    limiter.reset()
    r = client.delete(u(m, gid, f"/{t}"), headers=cookie(m))
    check("ownerless group: non-creator member is denied (fail closed)", r.status_code == 404, r.status_code)
    check("ownerless: nothing deleted", exists(t)["threads"] == 1)
    limiter.reset()
    r = client.delete(u(c, gid, f"/{t}"), headers=cookie(c))
    check("ownerless group: the thread creator can delete", r.status_code == 204, r.text)

    owner, bc = make_user(), make_user()
    gid2 = make_group([owner, bc], creator=owner)
    t2 = make_thread(gid2, make_msg(bc, gid2), bc)
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (owner, bc))
    limiter.reset()
    r = client.delete(u(owner, gid2, f"/{t2}"), headers=cookie(owner))
    check("owner who blocked the creator can still delete that thread", r.status_code == 204, (r.status_code, r.text))
    check("blocked-creator thread gone", exists(t2)["threads"] == 0)


def test_attachments(client):
    print("attachment keys: outbox, shared and foreign keys never queued, no S3 call")
    a, b = make_user(), make_user()
    gid = make_group([a, b], creator=a)
    set_flag("threads", "on", a)
    t, t_peer = make_thread(gid, make_msg(a, gid), a), make_thread(gid, make_msg(a, gid), a)
    k_own = own_key(a)
    k_main = own_key(a)
    k_peer = own_key(a)
    k_foreign = own_key(b)  # authored by b but stored under b's prefix
    add_tmsg(t, a, "own", key=k_own, kind="image")
    add_tmsg(t, a, "also in main chat", key=k_main, kind="image")
    make_msg(a, gid, key=k_main, kind="image")
    add_tmsg(t, a, "also in peer thread", key=k_peer, kind="image")
    add_tmsg(t_peer, a, "peer", key=k_peer, kind="image")
    add_tmsg(t, a, "forged prefix", key=k_foreign, kind="image")  # a authored it but key is b's prefix
    limiter.reset()
    with mock.patch.object(attachments, "_client", side_effect=AssertionError("S3 touched on the request path")), \
            mock.patch.object(attachments, "delete_object", side_effect=AssertionError("S3 delete on the request path")):
        r = client.delete(u(a, gid, f"/{t}"), headers=cookie(a))
    check("delete with attachments: 204", r.status_code == 204, (r.status_code, r.text))
    q = outbox([k_own, k_main, k_peer, k_foreign])
    check("author-owned unreferenced key queued", k_own in q, q)
    check("key still referenced by the main chat is NOT queued", k_main not in q, q)
    check("key referenced by another thread is NOT queued", k_peer not in q, q)
    check("foreign-prefix key is NOT queued", k_foreign not in q, q)
    check("peer thread and its attachment row survive", exists(t_peer)["msgs"] == 1)


def test_ws_frame(client):
    print("WS fan-out")
    a, b, c, outsider = make_user(), make_user(), make_user(), make_user()
    gid = make_group([a, b, c], creator=a)
    set_flag("threads", "on", a)
    t = make_thread(gid, make_msg(b, gid), b)
    socks = {x: FakeWS() for x in (a, b, c, outsider)}
    saved = dict(ws_manager.active_connections)
    try:
        ws_manager.active_connections.update(socks)
        limiter.reset()
        r = client.delete(u(b, gid, f"/{t}"), headers=cookie(b))
        check("delete 204", r.status_code == 204)
        want = {"type": "thread_deleted", "thread_id": t, "group_id": gid}
        for who, name in ((a, "owner"), (b, "actor (their other devices)"), (c, "other member")):
            check(f"{name} gets exactly the thread_deleted frame", socks[who].sent == [want], socks[who].sent)
        check("non-member gets nothing", socks[outsider].sent == [])
        f = socks[a].sent[0]
        check("frame carries ids only: no from_user, no text, no title", set(f) == {"type", "thread_id", "group_id"})

        # denied delete -> no frame
        t2 = make_thread(gid, make_msg(a, gid), a)
        for s in socks.values():
            s.sent.clear()
        limiter.reset()
        r = client.delete(u(c, gid, f"/{t2}"), headers=cookie(c))
        check("denied delete (plain member) sends no frame to anyone", r.status_code == 404 and all(not s.sent for s in socks.values()))

        class Dead:
            async def send_json(self, payload):
                raise RuntimeError("socket gone")

        ws_manager.active_connections[a] = Dead()
        limiter.reset()
        r = client.delete(u(a, gid, f"/{t2}"), headers=cookie(a))
        check("dead socket in the group never fails the committed delete", r.status_code == 204 and exists(t2)["threads"] == 0, r.status_code)
    finally:
        ws_manager.active_connections.clear()
        ws_manager.active_connections.update(saved)


def test_send_races_delete():
    print("a send racing a delete")
    a, b = make_user(), make_user()
    gid = make_group([a, b], creator=a)
    set_flag("threads", "on", a)
    t = make_thread(gid, make_msg(a, gid), a)
    mgr = ConnectionManager()
    mgr.active_connections[a] = FakeWS()
    mgr.active_connections[b] = FakeWS()
    pushed = []

    async def fake_push(*args, **kw):
        pushed.append(args)
        return True

    # A holds the row lock (as delete_thread does), the send blocks on the FK insert, then A deletes and commits.
    holder = DBManager()
    holder.cur.execute("SELECT 1 FROM threads WHERE _id=%s FOR UPDATE", (t,))
    box = {}

    def sender():
        async def go():
            await thread_send.send_thread_message(mgr, {"from_user": b, "type": "thread_message", "thread_id": t, "text": SECRET_BODY})
        with mock.patch.object(thread_send, "send_push", fake_push):
            asyncio.run(go())
        box["done"] = time.time()

    th = threading.Thread(target=sender)
    th.start()
    time.sleep(1.5)
    check("send is blocked while the delete holds the thread row lock", th.is_alive())
    holder.cur.execute("DELETE FROM threads WHERE _id=%s", (t,))
    holder.conn.commit()
    holder.close()
    th.join(timeout=20)
    check("send returned after the delete committed", not th.is_alive())
    errs = [f for f in mgr.active_connections[b].sent if f.get("type") == "error"]
    check("sender gets the uniform not_allowed error frame", len(errs) == 1 and "not_allowed" in json.dumps(errs[0]), mgr.active_connections[b].sent)
    check("nothing resurrected or orphaned", exists(t) == {"threads": 0, "msgs": 0, "followers": 0})
    check("no frame to the other member and no push", not mgr.active_connections[a].sent and not pushed)


def test_rate_limit(client):
    print("rate limit: fixed per-user scope thread_delete, separate from rename")
    a = make_user()
    gid = make_group([a], creator=a)
    set_flag("threads", "on", a)
    limiter.reset()
    ck = cookie(a)
    codes = [client.delete(u(a, gid, f"/{uuid.uuid4()}"), headers=ck).status_code for _ in range(12)]
    check("10/minute per user across DIFFERENT thread ids: 11th+ is 429", codes[:10].count(404) == 10 and 429 in codes[10:], codes)
    r = client.put(u(a, gid, f"/{uuid.uuid4()}"), json={"title": "x"}, headers=ck)
    check("rename bucket is separate (404 not 429 after delete bucket exhausted)", r.status_code == 404, r.status_code)
    b = make_user()
    gid_b = make_group([b], creator=b)
    check("another user has their own bucket", client.delete(u(b, gid_b, f"/{uuid.uuid4()}"), headers=cookie(b)).status_code == 404)
    limiter.reset()
    src = open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "routes", "threads.py")).read()
    check("fixed scope declared, never a path-bucketed limit", 'scope="thread_delete"' in src and "@limiter.limit" not in src)
    from backend.interactions.threads_config import get_threads_config
    check("delete_rate comes from config (10/minute)", get_threads_config().delete_rate == "10/minute")


def test_logging_ids_only(client):
    print("audit/logging: ids only")
    a, b = make_user(), make_user()
    gid = make_group([a, b], creator=a)
    set_flag("threads", "on", a)
    t = make_thread(gid, make_msg(a, gid, text=SECRET_BODY), a, title=SECRET_TITLE, root_preview=SECRET_BODY)
    add_tmsg(t, b, SECRET_BODY)
    cap = LogCapture()
    root = logging.getLogger()
    root.addHandler(cap)
    try:
        limiter.reset()
        client.delete(u(b, gid, f"/{t}"), headers=cookie(b))  # denied
        limiter.reset()
        r = client.delete(u(a, gid, f"/{t}"), headers=cookie(a))
    finally:
        root.removeHandler(cap)
    text = "\n".join(rec.getMessage() for rec in cap.records)
    check("delete succeeded", r.status_code == 204)
    check("THREAD_DELETE audit line carries user, group, thread ids", f"THREAD_DELETE user={a} group={gid} thread={t}" in text, text[-400:])
    check("no title or message text in any log line", SECRET_TITLE not in text and SECRET_BODY not in text)
    check("no bare ERROR-level record from the delete path", not [x for x in cap.records if x.levelno >= logging.ERROR], [x.getMessage() for x in cap.records if x.levelno >= logging.ERROR])


def test_encryption_states(client):
    for state in ("off", "on"):
        print(f"rename sealing + delete with content_encryption_write {state}")
        sql("INSERT INTO feature_flags (name, state) VALUES ('content_encryption_write', %s) "
            "ON CONFLICT (name) DO UPDATE SET state = EXCLUDED.state", (state,))
        flags.invalidate()
        a, b = make_user(), make_user()
        gid = make_group([a, b], creator=b)
        set_flag("threads", "on", a)
        root = make_msg(a, gid)
        limiter.reset()
        r = client.post(u(a, gid), json={"message_id": root, "title": SECRET_TITLE}, headers=cookie(a))
        check(f"[{state}] create 201", r.status_code == 201, r.text)
        tid = r.json()["id"]
        limiter.reset()
        r = client.put(u(a, gid, f"/{tid}"), json={"title": SECRET_TITLE + " renamed"}, headers=cookie(a))
        check(f"[{state}] rename returns the readable new title", r.status_code == 200 and r.json()["title"] == SECRET_TITLE + " renamed", r.text)
        raw = sql("SELECT title FROM threads WHERE _id=%s", (tid,))[0][0]
        if state == "on":
            check("[on] title sealed at rest (enc:v1:, no plaintext)", raw.startswith("enc:v1:") and SECRET_TITLE not in raw, raw[:30])
        else:
            check("[off] title stored as plaintext", raw == SECRET_TITLE + " renamed", raw)
        lst = client.get(u(a, gid), headers=cookie(a)).json()
        items = lst["threads"]
        check(f"[{state}] list shows the readable renamed title", any(i["id"] == tid and i["title"] == SECRET_TITLE + " renamed" for i in items), items)
        mid = add_tmsg(tid, a, SECRET_BODY)
        sql("UPDATE thread_messages SET text=%s WHERE _id=%s", (SECRET_BODY, mid))
        limiter.reset()
        r = client.delete(u(b, gid, f"/{tid}"), headers=cookie(b))
        check(f"[{state}] owner (not creator) deletes the thread: 204", r.status_code == 204, (r.status_code, r.text))
        check(f"[{state}] nothing left at rest", exists(tid) == {"threads": 0, "msgs": 0, "followers": 0})
        sql("DELETE FROM feature_flags WHERE name='content_encryption_write'") if state == "on" else None
        flags.invalidate()


def main():
    require_scratch_db()
    client = TestClient(main_module.app)
    try:
        test_flag_and_anon(client)
        test_authz_and_cascade(client)
        test_ownerless_and_blocked(client)
        test_attachments(client)
        test_ws_frame(client)
        test_send_races_delete()
        test_rate_limit(client)
        test_logging_ids_only(client)
        test_encryption_states(client)
    except BaseException as e:
        FAILED.append(("unexpected exception", repr(e)))
        raise
    finally:
        limiter.reset()
        sql("INSERT INTO feature_flags (name, state) VALUES ('content_encryption_write','off') "
            "ON CONFLICT (name) DO UPDATE SET state='off'")
        flags.invalidate()
        finish()


if __name__ == "__main__":
    main()
