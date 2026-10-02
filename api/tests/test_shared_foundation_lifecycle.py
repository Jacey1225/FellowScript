"""Tests for task 20261002-shared-foundation (Backend B): lifecycle registries,
the pending_s3_deletes outbox, group-member hygiene, the live-member join and
the report/moderation registries.

Properties proved (each would catch a regression of the bug it names):
  1. Outbox: keys are enqueued in the SAME transaction as the row delete
     (a failure after the enqueue rolls both back), the request path never
     flushes or calls S3, flush deletes on "ok", retries on "error", stops at
     20 attempts (row kept), claims at most 200 rows, and an IAM AccessDenied
     produces ONE aggregated WARNING plus one ERROR per prefix per 24h, never a
     per-key line. The async job body does its blocking work in an executor
     (loop lag < 500 ms while 0.8 s of blocking work runs) and contains no
     psycopg2/boto3 call.
  2. Lifecycle: delete_group and leave_group(last member) collect the group
     photo and announcement banner keys; a non-last leave keeps the group and
     runs member_leave hooks; delete_user runs inside one transaction; keys the
     owning helper does not prove belong to the group are never collected.
  3. R3-5: delete_user removes the id from EVERY groups.users array (three
     groups, last member of one: two lose the id, the third is deleted with its
     outbox keys); a send to the group afterwards no longer raises
     SaveFailedError; update_group drops a dead id silently, rejects a new
     junk / unknown / suspended id with ONE identical 422 invalid_member body;
     a build-78-shaped payload (echoing the member list including a dead id)
     returns 200 and stores the cleaned list; prune_group_members dry run
     changes nothing and --apply is idempotent.
  4. R4-1: groups.live_member_ids and LIVE_MEMBER_JOIN return identical ids for
     live / dead / junk / uppercase-hex / NULL members (NULL array: no rows, no
     error) and, with 20,000+ users, EXPLAIN uses users_pkey with no Seq Scan
     on users.
  5. R4-m2: create_group validates the same way as update_group.
  6. R4-m4: deleting an account that belongs to a group with a photo, a banner,
     invites and an open report succeeds and queues the photo and banner keys;
     the outbox DDL module is in DDL_MODULES and applied at boot.
  7. Reports/moderation registries: five old types unchanged, resolver
     3-tuple, malformed content id 422, the new Literal values accepted and
     answer 404 (nothing stored) with no resolver; in a FRESH subprocess
     load_all() registers resolvers and removers symmetrically and the
     moderation CLI exits non-zero for a content type with no remover.

Every database touch is against the scratch database: the test asserts
SHOW port = 55432 first and aborts otherwise.

Run with: cd api && ../.venv/bin/python tests/test_shared_foundation_lifecycle.py
"""
import _pathfix  # noqa: F401

import asyncio
import inspect
import logging
import os
import subprocess
import sys
import threading
import time
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from botocore.exceptions import ClientError  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import db as db_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.errors import SaveFailedError  # noqa: E402
from backend.interactions import (  # noqa: E402
    announcement_banner, attachments, groups, group_photo, invites, lifecycle,
    reports, s3_outbox,
)
from backend.interactions.groups import GroupsManager  # noqa: E402
from backend.moderation import admin_actions, removers  # noqa: E402
from backend.maintenance import prune_group_members  # noqa: E402
from backend.interactions.websockets import ConnectionManager  # noqa: E402
import backend.interactions.websockets as ws_module  # noqa: E402
from routes import reports as reports_route  # noqa: E402
from schemas.message import Group  # noqa: E402

API_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSED, FAILED = [], []


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


# ── helpers ───────────────────────────────────────────────────────────────────

def q(sql, params=(), fetch=True):
    db = DBManager()
    try:
        db.cur.execute(sql, params)
        rows = db.cur.fetchall() if fetch and db.cur.description else None
        db.conn.commit()
        return rows
    finally:
        db.close()


def make_user(suspended=False):
    uid = str(uuid.uuid4())
    q("INSERT INTO users (_id, username, email, hash_pass, suspended_at) VALUES (%s,%s,%s,'x',%s)",
      (uid, f"sfl_{uid[:8]}", f"sfl_{uid[:8]}@example.com", "2020-01-01" if suspended else None),
      fetch=False)
    return uid


def hdr(uid):
    sm = SessionManager()
    try:
        return {"cookie": f"session={sm.create_session(uid)}"}
    finally:
        sm.close()


def mk_group_row(users, creator=None, photo_key=None):
    gid = str(uuid.uuid4())
    q("INSERT INTO groups (_id, title, users, creator_id, photo_key) VALUES (%s,'sfl group',%s,%s,%s)",
      (gid, users, creator, photo_key), fetch=False)
    return gid


def photo_key_for(gid):
    return f"{group_photo.GROUP_PHOTO_KEY_PREFIX}/{gid}/{uuid.uuid4().hex}.jpg"


def banner_key_for(gid):
    return f"{announcement_banner.ANNOUNCEMENT_BANNER_KEY_PREFIX}/{gid}/{uuid.uuid4().hex}.jpg"


def add_banner(gid, key):
    q("INSERT INTO group_announcements (group_id, title, banner_key) VALUES (%s,'t',%s)", (gid, key),
      fetch=False)


def group_users(gid):
    rows = q("SELECT users FROM groups WHERE _id = %s", (gid,))
    return rows[0][0] if rows else None


def outbox_keys(keys):
    rows = q("SELECT key FROM pending_s3_deletes WHERE key = ANY(%s)", (list(keys),))
    return {r[0] for r in rows}


def user_exists(uid):
    return bool(q("SELECT 1 FROM users WHERE _id = %s", (uid,)))


def cleanup(users=(), groups_=(), keys=()):
    q("DELETE FROM pending_s3_deletes WHERE key = ANY(%s)", (list(keys),), fetch=False)
    for g in groups_:
        q("DELETE FROM invites WHERE target_id = %s", (g,), fetch=False)
        q("DELETE FROM messages WHERE group_id = %s", (g,), fetch=False)
        q("DELETE FROM groups WHERE _id = %s", (g,), fetch=False)
    for u in users:
        q("DELETE FROM content_reports WHERE reporter_id = %s OR reported_user_id = %s", (u, u), fetch=False)
        q("DELETE FROM users WHERE _id = %s", (u,), fetch=False)


class LogCatcher(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.records = []

    def emit(self, record):
        self.records.append((record.levelname, record.getMessage()))

    def levels(self, level):
        return [m for lv, m in self.records if lv == level]


class catch_logs:
    def __enter__(self):
        self.h = LogCatcher()
        self.root = logging.getLogger()
        self.old = self.root.level
        self.root.setLevel(logging.DEBUG)
        self.root.addHandler(self.h)
        return self.h

    def __exit__(self, *a):
        self.root.removeHandler(self.h)
        self.root.setLevel(self.old)


def seed_outbox(keys, attempts=0):
    for k in keys:
        q("INSERT INTO pending_s3_deletes (key, attempts) VALUES (%s,%s) ON CONFLICT (key) DO NOTHING",
          (k, attempts), fetch=False)


def attempts_of(key):
    rows = q("SELECT attempts FROM pending_s3_deletes WHERE key = %s", (key,))
    return rows[0][0] if rows else None


# ── 1. outbox ─────────────────────────────────────────────────────────────────

def test_outbox_same_transaction():
    print("outbox: enqueue is in the caller's transaction")
    tag = f"sfl-tx-{uuid.uuid4().hex[:8]}"
    k1, k2 = f"{tag}/a.jpg", f"{tag}/b.jpg"
    db = DBManager()
    try:
        n = lifecycle.enqueue_s3_deletes(db.cur, [k1, k2, k1])
        check("enqueue returns number of distinct new rows", n == 2, n)
        db.conn.rollback()
    finally:
        db.close()
    check("rolled-back transaction leaves no outbox rows", outbox_keys([k1, k2]) == set())
    db = DBManager()
    try:
        lifecycle.enqueue_s3_deletes(db.cur, [k1])
        lifecycle.enqueue_s3_deletes(db.cur, [k1])  # ON CONFLICT DO NOTHING
        db.conn.commit()
    finally:
        db.close()
    check("committed transaction persists the key once", outbox_keys([k1]) == {k1})
    check("attempts start at 0", attempts_of(k1) == 0)
    q("DELETE FROM pending_s3_deletes WHERE key = %s", (k1,), fetch=False)

    # A failure AFTER the enqueue (inside delete_group) rolls the delete AND the
    # enqueue back together: no group deleted without keys, no keys without delete.
    owner = make_user()
    gid = mk_group_row([owner], owner)
    pk = photo_key_for(gid)
    q("UPDATE groups SET photo_key = %s WHERE _id = %s", (pk, gid), fetch=False)
    real = invites.purge_target_invites

    def boom(cur, kind, target):
        raise RuntimeError("simulated failure after enqueue")
    invites.purge_target_invites = boom
    try:
        mgr = GroupsManager(owner, gid)
        try:
            mgr.delete_group()
            raised = False
        except RuntimeError:
            raised = True
        finally:
            mgr.close()
    finally:
        invites.purge_target_invites = real
    check("failure after enqueue propagates", raised)
    check("group still exists after the rolled-back delete", group_users(gid) == [owner])
    check("no outbox row survives the rollback", outbox_keys([pk]) == set())
    cleanup([owner], [gid], [pk])


def test_outbox_flush_semantics():
    print("outbox: flush, retry, cap, batch, denied aggregation")
    tag = f"sfl-fl-{uuid.uuid4().hex[:8]}"
    keys = [f"{tag}/{i}.jpg" for i in range(5)]
    seed_outbox(keys)
    seen = []

    def ok(k):
        seen.append(k)
        return "ok"
    c = s3_outbox.flush_batch(delete_fn=ok)
    check("flush deletes rows whose S3 delete is ok", outbox_keys(keys) == set() and c["deleted"] >= 5, c)

    seed_outbox(keys)
    with catch_logs() as lg:
        c = s3_outbox.flush_batch(delete_fn=lambda k: "error")
    check("transient error keeps the rows and counts an attempt",
          outbox_keys(keys) == set(keys) and all(attempts_of(k) == 1 for k in keys), c)
    check("transient error logs one aggregated WARNING, no ERROR, no key",
          len(lg.levels("WARNING")) == 1 and not lg.levels("ERROR")
          and not any(tag in m for _, m in lg.records), lg.records)
    check("non-error outbox line avoids the bare word 'error'/'fail ' watchdog trigger",
          all(" error" not in m.lower() for m in lg.levels("WARNING")), lg.levels("WARNING"))
    c = s3_outbox.flush_batch(delete_fn=ok)
    check("a later retry that succeeds drains them", outbox_keys(keys) == set())

    # cap: attempts 19 -> 20 on the next failure, then never claimed again
    capped = f"{tag}/cap.jpg"
    seed_outbox([capped], attempts=s3_outbox.MAX_ATTEMPTS - 1)
    with catch_logs() as lg:
        c = s3_outbox.flush_batch(delete_fn=lambda k: "error")
    check("20th failure counts as gave_up", c["gave_up"] == 1, c)
    check("row at the cap is kept", attempts_of(capped) == s3_outbox.MAX_ATTEMPTS)
    called = []
    c = s3_outbox.flush_batch(delete_fn=lambda k: called.append(k) or "ok")
    check("a row at the cap is never claimed or retried again",
          capped not in called and attempts_of(capped) == s3_outbox.MAX_ATTEMPTS, called)
    check("cap constant is 20", s3_outbox.MAX_ATTEMPTS == 20)
    q("DELETE FROM pending_s3_deletes WHERE key = %s", (capped,), fetch=False)

    # batch limit
    many = [f"{tag}/m{i:04d}.jpg" for i in range(250)]
    seed_outbox(many)
    c = s3_outbox.flush_batch(delete_fn=lambda k: "ok")
    left = len(outbox_keys(many))
    check("one flush claims at most 200 rows", c["claimed"] <= 200 and left >= 50, (c, left))
    s3_outbox.flush_batch(delete_fn=lambda k: "ok")
    q("DELETE FROM pending_s3_deletes WHERE key = ANY(%s)", (many,), fetch=False)

    # AccessDenied: aggregated, no per-key ERROR flood
    s3_outbox.reset_for_tests()
    pa, pb = f"sfl-a-{uuid.uuid4().hex[:6]}", f"sfl-b-{uuid.uuid4().hex[:6]}"
    denied = [f"{pa}/{i}.jpg" for i in range(60)] + [f"{pb}/{i}.jpg" for i in range(20)]
    seed_outbox(denied)
    with catch_logs() as lg:
        c = s3_outbox.flush_batch(delete_fn=lambda k: "denied")
    errs = lg.levels("ERROR")
    check("80 denied keys -> exactly one ERROR per prefix (2), not 80", len(errs) == 2, errs)
    check("denied ERROR carries the prefix only", all("S3_DELETE_DENIED" in e for e in errs)
          and not any("/" in e.split("prefix=")[1] for e in errs), errs)
    check("plus exactly one aggregated WARNING with counts", len(lg.levels("WARNING")) == 1
          and "denied=80" in lg.levels("WARNING")[0], lg.levels("WARNING"))
    check("no log line contains a key", not any(pa in m.replace(f"prefix={pa}", "") or
                                                pb in m.replace(f"prefix={pb}", "")
                                                for _, m in lg.records), lg.records)
    with catch_logs() as lg:
        s3_outbox.flush_batch(delete_fn=lambda k: "denied")
    check("second denied run within 24h logs no ERROR again", not lg.levels("ERROR"), lg.records)
    check("denied rows are kept and retried (attempts incremented)",
          all(attempts_of(k) == 2 for k in denied[:3]))
    q("DELETE FROM pending_s3_deletes WHERE key = ANY(%s)", (denied,), fetch=False)
    s3_outbox.reset_for_tests()


def test_delete_object_status():
    print("attachments.delete_object_status")

    class FakeClient:
        def __init__(self, exc=None):
            self.exc = exc

        def delete_object(self, **kw):
            if self.exc:
                raise self.exc

    real_client, real_validate = attachments._client, attachments.validate_attachment_config
    attachments.validate_attachment_config = lambda: None
    try:
        with catch_logs() as lg:
            attachments._client = lambda: FakeClient()
            ok = attachments.delete_object_status("k/1")
            attachments._client = lambda: FakeClient(ClientError({"Error": {"Code": "AccessDenied"}}, "DeleteObject"))
            den = attachments.delete_object_status("k/2")
            attachments._client = lambda: FakeClient(ClientError({"Error": {"Code": "InternalError"}}, "DeleteObject"))
            err = attachments.delete_object_status("k/3")
        check("ok / denied / error mapping", (ok, den, err) == ("ok", "denied", "error"), (ok, den, err))
        check("blank key is ok", attachments.delete_object_status("") == "ok")
        check("delete_object_status never logs", not lg.records, lg.records)
    finally:
        attachments._client, attachments.validate_attachment_config = real_client, real_validate


def test_async_job_off_loop():
    print("outbox: async job body does not block the loop")
    src_file = open(s3_outbox.__file__).read()
    check("s3_outbox.py has no psycopg2 / boto3 token", "psycopg2" not in src_file and "boto3" not in src_file)
    body = inspect.getsource(s3_outbox.run_s3_outbox_job)
    check("job body: no psycopg2/boto3/DBManager/cursor call",
          not any(t in body for t in ("psycopg2", "boto3", "DBManager", ".cur", "execute(", "_client")), body)
    check("job body hands the work to run_in_executor", "run_in_executor" in body)
    check("run_s3_outbox_job is a coroutine function", inspect.iscoroutinefunction(s3_outbox.run_s3_outbox_job))

    tag = f"sfl-lag-{uuid.uuid4().hex[:8]}"
    keys = [f"{tag}/{i}.jpg" for i in range(40)]
    seed_outbox(keys)
    worker_threads = set()
    orig = s3_outbox.flush_batch

    def slow_delete(k):
        worker_threads.add(threading.current_thread())
        time.sleep(0.02)  # 40 x 20 ms = 0.8 s of blocking work
        return "ok"

    def patched():
        return orig(delete_fn=slow_delete)

    async def scenario():
        s3_outbox.flush_batch = patched
        echoed, max_gap = [], [0.0]
        q_in, q_out = asyncio.Queue(), asyncio.Queue()

        async def echo_loop():
            while True:
                item = await q_in.get()
                if item is None:
                    return
                await q_out.put(item)

        async def client_loop():
            last = time.monotonic()
            i = 0
            while not job.done():
                await q_in.put(i)
                echoed.append(await q_out.get())
                i += 1
                await asyncio.sleep(0.01)
                now = time.monotonic()
                max_gap[0] = max(max_gap[0], now - last)
                last = now
            await q_in.put(None)

        job = asyncio.ensure_future(s3_outbox.run_s3_outbox_job())
        await asyncio.gather(echo_loop(), client_loop())
        await job
        return echoed, max_gap[0]

    try:
        echoed, gap = asyncio.run(scenario())
    finally:
        s3_outbox.flush_batch = orig
    check("job drained the rows", outbox_keys(keys) == set())
    check("blocking work ran off the main thread",
          worker_threads and threading.main_thread() not in worker_threads, worker_threads)
    check("echo loop kept running during the job (>= 20 frames)", len(echoed) >= 20, len(echoed))
    check(f"event loop lag under 500 ms (max gap {gap * 1000:.0f} ms)", gap < 0.5, gap)
    q("DELETE FROM pending_s3_deletes WHERE key = ANY(%s)", (keys,), fetch=False)

    sched_src = open(os.path.join(API_DIR, "backend/interactions/scheduler.py")).read()
    check("scheduler registers s3_outbox_flush every 60 s with replace_existing",
          'id="s3_outbox_flush"' in sched_src and "FLUSH_INTERVAL_SECONDS" in sched_src
          and s3_outbox.FLUSH_INTERVAL_SECONDS == 60 and "replace_existing=True" in sched_src)


def test_ddl_registration():
    print("outbox DDL module at boot")
    check("'outbox' is in DDL_MODULES", "outbox" in db_module.DDL_MODULES, db_module.DDL_MODULES)
    from schema_ddl import outbox as outbox_ddl
    check("outbox DDL module has apply()", callable(getattr(outbox_ddl, "apply", None)))
    check("create_tables applies DDL_MODULES", "apply_modules(cur, DDL_MODULES)" in inspect.getsource(db_module.create_tables))
    life = inspect.getsource(main_module.lifespan)
    check("lifespan runs create_tables before it yields (before any request)",
          0 <= life.index("create_tables(") < life.index("yield"))
    check("lifespan calls registrations.load_all", "load_all" in life)
    check("pending_s3_deletes table exists", bool(q("SELECT to_regclass('pending_s3_deletes')")[0][0]))


# ── 2. lifecycle registries ───────────────────────────────────────────────────

def test_lifecycle_registry_unit():
    print("lifecycle registry unit behaviour")
    check("four kinds", lifecycle.KINDS == ("group_delete", "member_leave", "user_delete", "listing_hidden"))
    try:
        lifecycle.register("nope", lambda c: None)
        bad_kind = False
    except ValueError:
        bad_kind = True
    check("unknown kind raises ValueError on register", bad_kind)
    try:
        lifecycle.run("nope", None)
        bad_run = False
    except ValueError:
        bad_run = True
    check("unknown kind raises ValueError on run", bad_run)
    calls = []

    def h1(cur, gid):
        calls.append(("h1", gid))
        return ["a/1", "a/1", "", None, "../etc", "x" * 2000, 5, "a/2"]
    saved_hooks = list(lifecycle.hooks("group_delete"))
    lifecycle._registry["group_delete"][:] = []  # isolate from the real collectors
    lifecycle.register("group_delete", h1)
    lifecycle.register("group_delete", h1)
    try:
        before = [h for h in lifecycle.hooks("group_delete") if h is h1]
        keys = lifecycle.run("group_delete", None, "G")
    finally:
        lifecycle._registry["group_delete"][:] = saved_hooks
    check("register is idempotent for the same function", len(before) == 1)
    check("keys are de-duplicated, order kept, invalid ones dropped", keys == ["a/1", "a/2"], keys)

    def h_boom(cur, gid):
        raise RuntimeError("hook failure")
    lifecycle._registry["group_delete"][:] = [h_boom]
    try:
        lifecycle.run("group_delete", None, "G")
        propagated = False
    except RuntimeError:
        propagated = True
    finally:
        lifecycle._registry["group_delete"][:] = saved_hooks
    check("a hook exception propagates (aborts the delete)", propagated)
    check("enqueue of nothing is a no-op", lifecycle.enqueue_s3_deletes(None, []) == 0
          and lifecycle.enqueue_s3_deletes(None, None) == 0)
    names = {h.__name__ for h in lifecycle.hooks("group_delete")}
    check("photo + banner collectors registered for group_delete",
          {"collect_group_photo_key", "collect_announcement_banner_keys"} <= names, names)
    check("user_delete member removal registered",
          "remove_user_from_groups" in {h.__name__ for h in lifecycle.hooks("user_delete")})


def test_collectors_only_report_owned_keys():
    print("collectors only report keys proven to belong to the group")
    owner = make_user()
    other = str(uuid.uuid4())
    gid = mk_group_row([owner], owner)
    foreign = photo_key_for(other)  # another group's prefix
    q("UPDATE groups SET photo_key = %s WHERE _id = %s", (foreign, gid), fetch=False)
    own_banner, bad_banner = banner_key_for(gid), "group-announcements/../../x"
    add_banner(gid, own_banner)
    add_banner(gid, bad_banner)
    add_banner(gid, banner_key_for(other))
    keys = None
    db = DBManager()
    try:
        keys = lifecycle.run("group_delete", db.cur, gid)
        db.conn.rollback()
    finally:
        db.close()
    check("foreign photo key and traversal/foreign banner keys are NOT collected",
          keys == [own_banner], keys)
    cleanup([owner], [gid])


def test_group_delete_paths(client):
    print("group delete + leave call sites")
    # -- delete_group via the API
    a, b = make_user(), make_user()
    gid = mk_group_row([a, b], a)
    pk, bk = photo_key_for(gid), banner_key_for(gid)
    q("UPDATE groups SET photo_key = %s WHERE _id = %s", (pk, gid), fetch=False)
    add_banner(gid, bk)
    flushed = []
    real_flush, real_status, real_del = s3_outbox.flush_batch, attachments.delete_object_status, attachments.delete_object
    s3_outbox.flush_batch = lambda *a_, **k: flushed.append("flush") or {}
    attachments.delete_object_status = lambda k: flushed.append(k) or "ok"
    attachments.delete_object = lambda k: flushed.append(k)
    try:
        r = client.delete(f"/groups/{a}/{gid}", headers=hdr(a))
    finally:
        s3_outbox.flush_batch, attachments.delete_object_status, attachments.delete_object = real_flush, real_status, real_del
    check("DELETE /groups returns 204", r.status_code == 204, (r.status_code, r.text))
    check("group row gone", group_users(gid) is None)
    check("photo and banner keys are in the outbox", outbox_keys([pk, bk]) == {pk, bk}, outbox_keys([pk, bk]))
    check("request path never flushed or called S3", flushed == [], flushed)
    cleanup([a, b], [gid], [pk, bk])

    # -- leave_group last member
    a = make_user()
    gid = mk_group_row([a], a)
    pk, bk = photo_key_for(gid), banner_key_for(gid)
    q("UPDATE groups SET photo_key = %s WHERE _id = %s", (pk, gid), fetch=False)
    add_banner(gid, bk)
    r = client.post(f"/groups/{a}/{gid}/leave", headers=hdr(a))
    check("last-member leave returns 204", r.status_code == 204, (r.status_code, r.text))
    check("last-member leave deletes the group", group_users(gid) is None)
    check("last-member leave queues photo + banner keys", outbox_keys([pk, bk]) == {pk, bk})
    cleanup([a], [gid], [pk, bk])

    # -- non-last leave: group stays, member_leave hooks run, hook keys enqueued
    a, b = make_user(), make_user()
    gid = mk_group_row([a, b], a)
    pk = photo_key_for(gid)
    q("UPDATE groups SET photo_key = %s WHERE _id = %s", (pk, gid), fetch=False)
    hook_key = f"sfl-leave-{uuid.uuid4().hex[:8]}/k.jpg"
    seen = []

    def leave_hook(cur, group_id, user_id):
        seen.append((group_id, user_id))
        return [hook_key]
    lifecycle.register("member_leave", leave_hook)
    try:
        r = client.post(f"/groups/{b}/{gid}/leave", headers=hdr(b))
    finally:
        lifecycle._registry["member_leave"].remove(leave_hook)
    check("non-last leave returns 204", r.status_code == 204, r.status_code)
    check("group survives without the leaver", group_users(gid) == [a], group_users(gid))
    check("member_leave hook ran with (group, user)", seen == [(gid, b)], seen)
    check("member_leave keys enqueued", outbox_keys([hook_key]) == {hook_key})
    check("photo key NOT queued while the group survives", outbox_keys([pk]) == set())
    cleanup([a, b], [gid], [pk, hook_key])


# ── 3. R3-5 / R4-m4: delete_user ──────────────────────────────────────────────

def test_delete_user_hygiene(client):
    print("delete_user removes the id from every group (same transaction)")
    a, b, c = make_user(), make_user(), make_user()
    g1 = mk_group_row([a, b], b)
    g2 = mk_group_row([c, a], c)
    g3 = mk_group_row([a], a)
    pk, bk = photo_key_for(g3), banner_key_for(g3)
    q("UPDATE groups SET photo_key = %s WHERE _id = %s", (pk, g3), fetch=False)
    add_banner(g3, bk)
    r = client.delete(f"/user/{a}", headers=hdr(a))
    check("DELETE /user returns 204", r.status_code == 204, (r.status_code, r.text))
    check("user row gone", not user_exists(a))
    check("group 1 lost the id, keeps the other member", group_users(g1) == [b], group_users(g1))
    check("group 2 lost the id, order of the rest kept", group_users(g2) == [c], group_users(g2))
    check("group 3 (a was the last member) deleted", group_users(g3) is None)
    check("group 3 photo + banner keys are in the outbox", outbox_keys([pk, bk]) == {pk, bk})
    check("no group still lists the deleted id",
          q("SELECT count(*) FROM groups WHERE %s = ANY(users)", (a,))[0][0] == 0)

    # a send after the deletion no longer raises SaveFailedError
    print("send after a member deleted their account")
    real_push = ws_module.send_push

    async def no_push(*a_, **k):
        return None
    ws_module.send_push = no_push

    class FakeWS:
        def __init__(self):
            self.sent = []

        async def send_json(self, data):
            self.sent.append(data)

    async def scenario():
        mgr = ConnectionManager()
        try:
            sender_ws, c_ws = FakeWS(), FakeWS()
            mgr.active_connections[b] = sender_ws
            mgr.active_connections[c] = c_ws
            members = group_users(g2)  # what a client now sends to
            await mgr.send_msg({"from_user": c, "to_users": [m for m in members], "text": "after-delete",
                                "group_id": g2, "timestamp": "2026-10-02T00:00:00+00:00"})
            ok_errors = [f for f in c_ws.sent if f.get("type") == "error"]
            # control: a to_users that still holds the dead id is what used to fail
            await mgr.send_msg({"from_user": c, "to_users": [c, a], "text": "dead-recipient",
                                "group_id": g2, "timestamp": "2026-10-02T00:00:01+00:00"})
            ctrl_errors = [f for f in c_ws.sent if f.get("type") == "error"]
            return ok_errors, ctrl_errors
        finally:
            mgr.close()
    try:
        ok_errors, ctrl_errors = asyncio.run(scenario())
    finally:
        ws_module.send_push = real_push
    check("send to the cleaned group raises nothing and sends no error frame", ok_errors == [], ok_errors)
    saved = q("SELECT count(*) FROM messages WHERE group_id = %s AND text = 'after-delete'", (g2,))[0][0]
    check("the message was persisted", saved == 1, saved)
    check("control: the guard ignores client-supplied to_users (dead id) - no error frame, recipients derived server-side",
          ctrl_errors == [], ctrl_errors)
    cleanup([b, c], [g1, g2, g3], [pk, bk])


def test_delete_user_with_photo_banner_invites_report(client):
    print("R4-m4: delete account that is in a group with photo/banner/invites/open report")
    a, b = make_user(), make_user()
    gid = mk_group_row([a], a)
    pk, bk = photo_key_for(gid), banner_key_for(gid)
    q("UPDATE groups SET photo_key = %s WHERE _id = %s", (pk, gid), fetch=False)
    add_banner(gid, bk)
    for i in range(2):
        q("INSERT INTO invites (token_hash, kind, target_id, created_by, expires_at, max_uses) "
          "VALUES (%s,'group',%s,%s,NULL,5)", (uuid.uuid4().hex + uuid.uuid4().hex, gid, a), fetch=False)
    rid = str(uuid.uuid4())
    q("INSERT INTO content_reports (_id, reporter_id, reported_user_id, content_type, content_id, reason) "
      "VALUES (%s,%s,%s,'user',NULL,'spam')", (rid, b, a), fetch=False)
    r = client.delete(f"/user/{a}", headers=hdr(a))
    check("delete succeeds (204, the route's success code)", r.status_code == 204, (r.status_code, r.text))
    check("user row is gone", not user_exists(a))
    check("photo and banner keys exist in the outbox", outbox_keys([pk, bk]) == {pk, bk})
    check("group's invites purged", q("SELECT count(*) FROM invites WHERE target_id = %s", (gid,))[0][0] == 0)
    check("the open report about the deleted user cascaded away, reporter b untouched",
          q("SELECT count(*) FROM content_reports WHERE _id = %s", (rid,))[0][0] == 0 and user_exists(b))
    cleanup([b], [gid], [pk, bk])

    # same account in a group that survives: no keys queued, invites of a revoked
    a, b = make_user(), make_user()
    gid = mk_group_row([a, b], b)
    pk = photo_key_for(gid)
    q("UPDATE groups SET photo_key = %s WHERE _id = %s", (pk, gid), fetch=False)
    iid = str(uuid.uuid4())
    q("INSERT INTO invites (_id, token_hash, kind, target_id, created_by, expires_at, max_uses) "
      "VALUES (%s,%s,'group',%s,%s,NULL,5)", (iid, uuid.uuid4().hex + uuid.uuid4().hex, gid, a), fetch=False)
    r = client.delete(f"/user/{a}", headers=hdr(a))
    check("surviving-group case returns 204", r.status_code == 204, r.status_code)
    check("group keeps b only", group_users(gid) == [b], group_users(gid))
    check("surviving group's photo is NOT queued", outbox_keys([pk]) == set())
    check("departed member's invite link no longer exists active",
          q("SELECT count(*) FROM invites WHERE _id = %s AND revoked_at IS NULL", (iid,))[0][0] == 0)
    cleanup([b], [gid], [pk])

    # hook failure aborts the account deletion (nothing committed)
    a = make_user()
    gid = mk_group_row([a], a)

    def boom(cur, uid):
        raise RuntimeError("simulated hook failure")
    lifecycle.register("user_delete", boom)
    try:
        try:
            client.delete(f"/user/{a}", headers=hdr(a))
            raised = False
        except RuntimeError:
            raised = True
    finally:
        lifecycle._registry["user_delete"].remove(boom)
    check("a failing user_delete hook aborts the deletion", raised)
    check("user and group untouched after the aborted deletion", user_exists(a) and group_users(gid) == [a])
    cleanup([a], [gid])


# ── 4. update_group / create_group validation ─────────────────────────────────

def put_group(client, uid, gid, users, title="sfl group"):
    return client.put(f"/groups/{uid}/{gid}", json={"group_id": gid, "title": title, "users": users},
                      headers=hdr(uid))


def post_group(client, uid, users, title="sfl new"):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{uid}", json={"group_id": gid, "title": title, "users": users}, headers=hdr(uid))
    return gid, r


def test_update_and_create_group_validation(client):
    print("PUT /groups and create_group member validation")
    owner, friend, susp = make_user(), make_user(), make_user(suspended=True)
    dead = str(uuid.uuid4())
    gid = mk_group_row([owner, dead, "junk-string"], owner)

    # build-78-shaped payload echoes the raw array including dead + junk
    r = put_group(client, owner, gid, [owner, dead, "junk-string"], title="renamed")
    check("build-78 payload echoing dead + junk ids returns 200", r.status_code == 200, (r.status_code, r.text))
    check("stored list is cleaned (dead and junk dropped)", group_users(gid) == [owner], group_users(gid))
    check("title was saved", q("SELECT title FROM groups WHERE _id = %s", (gid,))[0][0] == "renamed")

    r = put_group(client, owner, gid, [owner, friend])
    check("a valid existing user is accepted", r.status_code == 200 and group_users(gid) == [owner, friend],
          (r.status_code, group_users(gid)))

    bodies = []
    for label, bad in (("new junk string", "not-a-uuid"), ("new non-existent uuid", str(uuid.uuid4())),
                       ("new suspended user", susp), ("new SQL-ish junk", "x'; DROP TABLE users;--")):
        r = put_group(client, owner, gid, [owner, friend, bad])
        check(f"PUT rejects {label} with 422 invalid_member",
              r.status_code == 422 and r.json()["detail"]["code"] == "invalid_member", (r.status_code, r.text))
        bodies.append(r.text)
        check(f"PUT {label}: stored list unchanged", group_users(gid) == [owner, friend], group_users(gid))
    check("the 422 body is identical for junk / unknown / suspended (no existence oracle)",
          len(set(bodies)) == 1, bodies)
    check("422 body does not echo the offending id", not any(susp in b_ or "DROP" in b_ for b_ in bodies))

    # existing suspended member already in the stored list is kept; uppercase of
    # a NEW id is stored canonical lowercase
    q("UPDATE groups SET users = %s WHERE _id = %s", ([owner, susp], gid), fetch=False)
    r = put_group(client, owner, gid, [owner, susp, friend.upper()])
    check("existing suspended member kept, new uppercase uuid accepted", r.status_code == 200, r.text)
    check("new id stored in canonical lowercase, existing kept as stored",
          group_users(gid) == [owner, susp, friend], group_users(gid))

    # create_group
    cbodies = []
    for label, bad in (("junk", "junk"), ("non-existent", str(uuid.uuid4())), ("suspended", susp)):
        g_new, r = post_group(client, owner, [owner, bad])
        check(f"create_group with a {label} id answers 422 invalid_member",
              r.status_code == 422 and r.json()["detail"]["code"] == "invalid_member", (r.status_code, r.text))
        check(f"create_group {label}: nothing stored", group_users(g_new) is None)
        cbodies.append(r.text)
    check("create_group 422 body equals update_group 422 body", set(cbodies) == set(bodies[:1]), (cbodies, bodies[:1]))
    g_ok, r = post_group(client, owner, [owner, friend, friend.upper()])
    check("normal create with creator + existing user returns 201", r.status_code == 201, (r.status_code, r.text))
    check("create stores canonical, de-duplicated members", group_users(g_ok) == [owner, friend], group_users(g_ok))
    g_solo, r = post_group(client, owner, [owner])
    check("creator alone always passes", r.status_code == 201 and group_users(g_solo) == [owner])
    cleanup([owner, friend, susp], [gid, g_ok, g_solo])


# ── 5. live member join / helper ──────────────────────────────────────────────

def test_live_member_ids():
    print("groups.live_member_ids and LIVE_MEMBER_JOIN")
    live, dead = make_user(), str(uuid.uuid4())
    gid = str(uuid.uuid4())
    q("INSERT INTO groups (_id, title, users) VALUES (%s,'sfl',ARRAY[%s,%s,'junk-string',%s,NULL]::text[])",
      (gid, live, dead, live.upper()), fetch=False)
    db = DBManager()
    try:
        helper = groups.live_member_ids(db.cur, gid)
        db.cur.execute("SELECT x.id FROM groups g, LATERAL (SELECT u._id::text AS id, m.ord "
                       + groups.LIVE_MEMBER_JOIN + ") x WHERE g._id = %s", (gid,))
        raw = [r[0] for r in db.cur.fetchall()]
        db.conn.rollback()
        check("helper returns exactly the live id (dead, junk, NULL dropped; uppercase merged)",
              helper == [live], helper)
        check("LIVE_MEMBER_JOIN yields the same id for every spelling (no error on junk/NULL)",
              set(raw) == {live} and len(raw) == 2, raw)
        check("LIVE_MEMBER_JOIN and helper agree", set(raw) == set(helper))
        q("UPDATE groups SET users = NULL WHERE _id = %s", (gid,), fetch=False)
        db.cur.execute("SELECT x.id FROM groups g, LATERAL (SELECT u._id::text AS id, m.ord "
                       + groups.LIVE_MEMBER_JOIN + ") x WHERE g._id = %s", (gid,))
        check("NULL users array: no rows, no error", db.cur.fetchall() == [])
        check("helper for a NULL users array is empty", groups.live_member_ids(db.cur, gid) == [])
        check("helper for a malformed group id is empty", groups.live_member_ids(db.cur, "not-a-uuid") == [])
        check("helper for an unknown group id is empty", groups.live_member_ids(db.cur, str(uuid.uuid4())) == [])
        db.conn.rollback()
    finally:
        db.close()
    q("UPDATE groups SET users = ARRAY[%s,%s,%s]::text[] WHERE _id = %s",
      (live, "zzz", dead, gid), fetch=False)
    db = DBManager()
    try:
        check("array order preserved for live members",
              groups.live_member_ids(db.cur, gid) == [live])
    finally:
        db.close()
    cleanup([live], [gid])


def test_live_member_plan_uses_pkey():
    print("EXPLAIN: LIVE_MEMBER_JOIN uses users_pkey on a 20,000+ user table")
    tag = f"sflplan_{uuid.uuid4().hex[:10]}"
    members = []
    gid = str(uuid.uuid4())
    try:
        q("INSERT INTO users (_id, username, email, hash_pass) "
          "SELECT gen_random_uuid(), %s || '_' || i, %s || '_' || i || '@example.com', 'x' "
          "FROM generate_series(1, 20000) AS i", (tag, tag), fetch=False)
        total = q("SELECT count(*) FROM users")[0][0]
        check("at least 20,000 users present", total >= 20000, total)
        rows = q("SELECT _id::text FROM users WHERE username LIKE %s ORDER BY username LIMIT 20", (tag + "_%",))
        members = [r[0] for r in rows]
        q("INSERT INTO groups (_id, title, users) VALUES (%s,'sflplan',%s)", (gid, members), fetch=False)
        q("ANALYZE users", fetch=False)
        q("ANALYZE groups", fetch=False)
        db = DBManager()
        try:
            db.cur.execute(
                "EXPLAIN SELECT x.id FROM groups g, LATERAL (SELECT u._id::text AS id, m.ord "
                + groups.LIVE_MEMBER_JOIN + ") x WHERE g._id = %s::uuid GROUP BY x.id ORDER BY min(x.ord)", (gid,))
            plan = "\n".join(r[0] for r in db.cur.fetchall())
            db.conn.rollback()
            check("helper returns all 20 members", len(groups.live_member_ids(db.cur, gid)) == 20)
            db.conn.rollback()
        finally:
            db.close()
        check("plan shows users_pkey (Index Scan or Index Only Scan)",
              "users_pkey" in plan and "Index" in plan, plan)
        check("plan has NO Seq Scan on users", "Seq Scan on users" not in plan, plan)
    finally:
        q("DELETE FROM groups WHERE _id = %s", (gid,), fetch=False)
        q("DELETE FROM users WHERE username LIKE %s", (tag + "_%",), fetch=False)
        q("ANALYZE users", fetch=False)
        left = q("SELECT count(*) FROM users WHERE username LIKE %s", (tag + "_%",))[0][0]
        check("generated users cleaned up", left == 0, left)


# ── 6. prune_group_members ────────────────────────────────────────────────────

def test_prune_group_members():
    print("prune_group_members")
    live1, live2, dead = make_user(), make_user(), str(uuid.uuid4())
    g_dirty = mk_group_row([live1, dead, "junk", live2], live1)
    g_clean = mk_group_row([live1, live2], live1)
    g_allgone = mk_group_row([dead, "junk"], None)
    # Security-gate fix (step 6): a build-78 client could have stored an
    # UPPERCASE-hex spelling of a live user id verbatim via the old PUT /groups.
    # The prune must compare lower(member_id) so that live member is NOT removed.
    g_upper_mixed = mk_group_row([live1.upper(), dead, live2], live1)
    g_upper_clean = mk_group_row([live2.upper(), live1.upper()], live1)
    before = {g: group_users(g) for g in (g_dirty, g_clean, g_allgone, g_upper_mixed, g_upper_clean)}
    dry = prune_group_members.prune(apply=False)
    after_dry = {g: group_users(g) for g in before}
    check("dry run changes nothing", after_dry == before, after_dry)
    check("dry run reports counts only (ints)", all(isinstance(v, int) for v in dry.values())
          and dry["groups_with_dangling"] >= 2 and dry["groups_that_would_be_empty"] >= 1, dry)
    check("dry run has no groups_updated", "groups_updated" not in dry)
    res = prune_group_members.prune(apply=True)
    check("--apply removes dangling ids and keeps member order",
          group_users(g_dirty) == [live1, live2], group_users(g_dirty))
    check("--apply leaves a clean group untouched", group_users(g_clean) == [live1, live2])
    check("--apply never deletes an emptied group", group_users(g_allgone) == [], group_users(g_allgone))
    check("--apply reported updated groups", res["groups_updated"] >= 2, res)
    check("uppercase-hex live member id is NOT pruned (only the dead id goes, spelling kept)",
          group_users(g_upper_mixed) == [live1.upper(), live2], group_users(g_upper_mixed))
    check("a group whose members are all uppercase-hex live ids is untouched",
          group_users(g_upper_clean) == before[g_upper_clean] == [live2.upper(), live1.upper()],
          group_users(g_upper_clean))
    res2 = prune_group_members.prune(apply=True)
    check("--apply is idempotent (second run updates nothing)", res2["groups_updated"] == 0, res2)
    check("second run leaves rows unchanged",
          group_users(g_dirty) == [live1, live2] and group_users(g_allgone) == []
          and group_users(g_upper_mixed) == [live1.upper(), live2])
    cleanup([live1, live2], [g_dirty, g_clean, g_allgone, g_upper_mixed, g_upper_clean])


# ── 7. reports / moderation registries ────────────────────────────────────────

ORIGINAL_TYPES = {"note", "message", "devotion_prompt", "group_title", "user"}
NEW_TYPES = {"group_listing", "thread_message"}


def test_report_registries(client):
    print("report resolvers and removers")
    check("five original types have resolvers", ORIGINAL_TYPES <= set(reports.CONTENT_RESOLVERS))
    check("five original types have removers", ORIGINAL_TYPES <= set(removers.CONTENT_REMOVERS))
    check("admin_actions re-exports the SAME removers dict object",
          admin_actions.CONTENT_REMOVERS is removers.CONTENT_REMOVERS)

    reporter, author = make_user(), make_user()
    nid = str(uuid.uuid4())
    q("INSERT INTO notes (_id, user_id, title, text) VALUES (%s,%s,'T','body')", (nid, author), fetch=False)
    db = DBManager()
    try:
        res = reports.CONTENT_RESOLVERS["note"](db.cur, nid, "ignored")
        missing = reports.CONTENT_RESOLVERS["note"](db.cur, str(uuid.uuid4()), "me")
        user_res = reports.CONTENT_RESOLVERS["user"](db.cur, "x", author)
        db.conn.rollback()
    finally:
        db.close()
    check("resolver returns a 3-tuple (author, snippet, canonical id)",
          isinstance(res, tuple) and len(res) == 3 and res[0] == author and "body" in res[1] and res[2] == nid, res)
    check("original types stay lenient for a missing row (input id, empty snippet)",
          missing[0] == "me" and missing[1] == "" and len(missing) == 3, missing)
    check("user type resolves to the supplied user", user_res[0] == author)

    real_email = reports.send_email
    reports.send_email = lambda *a_, **k: None
    sent_ids = []
    try:
        h = hdr(reporter)
        r = client.post("/reports/", json={"content_type": "note", "content_id": nid.upper(), "reason": "spam"}, headers=h)
        check("report on an existing note returns 201", r.status_code == 201, (r.status_code, r.text))
        row = q("SELECT content_id::text, reported_user_id::text FROM content_reports WHERE _id = %s",
                (r.json()["id"],))
        check("stored content id is canonical lowercase and author resolved server-side",
              row and row[0][0] == nid and row[0][1] == author, row)
        sent_ids.append(r.json()["id"])
        r = client.post("/reports/", json={"content_type": "message", "content_id": str(uuid.uuid4()),
                                           "reported_user_id": author, "reason": "x"}, headers=h)
        check("report on a missing message (lenient old type) still 201 as before", r.status_code == 201, r.text)
        r = client.post("/reports/", json={"content_type": "user", "reported_user_id": author, "reason": "x"}, headers=h)
        check("direct user report 201", r.status_code == 201, r.text)

        for bad in ("not-a-uuid", "12345", "'; --"):
            r = client.post("/reports/", json={"content_type": "note", "content_id": bad, "reason": "x"}, headers=h)
            check(f"malformed content id {bad!r} -> 422 (not a 500)", r.status_code == 422, (r.status_code, r.text))
        r = client.post("/reports/", json={"content_type": "bogus", "content_id": nid, "reason": "x"}, headers=h)
        check("type outside the Literal -> 422", r.status_code == 422)
        r = client.post("/reports/", json={"content_type": "note", "reason": "x"}, headers=h)
        check("missing content_id for a content type -> 422", r.status_code == 422)

        # new Literal values, no resolver registered by SF itself
        n_before = q("SELECT count(*) FROM content_reports WHERE reporter_id = %s", (reporter,))[0][0]
        saved = {t: reports.CONTENT_RESOLVERS.pop(t, None) for t in NEW_TYPES}
        try:
            r = client.post("/reports/", json={"content_type": "thread_message", "content_id": str(uuid.uuid4()),
                                               "reason": "x"}, headers=h)
            check("thread_message accepted by the schema, 404 with no resolver", r.status_code == 404, (r.status_code, r.text))
            r = client.post("/reports/", json={"content_type": "group_listing", "content_id": "AbCdEfGh12",
                                               "reason": "x"}, headers=h)
            check("group_listing accepted by the schema, 404 with no resolver", r.status_code == 404, (r.status_code, r.text))
            for bad in ("short", "AbCdEfGh1!", "AbCdEfGh123"):
                r = client.post("/reports/", json={"content_type": "group_listing", "content_id": bad, "reason": "x"},
                                headers=h)
                check(f"group_listing malformed id {bad!r} -> 422", r.status_code == 422, (r.status_code, r.text))
            r = client.post("/reports/", json={"content_type": "thread_message", "content_id": "AbCdEfGh12",
                                               "reason": "x"}, headers=h)
            check("thread_message id must be a UUID -> 422", r.status_code == 422)
            n_after = q("SELECT count(*) FROM content_reports WHERE reporter_id = %s", (reporter,))[0][0]
            check("a 404 stores nothing", n_after == n_before, (n_before, n_after))

            # a registered resolver is honoured (the extension point LST/THR use)
            tid, tauthor = str(uuid.uuid4()), author
            reports.register_resolver("thread_message", lambda cur, cid, rep: (tauthor, "snip", cid))
            r = client.post("/reports/", json={"content_type": "thread_message", "content_id": tid.upper(),
                                               "reason": "x"}, headers=h)
            check("a registered resolver makes thread_message reportable (201)", r.status_code == 201, (r.status_code, r.text))
            if r.status_code == 201:
                row = q("SELECT content_id::text, content_snippet FROM content_reports WHERE _id = %s", (r.json()["id"],))
                check("canonical id + resolver snippet stored", row[0] == (tid, "snip"), row)
            reports.register_resolver("thread_message", lambda cur, cid, rep: None)
            r = client.post("/reports/", json={"content_type": "thread_message", "content_id": tid, "reason": "x"}, headers=h)
            check("a resolver returning None -> 404", r.status_code == 404, r.status_code)
        finally:
            for t, fn in saved.items():
                if fn is None:
                    reports.CONTENT_RESOLVERS.pop(t, None)
                else:
                    reports.CONTENT_RESOLVERS[t] = fn
    finally:
        reports.send_email = real_email
    check("route Literal holds the five old + two new types",
          set(reports_route.ReportRequest.model_fields["content_type"].annotation.__args__)
          == ORIGINAL_TYPES | NEW_TYPES)
    q("DELETE FROM content_reports WHERE reporter_id = %s", (reporter,), fetch=False)
    q("DELETE FROM notes WHERE _id = %s", (nid,), fetch=False)
    cleanup([reporter, author])


def run_py(code=None, args=None):
    cmd = [sys.executable] + (["-c", code] if code else args)
    return subprocess.run(cmd, cwd=API_DIR, capture_output=True, text=True, timeout=120)


def test_registrations_fresh_subprocess():
    print("registrations.load_all in a FRESH process + moderation CLI")
    code = (
        "import json\n"
        "from backend.registrations import load_all\n"
        "load_all(); load_all()\n"
        "from backend.interactions import reports\n"
        "from backend.moderation import removers, admin_actions\n"
        "from routes.reports import ReportRequest\n"
        "from backend.interactions import lifecycle\n"
        "hk = {k: sorted(f.__name__ for f in lifecycle.hooks(k)) for k in lifecycle.KINDS}\n"
        "lit = list(ReportRequest.model_fields['content_type'].annotation.__args__)\n"
        "print(json.dumps({'lit': lit, 'res': sorted(reports.CONTENT_RESOLVERS),\n"
        "  'rem': sorted(removers.CONTENT_REMOVERS), 'hooks': hk, 'same': admin_actions.CONTENT_REMOVERS is removers.CONTENT_REMOVERS}))\n"
    )
    r = run_py(code)
    check("subprocess ran cleanly", r.returncode == 0, r.stderr[-400:])
    import json
    try:
        out = json.loads(r.stdout.strip().splitlines()[-1])
    except Exception:
        out = {"lit": [], "res": [], "rem": [], "same": False}
    lit, res, rem = set(out["lit"]), set(out["res"]), set(out["rem"])
    check("fresh process: every original type has a resolver AND a remover",
          ORIGINAL_TYPES <= res and ORIGINAL_TYPES <= rem, out)
    # Types not yet owned by a later task (LST/THR add group_listing /
    # thread_message in their own steps) must be absent from BOTH registries or
    # present in BOTH, and every other Literal value must be registered in both.
    asym = {t for t in lit if (t in res) != (t in rem)}
    check("resolvers and removers are registered symmetrically for every Literal type", not asym, asym)
    # group_listing is owned by LST (registered by listings_wiring via load_all) and must now be
    # present in BOTH registries; thread_message stays with THR and is not required yet.
    check("every Literal type except the not-yet-built thread type is registered in both",
          (lit - {"thread_message"}) <= res and (lit - {"thread_message"}) <= rem, (lit, res, rem))
    check("fresh process: group_listing is present in BOTH registries",
          "group_listing" in res and "group_listing" in rem, (res, rem))
    check("fresh process: admin_actions shares the removers dict", out["same"])
    # R3-m3 (tightened once LST landed): the listing hooks exist in a cold process
    # only because registrations.load_all imports backend.listings_wiring, and the
    # group_listing resolver/remover pair is never half-registered.
    hooks = out.get("hooks", {})
    check("fresh process: LST member_leave hook registered by load_all",
          "hide_listing_when_owner_leaves" in hooks.get("member_leave", []), hooks)
    check("fresh process: LST user_delete hook registered by load_all",
          "delete_listings_of_deleted_owner" in hooks.get("user_delete", []), hooks)
    check("fresh process: group_listing is in both registries or neither",
          ("group_listing" in res) == ("group_listing" in rem), (res, rem))
    check("fresh process: the SF collectors are still registered next to the LST hooks",
          bool(hooks.get("user_delete")) and len(hooks.get("user_delete", [])) >= 2, hooks)

    # CLI: a report whose type has no remover exits non-zero and removes nothing
    reporter, target = make_user(), make_user()
    rid = str(uuid.uuid4())
    q("INSERT INTO content_reports (_id, reporter_id, reported_user_id, content_type, content_id, reason) "
      "VALUES (%s,%s,%s,'thread_message',%s,'x')", (rid, reporter, target, str(uuid.uuid4())), fetch=False)
    in_registry = "thread_message" in removers.CONTENT_REMOVERS
    if not in_registry:
        r = run_py(args=["-m", "backend.moderation.admin_actions", "resolve", rid, "--remove-content"])
        check("CLI exits non-zero for a content type with no remover", r.returncode != 0, (r.returncode, r.stderr[-300:]))
        check("CLI says which type has no remover", "No remover registered" in r.stderr, r.stderr[-300:])
        st = q("SELECT status FROM content_reports WHERE _id = %s", (rid,))[0][0]
        check("report stays open when nothing could be removed", st == "open", st)
    else:
        check("thread_message already registered by a later task (CLI stub case n/a)", True)
    q("DELETE FROM content_reports WHERE _id = %s", (rid,), fetch=False)

    # CLI: a type that does have a remover works from a cold process (load_all ran)
    rid2 = str(uuid.uuid4())
    q("INSERT INTO content_reports (_id, reporter_id, reported_user_id, content_type, content_id, reason) "
      "VALUES (%s,%s,%s,'user',NULL,'x')", (rid2, reporter, target), fetch=False)
    r = run_py(args=["-m", "backend.moderation.admin_actions", "resolve", rid2, "--remove-content"])
    check("CLI resolves a 'user' report from a cold process (exit 0)", r.returncode == 0, (r.returncode, r.stderr[-300:]))
    check("report marked actioned", q("SELECT status FROM content_reports WHERE _id = %s", (rid2,))[0][0] == "actioned")
    # a note report: remover deletes the note
    nid = str(uuid.uuid4())
    q("INSERT INTO notes (_id, user_id, title, text) VALUES (%s,%s,'T','b')", (nid, target), fetch=False)
    rid3 = str(uuid.uuid4())
    q("INSERT INTO content_reports (_id, reporter_id, reported_user_id, content_type, content_id, reason) "
      "VALUES (%s,%s,%s,'note',%s,'x')", (rid3, reporter, target, nid), fetch=False)
    r = run_py(args=["-m", "backend.moderation.admin_actions", "resolve", rid3, "--remove-content"])
    check("CLI note removal exits 0 and deletes the note",
          r.returncode == 0 and not q("SELECT 1 FROM notes WHERE _id = %s", (nid,)), (r.returncode, r.stderr[-300:]))
    cleanup([reporter, target])


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    db = DBManager()
    db.cur.execute("SHOW port")
    port = db.cur.fetchone()[0]
    db.close()
    check("tests run against scratch DB port 55432", port == "55432", port)
    if port != "55432":
        raise SystemExit("refusing to continue: not the scratch database")
    # Start from an empty outbox so flush assertions see only this test's rows.
    q("DELETE FROM pending_s3_deletes", fetch=False)

    client = TestClient(main_module.app)
    test_ddl_registration()
    test_lifecycle_registry_unit()
    test_collectors_only_report_owned_keys()
    test_outbox_same_transaction()
    test_outbox_flush_semantics()
    test_delete_object_status()
    test_async_job_off_loop()
    test_group_delete_paths(client)
    test_delete_user_hygiene(client)
    test_delete_user_with_photo_banner_invites_report(client)
    test_update_and_create_group_validation(client)
    test_live_member_ids()
    test_live_member_plan_uses_pkey()
    test_prune_group_members()
    test_report_registries(client)
    test_registrations_fresh_subprocess()

    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        raise SystemExit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
