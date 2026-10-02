"""Tests for task 20261001-chat-pagination, backend step 1 (1a): everything the
paged endpoints and threads build on, with no endpoint-shaped behaviour yet.

Properties proved (each would catch a regression of the specific change):
  1. DDL module ``chat_pagination``: applies twice cleanly on a database that
     has no ``seq`` column, and on one where ALTER steps 1-4 already ran (the
     "Jacey ran the ALTERs first" path); both indexes exist and are VALID
     (pg_index.indisvalid); idx_messages_deleted_by is partial; creating the
     group index before the column exists fails (the ordering guard). Done in
     a throwaway schema inside a rolled-back transaction, plus a double apply
     against the real tables.
  2. Ordering: rows with identical timestamps (microsecond and iOS
     whole-second) come back in server ``seq`` order across every page
     boundary of the keyset predicate, with no duplicate and no gap; legacy
     rows with NULL seq read as 0; the SF cursor codec round-trips a row.
  3. Timestamp clamp: future beyond skew becomes now, within skew is kept,
     unparseable becomes now, Z / +00:00 / DST-offset / naive / whole-second
     parse, past values are never changed. Times are relative to the current
     clock.
  4. save_message returns (id, stored ISO Z microseconds); the sender-only ack
     {type, client_ref, id, group_id, timestamp} matches the stored row, is
     never sent to recipients, carries no from_user/text; client_ref
     validation matrix; recipient frame gains ``id`` and keeps the original
     timestamp string when accepted, whole-second Z when clamped; a
     save_message stub returning None still delivers (no id, no ack); the
     SaveFailedError path still sends the error frame to the sender, no ack.
  5. Legacy shape snapshot (build-78 shaped fixtures): group history, DM
     history and WS frames are key-for-key identical except for the added
     ``id``; replayed with the chat_pagination flags off and on.
  6. Soft-deleted rows (deleted_at set directly) are excluded from
     fetch_group (host and other) and read_friend / GET /message/messages
     (DM readers) but remain readable by reports._resolve_message.
  7. author_set: self + current members minus blocks in both directions;
     ex-member, dead account id and junk string in groups.users ignored and
     never make a page query raise; source-level guard that it goes through
     live_member_ids with no join of its own.
  8. Config validation failure modes; wired into startup_checks.
  9. save_message: no stale-singleton regressions are covered by the existing
     test_ws_stale_cursor_reconnect suite, which still has to pass.

Not asserted on purpose: friends.py ``last_contact`` (PAG#3 filters it).

Run with: cd api && ../.venv/bin/python tests/test_chat_pagination.py
"""
import _pathfix  # noqa: F401

import asyncio
import inspect
import json
import logging
import os
import re
import sys
import tempfile
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

import psycopg2  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import db as db_module  # noqa: E402
from db import DBManager  # noqa: E402
import backend.interactions.websockets as ws_module  # noqa: E402
from backend.interactions.websockets import (  # noqa: E402
    ConnectionManager, clamp_message_timestamp, parse_client_timestamp,
    valid_client_ref, wire_timestamp_whole_seconds,
)
from backend.interactions import flags, paging, groups as groups_module, reports  # noqa: E402
from backend.interactions import chat_config  # noqa: E402
from backend.interactions.groups import GroupsManager, author_set  # noqa: E402
from backend.interactions.friends import FriendsManager  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.errors import SaveFailedError  # noqa: E402
from backend import startup_checks  # noqa: E402
import schema_ddl  # noqa: E402
from schema_ddl import chat_pagination as ddl  # noqa: E402

PASSED, FAILED = [], []
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


class FakeWS:
    def __init__(self, fail=False):
        self.sent = []
        self.fail = fail

    async def send_json(self, payload):
        if self.fail:
            raise RuntimeError("socket gone")
        self.sent.append(payload)


# --------------------------------------------------------------------------- helpers

def make_user(prefix="pag") -> str:
    uid = str(uuid.uuid4())
    d = DBManager()
    try:
        d.insertion("users", {
            "_id": uid, "username": f"{prefix}_{uid[:8]}", "email": f"{prefix}_{uid[:8]}@example.com",
            "hash_pass": "x",
        })
    finally:
        d.close()
    return uid


def make_group(users, title="pag-test") -> str:
    gid = str(uuid.uuid4())
    d = DBManager()
    try:
        d.cur.execute("INSERT INTO groups (_id, title, users) VALUES (%s, %s, %s)", (gid, title, list(users)))
        d.conn.commit()
    finally:
        d.close()
    return gid


def insert_msg(from_user, group_id, text, ts, seq="default", deleted=False, to_users=()) -> str:
    """Direct INSERT. seq='default' uses the column default, None writes NULL."""
    mid = str(uuid.uuid4())
    d = DBManager()
    try:
        if seq == "default":
            d.cur.execute(
                "INSERT INTO messages (_id, from_user, group_id, text, timestamp) VALUES (%s,%s,%s,%s,%s)",
                (mid, from_user, group_id, text, ts),
            )
        else:
            d.cur.execute(
                "INSERT INTO messages (_id, from_user, group_id, text, timestamp, seq) VALUES (%s,%s,%s,%s,%s,%s)",
                (mid, from_user, group_id, text, ts, seq),
            )
        if deleted:
            d.cur.execute("UPDATE messages SET deleted_at = NOW(), deleted_by = %s WHERE _id = %s", (from_user, mid))
        for u in to_users:
            d.cur.execute("INSERT INTO message_recipients (message_id, user_id) VALUES (%s,%s)", (mid, u))
        d.conn.commit()
    finally:
        d.close()
    return mid


def cleanup(user_ids, group_ids):
    d = DBManager()
    try:
        for gid in group_ids:
            d.cur.execute("DELETE FROM message_recipients WHERE message_id IN (SELECT _id FROM messages WHERE group_id = %s)", (gid,))
            d.cur.execute("DELETE FROM messages WHERE group_id = %s", (gid,))
            d.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            d.cur.execute("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
            d.cur.execute("DELETE FROM message_recipients WHERE message_id IN (SELECT _id FROM messages WHERE from_user = %s)", (uid,))
            d.cur.execute("DELETE FROM messages WHERE from_user = %s", (uid,))
            d.cur.execute("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
            d.cur.execute("DELETE FROM blocked_users WHERE blocker_id = %s OR blocked_id = %s", (uid, uid))
            d.cur.execute("DELETE FROM groups WHERE %s = ANY(users)", (uid,))
            d.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        d.conn.commit()
    finally:
        d.close()


def session_cookie(uid) -> dict:
    sm = SessionManager()
    try:
        return {"cookie": f"session={sm.create_session(uid)}"}
    finally:
        sm.close()


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat()


def db_row(mid):
    d = DBManager()
    try:
        d.cur.execute("SELECT _id::text, timestamp, seq, deleted_at FROM messages WHERE _id = %s", (mid,))
        return d.cur.fetchone()
    finally:
        d.close()


# --------------------------------------------------------------------------- 0 scratch DB

def assert_scratch():
    d = DBManager()
    d.cur.execute("SHOW port")
    port = d.cur.fetchone()[0]
    d.close()
    check("tests run against scratch DB port 55432", port == "55432", port)
    if port != "55432":
        raise SystemExit("refusing to continue: not the scratch database")


# --------------------------------------------------------------------------- 1 DDL

def index_info(cur, name, schema=None):
    cur.execute(
        "SELECT i.indisvalid, pg_get_indexdef(i.indexrelid), i.indpred IS NOT NULL "
        "FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE c.relname = %s AND n.nspname = COALESCE(%s, n.nspname)",
        (name, schema),
    )
    return cur.fetchall()


def make_tmp_tables(cur, schema, with_seq_alters=False):
    cur.execute(f"CREATE SCHEMA {schema}")
    cur.execute(f"SET LOCAL search_path = {schema}, public")
    cur.execute("CREATE TABLE users (_id UUID PRIMARY KEY)")
    cur.execute(
        "CREATE TABLE messages (_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), from_user UUID, group_id UUID, "
        "text TEXT NOT NULL, timestamp TIMESTAMPTZ DEFAULT NOW())"
    )
    if with_seq_alters:
        # ALTER steps 1-4 of contract 6.15, run by hand (the Jacey-first path).
        cur.execute("CREATE SEQUENCE IF NOT EXISTS messages_seq")
        cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS seq BIGINT")
        cur.execute("ALTER TABLE messages ALTER COLUMN seq SET DEFAULT nextval('messages_seq')")
        cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ")
        cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_by UUID REFERENCES users(_id) ON DELETE SET NULL")


def ddl_checks(cur, schema, label):
    gp = index_info(cur, "idx_messages_group_page", schema)
    db_ = index_info(cur, "idx_messages_deleted_by", schema)
    check(f"{label}: idx_messages_group_page exists exactly once", len(gp) == 1, str(gp))
    check(f"{label}: idx_messages_group_page is valid (indisvalid)", bool(gp) and gp[0][0] is True, str(gp))
    if gp:
        d = gp[0][1].lower().replace('"', "")
        check(f"{label}: group index key is (group_id, timestamp DESC, COALESCE(seq,0) DESC, _id DESC)",
              "group_id" in d and "timestamp desc" in d and "coalesce(seq, (0)::bigint) desc" in d and "_id desc" in d, d)
        check(f"{label}: group index is not partial", gp[0][2] is False, d)
    check(f"{label}: idx_messages_deleted_by exists and is valid", len(db_) == 1 and db_[0][0] is True, str(db_))
    if db_:
        check(f"{label}: idx_messages_deleted_by is partial (deleted_by IS NOT NULL)",
              db_[0][2] is True and "is not null" in db_[0][1].lower(), db_[0][1])
    cur.execute(
        "SELECT column_name, is_nullable, column_default FROM information_schema.columns "
        "WHERE table_schema = %s AND table_name = 'messages' AND column_name IN ('seq','deleted_at','deleted_by')",
        (schema,),
    )
    cols = {r[0]: r for r in cur.fetchall()}
    check(f"{label}: seq, deleted_at, deleted_by columns exist", set(cols) == {"seq", "deleted_at", "deleted_by"}, str(cols))
    if "seq" in cols:
        check(f"{label}: seq is nullable with nextval default",
              cols["seq"][1] == "YES" and "nextval" in (cols["seq"][2] or "") and "messages_seq" in cols["seq"][2], str(cols["seq"]))


def test_ddl():
    print("DDL module chat_pagination")
    check("chat_pagination is registered in DDL_MODULES", "chat_pagination" in db_module.DDL_MODULES, str(db_module.DDL_MODULES))
    mods = list(db_module.DDL_MODULES)
    check("chat_pagination comes after flags and outbox",
          mods.index("chat_pagination") > mods.index("flags") and mods.index("chat_pagination") > mods.index("outbox"), str(mods))

    # Fresh path, twice.
    d = DBManager()
    try:
        cur = d.cur
        make_tmp_tables(cur, "pagtest_fresh")
        ddl.apply(cur)
        ddl_checks(cur, "pagtest_fresh", "fresh apply #1")
        ddl.apply(cur)
        ddl_checks(cur, "pagtest_fresh", "fresh apply #2 (idempotent)")
        cur.execute("SELECT count(*) FROM pg_indexes WHERE schemaname = 'pagtest_fresh' AND tablename = 'messages' AND indexname LIKE 'idx_messages_%'")
        # group page, deleted_by, and the DM page index added by the DM step.
        check("second apply created no duplicate indexes", cur.fetchone()[0] == 3)
    finally:
        d.conn.rollback()
        d.close()

    # Jacey-first path: ALTER steps 1-4 already ran, then boot applies the module.
    d = DBManager()
    try:
        cur = d.cur
        make_tmp_tables(cur, "pagtest_alters", with_seq_alters=True)
        ddl.apply(cur)
        ddl_checks(cur, "pagtest_alters", "ALTERs-first apply #1")
        ddl.apply(cur)
        ddl_checks(cur, "pagtest_alters", "ALTERs-first apply #2")
    finally:
        d.conn.rollback()
        d.close()

    # Out-of-band index already built (Jacey ran CREATE INDEX too): apply is a no-op.
    d = DBManager()
    try:
        cur = d.cur
        make_tmp_tables(cur, "pagtest_oob", with_seq_alters=True)
        cur.execute("CREATE INDEX idx_messages_group_page ON messages (group_id, timestamp DESC, (COALESCE(seq, 0)) DESC, _id DESC)")
        ddl.apply(cur)
        ddl_checks(cur, "pagtest_oob", "out-of-band index then apply")
    finally:
        d.conn.rollback()
        d.close()

    # Ordering guard: the group index before the column exists must fail.
    d = DBManager()
    try:
        cur = d.cur
        make_tmp_tables(cur, "pagtest_guard")
        cur.execute("SAVEPOINT s")
        failed = None
        try:
            cur.execute("CREATE INDEX idx_messages_group_page ON messages (group_id, timestamp DESC, (COALESCE(seq, 0)) DESC, _id DESC)")
        except psycopg2.errors.UndefinedColumn as e:
            failed = e
        cur.execute("ROLLBACK TO SAVEPOINT s")
        check("CREATE INDEX before the seq column exists fails (ordering guard)", failed is not None)
        src = inspect.getsource(ddl.apply)
        check("apply() creates the sequence/column/default before the group index",
              src.index("CREATE SEQUENCE") < src.index("ADD COLUMN IF NOT EXISTS seq")
              < src.index("SET DEFAULT nextval") < src.index("idx_messages_group_page"))
        check("apply() never uses CONCURRENTLY", "CONCURRENTLY" not in src)
    finally:
        d.conn.rollback()
        d.close()

    # Real tables: boot already applied it; apply twice more, both indexes valid.
    d = DBManager()
    try:
        ddl.apply(d.cur)
        ddl.apply(d.cur)
        d.conn.commit()
        ddl_checks(d.cur, "public", "real tables")
    finally:
        d.close()


# --------------------------------------------------------------------------- 3 clamp

def test_clamp():
    print("Timestamp clamp")
    now = datetime.now(timezone.utc).replace(microsecond=0)
    skew = chat_config.get_pagination_config().future_timestamp_skew_seconds
    check("skew from chat.json is 300", skew == 300, str(skew))

    check("future beyond skew is clamped to now",
          clamp_message_timestamp(iso(now + timedelta(seconds=skew + 60)), now=now) == now)
    check("far future (a year) is clamped to now",
          clamp_message_timestamp(iso(now + timedelta(days=365)), now=now) == now)
    inside = now + timedelta(seconds=skew - 30)
    check("future within skew is kept", clamp_message_timestamp(iso(inside), now=now) == inside)
    check("exactly at the skew edge is kept",
          clamp_message_timestamp(iso(now + timedelta(seconds=skew)), now=now) == now + timedelta(seconds=skew))
    for junk in ("", "not a date", "2026-13-45T99:99:99Z", None, 12345, "x" * 100, "   "):
        check(f"unparseable {junk!r:.20} becomes now", clamp_message_timestamp(junk, now=now) == now)
    past = now - timedelta(hours=5, seconds=7)
    check("past value unchanged", clamp_message_timestamp(iso(past), now=now) == past)
    check("ancient value unchanged", clamp_message_timestamp("2001-01-01T00:00:00Z", now=now) == datetime(2001, 1, 1, tzinfo=timezone.utc))
    p = now - timedelta(minutes=10)
    z = p.strftime("%Y-%m-%dT%H:%M:%SZ")
    check("trailing Z parses", clamp_message_timestamp(z, now=now) == p)
    check("+00:00 parses", clamp_message_timestamp(p.strftime("%Y-%m-%dT%H:%M:%S+00:00"), now=now) == p)
    est = (p - timedelta(hours=4)).replace(tzinfo=timezone(timedelta(hours=-4)))
    # same instant written in a -04:00 (DST) offset
    off = p.astimezone(timezone(timedelta(hours=-4))).strftime("%Y-%m-%dT%H:%M:%S-04:00")
    check("DST offset (-04:00) is converted to the same instant", clamp_message_timestamp(off, now=now) == p, off)
    off2 = p.astimezone(timezone(timedelta(hours=5, minutes=30))).strftime("%Y-%m-%dT%H:%M:%S+05:30")
    check("+05:30 offset converted", clamp_message_timestamp(off2, now=now) == p, off2)
    naive = p.strftime("%Y-%m-%dT%H:%M:%S")
    check("naive value is read as UTC", clamp_message_timestamp(naive, now=now) == p)
    micro = (p + timedelta(microseconds=123456)).strftime("%Y-%m-%dT%H:%M:%S.%f+00:00")
    check("microseconds preserved", clamp_message_timestamp(micro, now=now) == p + timedelta(microseconds=123456))
    check("future with offset beyond skew clamped",
          clamp_message_timestamp((now + timedelta(hours=1)).astimezone(timezone(timedelta(hours=-4))).isoformat(), now=now) == now)
    check("wire_timestamp_whole_seconds drops fractions and uses Z",
          wire_timestamp_whole_seconds(p + timedelta(microseconds=999999)) == z)
    check("parse_client_timestamp returns None for junk", parse_client_timestamp("nope") is None)


# --------------------------------------------------------------------------- 4 save/ack/frames

async def send(manager, sender, recipients, group_id, text, timestamp, client_ref="__absent__", extra=None):
    payload = {"from_user": sender, "to_users": recipients, "text": text, "group_id": group_id, "timestamp": timestamp}
    if client_ref != "__absent__":
        payload["client_ref"] = client_ref
    if extra:
        payload.update(extra)
    await manager.send_msg(payload)
    return payload


async def test_ws():
    print("save_message / ack / frames")
    sender, ra, rb = make_user("pagws_s"), make_user("pagws_a"), make_user("pagws_b")
    gid = make_group([sender, ra, rb])
    pushed = []

    async def fake_push(token, title, body, data=None):
        pushed.append(token)
        return True

    orig_push = ws_module.send_push
    ws_module.send_push = fake_push
    manager = ConnectionManager()
    try:
        s_ws, a_ws, b_ws = FakeWS(), FakeWS(), FakeWS()
        manager.active_connections.update({sender: s_ws, ra: a_ws, rb: b_ws})
        now = datetime.now(timezone.utc)

        # ---- accepted past timestamp, with client_ref
        accepted = iso(now - timedelta(minutes=5))  # +00:00 with microseconds
        text = f"ack-{uuid.uuid4().hex[:8]}"
        await send(manager, sender, [sender, ra, rb], gid, text, accepted, client_ref="ref-1_A")
        d = DBManager()
        d.cur.execute("SELECT _id::text, timestamp FROM messages WHERE text = %s", (text,))
        rows = d.cur.fetchall()
        d.close()
        check("message stored exactly once", len(rows) == 1, str(rows))
        mid, stored_ts = rows[0]
        check("sender socket got exactly one frame: the ack", len(s_ws.sent) == 1, str(s_ws.sent))
        ack = s_ws.sent[0]
        check("ack has exactly {type, client_ref, id, group_id, timestamp}",
              set(ack) == {"type", "client_ref", "id", "group_id", "timestamp"}, str(ack))
        check("ack type is 'ack'", ack.get("type") == "ack")
        check("ack client_ref echoed", ack.get("client_ref") == "ref-1_A")
        check("ack id equals the stored row _id", ack.get("id") == mid, f"{ack.get('id')} vs {mid}")
        check("ack id is a lowercase string uuid", bool(UUID_RE.match(ack.get("id", ""))))
        check("ack group_id is the group", ack.get("group_id") == gid)
        check("ack timestamp equals the stored row timestamp (ISO Z, microseconds)",
              ack.get("timestamp") == paging.format_timestamp(stored_ts) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z", ack["timestamp"]),
              f"{ack.get('timestamp')} vs {paging.format_timestamp(stored_ts)}")
        check("ack has no from_user / text (cannot render as a bubble)", "from_user" not in ack and "text" not in ack)
        for name, w in (("A", a_ws), ("B", b_ws)):
            check(f"recipient {name} got exactly one frame and it is not an ack",
                  len(w.sent) == 1 and w.sent[0].get("type") != "ack" and "client_ref" not in w.sent[0], str(w.sent))
        fa = a_ws.sent[0]
        check("recipient frame carries id equal to the stored id", fa.get("id") == mid)
        check("recipient frame keeps the client's ORIGINAL timestamp string when accepted",
              fa.get("timestamp") == accepted, f"{fa.get('timestamp')} vs {accepted}")
        check("recipient frame legacy keys unchanged, id appended last",
              list(fa) == ["from_user", "text", "group_id", "timestamp", "attachment_kind",
                           "attachment_meta", "attachment_url", "id"], str(list(fa)))

        # ---- whole-second Z (what iOS sends), accepted, kept verbatim
        for w in (s_ws, a_ws, b_ws):
            w.sent.clear()
        ios_ts = (now - timedelta(minutes=3)).strftime("%Y-%m-%dT%H:%M:%SZ")
        t2 = f"ios-{uuid.uuid4().hex[:8]}"
        await send(manager, sender, [sender, ra, rb], gid, t2, ios_ts, client_ref="ios1")
        check("iOS whole-second Z timestamp relayed verbatim", a_ws.sent and a_ws.sent[0]["timestamp"] == ios_ts, str(a_ws.sent))
        check("iOS ack timestamp is the stored instant to the second",
              s_ws.sent and s_ws.sent[0]["timestamp"].startswith(ios_ts[:-1]), str(s_ws.sent))

        # ---- clamped (far future): recipients get whole-second Z of the stored instant
        for w in (s_ws, a_ws, b_ws):
            w.sent.clear()
        t3 = f"future-{uuid.uuid4().hex[:8]}"
        fut = iso(now + timedelta(days=30))
        await send(manager, sender, [sender, ra, rb], gid, t3, fut, client_ref="fut1")
        d = DBManager()
        d.cur.execute("SELECT timestamp FROM messages WHERE text = %s", (t3,))
        stored = d.cur.fetchone()[0]
        d.close()
        check("far-future timestamp stored as about now, not 30 days ahead",
              abs((stored - datetime.now(timezone.utc)).total_seconds()) < 60, str(stored))
        fr = a_ws.sent[0]["timestamp"]
        check("clamped recipient timestamp is whole-second Z of the stored instant",
              re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", fr) is not None
              and fr == stored.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), fr)
        check("clamped ack timestamp is the stored instant with microseconds",
              s_ws.sent[0]["timestamp"] == paging.format_timestamp(stored), s_ws.sent[0]["timestamp"])

        # ---- unparseable timestamp
        for w in (s_ws, a_ws, b_ws):
            w.sent.clear()
        t4 = f"junk-{uuid.uuid4().hex[:8]}"
        await send(manager, sender, [sender, ra], gid, t4, "garbage", client_ref="junk1")
        check("unparseable timestamp is stored (message not dropped) and relayed as whole-second Z",
              a_ws.sent and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", a_ws.sent[0]["timestamp"]) is not None, str(a_ws.sent))

        # ---- client_ref validation matrix: saved always, ack only when valid
        valid = ["a", "A1_-", "x" * 64, "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-"[:64]]
        invalid = ["", "x" * 65, "has space", "dot.dot", "semi;colon", "naïve", "<b>", "a/b", "line\nbreak", 5, None, ["a"], {"a": 1}, True]
        for ref in valid:
            for w in (s_ws, a_ws):
                w.sent.clear()
            tx = f"ref-{uuid.uuid4().hex[:8]}"
            await send(manager, sender, [sender, ra], gid, tx, iso(now - timedelta(minutes=1)), client_ref=ref)
            check(f"valid client_ref {ref[:12]!r}.. ({len(ref)} chars) is acked",
                  len(s_ws.sent) == 1 and s_ws.sent[0].get("client_ref") == ref, str(s_ws.sent))
        for ref in invalid:
            for w in (s_ws, a_ws):
                w.sent.clear()
            tx = f"badref-{uuid.uuid4().hex[:8]}"
            await send(manager, sender, [sender, ra], gid, tx, iso(now - timedelta(minutes=1)), client_ref=ref)
            d = DBManager()
            d.cur.execute("SELECT count(*) FROM messages WHERE text = %s", (tx,))
            n = d.cur.fetchone()[0]
            d.close()
            check(f"invalid client_ref {str(ref)[:12]!r} ignored: still saved, no ack, recipient still delivered",
                  n == 1 and not s_ws.sent and len(a_ws.sent) == 1, f"n={n} s={s_ws.sent} a={len(a_ws.sent)}")
        for w in (s_ws, a_ws):
            w.sent.clear()
        await send(manager, sender, [sender, ra], gid, f"noref-{uuid.uuid4().hex[:6]}", iso(now - timedelta(minutes=1)))
        check("absent client_ref: no ack, recipient delivered with id",
              not s_ws.sent and len(a_ws.sent) == 1 and "id" in a_ws.sent[0], str(s_ws.sent))
        check("valid_client_ref helper agrees with the matrix",
              all(valid_client_ref(v) == v for v in valid) and all(valid_client_ref(v) is None for v in invalid))

        # ---- save_message return shape
        m = Message_for(sender, [ra], gid, f"ret-{uuid.uuid4().hex[:6]}", iso(now - timedelta(minutes=2)))
        res = manager.save_message(m)
        check("save_message returns a (id, stored_ts) tuple", isinstance(res, tuple) and len(res) == 2, repr(res))
        check("save_message id is a string uuid", bool(UUID_RE.match(res[0])), res[0])
        check("save_message timestamp is ISO Z microseconds",
              re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z", res[1]) is not None, res[1])
        row = db_row(res[0])
        check("save_message timestamp equals the stored row", paging.format_timestamp(row[1]) == res[1])
        check("seq is assigned by the server on insert", row[2] is not None and row[2] > 0, str(row))

        # ---- save_message stub returning None: delivery continues, no id, no ack
        for w in (s_ws, a_ws, b_ws):
            w.sent.clear()
        orig_save = manager.save_message
        manager.save_message = lambda msg: None
        try:
            orig_ts = iso(now - timedelta(minutes=4))
            await send(manager, sender, [sender, ra, rb], gid, "stub-none", orig_ts, client_ref="stub1")
        finally:
            manager.save_message = orig_save
        check("None-returning save_message: recipients still get the frame",
              len(a_ws.sent) == 1 and len(b_ws.sent) == 1, f"{a_ws.sent} {b_ws.sent}")
        check("None-returning save_message: frame has no 'id' key (omitted, never null)",
              "id" not in a_ws.sent[0], str(a_ws.sent[0]))
        check("None-returning save_message: original timestamp relayed", a_ws.sent[0]["timestamp"] == orig_ts)
        check("None-returning save_message: no ack even with a valid client_ref", not s_ws.sent, str(s_ws.sent))

        # ---- SaveFailedError path still sends the error frame to the sender, no ack, no recipient frames
        for w in (s_ws, a_ws, b_ws):
            w.sent.clear()

        def failing(msg):
            raise SaveFailedError()

        manager.save_message = failing
        try:
            await send(manager, sender, [sender, ra, rb], gid, "stub-fail", iso(now), client_ref="fail1")
        finally:
            manager.save_message = orig_save
        check("SaveFailedError: sender receives exactly one frame, the message_not_saved error",
              len(s_ws.sent) == 1 and s_ws.sent[0].get("type") == "error" and s_ws.sent[0].get("reason") == "message_not_saved",
              str(s_ws.sent))
        check("SaveFailedError: no ack and no recipient frames",
              all(x.get("type") != "ack" for x in s_ws.sent) and not a_ws.sent and not b_ws.sent)

        # ---- ack send failure does not stop delivery
        for w in (a_ws, b_ws):
            w.sent.clear()
        manager.active_connections[sender] = FakeWS(fail=True)
        try:
            await send(manager, sender, [sender, ra], gid, f"ackfail-{uuid.uuid4().hex[:6]}", iso(now - timedelta(minutes=1)), client_ref="af1")
            check("ack socket failure is swallowed and recipients still delivered", len(a_ws.sent) == 1, str(a_ws.sent))
        except Exception as e:  # noqa: BLE001
            check("ack socket failure is swallowed and recipients still delivered", False, repr(e))
        manager.active_connections[sender] = s_ws

        # ---- offline sender: no crash
        del manager.active_connections[sender]
        try:
            await send(manager, sender, [ra], gid, f"offline-{uuid.uuid4().hex[:6]}", iso(now - timedelta(minutes=1)), client_ref="off1")
            check("offline sender with client_ref does not crash", True)
        except Exception as e:  # noqa: BLE001
            check("offline sender with client_ref does not crash", False, repr(e))
        manager.active_connections[sender] = s_ws

        # ---- spoofing / self-echo unchanged: sender never receives a recipient frame
        s_ws.sent.clear()
        await send(manager, sender, [sender, ra, rb], gid, f"echo-{uuid.uuid4().hex[:6]}", iso(now - timedelta(minutes=1)))
        check("self-echo suppression unchanged (no client_ref -> sender gets nothing)", not s_ws.sent, str(s_ws.sent))
    finally:
        manager.close()
        ws_module.send_push = orig_push
        cleanup([sender, ra, rb], [gid])


def Message_for(sender, to_users, gid, text, ts):
    from schemas.message import Message
    return Message(from_user=sender, to_users=to_users, text=text, group_id=gid, timestamp=ts)


# --------------------------------------------------------------------------- 2 ordering / cursor

KEYSET_SQL = (
    "SELECT _id::text, timestamp, seq, text FROM messages "
    "WHERE group_id = %s AND deleted_at IS NULL "
    "{pred} "
    "ORDER BY timestamp DESC, COALESCE(seq, 0) DESC, _id DESC LIMIT %s"
)


def page_through(group_id, size):
    """Walk the whole group via the SF codec and the shared keyset predicate."""
    d = DBManager()
    out, pages, cursor_params = [], 0, None
    try:
        while True:
            cur = paging.decode_cursor(cursor_params, "uuid", True) if cursor_params else None
            if cur is None:
                d.cur.execute(KEYSET_SQL.format(pred=""), (group_id, size + 1))
            else:
                pred = f"AND (timestamp, COALESCE(seq, 0), _id) < ({paging.TS_SQL}, {paging.SEQ_SQL}, {cur.id_sql})"
                d.cur.execute(KEYSET_SQL.format(pred=pred), (group_id, *cur.params(), size + 1))
            rows = d.cur.fetchall()
            has_more = len(rows) > size
            rows = rows[:size]
            out.extend(rows)
            pages += 1
            if not has_more:
                break
            last = rows[-1]
            enc = paging.encode_cursor(last[1], last[2], last[0])
            cursor_params = {
                "cursor_timestamp": enc["next_cursor_timestamp"],
                "cursor_id": enc["next_cursor_id"],
            }
            if enc["next_cursor_seq"] is not None:
                cursor_params["cursor_seq"] = str(enc["next_cursor_seq"])
            assert pages < 200
        return out, pages
    finally:
        d.close()


def test_ordering_and_cursor():
    print("seq tiebreak ordering and cursor round-trip")
    u1, u2 = make_user("pagord_a"), make_user("pagord_b")
    gid = make_group([u1, u2])
    try:
        base = (datetime.now(timezone.utc) - timedelta(hours=2)).replace(microsecond=0)
        # 7 rows, identical microsecond timestamp, inserted in order (seq ascending).
        same = [insert_msg(u1 if i % 2 else u2, gid, f"same-{i}", base) for i in range(7)]
        # iOS whole-second pair, one second later (identical second).
        ios = [insert_msg(u1, gid, f"ios-{i}", base + timedelta(seconds=1)) for i in range(2)]
        # A later distinct row and an earlier one.
        late = insert_msg(u2, gid, "late", base + timedelta(seconds=5))
        early = insert_msg(u2, gid, "early", base - timedelta(seconds=5))
        # Legacy rows: NULL seq (pre-migration), same timestamp as the 'same' group.
        legacy = [insert_msg(u1, gid, f"legacy-{i}", base, seq=None) for i in range(3)]

        expected_new_to_old = [late] + ios[::-1] + same[::-1]
        for size in (1, 2, 3, 4, 5, 100):
            rows, pages = page_through(gid, size)
            ids = [r[0] for r in rows]
            check(f"size {size}: no duplicates across {pages} pages", len(ids) == len(set(ids)), str(len(ids)))
            check(f"size {size}: every row returned exactly once (no gap)", set(ids) == set(same + ios + [late, early] + legacy))
            check(f"size {size}: same-timestamp rows are in descending seq order across page boundaries",
                  [i for i in ids if i in same] == same[::-1], str([r[3] for r in rows]))
            check(f"size {size}: iOS same-second pair in seq order", [i for i in ids if i in ios] == ios[::-1])
            check(f"size {size}: late first, early last", ids[0] == late and ids[-1] in (early,), f"{rows[0][3]} {rows[-1][3]}")
            check(f"size {size}: NULL-seq legacy rows sort below seq'd rows with the same timestamp (read as 0)",
                  ids.index(same[0]) < min(ids.index(x) for x in legacy), str([r[3] for r in rows]))
            leg = [i for i in ids if i in legacy]
            check(f"size {size}: NULL-seq rows among themselves tie-break by _id DESC", leg == sorted(legacy, reverse=True), str(leg))
        rows, _ = page_through(gid, 100)
        check("ordering identical for any page size", [r[0] for r in rows] == [r[0] for r in page_through(gid, 3)[0]])
        check("seq is strictly increasing in insert order for the same-timestamp rows",
              [db_row(i)[2] for i in same] == sorted(db_row(i)[2] for i in same)
              and len({db_row(i)[2] for i in same}) == len(same))

        # Cursor round trip.
        r = db_row(same[3])
        enc = paging.encode_cursor(r[1], r[2], r[0])
        params = {"cursor_timestamp": enc["next_cursor_timestamp"], "cursor_id": enc["next_cursor_id"], "cursor_seq": str(enc["next_cursor_seq"])}
        dec = paging.decode_cursor(params, "uuid", True)
        check("cursor round-trips (timestamp microseconds, seq, id)",
              dec.timestamp == paging.format_timestamp(r[1]) and dec.seq == r[2] and dec.id == r[0], str(dec))
        check("cursor id is lowercase uuid", dec.id == dec.id.lower())
        legacy_row = db_row(legacy[0])
        enc2 = paging.encode_cursor(legacy_row[1], legacy_row[2], legacy_row[0])
        check("a NULL-seq row encodes seq null and decodes to 0",
              enc2["next_cursor_seq"] is None and paging.decode_cursor(
                  {"cursor_timestamp": enc2["next_cursor_timestamp"], "cursor_id": enc2["next_cursor_id"]}, "uuid", True).seq == 0)
        for bad in ({"cursor_timestamp": "2026-10-01T00:00:00", "cursor_id": r[0]},
                    {"cursor_timestamp": enc["next_cursor_timestamp"], "cursor_id": "not-a-uuid"},
                    {"cursor_timestamp": enc["next_cursor_timestamp"]},
                    {"cursor_timestamp": enc["next_cursor_timestamp"], "cursor_id": r[0], "cursor_seq": "-1"},
                    {"cursor_timestamp": enc["next_cursor_timestamp"], "cursor_id": r[0], "cursor_seq": "1; DROP TABLE messages"}):
            try:
                paging.decode_cursor(bad, "uuid", True)
                check(f"bad cursor rejected {list(bad)}", False, "no error")
            except Exception as e:  # noqa: BLE001
                check(f"bad cursor rejected {list(bad)}", getattr(e, "status_code", None) == 422, repr(e))

        # Deleted rows never appear and a page boundary skips them cleanly.
        gone = insert_msg(u1, gid, "gone", base + timedelta(seconds=3), deleted=True)
        rows, _ = page_through(gid, 2)
        check("soft-deleted row is excluded from the keyset walk", gone not in [x[0] for x in rows])

        # Plan uses the new index when seq scans are discouraged.
        d = DBManager()
        try:
            d.cur.execute("SET LOCAL enable_seqscan = off")
            d.cur.execute("EXPLAIN " + KEYSET_SQL.format(pred="") % ("'" + gid + "'", 10))
            plan = "\n".join(r[0] for r in d.cur.fetchall())
            check("page query can use idx_messages_group_page", "idx_messages_group_page" in plan, plan)
        finally:
            d.conn.rollback()
            d.close()
    finally:
        cleanup([u1, u2], [gid])


# --------------------------------------------------------------------------- 7 author_set

def test_author_set():
    print("author_set")
    me, member, blocked_by_me, blocks_me, ex_member, outsider = (make_user(f"pagas{i}") for i in range(6))
    dead = str(uuid.uuid4())  # no such user
    gid = make_group([me, member, blocked_by_me, blocks_me, dead, "not-a-uuid", "", member.upper()])
    d = DBManager()
    try:
        d.cur.execute("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s, %s)", (me, blocked_by_me))
        d.cur.execute("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s, %s)", (blocks_me, me))
        d.conn.commit()
        authors = author_set(d.cur, gid, me)
        check("author_set includes self and a plain member", me in authors and member in authors, str(authors))
        check("blocked-by-me member excluded", blocked_by_me not in authors)
        check("member who blocked me excluded (both directions)", blocks_me not in authors)
        check("ex-member / non-member excluded", ex_member not in authors and outsider not in authors)
        check("dead account id ignored", dead not in authors)
        check("junk strings ignored", "not-a-uuid" not in authors and "" not in authors)
        check("ids are canonical lowercase and de-duplicated",
              all(a == a.lower() for a in authors) and len(authors) == len(set(authors)), str(authors))
        # Never makes a page query raise.
        try:
            d.cur.execute("SELECT count(*) FROM messages WHERE group_id = %s AND from_user = ANY(%s::uuid[])", (gid, authors))
            check("= ANY(author_set::uuid[]) does not raise with junk in groups.users", True)
        except Exception as e:  # noqa: BLE001
            d.conn.rollback()
            check("= ANY(author_set::uuid[]) does not raise with junk in groups.users", False, repr(e))
        # Caller is always in their own set even if they are not a listed member
        # (the route's is_member check gates access; author_set only resolves authors).
        check("caller is included even when absent from groups.users",
              ex_member in author_set(d.cur, gid, ex_member))
        # Unknown group: only the caller.
        check("unknown group id yields only the caller", author_set(d.cur, str(uuid.uuid4()), me) == [me])
        check("malformed group id yields only the caller", author_set(d.cur, "zzz", me) == [me])
        check("malformed caller id yields empty", author_set(d.cur, gid, "zzz") == [])
        # Ex-member really excluded after leaving.
        d.cur.execute("UPDATE groups SET users = array_remove(users, %s) WHERE _id = %s", (member, gid))
        d.cur.execute("UPDATE groups SET users = array_remove(users, %s) WHERE _id = %s", (member.upper(), gid))
        d.conn.commit()
        check("a member removed from groups.users drops out of the set", member not in author_set(d.cur, gid, me))
        # Unblocking restores.
        d.cur.execute("DELETE FROM blocked_users WHERE blocker_id = %s", (me,))
        d.conn.commit()
        check("unblocking restores the author", blocked_by_me in author_set(d.cur, gid, me))
    finally:
        d.close()
        cleanup([me, member, blocked_by_me, blocks_me, ex_member, outsider], [gid])

    src = inspect.getsource(author_set)
    check("author_set calls groups.live_member_ids", "live_member_ids(" in src)
    check("author_set has no unnest( of its own", "unnest(" not in src.lower())
    check("author_set has no ::text join of its own", "::text =" not in src.replace(" ", "") and "::text=" not in src.replace(" ", "") and "= x::text" not in src)
    check("author_set has no LIVE_MEMBER_JOIN copy / users join of its own", "JOIN users" not in src and "LIVE_MEMBER_JOIN +" not in src)


# --------------------------------------------------------------------------- 5/6 legacy readers

LEGACY_GROUP_KEYS = ["from_user", "group_id", "text", "timestamp", "attachment_kind", "attachment_meta"]
LEGACY_DM_KEYS = ["from_user", "text", "timestamp", "attachment_kind", "attachment_meta", "attachment_url"]


def test_legacy_readers():
    print("legacy response shape and soft-delete filters")
    host, other, third, blocker = (make_user(f"pagleg{i}") for i in range(4))
    gid = make_group([host, other, blocker])
    client = TestClient(main_module.app)
    ck_host = session_cookie(host)
    saved_flags = {}
    d = DBManager()
    try:
        d.cur.execute("SELECT name, state, canary_user_ids::text[] FROM feature_flags WHERE name IN ('chat_pagination','chat_pagination_dm')")
        saved_flags = {r[0]: (r[1], r[2] or []) for r in d.cur.fetchall()}
    finally:
        d.close()
    try:
        base = datetime.now(timezone.utc) - timedelta(hours=1)
        g_host_ok = insert_msg(host, gid, "g-host-ok", base)
        g_other_ok = insert_msg(other, gid, "g-other-ok", base + timedelta(seconds=1))
        g_host_del = insert_msg(host, gid, "g-host-deleted", base + timedelta(seconds=2), deleted=True)
        g_other_del = insert_msg(other, gid, "g-other-deleted", base + timedelta(seconds=3), deleted=True)
        g_blocked = insert_msg(blocker, gid, "g-blocked-author", base + timedelta(seconds=4))
        d = DBManager()
        d.cur.execute("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s, %s)", (host, blocker))
        d.conn.commit()
        d.close()
        dm_h_ok = insert_msg(host, None, "dm-host-ok", base, to_users=[other])
        dm_o_ok = insert_msg(other, None, "dm-other-ok", base + timedelta(seconds=1), to_users=[host])
        dm_h_del = insert_msg(host, None, "dm-host-deleted", base + timedelta(seconds=2), deleted=True, to_users=[other])
        dm_o_del = insert_msg(other, None, "dm-other-deleted", base + timedelta(seconds=3), deleted=True, to_users=[host])
        # an attachment row to snapshot the attachment_url shape
        d = DBManager()
        att = str(uuid.uuid4())
        d.cur.execute(
            "INSERT INTO messages (_id, from_user, group_id, text, timestamp, attachment_kind, attachment_key, attachment_meta) "
            "VALUES (%s,%s,%s,%s,%s,'image','k/obj.png','{\"w\":1}')", (att, host, gid, "g-att", base + timedelta(seconds=6)))
        d.conn.commit()
        d.close()

        def group_json():
            r = client.get(f"/groups/{host}/{gid}", headers=ck_host)
            return r.status_code, r.json()

        for state in ("off", "on"):
            for name in ("chat_pagination", "chat_pagination_dm"):
                flags.set_flag(name, state, actor=host)
            flags.invalidate()
            tag = f"flags {state}"
            code, body = group_json()
            check(f"{tag}: GET group still 200", code == 200, str(code))
            check(f"{tag}: legacy top-level keys unchanged, no 'page' block yet",
                  {"group", "members", "host_msgs", "other_msgs"} <= set(body) and "page" not in body, str(sorted(body)))
            hm, om = body["host_msgs"], body["other_msgs"]
            hid = {m["id"]: m for m in hm}
            check(f"{tag}: host_msgs complete minus soft-deleted", {m["text"] for m in hm} == {"g-host-ok", "g-att"}, str([m["text"] for m in hm]))
            check(f"{tag}: other_msgs excludes soft-deleted and blocked authors", {m["text"] for m in om} == {"g-other-ok"}, str([m["text"] for m in om]))
            plain = next(m for m in hm if m["text"] == "g-host-ok")
            check(f"{tag}: legacy group row keys identical except trailing 'id'",
                  list(plain) == LEGACY_GROUP_KEYS + ["id"], str(list(plain)))
            check(f"{tag}: group row value types (build-78 shape)",
                  isinstance(plain["from_user"], str) and plain["from_user"].startswith("pagleg")
                  and isinstance(plain["text"], str) and isinstance(plain["timestamp"], str)
                  and plain["attachment_kind"] is None and plain["attachment_meta"] in ({}, None) and plain["group_id"] == gid
                  and UUID_RE.match(plain["id"]) is not None and plain["id"] == g_host_ok, str(plain))
            attm = next(m for m in hm if m["text"] == "g-att")
            check(f"{tag}: attachment row has attachment_url, never attachment_key, and no seq/deleted_* leak",
                  "attachment_url" in attm and "attachment_key" not in attm
                  and not ({"seq", "deleted_at", "deleted_by"} & set(attm)), str(list(attm)))
            check(f"{tag}: username (not uuid) in from_user", plain["from_user"] != host)

            r = client.get(f"/message/messages/{host}/", params={"guest_user": other}, headers=ck_host)
            check(f"{tag}: GET /message/messages 200", r.status_code == 200, str(r.status_code))
            payload = r.json()["payload"]
            check(f"{tag}: DM payload keys unchanged", set(payload) == {"friend", "host_msgs", "other_msgs"}, str(sorted(payload)))
            check(f"{tag}: DM host/other contain only non-deleted rows",
                  [m["text"] for m in payload["host_msgs"]] == ["dm-host-ok"]
                  and [m["text"] for m in payload["other_msgs"]] == ["dm-other-ok"], str(payload))
            check(f"{tag}: DM row keys identical except trailing 'id'",
                  list(payload["host_msgs"][0]) == LEGACY_DM_KEYS + ["id"], str(list(payload["host_msgs"][0])))
            row = payload["host_msgs"][0]
            check(f"{tag}: DM row types and id", isinstance(row["timestamp"], str) and isinstance(row["attachment_meta"], dict)
                  and row["attachment_url"] is None and row["id"] == dm_h_ok, str(row))

            r = client.get(f"/friends/{host}/{other}", headers=ck_host)
            if r.status_code == 200:
                fb = r.json()
                inner = fb.get("payload", fb)
                texts = [m["text"] for m in inner.get("host_msgs", [])] + [m["text"] for m in inner.get("other_msgs", [])]
                check(f"{tag}: GET /friends/.. history excludes soft-deleted rows", not any("deleted" in t for t in texts), str(texts))

        # manager level
        gm = GroupsManager(host, gid)
        try:
            res = gm.fetch_group()
        finally:
            gm.close()
        all_texts = [m["text"] for m in res["host_msgs"] + res["other_msgs"]]
        check("fetch_group (manager) excludes soft-deleted host and other rows", not any("deleted" in t for t in all_texts), str(all_texts))
        fm = FriendsManager(host)
        try:
            res = fm.read_friend(other)
        finally:
            fm.close()
        texts = [m["text"] for m in res["host_msgs"] + res["other_msgs"]]
        check("read_friend (manager) excludes soft-deleted rows in both directions", sorted(texts) == ["dm-host-ok", "dm-other-ok"], str(texts))

        # Fan-in: undeleting restores (proves the filter is deleted_at, not data loss)
        d = DBManager()
        d.cur.execute("UPDATE messages SET deleted_at = NULL, deleted_by = NULL WHERE _id = %s", (dm_h_del,))
        d.conn.commit()
        d.close()
        fm = FriendsManager(host)
        try:
            texts = [m["text"] for m in fm.read_friend(other)["host_msgs"]]
        finally:
            fm.close()
        check("clearing deleted_at makes the DM row readable again", "dm-host-deleted" in texts, str(texts))
        d = DBManager()
        d.cur.execute("UPDATE messages SET deleted_at = NOW(), deleted_by = %s WHERE _id = %s", (host, dm_h_del))
        d.conn.commit()
        d.close()

        # Evidence retention: report resolver still reads deleted content.
        d = DBManager()
        try:
            res = reports._resolve_message(d.cur, g_other_del, other)
            check("reports._resolve_message still reads a soft-deleted message (evidence retention)",
                  res is not None and res[1] == "g-other-deleted" and res[0] == other, str(res))
            res = reports.CONTENT_RESOLVERS["message"](d.cur, dm_o_del, other)
            check("registered 'message' resolver reads a soft-deleted DM", res[1] == "dm-other-deleted", str(res))
            src = inspect.getsource(reports._resolve_message)
            check("_resolve_message source has no deleted_at filter", "deleted_at" not in src)
        finally:
            d.close()
    finally:
        for name in ("chat_pagination", "chat_pagination_dm"):
            st, canary = saved_flags.get(name, ("off", []))
            try:
                flags.set_flag(name, st, canary, actor=host)
            except Exception as e:  # noqa: BLE001
                print("  WARN could not restore flag", name, repr(e))
        flags.invalidate()
        cleanup([host, other, third, blocker], [gid])


# --------------------------------------------------------------------------- 8 config

def test_config():
    print("config validation")
    good = json.loads(Path(chat_config.CONFIG_PATH).read_text())
    cfg = chat_config.get_pagination_config()
    check("shipped chat.json loads: 30/30/100, skew 300, rate 120/minute",
          (cfg.initial_page_size, cfg.page_size, cfg.max_page_size, cfg.future_timestamp_skew_seconds, cfg.rate_limits["messages_page"])
          == (30, 30, 100, 300, "120/minute"), str(cfg))
    check("startup_checks wires check_chat_pagination_config",
          startup_checks.check_chat_pagination_config in startup_checks.CHECKS)

    orig_path = chat_config.CONFIG_PATH
    chat_config.reset_for_tests()

    def attempt(label, mutate=None, raw_text=None, missing=False):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "chat.json"
            if not missing:
                if raw_text is not None:
                    p.write_text(raw_text)
                else:
                    data = json.loads(json.dumps(good))
                    mutate(data)
                    p.write_text(json.dumps(data))
            chat_config.CONFIG_PATH = p
            try:
                chat_config.validate_pagination_config()
                check(f"config rejects {label}", False, "accepted")
            except Exception as e:  # noqa: BLE001
                check(f"config rejects {label}", type(e).__name__ == "ConfigSectionError", repr(e))
            finally:
                chat_config.CONFIG_PATH = orig_path
                chat_config.reset_for_tests()

    try:
        attempt("missing file", missing=True)
        attempt("invalid JSON", raw_text="{nope")
        attempt("top level not an object", raw_text="[]")
        attempt("missing pagination section", lambda d: d.pop("pagination"))
        for key in ("initial_page_size", "page_size", "max_page_size", "future_timestamp_skew_seconds", "rate_limits"):
            attempt(f"missing key {key}", lambda d, k=key: d["pagination"].pop(k))
        attempt("unknown key", lambda d: d["pagination"].update(bogus=1))
        attempt("string page_size", lambda d: d["pagination"].update(page_size="30"))
        attempt("bool page_size", lambda d: d["pagination"].update(page_size=True))
        attempt("zero page_size", lambda d: d["pagination"].update(page_size=0))
        attempt("negative initial_page_size", lambda d: d["pagination"].update(initial_page_size=-1))
        attempt("page_size above max", lambda d: d["pagination"].update(page_size=101))
        attempt("initial above max", lambda d: d["pagination"].update(initial_page_size=500))
        attempt("negative skew", lambda d: d["pagination"].update(future_timestamp_skew_seconds=-1))
        attempt("absurd skew", lambda d: d["pagination"].update(future_timestamp_skew_seconds=10**7))
        attempt("bad rate limit string", lambda d: d["pagination"]["rate_limits"].update(messages_page="lots"))
        attempt("non-string rate limit", lambda d: d["pagination"]["rate_limits"].update(messages_page=5))
        attempt("unknown rate_limits key", lambda d: d["pagination"]["rate_limits"].update(other="1/minute"))
        attempt("missing rate_limits key", lambda d: d["pagination"].update(rate_limits={}))
        # a good alternative still loads (no hidden constants)
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "chat.json"
            data = json.loads(json.dumps(good))
            data["pagination"].update(initial_page_size=10, page_size=5, max_page_size=20, future_timestamp_skew_seconds=60)
            p.write_text(json.dumps(data))
            chat_config.CONFIG_PATH = p
            chat_config.validate_pagination_config()
            c2 = chat_config.get_pagination_config()
            check("values come from the file (no code constants)", (c2.initial_page_size, c2.page_size, c2.max_page_size, c2.future_timestamp_skew_seconds) == (10, 5, 20, 60))
            check("clamp honours the configured skew",
                  clamp_message_timestamp((datetime.now(timezone.utc) + timedelta(seconds=120)).isoformat()) < datetime.now(timezone.utc) + timedelta(seconds=30))
    finally:
        chat_config.CONFIG_PATH = orig_path
        chat_config.reset_for_tests()


def main():
    logging.getLogger().setLevel(logging.WARNING)
    assert_scratch()
    test_config()
    test_ddl()
    test_clamp()
    test_ordering_and_cursor()
    test_author_set()
    asyncio.run(test_ws())
    test_legacy_readers()

    print("\n" + "=" * 60)
    print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} failed")
    for f in FAILED:
        print("  FAILED:", f)
    print("STATUS:", "ALL PASS" if not FAILED else "FAILURES")
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
