"""Shared helpers for the join-requests test scripts (test_group_join_requests*.py).
Not a test itself (no ``test_`` prefix). Scratch database only: ``start()`` asserts
SHOW port = 55432 before anything else runs, and every script calls it first.
"""
import _pathfix  # noqa: F401

import dataclasses
import logging
import sys
import uuid

import _thr_common as C
from _thr_common import check, cookie, make_group, make_user, sql
from fastapi.testclient import TestClient

import main as main_module
from backend.interactions import flags, join_requests_config as jrc
from backend.monitoring.watchdog import _match_error_signal
from backend.rate_limiting import limiter
from backend.registrations import load_all
from db import DBManager

FLAGS = ("join_requests", "explorer_browse", "join_request_push")
_SAVED_FLAGS: dict = {}
_LISTINGS: list = []
H = cookie

LOG_FORMAT = "%(asctime)s [%(name)s] %(levelname)s - %(message)s"


class Capture(logging.Handler):
    """Collects records and the formatted lines the CloudWatch watchdog would see."""

    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.setFormatter(logging.Formatter(LOG_FORMAT))
        self.records = []
        self.lines = []

    def emit(self, record):
        self.records.append(record)
        self.lines.append(self.format(record))

    def clear(self):
        self.records.clear()
        self.lines.clear()

    def watchdog_hits(self):
        return [(ln, _match_error_signal(ln)) for ln in self.lines if _match_error_signal(ln)]

    def levels(self):
        return {r.levelname for r in self.records}


def start():
    """Assert the scratch DB, wire hooks, return (client, log capture)."""
    C.require_scratch_db()
    load_all()
    cap = Capture()
    logging.getLogger().addHandler(cap)
    logging.getLogger().setLevel(logging.DEBUG)
    for name in FLAGS:
        rows = sql("SELECT state, canary_user_ids::text[] FROM feature_flags WHERE name = %s", (name,))
        _SAVED_FLAGS[name] = rows[0] if rows else None
    return TestClient(main_module.app), cap


def set_flags(owner, join_requests="on", explorer_browse="on", push="off"):
    for name, state in (("join_requests", join_requests), ("explorer_browse", explorer_browse),
                        ("join_request_push", push)):
        flags.set_flag(name, state, actor=owner)
    flags.invalidate()


def make_listing(owner, members=(), max_members=None, accepting=True, status="published", title="Jrq Group"):
    """A group owned by ``owner`` (also a member) plus its listing. Returns (group_id, public_id)."""
    gid = make_group([owner, *members], creator=owner)
    sql("UPDATE groups SET title = %s, max_members = %s WHERE _id = %s", (title, max_members, gid))
    pid = "Jq" + uuid.uuid4().hex[:8]
    sql("INSERT INTO group_listings (public_id, group_id, title, status, accepting_requests) "
        "VALUES (%s,%s,%s,%s,%s)", (pid, gid, title, status, accepting))
    _LISTINGS.append(gid)
    return gid, pid


def override_cfg(**kw):
    jrc._cached = dataclasses.replace(jrc.get_join_requests_config(), **kw)
    return jrc._cached


def restore_cfg():
    jrc.reset_for_tests()


def rows(sql_text, params=()):
    return sql(sql_text, params)


def req_status(rid):
    r = sql("SELECT status FROM group_join_requests WHERE id = %s", (rid,))
    return r[0][0] if r else None


def members(gid):
    return sql("SELECT users FROM groups WHERE _id = %s", (gid,))[0][0]


def finish():
    for name, saved in _SAVED_FLAGS.items():
        try:
            if saved is None:
                sql("UPDATE feature_flags SET state = 'off' WHERE name = %s", (name,))
            else:
                sql("UPDATE feature_flags SET state = %s, canary_user_ids = %s::uuid[] WHERE name = %s",
                    (saved[0], saved[1] or [], name))
        except Exception:  # noqa: BLE001
            pass
    flags.invalidate()
    restore_cfg()
    for gid in _LISTINGS:
        sql("DELETE FROM group_join_requests WHERE group_id = %s", (gid,))
        sql("DELETE FROM group_listings WHERE group_id = %s", (gid,))
        sql("DELETE FROM invites WHERE target_id = %s", (gid,))
    for uid in C.USERS:
        sql("DELETE FROM group_join_requests WHERE user_id = %s", (uid,))
    C.cleanup()
    print(f"\n{'=' * 60}")
    if C.FAILED:
        print(f"RESULT: {len(C.PASSED)} passed, {len(C.FAILED)} FAILED")
        for label, detail in C.FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    print(f"RESULT: {len(C.PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


def call(cli, method, url, uid, reset=True, **kw):
    if reset:
        limiter.reset()
    return getattr(cli, method)(url, headers=H(uid), **kw)


def req(cli, uid, pid, note=None, reset=True):
    body = {} if note is None else {"note": note}
    return call(cli, "post", f"/join-requests/{uid}/listings/{pid}/request", uid, reset=reset, json=body)


def mine(cli, uid, pid=None):
    suffix = f"?public_id={pid}" if pid else ""
    return call(cli, "get", f"/join-requests/{uid}/requests{suffix}", uid)


def owner_list(cli, uid, gid):
    return call(cli, "get", f"/join-requests/{uid}/groups/{gid}/requests", uid)


def decide(cli, uid, gid, rid, action, **kw):
    return call(cli, "post", f"/join-requests/{uid}/groups/{gid}/requests/{rid}/{action}", uid, **kw)
