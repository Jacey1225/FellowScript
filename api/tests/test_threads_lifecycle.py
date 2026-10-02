"""Tests for task 20261001-message-threads step 7: thread_message moderation
registrations and group / account lifecycle cleanup.

Scratch database only (asserts SHOW port = 55432 first). Proves:
  * registrations.load_all registers the thread_message resolver, remover and the
    group_delete collector, in-process AND in a FRESH subprocess (so only load_all can
    have done it, R3-m3); the report schema accepts thread_message
  * report round trip: 201 stores the text snippet, author and canonical id; a soft-deleted
    thread message is still reportable (evidence retention, no deleted_at filter); unknown
    id 404 stores nothing; non-UUID 422
  * moderation CLI removal executed in a fresh subprocess: row hard-deleted, author-owned
    unreferenced attachment key queued in the pending_s3_deletes OUTBOX; foreign-prefix and
    shared keys are never queued; report marked actioned; no per-key S3 delete
  * group deleted by BOTH paths (creator DELETE and last-member leave): threads,
    thread_messages and followers cascade away, author-owned keys queued to the outbox, keys
    still referenced outside the group or by another group's thread are kept, foreign-prefix
    keys never queued, request path never calls S3; works with the flag off
  * a non-last leave keeps the threads and queues nothing
  * delete_user with thread messages: messages and threads are kept with the author
    nulled (decision D12), no key queued, account deletion still succeeds
Run with: cd api && ../.venv/bin/python tests/test_threads_lifecycle.py
"""
import _pathfix  # noqa: F401
from _thr_common import (  # noqa: F401
    API_DIR, FAILED, check, cookie, finish, make_group, make_msg, make_thread, make_user, add_tmsg,
    own_key, require_scratch_db, set_flag, sql,
)

import json
import subprocess
import sys
import uuid

from fastapi.testclient import TestClient

import main as main_module
from backend import registrations
from backend.interactions import attachments, lifecycle, reports, s3_outbox
from backend.moderation import admin_actions, removers
from backend.rate_limiting import limiter
from routes.reports import ReportRequest


def run_py(code=None, args=None):
    cmd = [sys.executable] + (["-c", code] if code else args)
    return subprocess.run(cmd, cwd=API_DIR, capture_output=True, text=True, timeout=120)


def outbox(keys):
    return {r[0] for r in sql("SELECT key FROM pending_s3_deletes WHERE key = ANY(%s)", (list(keys),))}


def tm_key(tid, author, key, kind="image"):
    mid = add_tmsg(tid, author, "with key", key=key, kind=kind)
    return mid


def test_registrations():
    print("registrations")
    registrations.load_all()
    registrations.load_all()  # idempotent
    check("in-process: resolver registered", "thread_message" in reports.CONTENT_RESOLVERS)
    check("in-process: remover registered", "thread_message" in removers.CONTENT_REMOVERS)
    check("admin_actions shares the removers registry object", admin_actions.CONTENT_REMOVERS is removers.CONTENT_REMOVERS)
    names = {h.__name__ for h in lifecycle.hooks("group_delete")}
    check("group_delete collector registered", "collect_thread_attachment_keys" in names, names)
    check("no user_delete hook for threads (author nulled, content kept, D12)",
          not any("thread" in h.__name__ for h in lifecycle.hooks("user_delete")))
    check("no member_leave hook for threads (a thread dies only with its group)",
          not any("thread" in h.__name__ for h in lifecycle.hooks("member_leave")))
    check("report schema accepts thread_message", "thread_message" in ReportRequest.model_fields["content_type"].annotation.__args__)
    code = (
        "import json\n"
        "from backend.registrations import load_all\n"
        "load_all()\n"
        "from backend.interactions import reports, lifecycle\n"
        "from backend.moderation import removers\n"
        "print(json.dumps({'res': sorted(reports.CONTENT_RESOLVERS), 'rem': sorted(removers.CONTENT_REMOVERS),\n"
        " 'gd': sorted(f.__name__ for f in lifecycle.hooks('group_delete'))}))\n"
    )
    r = run_py(code)
    check("fresh subprocess ran cleanly", r.returncode == 0, r.stderr[-300:])
    out = json.loads(r.stdout.strip().splitlines()[-1])
    check("fresh process: resolver + remover registered by load_all alone",
          "thread_message" in out["res"] and "thread_message" in out["rem"], out)
    check("fresh process: group_delete collector registered", "collect_thread_attachment_keys" in out["gd"], out)
    bare = run_py("from backend.moderation import removers\nprint('thread_message' in removers.CONTENT_REMOVERS)")
    check("without load_all a cold process has NO thread_message remover (so load_all is what the CLI relies on)",
          bare.stdout.strip().splitlines()[-1] == "False", (bare.stdout, bare.stderr[-200:]))


def test_report_round_trip(client):
    print("thread_message report round trip")
    author, reporter, other = make_user(), make_user(), make_user()
    gid = make_group([author, reporter])
    tid = make_thread(gid, make_msg(author, gid), author)
    mid = add_tmsg(tid, author, "report me please")
    real_email = reports.send_email
    reports.send_email = lambda *a, **k: None
    try:
        limiter.reset()
        r = client.post("/reports/", json={"content_type": "thread_message", "content_id": mid.upper(), "reason": "spam"}, headers=cookie(reporter))
        check("report 201", r.status_code == 201, r.text)
        row = sql("SELECT reported_user_id::text, content_id::text, content_snippet, content_type, status FROM content_reports WHERE _id=%s", (r.json()["id"],))[0]
        check("stored: author as reported user, canonical id, text snippet, open",
              row == (author, mid, "report me please", "thread_message", "open"), row)
        sql("UPDATE thread_messages SET deleted_at=NOW() WHERE _id=%s", (mid,))
        r2 = client.post("/reports/", json={"content_type": "thread_message", "content_id": mid, "reason": "late"}, headers=cookie(reporter))
        check("a soft-deleted thread message is still reportable and keeps its text (no deleted_at filter)", r2.status_code == 201
              and sql("SELECT content_snippet FROM content_reports WHERE _id=%s", (r2.json()["id"],))[0][0] == "report me please", r2.text)
        n = sql("SELECT COUNT(*) FROM content_reports WHERE reporter_id=%s", (reporter,))[0][0]
        r3 = client.post("/reports/", json={"content_type": "thread_message", "content_id": str(uuid.uuid4()), "reason": "x"}, headers=cookie(reporter))
        check("unknown thread message id: 404", r3.status_code == 404, r3.text)
        r4 = client.post("/reports/", json={"content_type": "thread_message", "content_id": "AbCdEfGh12", "reason": "x"}, headers=cookie(reporter))
        check("non-UUID id: 422", r4.status_code == 422)
        r5 = client.post("/reports/", json={"content_type": "thread_message", "reason": "x"}, headers=cookie(reporter))
        check("missing content_id: 422", r5.status_code == 422)
        check("404/422 stored nothing", sql("SELECT COUNT(*) FROM content_reports WHERE reporter_id=%s", (reporter,))[0][0] == n)
        # author id nulled after the author's account is gone: reported user falls back to the client value
        sql("UPDATE thread_messages SET from_user=NULL WHERE _id=%s", (mid,))
        r6 = client.post("/reports/", json={"content_type": "thread_message", "content_id": mid, "reported_user_id": other, "reason": "x"}, headers=cookie(reporter))
        check("author-less row (deleted account) is still reportable", r6.status_code == 201, r6.text)
    finally:
        reports.send_email = real_email
        limiter.reset()


def test_cli_removal():
    print("moderation CLI removal in a FRESH subprocess")
    author, other, reporter = make_user(), make_user(), make_user()
    gid = make_group([author, other])
    tid = make_thread(gid, make_msg(author, gid), author)
    own = own_key(author)
    foreign = f"attachments/{other}/{uuid.uuid4().hex}.jpg"   # author != key owner
    shared = own_key(author)
    sql("INSERT INTO messages (_id, from_user, group_id, text, timestamp, attachment_kind, attachment_key) VALUES (%s,%s,%s,'',NOW(),'image',%s)",
        (str(uuid.uuid4()), author, gid, shared))
    from _thr_common import KEYS
    KEYS.append(foreign)
    cases = {
        "own": (tm_key(tid, author, own), own, True),
        "foreign prefix": (tm_key(tid, author, foreign), foreign, False),
        "shared with a messages row": (tm_key(tid, author, shared), shared, False),
        "no attachment": (add_tmsg(tid, author, "plain text"), None, False),
    }
    for name, (mid, key, expect_queued) in cases.items():
        rid = str(uuid.uuid4())
        sql("INSERT INTO content_reports (_id, reporter_id, reported_user_id, content_type, content_id, reason) VALUES (%s,%s,%s,'thread_message',%s,'x')",
            (rid, reporter, author, mid))
        r = run_py(args=["-m", "backend.moderation.admin_actions", "resolve", rid, "--remove-content"])
        check(f"CLI exit 0 ({name})", r.returncode == 0, (r.returncode, r.stderr[-300:]))
        check(f"row hard-deleted ({name})", sql("SELECT 1 FROM thread_messages WHERE _id=%s", (mid,)) == [])
        check(f"report actioned ({name})", sql("SELECT status FROM content_reports WHERE _id=%s", (rid,))[0][0] == "actioned")
        if key:
            check(f"key {'queued in the outbox' if expect_queued else 'NOT queued'} ({name})", (key in outbox([key])) == expect_queued, outbox([key]))
    check("other thread messages untouched by the removals", sql("SELECT COUNT(*) FROM thread_messages WHERE thread_id=%s", (tid,))[0][0] == 0)
    # a second report for a message that no longer exists must not crash the CLI
    rid = str(uuid.uuid4())
    sql("INSERT INTO content_reports (_id, reporter_id, reported_user_id, content_type, content_id, reason) VALUES (%s,%s,%s,'thread_message',%s,'x')",
        (rid, reporter, author, str(uuid.uuid4())))
    r = run_py(args=["-m", "backend.moderation.admin_actions", "resolve", rid, "--remove-content"])
    check("CLI removal of an already-gone message exits 0", r.returncode == 0, (r.returncode, r.stderr[-300:]))
    src = open(f"{API_DIR}/backend/threads_wiring.py").read()
    check("remover never calls delete_object (outbox only)", "delete_object(" not in src and "import attachments" not in src and "enqueue_s3_deletes(cur" in src)


class NoS3:
    """Patch the outbox flush and S3 delete calls so we can prove the request path never touches S3."""

    def __enter__(self):
        self.calls = []
        self.real = (s3_outbox.flush_batch, attachments.delete_object_status, attachments.delete_object)
        s3_outbox.flush_batch = lambda *a, **k: self.calls.append("flush") or {}
        attachments.delete_object_status = lambda k: self.calls.append(k) or "ok"
        attachments.delete_object = lambda k: self.calls.append(k)
        return self

    def __exit__(self, *exc):
        s3_outbox.flush_batch, attachments.delete_object_status, attachments.delete_object = self.real


def build_group_with_threads():
    a, b = make_user(), make_user()
    gid, other_gid = make_group([a, b], creator=a), make_group([b])
    set = {}
    t1 = make_thread(gid, make_msg(a, gid, "r1"), a, title="t1")
    t2 = make_thread(gid, make_msg(b, gid, "r2"), b, title="t2")
    set["own_a"], set["own_b"] = own_key(a), own_key(b)
    set["foreign"] = f"attachments/{b}/{uuid.uuid4().hex}.jpg"
    set["kept_msg"], set["kept_thread"] = own_key(a), own_key(a)
    from _thr_common import KEYS
    KEYS.append(set["foreign"])
    tm_key(t1, a, set["own_a"])
    tm_key(t2, b, set["own_b"])
    tm_key(t1, a, set["foreign"])                      # a's row pointing into b's prefix: never queued
    tm_key(t1, a, set["kept_msg"])
    sql("INSERT INTO messages (_id, from_user, group_id, text, timestamp, attachment_kind, attachment_key) VALUES (%s,%s,%s,'',NOW(),'image',%s)",
        (str(uuid.uuid4()), a, other_gid, set["kept_msg"]))  # also used OUTSIDE this group
    tm_key(t2, a, set["kept_thread"])
    t_other = make_thread(other_gid, make_msg(b, other_gid), b, title="elsewhere")
    tm_key(t_other, a, set["kept_thread"])             # also used by ANOTHER group's thread
    sql("INSERT INTO thread_followers (thread_id, user_id) VALUES (%s,%s),(%s,%s) ON CONFLICT DO NOTHING", (t1, a, t2, b))
    return a, b, gid, other_gid, (t1, t2, t_other), set


def assert_group_gone(label, gid, tids, keys, other_tid):
    check(f"{label}: group row gone", sql("SELECT 1 FROM groups WHERE _id=%s", (gid,)) == [])
    check(f"{label}: threads cascaded away", sql("SELECT COUNT(*) FROM threads WHERE group_id=%s", (gid,))[0][0] == 0)
    check(f"{label}: thread_messages cascaded away", sql("SELECT COUNT(*) FROM thread_messages WHERE thread_id = ANY(%s::uuid[])", (list(tids),))[0][0] == 0)
    check(f"{label}: thread_followers cascaded away", sql("SELECT COUNT(*) FROM thread_followers WHERE thread_id = ANY(%s::uuid[])", (list(tids),))[0][0] == 0)
    check(f"{label}: author-owned keys queued in the outbox", {keys["own_a"], keys["own_b"]} <= outbox(keys.values()), outbox(keys.values()))
    check(f"{label}: foreign-prefix key NOT queued", keys["foreign"] not in outbox(keys.values()))
    check(f"{label}: key still referenced by a message outside the group NOT queued", keys["kept_msg"] not in outbox(keys.values()))
    check(f"{label}: key still used by another group's thread NOT queued", keys["kept_thread"] not in outbox(keys.values()))
    check(f"{label}: the other group's thread and its messages survive",
          sql("SELECT COUNT(*) FROM thread_messages WHERE thread_id=%s", (other_tid,))[0][0] == 1)


def test_group_delete_paths(client):
    print("group deleted by BOTH paths (flag off: cleanup must not depend on the flag)")
    for path in ("delete", "leave-last-member"):
        a, b, gid, other_gid, tids, keys = build_group_with_threads()
        if path == "leave-last-member":
            sql("UPDATE groups SET users=%s WHERE _id=%s", ([a], gid))
        sql("DELETE FROM pending_s3_deletes WHERE key = ANY(%s)", (list(keys.values()),))
        with NoS3() as s3:
            if path == "delete":
                r = client.delete(f"/groups/{a}/{gid}", headers=cookie(a))
            else:
                r = client.post(f"/groups/{a}/{gid}/leave", headers=cookie(a))
        check(f"{path}: HTTP 204", r.status_code == 204, (r.status_code, r.text))
        check(f"{path}: request path never flushed or called S3", s3.calls == [], s3.calls)
        assert_group_gone(path, gid, tids[:2], keys, tids[2])
        # the cleaned-up collector also leaves the ids unqueued twice-safe: running again is harmless
        sql("DELETE FROM pending_s3_deletes WHERE key = ANY(%s)", (list(keys.values()),))

    print("non-last leave keeps threads and queues nothing")
    a, b, gid, other_gid, tids, keys = build_group_with_threads()
    sql("DELETE FROM pending_s3_deletes WHERE key = ANY(%s)", (list(keys.values()),))
    r = client.post(f"/groups/{a}/{gid}/leave", headers=cookie(a))
    check("non-last leave 204", r.status_code == 204, r.text)
    check("group and its threads stay", sql("SELECT COUNT(*) FROM threads WHERE group_id=%s", (gid,))[0][0] == 2)
    check("thread messages stay", sql("SELECT COUNT(*) FROM thread_messages WHERE thread_id=%s", (tids[0],))[0][0] == 3)
    check("nothing queued", outbox(keys.values()) == set())

    print("collector direct: runs before the group row is deleted, own keys only, valid keys only")
    from backend.threads_wiring import collect_thread_attachment_keys
    from db import DBManager
    a2, b2, gid2, other2, tids2, keys2 = build_group_with_threads()
    d = DBManager()
    try:
        got = set(collect_thread_attachment_keys(d.cur, gid2))
        check("collector returns exactly the author-owned, unreferenced-elsewhere keys", got == {keys2["own_a"], keys2["own_b"]}, got)
        check("collector wrote nothing (the caller enqueues)", outbox(keys2.values()) == set())
        check("collector of an unknown group is empty", collect_thread_attachment_keys(d.cur, str(uuid.uuid4())) == [])
    finally:
        d.conn.rollback()
        d.close()


def test_delete_user(client):
    print("delete_user with thread messages (content kept, author nulled, D12)")
    a, b = make_user(), make_user()
    gid = make_group([a, b], creator=b)
    root = make_msg(b, gid, "b root")
    tid = make_thread(gid, root, a, title="a made this", root_author=b)
    k = own_key(a)
    mid = tm_key(tid, a, k)
    mid_b = add_tmsg(tid, b, "from b")
    sql("INSERT INTO thread_followers (thread_id, user_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (tid, a))
    sql("DELETE FROM pending_s3_deletes WHERE key=%s", (k,))
    r = client.delete(f"/user/{a}", headers=cookie(a))
    check("account deletion succeeds (204)", r.status_code == 204, (r.status_code, r.text))
    row = sql("SELECT from_user, text FROM thread_messages WHERE _id=%s", (mid,))
    check("the deleted user's thread message is kept with the author nulled", row == [(None, "with key")], row)
    check("other users' thread messages untouched", sql("SELECT from_user::text FROM thread_messages WHERE _id=%s", (mid_b,))[0][0] == b)
    th = sql("SELECT created_by, group_id::text FROM threads WHERE _id=%s", (tid,))
    check("thread survives with created_by nulled", th == [(None, gid)], th)
    check("deleted user's follower row cascaded", sql("SELECT COUNT(*) FROM thread_followers WHERE thread_id=%s AND user_id=%s", (tid, a))[0][0] == 0)
    check("no attachment key queued by account deletion (no user_delete hook)", outbox([k]) == set())
    check("group survives with the remaining member", sql("SELECT users FROM groups WHERE _id=%s", (gid,))[0][0] == [b])


def main():
    require_scratch_db()
    client = TestClient(main_module.app)
    try:
        a0 = make_user()
        set_flag("threads", "off", a0)  # lifecycle cleanup must not depend on the flag
        test_registrations()
        test_report_round_trip(client)
        test_cli_removal()
        test_group_delete_paths(client)
        test_delete_user(client)
    except BaseException as e:
        FAILED.append(("unexpected exception", repr(e)))
        raise
    finally:
        limiter.reset()
        finish()


if __name__ == "__main__":
    main()
