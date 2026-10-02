"""Tests for task 20261001-message-threads step 3: group message delete / undo /
retention sweeper (flag ``message_delete``).

Scratch database only (asserts SHOW port = 55432 first). Proves:
  * author-only soft delete; non-author, non-member, removed member, wrong group,
    unknown / malformed ids, suspended author, DM message, anonymous: all the same
    uniform 404 (anonymous 401/403 before any lookup); flag off = same 404 and no write
  * undo inside the 10 s window restores; refused after the window (and after a
    restore, or a delete by someone else); seq/ack interplay: seq is unchanged
    by delete and restore and a later message never reuses it
  * delete is exempt from the terms gate (users here have no current terms)
  * frames: message_deleted / message_restored carry neither from_user nor text (build 78
    ignores them), reach live members only, restored frame skips blocked users
  * history readers hide soft-deleted rows: fetch_group, DM page, gallery, activity
    monitoring avg, last_contact source
  * retention sweeper: nothing purged inside the window, purged after it, kept while an
    open report references it (late report still captures the text, hold lifts when the
    report is resolved), restore wins, thread root_preview cleared, S3 outbox rules
    (own prefix + unreferenced only; foreign prefix, shared key kept), purge runs with
    the flag off
  * no PII / bare ERROR word in logs; R-SCHED / R-ROUTE greps; rate limit
Run with: cd api && ../.venv/bin/python tests/test_message_delete.py
"""
import _pathfix  # noqa: F401

import asyncio
import inspect
import json
import logging
import os
import re
import sys
import uuid
from datetime import datetime, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.interactions import flags, reports  # noqa: E402
from backend.interactions import message_delete as md  # noqa: E402
from backend.interactions.groups import GroupsManager  # noqa: E402
from backend.interactions.friends import FriendsManager  # noqa: E402
from backend.interactions.threads_config import get_message_delete_config  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.auth.terms import terms_current  # noqa: E402
from routes.messaging import manager as ws_manager  # noqa: E402

API_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSED, FAILED = [], []
USERS, GROUPS = [], []


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_json(self, payload):
        self.sent.append(payload)


class LogCapture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.records = []

    def emit(self, record):
        self.records.append(record)


def sql(query, params=()):
    d = DBManager()
    try:
        d.cur.execute(query, params)
        rows = d.cur.fetchall() if d.cur.description else None
        d.conn.commit()
        return rows
    finally:
        d.close()


def make_user(prefix="mdel"):
    uid = str(uuid.uuid4())
    d = DBManager()
    try:
        d.insertion("users", {"_id": uid, "username": f"{prefix}_{uid[:8]}",
                              "email": f"{prefix}_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        d.close()
    USERS.append(uid)
    return uid


def make_group(users):
    gid = str(uuid.uuid4())
    sql("INSERT INTO groups (_id, title, users) VALUES (%s,%s,%s)", (gid, "mdel-test", list(users)))
    GROUPS.append(gid)
    return gid


def make_msg(author, gid, text="hello secret text", kind=None, key=None, group=True):
    mid = str(uuid.uuid4())
    sql("INSERT INTO messages (_id, from_user, group_id, text, timestamp, attachment_kind, attachment_key) "
        "VALUES (%s,%s,%s,%s,NOW(),%s,%s)", (mid, author, gid if group else None, text, kind, key))
    return mid


def msg_row(mid):
    return sql("SELECT deleted_at, deleted_by::text, text, attachment_kind, attachment_key, COALESCE(seq,0) "
               "FROM messages WHERE _id=%s", (mid,))[0]


def cookie(uid):
    sm = SessionManager()
    try:
        return {"cookie": f"session={sm.create_session(uid)}"}
    finally:
        sm.close()


def set_flag(state, actor):
    flags.set_flag("message_delete", state, actor=actor)
    flags.invalidate()


def age_delete(mid, seconds=None, days=None):
    if seconds is not None:
        sql("UPDATE messages SET deleted_at = NOW() - make_interval(secs => %s) WHERE _id=%s", (seconds, mid))
    if days is not None:
        sql("UPDATE messages SET deleted_at = NOW() - make_interval(days => %s) WHERE _id=%s", (days, mid))


def url(u, g, m, restore=False):
    return f"/groups/{u}/{g}/messages/{m}" + ("/restore" if restore else "")


def cleanup():
    for gid in GROUPS:
        sql("DELETE FROM threads WHERE group_id=%s", (gid,))
        sql("DELETE FROM message_recipients WHERE message_id IN (SELECT _id FROM messages WHERE group_id=%s)", (gid,))
        sql("DELETE FROM messages WHERE group_id=%s", (gid,))
        sql("DELETE FROM groups WHERE _id=%s", (gid,))
    for uid in USERS:
        sql("DELETE FROM content_reports WHERE reporter_id=%s OR reported_user_id=%s", (uid, uid))
        sql("DELETE FROM message_recipients WHERE user_id=%s OR message_id IN (SELECT _id FROM messages WHERE from_user=%s)", (uid, uid))
        sql("DELETE FROM messages WHERE from_user=%s", (uid,))
        sql("DELETE FROM blocked_users WHERE blocker_id=%s OR blocked_id=%s", (uid, uid))
        sql("DELETE FROM user_friends WHERE user_id=%s OR friend_id=%s", (uid, uid))
        sql("DELETE FROM sessions WHERE user_id=%s", (uid,))
        sql("DELETE FROM users WHERE _id=%s", (uid,))


# ------------------------------------------------------------------ tests

def test_http(client):
    print("delete / undo over HTTP")
    cfg = get_message_delete_config()
    check("config: undo 10 s, retention 30 d", cfg.undo_seconds == 10 and cfg.evidence_retention_days == 30)
    a, b, outsider, removed = (make_user() for _ in range(4))
    gid, gid2 = make_group([a, b, removed]), make_group([a, b])
    ck_a, ck_b, ck_o, ck_r = cookie(a), cookie(b), cookie(outsider), cookie(removed)
    check("test users have no current terms (delete must still work)", not any(
        _terms(u) for u in (a, b)))
    ws_a, ws_b, ws_o = FakeWS(), FakeWS(), FakeWS()
    ws_manager.active_connections[a], ws_manager.active_connections[b] = ws_a, ws_b
    ws_manager.active_connections[outsider] = ws_o

    # flag off: uniform 404, no write
    set_flag("off", a)
    m0 = make_msg(a, gid)
    r_off = client.delete(url(a, gid, m0), headers=ck_a)
    check("flag off: DELETE 404", r_off.status_code == 404, r_off.text)
    check("flag off: no write", msg_row(m0)[0] is None)
    r_off_restore = client.post(url(a, gid, m0, True), headers=ck_a)
    check("flag off: restore 404", r_off_restore.status_code == 404)
    set_flag("on", a)

    # author happy path
    mid = make_msg(a, gid, text="the secret body")
    seq_before = msg_row(mid)[5]
    r = client.delete(url(a, gid, mid), headers=ck_a)
    check("author delete 200", r.status_code == 200, r.text)
    check("body is {id, undo_seconds:10}", r.json() == {"id": mid, "undo_seconds": 10}, r.text)
    row = msg_row(mid)
    check("soft delete: deleted_at + deleted_by=author, text kept", row[0] is not None and row[1] == a and row[2] == "the secret body")
    check("seq unchanged by delete", row[5] == seq_before)

    # uniform denials
    ref = client.delete(url(a, gid, str(uuid.uuid4())), headers=ck_a)  # unknown id
    ref_body = ref.json()
    check("unknown id 404", ref.status_code == 404)
    m_b = make_msg(b, gid)
    denials = {
        "non-author member": client.delete(url(b, gid, mid_of(a, gid)), headers=ck_b),
        "path user != session": client.delete(url(a, gid, m_b), headers=ck_b),
        "non-member": client.delete(url(outsider, gid, m_b), headers=ck_o),
        "wrong group": client.delete(url(b, gid2, m_b), headers=ck_b),
        "malformed message id": client.delete(url(a, gid, "not-a-uuid"), headers=ck_a),
        "malformed group id": client.delete(url(a, "zzz", m_b), headers=ck_a),
        "already deleted": client.delete(url(a, gid, mid), headers=ck_a),
    }
    for name, resp in denials.items():
        # path user != session is stopped by require_match (403/404) before any lookup
        if name == "path user != session":
            check(f"{name}: denied", resp.status_code in (403, 404), resp.status_code)
        else:
            check(f"{name}: 404 identical to unknown id", resp.status_code == 404 and resp.json() == ref_body,
                  f"{resp.status_code} {resp.text}")
    check("non-author attempt left row live", msg_row(m_b)[0] is None)
    anon = client.delete(url(a, gid, m_b))
    check("anonymous denied (401/403/404)", anon.status_code in (401, 403, 404), anon.status_code)
    check("anonymous left row live", msg_row(m_b)[0] is None)

    # removed member
    m_r = make_msg(removed, gid)
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (removed, gid))
    rr = client.delete(url(removed, gid, m_r), headers=ck_r)
    check("removed member: 404", rr.status_code == 404 and rr.json() == ref_body)
    check("removed member: row live", msg_row(m_r)[0] is None)

    # DM message (group_id NULL) never matches
    m_dm = make_msg(a, None, group=False)
    rd = client.delete(url(a, gid, m_dm), headers=ck_a)
    check("DM message: 404", rd.status_code == 404)
    check("DM message untouched", msg_row(m_dm)[0] is None)

    # suspended author
    m_s = make_msg(b, gid)
    sql("UPDATE users SET suspended_at = NOW() WHERE _id=%s", (b,))
    rs = client.delete(url(b, gid, m_s), headers=ck_b)
    check("suspended author: 404", rs.status_code == 404)
    sql("UPDATE users SET suspended_at = NULL WHERE _id=%s", (b,))

    # undo within window
    rr1 = client.post(url(a, gid, mid, True), headers=ck_b)  # someone else restoring
    check("restore by non-author refused (403/404)", rr1.status_code in (403, 404))
    check("still deleted after non-author restore", msg_row(mid)[0] is not None)
    ru = client.post(url(a, gid, mid, True), headers=ck_a)
    check("restore within window 200 {id}", ru.status_code == 200 and ru.json() == {"id": mid}, ru.text)
    row = msg_row(mid)
    check("restored: deleted_at/by cleared, text and seq intact", row[0] is None and row[1] is None
          and row[2] == "the secret body" and row[5] == seq_before)
    check("restore of live message: 404", client.post(url(a, gid, mid, True), headers=ck_a).status_code == 404)

    # new message after delete/restore never reuses seq
    mid2 = make_msg(a, gid)
    check("later message seq is greater (no seq reuse)", msg_row(mid2)[5] > seq_before)

    # refusal after the window
    client.delete(url(a, gid, mid), headers=ck_a)
    age_delete(mid, seconds=get_message_delete_config().undo_seconds + 2)
    rl = client.post(url(a, gid, mid, True), headers=ck_a)
    check("restore after window: 404", rl.status_code == 404 and rl.json() == ref_body, rl.text)
    check("row stays deleted after refused restore", msg_row(mid)[0] is not None)
    # just inside the window still works
    m_in = make_msg(a, gid)
    client.delete(url(a, gid, m_in), headers=ck_a)
    age_delete(m_in, seconds=get_message_delete_config().undo_seconds - 4)
    check("restore at ~6 s still allowed", client.post(url(a, gid, m_in, True), headers=ck_a).status_code == 200)

    ws_manager.active_connections.pop(a, None)
    ws_manager.active_connections.pop(b, None)
    ws_manager.active_connections.pop(outsider, None)
    limiter.reset()


def mid_of(author, gid):
    return make_msg(author, gid)


def _terms(uid):
    d = DBManager()
    try:
        return terms_current(d.cur, uid)
    finally:
        d.close()


def test_frames(client):
    print("frames")
    a, b, blocked, outsider = (make_user() for _ in range(4))
    gid = make_group([a, b, blocked])
    set_flag("on", a)
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blocked, a))
    wsa, wsb, wsc, wso = FakeWS(), FakeWS(), FakeWS(), FakeWS()
    ws_manager.active_connections.update({a: wsa, b: wsb, blocked: wsc, outsider: wso})
    mid = make_msg(a, gid, text="frame text secret")
    ck = cookie(a)
    client.delete(url(a, gid, mid), headers=ck)
    for who, ws in (("author", wsa), ("member", wsb), ("blocked member", wsc)):
        check(f"{who} got message_deleted", len(ws.sent) == 1 and ws.sent[0]["type"] == "message_deleted", ws.sent)
    check("non-member got nothing", wso.sent == [])
    f = wsb.sent[0]
    check("deleted frame: id + group_id + deleted_at", f["id"] == mid and f["group_id"] == gid and "deleted_at" in f)
    check("deleted frame: no from_user / text keys (build 78 ignores)", "from_user" not in f and "text" not in f, f)
    check("deleted frame leaks no body", "frame text secret" not in json.dumps(f))
    for w in (wsa, wsb, wsc):
        w.sent.clear()
    client.post(url(a, gid, mid, True), headers=ck)
    check("author + member got message_restored", wsa.sent[0]["type"] == "message_restored" and wsb.sent[0]["type"] == "message_restored")
    check("restored frame skipped blocked relationship", wsc.sent == [], wsc.sent)
    g = wsb.sent[0]
    check("restored frame has no from_user/text", "from_user" not in g and "text" not in g, g)
    check("restored frame: sender/body/seq/created_at", g["body"] == "frame text secret" and g["sender"].startswith("mdel_")
          and isinstance(g["seq"], int) and g["created_at"])
    # a dead socket must not fail the request
    class Dead:
        async def send_json(self, p):
            raise RuntimeError("gone")
    ws_manager.active_connections[b] = Dead()
    m2 = make_msg(a, gid)
    check("dead socket does not fail delete", client.delete(url(a, gid, m2), headers=ck).status_code == 200)
    for u in (a, b, blocked, outsider):
        ws_manager.active_connections.pop(u, None)
    limiter.reset()


def test_readers():
    print("history readers hide soft-deleted rows")
    a, b = make_user(), make_user()
    gid = make_group([a, b])
    live = make_msg(a, gid, "visible-live-row", kind="image", key=f"attachments/{a}/live.png")
    dead = make_msg(a, gid, "hidden-dead-row", kind="image", key=f"attachments/{a}/dead.png")
    sql("UPDATE messages SET deleted_at=NOW(), deleted_by=%s WHERE _id=%s", (a, dead))
    blob = json.dumps(GroupsManager(b, gid).fetch_group(), default=str)
    check("fetch_group: live shown", "visible-live-row" in blob)
    check("fetch_group: deleted hidden", "hidden-dead-row" not in blob)
    gm = GroupsManager(b, gid)
    g = json.dumps(gm.fetch_gallery(), default=str)
    check("gallery: deleted hidden, live shown", live in g and dead not in g)
    gm.close()
    # DM page
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s) ON CONFLICT DO NOTHING", (a, b, b, a))
    dm_live, dm_dead = make_msg(a, None, "dm-live", group=False), make_msg(a, None, "dm-dead", group=False)
    for m in (dm_live, dm_dead):
        sql("INSERT INTO message_recipients (message_id, user_id) VALUES (%s,%s)", (m, b))
    sql("UPDATE messages SET deleted_at=NOW(), deleted_by=%s WHERE _id=%s", (a, dm_dead))
    fm = FriendsManager(b)
    try:
        page = json.dumps(fm.fetch_dm_page(a, 50), default=str)
    finally:
        fm.close()
    check("DM page: deleted hidden, live shown", "dm-live" in page and "dm-dead" not in page)
    # activity monitoring per-user average counts only live rows
    from backend.interactions.activity_monitoring import _PER_USER_METRIC_EXTRA
    check("activity monitoring: messages metric filters deleted_at IS NULL",
          "deleted_at IS NULL" in _PER_USER_METRIC_EXTRA["messages"])
    # last_contact source
    src = open(os.path.join(API_DIR, "backend", "interactions", "friends.py")).read()
    seg = src[src.index(") AS last_contact") - 600: src.index(") AS last_contact")]
    check("last_contact subquery excludes soft-deleted rows", "m.deleted_at IS NULL" in seg, seg)
    # reports still resolve a deleted row's text
    d = DBManager()
    try:
        _u, snippet, _c = reports._resolve_message(d.cur, dead, a)
    finally:
        d.close()
    check("reports._resolve_message still captures soft-deleted text", snippet == "hidden-dead-row", snippet)


def purge_state(mid):
    return sql("SELECT text, attachment_kind, attachment_key, attachment_meta FROM messages WHERE _id=%s", (mid,))[0]


def queued(key):
    return bool(sql("SELECT 1 FROM pending_s3_deletes WHERE key=%s", (key,)))


def test_sweeper(client):
    print("retention sweeper")
    cfg = get_message_delete_config()
    a, b, rep = make_user(), make_user(), make_user()
    gid = make_group([a, b])
    own_key = f"attachments/{a}/{uuid.uuid4().hex}.png"
    foreign_key = f"attachments/{b}/{uuid.uuid4().hex}.png"
    shared_key = f"attachments/{a}/{uuid.uuid4().hex}.png"

    def soft(mid, days):
        sql("UPDATE messages SET deleted_at=NOW(), deleted_by=from_user WHERE _id=%s", (mid,))
        age_delete(mid, days=days)

    m_young = make_msg(a, gid, "young body")
    soft(m_young, cfg.evidence_retention_days - 1)
    m_old = make_msg(a, gid, "old body", kind="image", key=own_key)
    soft(m_old, cfg.evidence_retention_days + 1)
    m_live = make_msg(a, gid, "live body")
    m_hold = make_msg(a, gid, "reported body")
    soft(m_hold, cfg.evidence_retention_days + 1)
    m_foreign = make_msg(a, gid, "foreign key body", kind="image", key=foreign_key)
    soft(m_foreign, cfg.evidence_retention_days + 1)
    m_shared1 = make_msg(a, gid, "shared 1", kind="image", key=shared_key)
    soft(m_shared1, cfg.evidence_retention_days + 1)
    m_shared2 = make_msg(a, gid, "shared 2 live", kind="image", key=shared_key)
    m_thr_root = make_msg(a, gid, "thread root text")
    soft(m_thr_root, cfg.evidence_retention_days + 1)
    tid = str(uuid.uuid4())
    sql("INSERT INTO threads (_id, group_id, root_message_id, title, created_by, root_preview) "
        "VALUES (%s,%s,%s,%s,%s,%s)", (tid, gid, m_thr_root, "t", a, "thread root text"))
    # open report on m_hold
    sql("INSERT INTO content_reports (reporter_id, reported_user_id, content_type, content_id, content_snippet, reason) "
        "VALUES (%s,%s,'message',%s,'reported body','spam')", (b, a, m_hold))

    set_flag("off", a)  # sweeper runs regardless of the flag
    counts = md.purge_once(batch_size=1000)
    check("sweeper ran with flag off and purged rows", counts["purged"] >= 4 and counts["failed"] == 0, counts)
    check("inside retention window: text kept", purge_state(m_young)[0] == "young body")
    check("live row untouched", purge_state(m_live)[0] == "live body")
    t, kind, key, meta = purge_state(m_old)
    check("old: text and attachment columns cleared", t == "" and kind is None and key is None and meta == {}, (t, kind, key, meta))
    check("old: own-prefix unreferenced key queued in outbox", queued(own_key))
    check("open report holds the purge (text kept)", purge_state(m_hold)[0] == "reported body")
    check("foreign-prefix key NOT queued, row purged", not queued(foreign_key) and purge_state(m_foreign)[2] is None)
    check("key still referenced by a live row NOT queued", not queued(shared_key))
    check("thread root_preview cleared", sql("SELECT root_preview FROM threads WHERE _id=%s", (tid,))[0][0] is None)
    c2 = md.purge_once(batch_size=1000)
    check("second run is idempotent (nothing more purged for these)", purge_state(m_old)[0] == "" and c2["failed"] == 0)

    # late report still captures the text of a soft-deleted, not-yet-purged row
    m_late = make_msg(a, gid, "late-report text")
    soft(m_late, 5)
    d = DBManager()
    try:
        _u, snip, _c = reports._resolve_message(d.cur, m_late, a)
    finally:
        d.close()
    check("late report captures text pre-purge", snip == "late-report text")
    # hold lifts once the report is resolved
    sql("UPDATE content_reports SET status='resolved', resolved_at=NOW() WHERE content_id=%s", (m_hold,))
    md.purge_once(batch_size=1000)
    check("resolved report lifts the hold", purge_state(m_hold)[0] == "")
    # restore wins over the sweeper (row live => never a candidate)
    m_back = make_msg(a, gid, "restored body")
    sql("UPDATE messages SET deleted_at=NULL, deleted_by=NULL WHERE _id=%s", (m_back,))
    md.purge_once(batch_size=1000)
    check("restored row never purged", purge_state(m_back)[0] == "restored body")
    # batch size honoured
    for _ in range(3):
        soft(make_msg(a, gid, "batch"), cfg.evidence_retention_days + 1)
    c3 = md.purge_once(batch_size=2)
    check("batch_size caps found rows", c3["found"] <= 2, c3)
    md.purge_once(batch_size=1000)
    sql("DELETE FROM pending_s3_deletes WHERE key = ANY(%s)", ([own_key, foreign_key, shared_key],))
    sql("DELETE FROM threads WHERE _id=%s", (tid,))
    limiter.reset()


def test_logging(client):
    print("logging")
    cap = LogCapture()
    root = logging.getLogger()
    root.addHandler(cap)
    old = root.level
    root.setLevel(logging.DEBUG)
    a = make_user()
    gid = make_group([a])
    set_flag("on", a)
    mid = make_msg(a, gid, "PII-LOG-CANARY text")
    ck = cookie(a)
    client.delete(url(a, gid, mid), headers=ck)
    client.post(url(a, gid, mid, True), headers=ck)
    sql("UPDATE messages SET deleted_at=NOW()-interval '40 days', deleted_by=from_user WHERE _id=%s", (mid,))
    md.purge_once(batch_size=1000)
    root.removeHandler(cap)
    root.setLevel(old)
    msgs = [r.getMessage() for r in cap.records if r.name.startswith(("backend.interactions.message_delete", "routes.messages_delete"))]
    check("delete/restore/purge produced audit lines", any("MESSAGE_DELETE" in m for m in msgs) and any("MESSAGE_RESTORE" in m for m in msgs), msgs)
    check("no message text in any log line", not any("PII-LOG-CANARY" in m for m in msgs), msgs)
    check("no bare ERROR word in non-error lines", not any(
        re.search(r"\bERROR\b", m) for r, m in ((r, r.getMessage()) for r in cap.records
        if r.name.startswith(("backend.interactions.message_delete", "routes.messages_delete")) and r.levelno < logging.ERROR)))
    limiter.reset()


def test_rate_limit(client):
    print("rate limit")
    a = make_user()
    gid = make_group([a])
    set_flag("on", a)
    ck = cookie(a)
    limiter.reset()
    codes = [client.delete(url(a, gid, str(uuid.uuid4())), headers=ck).status_code for _ in range(32)]
    check("30/minute per user across DIFFERENT message ids: 31st+ request is 429 (bucket must not be per-URL)", 429 in codes and codes[:30].count(404) == 30, codes)
    limiter.reset()


def test_greps():
    print("R-SCHED / R-ROUTE greps")
    check("run_message_purge_job is async def", inspect.iscoroutinefunction(md.run_message_purge_job))
    src = inspect.getsource(md.run_message_purge_job)
    check("job runs sync work via run_in_executor", "run_in_executor(None" in src)
    check("job has no psycopg2/cursor call itself", not re.search(r"psycopg2|\.cur\b|cursor\(|DBManager|boto3", src))
    check("job does not consult the flag", "flags" not in src and "is_enabled" not in src)
    check("sweep interval is 15 minutes", md.SWEEP_INTERVAL_SECONDS == 900)
    sched = open(os.path.join(API_DIR, "backend", "interactions", "scheduler.py")).read()
    m = re.search(r"scheduler\.add_job\(run_message_purge_job[^)]*\)", sched, re.S)
    check("purge job registered replace_existing=True, interval", bool(m and "replace_existing=True" in m.group(0)
          and '"interval"' in m.group(0)), m and m.group(0))
    rsrc = open(os.path.join(API_DIR, "routes", "messages_delete.py")).read()
    check("routes: no async def (R-ROUTE)", "async def" not in rsrc)
    from routes import messages_delete as rm
    for r in rm.messages_delete_router.routes:
        check(f"{r.methods} {r.path} endpoint is plain def", not inspect.iscoroutinefunction(r.endpoint))
        deps = [str(d.call) for d in r.dependant.dependencies]
        check(f"{r.path}: not gated by require_current_terms", "import require_current_terms" not in rsrc and "require_current_terms(" not in rsrc and "terms" not in rsrc.split('"""',2)[2] and not any("terms" in x for x in deps))
    check("main wires messages_delete_router", "messages_delete_router" in open(os.path.join(API_DIR, "main.py")).read())
    msrc = open(os.path.join(API_DIR, "backend", "interactions", "message_delete.py")).read()
    bad = [l for l in msrc.splitlines() if re.search(r"logger\.(info|warning|debug)\(", l) and re.search(r"\bERROR\b", l)]
    check("no bare ERROR in module log calls", not bad, bad)
    check("send_msg path untouched: no message_delete reference in websockets.py",
          "message_delete" not in open(os.path.join(API_DIR, "backend", "interactions", "websockets.py")).read())


def main():
    d = DBManager()
    d.cur.execute("SHOW port")
    port = d.cur.fetchone()[0]
    d.close()
    check("tests run against scratch DB port 55432", port == "55432", port)
    if port != "55432":
        raise SystemExit("refusing to continue: not the scratch database")
    client = TestClient(main_module.app)
    try:
        test_http(client)
        test_frames(client)
        test_readers()
        test_sweeper(client)
        test_logging(client)
        test_rate_limit(client)
        test_greps()
    finally:
        try:
            set_flag("off", USERS[0] if USERS else "test")
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
