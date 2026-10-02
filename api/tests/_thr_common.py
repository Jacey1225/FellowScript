"""Shared helpers for the message-thread test scripts (test_threads.py,
test_thread_websocket.py, test_threads_lifecycle.py). Not a test itself (no
``test_`` prefix). Scratch database only: ``require_scratch_db()`` asserts
SHOW port = 55432 before anything else runs.
"""
import _pathfix  # noqa: F401

import logging
import os
import sys
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from db import DBManager  # noqa: E402
from backend.interactions import flags  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from schemas.users import CURRENT_TERMS_VERSION  # noqa: E402

API_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSED, FAILED = [], []
USERS, GROUPS, KEYS = [], [], []


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


def require_scratch_db():
    d = DBManager()
    try:
        d.cur.execute("SHOW port")
        port = d.cur.fetchone()[0]
    finally:
        d.close()
    check("tests run against scratch DB port 55432", port == "55432", port)
    if port != "55432":
        raise SystemExit("refusing to continue: not the scratch database")


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


def make_user(prefix="thr", terms=True, suspended=False):
    uid = str(uuid.uuid4())
    sql("INSERT INTO users (_id, username, email, hash_pass, terms_version, suspended_at) "
        "VALUES (%s,%s,%s,'x',%s,%s)",
        (uid, f"{prefix}_{uid[:8]}", f"{prefix}_{uid[:8]}@example.com",
         CURRENT_TERMS_VERSION if terms else None, "2020-01-01" if suspended else None))
    USERS.append(uid)
    return uid


def make_group(users, creator=None):
    gid = str(uuid.uuid4())
    sql("INSERT INTO groups (_id, title, users, creator_id) VALUES (%s,%s,%s,%s)",
        (gid, "thr-test", list(users), creator))
    GROUPS.append(gid)
    return gid


def make_msg(author, gid, text="hello root", kind=None, key=None, group=True):
    mid = str(uuid.uuid4())
    sql("INSERT INTO messages (_id, from_user, group_id, text, timestamp, attachment_kind, attachment_key) "
        "VALUES (%s,%s,%s,%s,NOW(),%s,%s)", (mid, author, gid if group else None, text, kind, key))
    return mid


def make_thread(gid, root, creator, title="a thread", root_author=None, root_preview="hello root"):
    tid = str(uuid.uuid4())
    sql("INSERT INTO threads (_id, group_id, root_message_id, root_preview, root_author_id, title, created_by) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s)", (tid, gid, root, root_preview, root_author or creator, title, creator))
    return tid


def add_tmsg(tid, author, text="reply", key=None, kind=None, deleted=False):
    mid = str(uuid.uuid4())
    sql("INSERT INTO thread_messages (_id, thread_id, from_user, text, attachment_kind, attachment_key, created_at) "
        "VALUES (%s,%s,%s,%s,%s,%s,NOW())", (mid, tid, author, text, kind, key))
    if deleted:
        sql("UPDATE thread_messages SET deleted_at = NOW() WHERE _id=%s", (mid,))
    return mid


def tcount(tid):
    return sql("SELECT COUNT(*) FROM thread_messages WHERE thread_id=%s", (tid,))[0][0]


def cookie(uid):
    sm = SessionManager()
    try:
        return {"cookie": f"session={sm.create_session(uid)}"}
    finally:
        sm.close()


def set_flag(name, state, actor):
    flags.set_flag(name, state, actor=actor)
    flags.invalidate()


def own_key(uid, ext="jpg"):
    key = f"attachments/{uid}/{uuid.uuid4().hex}.{ext}"
    KEYS.append(key)
    return key


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
        sql("DELETE FROM device_tokens WHERE user_id=%s", (uid,))
        sql("DELETE FROM blocked_users WHERE blocker_id=%s OR blocked_id=%s", (uid, uid))
        sql("DELETE FROM user_friends WHERE user_id=%s OR friend_id=%s", (uid, uid))
        sql("DELETE FROM sessions WHERE user_id=%s", (uid,))
        sql("DELETE FROM users WHERE _id=%s", (uid,))
    if KEYS:
        sql("DELETE FROM pending_s3_deletes WHERE key = ANY(%s)", (KEYS,))


def finish(flag_names=("threads",)):
    try:
        for n in flag_names:
            set_flag(n, "off", USERS[0] if USERS else "test")
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
