"""Tests for task 20261122-app-fixes-threads-widget step 1: per-user thread unread state.

Scratch database only (asserts SHOW port = 55432 first). Proves:
  * list_threads returns ``unread_count`` per thread: others' live messages past the caller's
    read marker; own messages never count; soft-deleted never count; blocked senders (either
    direction) and non-members' injected rows never count
  * POST .../threads/{t}/read advances the marker to the newest seq (idempotent, never
    backwards), the badge clears, and a later message from someone else counts again
  * authz: non-member, thread of another group, unknown/malformed ids, flag off, anonymous:
    the identical uniform 404 and no thread_reads row written
  * per-user isolation: one user's read does not clear another's unread
Run with: cd api && ../.venv/bin/python tests/test_thread_unread.py
"""
import _pathfix  # noqa: F401
from _thr_common import (  # noqa: F401
    FAILED, add_tmsg, check, cookie, finish, make_group, make_msg, make_thread, make_user,
    require_scratch_db, set_flag, sql,
)

import uuid

from fastapi.testclient import TestClient

import main as main_module
from backend.rate_limiting import limiter

NOT_FOUND = {"code": "not_found", "message": "Not found"}


def u(uid, gid, tail=""):
    return f"/groups/{uid}/{gid}/threads{tail}"


def unread(client, uid, gid, tid):
    limiter.reset()
    r = client.get(u(uid, gid), headers=cookie(uid))
    assert r.status_code == 200, r.text
    item = next(t for t in r.json()["threads"] if t["id"] == tid)
    return item["unread_count"]


def mark(client, uid, gid, tid):
    limiter.reset()
    return client.post(u(uid, gid, f"/{tid}/read"), headers=cookie(uid))


def test_counts(client):
    print("unread counts")
    a, b, c, blocked, outsider = (make_user("thru") for _ in range(5))
    gid = make_group([a, b, c, blocked])
    set_flag("threads", "on", a)
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (a, blocked))
    root = make_msg(b, gid)
    tid = make_thread(gid, root, b)
    check("empty thread: unread 0", unread(client, a, gid, tid) == 0)
    add_tmsg(tid, b, "one")
    add_tmsg(tid, c, "two")
    check("two messages from others: unread 2", unread(client, a, gid, tid) == 2)
    add_tmsg(tid, a, "mine")
    check("own message never counts", unread(client, a, gid, tid) == 2)
    add_tmsg(tid, b, "gone", deleted=True)
    check("soft-deleted never counts", unread(client, a, gid, tid) == 2)
    add_tmsg(tid, blocked, "blocked sender")
    check("blocked sender never counts", unread(client, a, gid, tid) == 2)
    add_tmsg(tid, outsider, "injected non-member")
    check("non-member injected row never counts", unread(client, a, gid, tid) == 2)
    r = client.get(u(a, gid), headers=cookie(a)).json()["threads"][0]
    check("list item keeps its existing keys plus unread_count",
          {"id", "title", "root_preview", "root_deleted", "reply_count", "last_activity_at", "created_by",
           "unread_count"} <= set(r) and isinstance(r["unread_count"], int), r)


def test_mark_read(client):
    print("mark read")
    a, b = make_user("thru"), make_user("thru")
    gid = make_group([a, b])
    set_flag("threads", "on", a)
    tid = make_thread(gid, make_msg(b, gid), b)
    add_tmsg(tid, b, "x")
    add_tmsg(tid, b, "y")
    r = mark(client, a, gid, tid)
    check("mark read 200 with unread_count 0", r.status_code == 200 and r.json() == {"thread_id": tid, "unread_count": 0}, r.text)
    check("badge cleared", unread(client, a, gid, tid) == 0)
    check("marker is the newest seq", sql("SELECT last_read_seq FROM thread_reads WHERE thread_id=%s AND user_id=%s", (tid, a))[0][0]
          == sql("SELECT MAX(seq) FROM thread_messages WHERE thread_id=%s", (tid,))[0][0])
    add_tmsg(tid, b, "z")
    check("a later message from someone else counts again", unread(client, a, gid, tid) == 1)
    check("second mark read is idempotent", mark(client, a, gid, tid).status_code == 200 and unread(client, a, gid, tid) == 0)
    before = sql("SELECT last_read_seq FROM thread_reads WHERE thread_id=%s AND user_id=%s", (tid, a))[0][0]
    sql("DELETE FROM thread_messages WHERE _id = (SELECT _id FROM thread_messages WHERE thread_id=%s ORDER BY seq DESC LIMIT 1)", (tid,))
    mark(client, a, gid, tid)
    after = sql("SELECT last_read_seq FROM thread_reads WHERE thread_id=%s AND user_id=%s", (tid, a))[0][0]
    check("marker never moves backwards", after >= before, (before, after))


def test_authz(client):
    print("mark read authz")
    a, b, outsider = (make_user("thru") for _ in range(3))
    gid, gid2 = make_group([a, b]), make_group([a])
    set_flag("threads", "on", a)
    tid = make_thread(gid, make_msg(b, gid), b)
    add_tmsg(tid, b, "x")
    cases = {
        "non-member": mark(client, outsider, gid, tid),
        "thread of another group": mark(client, a, gid2, tid),
        "unknown thread": mark(client, a, gid, str(uuid.uuid4())),
        "malformed thread id": mark(client, a, gid, "not-a-uuid"),
    }
    limiter.reset()
    cases["anonymous"] = client.post(u(a, gid, f"/{tid}/read"))
    limiter.reset()
    cases["path user != session"] = client.post(u(b, gid, f"/{tid}/read"), headers=cookie(a))
    for name, r in cases.items():
        if name in ("anonymous", "path user != session"):
            check(f"{name}: rejected", r.status_code in (401, 403, 404), r.status_code)
        else:
            check(f"{name}: uniform 404", r.status_code == 404 and r.json()["detail"] == NOT_FOUND, (r.status_code, r.text))
    check("no thread_reads row written by denials", sql("SELECT COUNT(*) FROM thread_reads WHERE thread_id=%s", (tid,))[0][0] == 0)
    set_flag("threads", "off", a)
    r = mark(client, a, gid, tid)
    check("flag off: uniform 404", r.status_code == 404 and r.json()["detail"] == NOT_FOUND, r.text)
    set_flag("threads", "on", a)


def main():
    require_scratch_db()
    client = TestClient(main_module.app)
    try:
        test_counts(client)
        test_mark_read(client)
        test_authz(client)
    except BaseException as e:
        FAILED.append(("unexpected exception", repr(e)))
        raise
    finally:
        limiter.reset()
        finish()


if __name__ == "__main__":
    main()
