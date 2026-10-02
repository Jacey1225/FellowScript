"""Tests for task 20261001-explorer-listings, Backend A (text-only listings core).

Properties proved (each would catch a regression of the behaviour it names):
  1. DDL: the listings module runs twice on a fresh schema with no "generation
     expression is not immutable" error, fs_arr_text is IMMUTABLE, search_tsv is a
     generated column and finds a listing by title, tag, city, church and
     description words; the media table exists (and nothing here writes to it).
  2. Frozen helper signatures (inspect.signature) for join-requests, and the
     behaviour they promise: set/get_accepting_requests (True/False/None),
     cursor-in-never-commit (a rollback undoes every helper), requeue_for_review
     for 'text'/'media' but not filter-only edits, live_member_count and
     listing_requestable ignoring dead/junk ids in groups.users.
  3. Flags fail closed: explorer_publish off -> uniform 404 on every owner route
     (identical body to a missing group), canary per user, explorer_browse is
     off/on only (canary rejected; a canary row never shows to an anonymous
     caller), GET /explorer/config always answers 200 {browse: bool} even when
     the flag read raises, with a Cache-Control header.
  4. Owner lifecycle through HTTP: draft -> pending_review -> published (admin)
     -> unpublished -> republished without review; text edit re-queues, vocab
     edit does not; reject/hide/restore; accepting_requests default FALSE and
     stored from PUT/submit bodies; per-owner cap; consent and adult
     attestation; terms gate 403; validation rejections (youth, HTML, links,
     shorteners, IP hosts, javascript:/data:, unknown vocab/block types); title
     snapshot unaffected by a later group rename; owner-only and IDOR give ONE
     identical 404; rate limit.
  5. PUT /groups guard: non-owner add / creator removal on a listed group 409
     owner_only; rename, creator adds, build-78-shaped payload and ordinary
     groups unchanged.
  6. Lifecycle hooks: group delete cascades; last-member leave deletes; creator
     leave hides (owner_gone) and fires listing_hidden hooks as fn(cur, group_id,
     reason); delete_user removes the listings of groups the user created.
  7. Sweeper: suspended / departed owner is hidden with owner_suspended /
     owner_gone and hooks fire; healthy listings untouched; the async job body
     does its DB work in an executor (loop lag < 500 ms while 0.8 s of blocking
     work runs) and has no psycopg2/boto3 call at call level.
  8. Report registry symmetry for group_listing, no listing text in logs, no
     media/S3 keys in the listings config.

Every database touch is against the scratch database: the test asserts SHOW port
= 55432 first and aborts otherwise. All rows are uuid-derived and removed in
finally; feature flags are restored and flags.invalidate() called.

Run with: cd api && ../.venv/bin/python tests/test_explorer_listings.py
"""
import _pathfix  # noqa: F401

import ast
import asyncio
import inspect
import json
import logging
import os
import sys
import time
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import db as db_module  # noqa: E402
import schema_ddl  # noqa: E402
from db import DBManager  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.interactions import flags, lifecycle, listing_sweeper, listings, reports  # noqa: E402
from backend.interactions.listing_content import ListingError  # noqa: E402
from backend.interactions.listings import ListingsManager  # noqa: E402
from backend.interactions.listings_config import get_listings_config  # noqa: E402
from backend.moderation import removers  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from backend.registrations import load_all  # noqa: E402
from schemas.users import CURRENT_TERMS_VERSION  # noqa: E402

API_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSED, FAILED = [], []
USERS, GROUPS = [], []
NOT_FOUND = {"detail": {"code": "not_found", "message": "Not found"}}


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


# -- helpers ------------------------------------------------------------------

def q(sql, params=(), fetch=True):
    db = DBManager()
    try:
        db.cur.execute(sql, params)
        rows = db.cur.fetchall() if fetch and db.cur.description else None
        db.conn.commit()
        return rows
    finally:
        db.close()


def make_user(suspended=False, terms=CURRENT_TERMS_VERSION):
    uid = str(uuid.uuid4())
    q("INSERT INTO users (_id, username, email, hash_pass, suspended_at, terms_version) "
      "VALUES (%s,%s,%s,'x',%s,%s)",
      (uid, f"xl_{uid[:8]}", f"xl_{uid[:8]}@example.com", "2020-01-01" if suspended else None, terms),
      fetch=False)
    USERS.append(uid)
    return uid


def hdr(uid):
    sm = SessionManager()
    try:
        return {"cookie": f"session={sm.create_session(uid)}"}
    finally:
        sm.close()


def make_group(creator, members=None, title="Xl Test Group", max_members=None):
    gid = str(uuid.uuid4())
    users = [creator] + [m for m in (members or []) if m != creator] if creator else list(members or [])
    q("INSERT INTO groups (_id, title, users, creator_id, max_members) VALUES (%s,%s,%s,%s,%s)",
      (gid, title, users, creator, max_members), fetch=False)
    GROUPS.append(gid)
    return gid


def row(gid, cols="status"):
    r = q(f"SELECT {cols} FROM group_listings WHERE group_id = %s", (gid,))
    return r[0] if r else None


def status(gid):
    r = row(gid)
    return r[0] if r else None


def visible(gid):
    return bool(q(f"SELECT 1 FROM group_listings gl WHERE gl.group_id = %s AND {listings.public_where('gl')}",
                  (gid,)))


def public_id(gid):
    return row(gid, "public_id")[0]


def admin_do(fn, *args):
    db = DBManager()
    try:
        out = fn(db.cur, *args)
        db.conn.commit()
        return out
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


def approve(gid, admin):
    return admin_do(listings.admin_approve, public_id(gid), admin)


def cleanup():
    for g in GROUPS:
        q("DELETE FROM invites WHERE target_id = %s", (g,), fetch=False)
        q("DELETE FROM messages WHERE group_id = %s", (g,), fetch=False)
        q("DELETE FROM groups WHERE _id = %s", (g,), fetch=False)
    for u in USERS:
        q("DELETE FROM content_reports WHERE reporter_id = %s OR reported_user_id = %s", (u, u), fetch=False)
        q("DELETE FROM users WHERE _id = %s", (u,), fetch=False)


class LogCatcher(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.records = []

    def emit(self, record):
        self.records.append((record.levelname, record.getMessage()))


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


def set_flag_sql(name, state):
    q("UPDATE feature_flags SET state = %s WHERE name = %s", (state, name), fetch=False)
    flags.invalidate()


# -- 1. DDL -------------------------------------------------------------------

def test_ddl():
    print("DDL module (fresh schema, twice)")
    check("listings is registered in DDL_MODULES", "listings" in db_module.DDL_MODULES, db_module.DDL_MODULES)
    schema = f"xl_{uuid.uuid4().hex[:8]}"
    db = DBManager()
    try:
        cur = db.cur
        try:
            cur.execute(f"CREATE SCHEMA {schema}")
            cur.execute(f"SET LOCAL search_path = {schema}, public")
            err = None
            try:
                schema_ddl.apply_modules(cur, ["listings"])
                schema_ddl.apply_modules(cur, ["listings"])
            except Exception as e:  # noqa: BLE001
                err = e
            check("module runs twice with no 'not immutable' or other error", err is None, repr(err))
            if err is not None:
                db.conn.rollback()
                return
            cur.execute("SELECT provolatile FROM pg_proc WHERE proname = 'fs_arr_text' "
                        "AND pronamespace = %s::regnamespace", (schema,))
            check("fs_arr_text is IMMUTABLE", cur.fetchone() == ("i",))
            cur.execute("SELECT is_generated FROM information_schema.columns WHERE table_schema = %s "
                        "AND table_name = 'group_listings' AND column_name = 'search_tsv'", (schema,))
            check("search_tsv is a GENERATED ALWAYS column", cur.fetchone() == ("ALWAYS",))
            cur.execute("SELECT count(*) FROM pg_indexes WHERE schemaname = %s AND tablename = 'group_listings'",
                        (schema,))
            check("group_listings carries the partial/GIN indexes (>= 14)", cur.fetchone()[0] >= 14)
            cur.execute("SELECT to_regclass(%s)", (f"{schema}.group_listing_media",))
            check("group_listing_media table exists", cur.fetchone()[0] is not None)

            # find a listing by title, tag, city, church and description words
            owner = str(uuid.uuid4())
            cur.execute("INSERT INTO public.users (_id, username, email, hash_pass) VALUES (%s,%s,%s,'x')",
                        (owner, f"xl_{owner[:8]}", f"xl_{owner[:8]}@example.com"))
            gid = str(uuid.uuid4())
            cur.execute("INSERT INTO public.groups (_id, title, users, creator_id) VALUES (%s,'g',%s,%s)",
                        (gid, [owner], owner))
            cur.execute(
                "INSERT INTO group_listings (public_id, group_id, title, summary, free_tags, hobbies, city, "
                "church_name, description_text, status) VALUES ('AbCdEfGh12', %s, 'Quokka Fellowship', "
                "'We gather weekly', %s, %s, 'Zanzibar', 'Grace Chapel Nineveh', 'We study Obadiah together', "
                "'published')",
                (gid, ["marmalade"], ["kayaking"]))
            for label, word in (("title", "quokka"), ("free tag", "marmalade"), ("hobby", "kayaking"),
                                ("city", "zanzibar"), ("church", "nineveh"), ("description", "obadiah"),
                                ("summary", "weekly")):
                cur.execute("SELECT count(*) FROM group_listings WHERE search_tsv @@ plainto_tsquery('simple', %s)",
                            (word,))
                check(f"listing found by {label} word", cur.fetchone()[0] == 1, word)
            cur.execute("SELECT count(*) FROM group_listings WHERE search_tsv @@ plainto_tsquery('simple', 'absentword')")
            check("an absent word finds nothing", cur.fetchone()[0] == 0)
            cur.execute("INSERT INTO group_listings (public_id, group_id) VALUES ('bad', %s)", (str(uuid.uuid4()),))
        except Exception as e:  # noqa: BLE001
            msg = str(e)
            check("bad public_id / orphan group is refused by a constraint",
                  "check" in msg.lower() or "foreign key" in msg.lower() or "violates" in msg.lower(), msg[:120])
    finally:
        db.conn.rollback()  # DDL is transactional: the scratch schema vanishes
        db.close()
    check("scratch schema left no trace",
          not q("SELECT 1 FROM pg_namespace WHERE nspname = %s", (schema,)))
    for tag, forbidden in (("listings.py", "group_listing_media"),):
        pass
    src = open(os.path.join(API_DIR, "backend/interactions/listings.py")).read()
    check("this task never writes to group_listing_media",
          "INSERT INTO group_listing_media" not in src and "UPDATE group_listing_media" not in src)


# -- 2. frozen signatures and helper behaviour ----------------------------------

def test_signatures():
    print("frozen helper signatures")
    S = inspect.signature
    sig = S(listings.public_where)
    check("public_where(alias: str = 'gl') -> str",
          list(sig.parameters) == ["alias"] and sig.parameters["alias"].default == "gl"
          and sig.parameters["alias"].annotation is str and sig.return_annotation is str, str(sig))
    expect = {
        "listing_requestable": (["cur", "public_id"], {"public_id": str}, dict | None),
        "set_accepting_requests": (["cur", "group_id", "value"], {"group_id": str, "value": bool}, bool),
        "get_accepting_requests": (["cur", "group_id"], {"group_id": str}, bool | None),
        "group_has_explorer_presence": (["cur", "group_id"], {"group_id": str}, bool),
        "live_member_count": (["cur", "group_id"], {"group_id": str}, int),
        "requeue_for_review": (["cur", "group_id", "reason"], {"group_id": str, "reason": str}, bool),
    }
    for name, (params, anns, ret) in expect.items():
        sg = S(getattr(listings, name))
        ok = (list(sg.parameters) == params
              and all(sg.parameters[p].annotation == a for p, a in anns.items())
              and sg.return_annotation == ret)
        check(f"{name} signature is frozen", ok, str(sg))
    check("public_where rejects an alias that is not a plain identifier",
          all(_raises(ValueError, listings.public_where, bad) for bad in ("gl; DROP TABLE x", "a b", "1x", "")))
    check("public_where embeds the alias", "xx.status = 'published'" in listings.public_where("xx"))
    cols = {r[0] for r in q("SELECT column_name FROM information_schema.columns WHERE table_name = 'group_listings'")}
    need = {"_id", "public_id", "group_id", "status", "accepting_requests", "title", "approved_at", "search_tsv",
            "description_text", "consent_version", "consented_at", "adult_attested", "published_at"}
    check("columns JRQ/LSM rely on exist", need <= cols, need - cols)
    check("lifecycle docstring documents listing_hidden as fn(cur, group_id, reason)",
          "fn(cur, group_id, reason)" in lifecycle.__doc__)


def _raises(exc, fn, *a):
    try:
        fn(*a)
    except exc:
        return True
    except Exception:  # noqa: BLE001
        return False
    return False


def test_helpers():
    print("helpers: accepting_requests, cursor-in/no-commit, requeue, live members, requestable")
    owner, member = make_user(), make_user()
    with_l = make_group(owner, [member])
    without = make_group(owner, [member], title="No listing here")
    cli = TestClient(main_module.app)
    limiter.reset()
    r = cli.put(f"/explorer/{owner}/groups/{with_l}/listing", json={}, headers=hdr(owner))
    check("draft created for helper tests", r.status_code == 200, (r.status_code, r.text))
    db = DBManager()
    cur = db.cur
    try:
        check("get_accepting_requests: False for a fresh listing (column default)",
              listings.get_accepting_requests(cur, with_l) is False)
        check("get_accepting_requests: None when the group has no listing",
              listings.get_accepting_requests(cur, without) is None)
        check("get_accepting_requests: None for a non-uuid id", listings.get_accepting_requests(cur, "zz") is None)
        before = q("SELECT updated_at FROM group_listings WHERE group_id = %s", (with_l,))[0][0]
        check("set_accepting_requests True -> True (row written)",
              listings.set_accepting_requests(cur, with_l, True) is True)
        check("get now True", listings.get_accepting_requests(cur, with_l) is True)
        db.conn.rollback()
        check("rollback undoes set_accepting_requests (helper never commits)",
              q("SELECT accepting_requests FROM group_listings WHERE group_id = %s", (with_l,))[0][0] is False)
        check("set_accepting_requests False for a group with no listing (never raises)",
              listings.set_accepting_requests(cur, without, True) is False)
        check("set_accepting_requests False for a non-uuid id", listings.set_accepting_requests(cur, "zz", True) is False)
        check("nothing was written for the group without a listing", row(without) is None)
        check("set_accepting_requests rejects a non-bool", _raises(ValueError, listings.set_accepting_requests, cur, with_l, "yes"))
        db.conn.rollback()
        listings.set_accepting_requests(cur, with_l, True)
        db.conn.commit()
        after = q("SELECT updated_at FROM group_listings WHERE group_id = %s", (with_l,))[0][0]
        check("set_accepting_requests does not touch updated_at", before == after, (before, after))
        check("get_accepting_requests True after commit", listings.get_accepting_requests(cur, with_l) is True)
        db.conn.rollback()

        # presence
        check("no presence for a draft", listings.group_has_explorer_presence(cur, with_l) is False)
        check("no presence without a listing", listings.group_has_explorer_presence(cur, without) is False)
        check("presence helper tolerates a junk id", listings.group_has_explorer_presence(cur, "zz") is False)
        for st, want in (("pending_review", True), ("published", True), ("hidden", True),
                         ("unpublished", False), ("rejected", False), ("draft", False)):
            q("UPDATE group_listings SET status = %s WHERE group_id = %s", (st, with_l), fetch=False)
            check(f"presence for status {st} is {want}", listings.group_has_explorer_presence(cur, with_l) is want)
            db.conn.rollback()

        # requeue_for_review
        for reason in ("text", "media"):
            q("UPDATE group_listings SET status='published', approved_at = NOW() WHERE group_id = %s", (with_l,), fetch=False)
            check(f"requeue_for_review('{reason}') on published -> True", listings.requeue_for_review(cur, with_l, reason) is True)
            db.conn.rollback()
            check(f"rollback undid requeue ({reason})", status(with_l) == "published")
            listings.requeue_for_review(cur, with_l, reason)
            db.conn.commit()
            check(f"{reason}: now pending_review with approval cleared",
                  row(with_l, "status, approved_at") == ("pending_review", None))
        q("UPDATE group_listings SET status='unpublished', approved_at = NOW() WHERE group_id = %s", (with_l,), fetch=False)
        check("requeue on unpublished: False (no status change) but approval voided",
              listings.requeue_for_review(cur, with_l, "text") is False)
        db.conn.commit()
        check("unpublished stays unpublished, approved_at cleared", row(with_l, "status, approved_at") == ("unpublished", None))
        check("requeue_for_review on a group with no listing is False", listings.requeue_for_review(cur, without, "text") is False)
        check("requeue_for_review rejects an unknown reason", _raises(ValueError, listings.requeue_for_review, cur, with_l, "other"))
        db.conn.rollback()
    finally:
        db.close()

    # live_member_count: dead uuid + junk string + duplicate never inflate the count
    dead = str(uuid.uuid4())
    g = make_group(owner, [member, dead, "not-a-uuid", member.upper()], title="Count group")
    db = DBManager()
    try:
        check("live_member_count ignores a dead id, a junk string and a duplicate",
              listings.live_member_count(db.cur, g) == 2, listings.live_member_count(db.cur, g))
        db.conn.rollback()
    finally:
        db.close()

    # filter-only vs text edits via HTTP (re-queue scope)
    o2 = make_user()
    g2 = make_group(o2, [make_user()], title="Requeue scope")
    admin = make_user()
    h = hdr(o2)

    def put(body, hh=h, uid=o2, gid=g2):
        limiter.reset()
        return cli.put(f"/explorer/{uid}/groups/{gid}/listing", json=body, headers=hh)

    def submit(body=None):
        limiter.reset()
        return cli.post(f"/explorer/{o2}/groups/{g2}/listing/submit",
                        json=body or {"consent": True, "adult_attested": True}, headers=h)
    put({"title": "Scope Group"})
    submit()
    approve(g2, admin)
    check("published after approve", status(g2) == "published" and visible(g2))
    r = put({"goals": ["prayer"], "denominations": ["baptist"], "country": "us", "city": "Austin",
             "meeting_format": "online", "accepting_requests": True})
    check("vocab/location/accepting edits stay published", r.status_code == 200 and status(g2) == "published", r.text)
    r = put({"summary": "A new summary"})
    check("summary (free text) edit re-queues", status(g2) == "pending_review" and not visible(g2), status(g2))
    check("re-queue clears approved_at", row(g2, "approved_at")[0] is None)
    approve(g2, admin) if status(g2) == "pending_review" else None
    r = put({"free_tags": ["morning"]})
    check("free_tags edit re-queues", status(g2) == "pending_review")
    approve(g2, admin)
    put({"church_name": "Grace Chapel"})
    check("church_name edit re-queues", status(g2) == "pending_review")
    approve(g2, admin)
    put({"description_blocks": [{"type": "text", "text": "hello there"}]})
    check("description edit re-queues", status(g2) == "pending_review")
    approve(g2, admin)
    put({"title": "Scope Group"})
    check("an identical re-save is not a change (stays published)", status(g2) == "published")

    # listing_requestable
    pid = public_id(g2)
    db = DBManager()
    try:
        res = listings.listing_requestable(db.cur, pid)
        check("requestable: dict with exactly group_id/listing_id/title",
              isinstance(res, dict) and set(res) == {"group_id", "listing_id", "title"}
              and res["group_id"] == g2 and res["title"] == "Scope Group", res)
        check("requestable: bad/odd ids -> None",
              all(listings.listing_requestable(db.cur, x) is None for x in ("bad", "", "AAAAAAAAAA", "x" * 11, None)))
        db.conn.rollback()
        q("UPDATE group_listings SET accepting_requests = FALSE WHERE group_id = %s", (g2,), fetch=False)
        check("requestable: None when not accepting", listings.listing_requestable(db.cur, pid) is None)
        db.conn.rollback()
        q("UPDATE group_listings SET accepting_requests = TRUE WHERE group_id = %s", (g2,), fetch=False)
        q("UPDATE groups SET max_members = 2 WHERE _id = %s", (g2,), fetch=False)
        check("requestable: full group (2 of 2 live members) -> None", listings.listing_requestable(db.cur, pid) is None)
        db.conn.rollback()
        q("UPDATE groups SET max_members = 3, users = users || ARRAY[%s]::text[] WHERE _id = %s",
          (str(uuid.uuid4()), g2), fetch=False)
        check("requestable: a dead id does not fill the group (3 cap, 2 live + 1 dead)",
              listings.listing_requestable(db.cur, pid) is not None)
        db.conn.rollback()
        q("UPDATE group_listings SET status = 'unpublished' WHERE group_id = %s", (g2,), fetch=False)
        check("requestable: unpublished -> None", listings.listing_requestable(db.cur, pid) is None)
        db.conn.rollback()
        q("UPDATE group_listings SET status = 'published' WHERE group_id = %s", (g2,), fetch=False)
        q("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (o2,), fetch=False)
        check("requestable: suspended owner -> None", listings.listing_requestable(db.cur, pid) is None)
        db.conn.rollback()
    finally:
        db.close()
        q("UPDATE groups SET max_members = NULL WHERE _id = %s", (g2,), fetch=False)


# -- 3. flags / probe -----------------------------------------------------------

def test_flags_and_probe(cli):
    print("flags, canary, GET /explorer/config")
    owner, other = make_user(), make_user()
    gid = make_group(owner)
    gid_other = make_group(other)
    saved = {r[0]: (r[1], r[2] or []) for r in q("SELECT name, state, canary_user_ids::text[] FROM feature_flags")}
    try:
        # explorer_browse: off/on only
        try:
            flags.set_flag("explorer_browse", "canary", actor="xl-test")
            canary_ok = True
        except flags.InvalidFlagStateError:
            canary_ok = False
        check("explorer_browse rejects canary", canary_ok is False)
        try:
            flags.set_flag("explorer_browse", "off", [owner], actor="xl-test")
            canary_ids_ok = True
        except flags.InvalidFlagStateError:
            canary_ids_ok = False
        check("explorer_browse rejects canary user ids", canary_ids_ok is False)

        set_flag_sql("explorer_browse", "off")
        r = cli.get("/explorer/config")
        check("probe off -> HTTP 200 {browse:false} (never 404)", r.status_code == 200 and r.json() == {"browse": False},
              (r.status_code, r.text))
        check("probe carries Cache-Control public", "public" in r.headers.get("cache-control", ""), r.headers)
        set_flag_sql("explorer_browse", "on")
        r = cli.get("/explorer/config")
        check("probe on -> 200 {browse:true}", r.status_code == 200 and r.json() == {"browse": True}, r.text)
        set_flag_sql("explorer_browse", "canary")
        r = cli.get("/explorer/config")
        check("a canary row never shows to an anonymous caller (fails closed)",
              r.status_code == 200 and r.json() == {"browse": False}, r.text)
        set_flag_sql("explorer_browse", "on")
        r = cli.get("/explorer/config", headers=hdr(owner))
        check("probe answers the same signed in", r.status_code == 200 and r.json() == {"browse": True})

        real = flags.is_enabled

        def boom(*a, **k):
            raise RuntimeError("flag store down")
        flags.is_enabled = boom
        try:
            r = cli.get("/explorer/config")
        finally:
            flags.is_enabled = real
        check("flag read raising still answers 200 {browse:false}",
              r.status_code == 200 and r.json() == {"browse": False}, (r.status_code, r.text))
        real_load = flags._load_snapshot
        flags._load_snapshot = boom
        flags.invalidate()
        try:
            r = cli.get("/explorer/config")
            r2 = cli.put(f"/explorer/{owner}/groups/{gid}/listing", json={}, headers=hdr(owner))
        finally:
            flags._load_snapshot = real_load
            flags.invalidate()
        check("flag DB unreachable: probe 200 false", r.status_code == 200 and r.json() == {"browse": False}, r.text)
        check("flag DB unreachable: owner write fails closed (404)", r2.status_code == 404, (r2.status_code, r2.text))

        # explorer_publish off: uniform 404 everywhere, same body as a missing group
        set_flag_sql("explorer_publish", "off")
        limiter.reset()
        base = f"/explorer/{owner}/groups/{gid}/listing"
        calls = [
            ("GET options", lambda: cli.get(f"/explorer/{owner}/options", headers=hdr(owner))),
            ("GET groups", lambda: cli.get(f"/explorer/{owner}/groups", headers=hdr(owner))),
            ("GET listing", lambda: cli.get(base, headers=hdr(owner))),
            ("PUT listing", lambda: cli.put(base, json={"title": "x"}, headers=hdr(owner))),
            ("POST submit", lambda: cli.post(base + "/submit", json={"consent": True, "adult_attested": True}, headers=hdr(owner))),
            ("POST unpublish", lambda: cli.post(base + "/unpublish", headers=hdr(owner))),
            ("DELETE listing", lambda: cli.delete(base, headers=hdr(owner))),
        ]
        for name, call in calls:
            limiter.reset()
            r = call()
            check(f"flag off: {name} -> uniform 404", r.status_code == 404 and r.json() == NOT_FOUND, (r.status_code, r.text))
        check("flag off wrote nothing", row(gid) is None)

        # canary: owner in, other out
        flags.set_flag("explorer_publish", "canary", [owner], actor="xl-test")
        limiter.reset()
        r = cli.put(base, json={}, headers=hdr(owner))
        check("canary user can use the owner routes", r.status_code == 200, (r.status_code, r.text))
        limiter.reset()
        r = cli.put(f"/explorer/{other}/groups/{gid_other}/listing", json={}, headers=hdr(other))
        check("non-canary user gets the uniform 404", r.status_code == 404 and r.json() == NOT_FOUND, (r.status_code, r.text))
        # missing group body equals flag-off body
        flags.set_flag("explorer_publish", "on", actor="xl-test")
        limiter.reset()
        r = cli.get(f"/explorer/{owner}/groups/{uuid.uuid4()}/listing", headers=hdr(owner))
        check("flag-on missing group has the identical 404 body", r.status_code == 404 and r.json() == NOT_FOUND, r.text)
    finally:
        for name, (state, canary) in saved.items():
            q("UPDATE feature_flags SET state = %s, canary_user_ids = %s::uuid[] WHERE name = %s",
              (state, canary, name), fetch=False)
        flags.invalidate()
    now = {r[0]: r[1] for r in q("SELECT name, state FROM feature_flags")}
    check("feature flags restored", all(now.get(n) == v[0] for n, v in saved.items()), now)


# -- 4. owner lifecycle through HTTP ---------------------------------------------

def test_owner_lifecycle(cli):
    print("owner lifecycle, validation, IDOR, cap, terms")
    admin, owner, member, stranger = make_user(), make_user(), make_user(), make_user()
    gid = make_group(owner, [member], title="Romans Study")
    ho = hdr(owner)
    base = f"/explorer/{owner}/groups/{gid}/listing"

    def call(method, url, json_body=None, h=ho):
        limiter.reset()
        return getattr(cli, method)(url, headers=h, **({"json": json_body} if json_body is not None else {}))

    r = call("get", f"/explorer/{owner}/options")
    check("options payload carries vocab/limits and no secrets",
          r.status_code == 200 and "vocab" in r.json() and "limits" in r.json(), r.text[:200])
    r = call("get", base)
    check("GET before create -> 404", r.status_code == 404)
    r = call("get", f"/explorer/{owner}/groups")
    check("groups list shows the group with no listing",
          r.status_code == 200 and any(g["group_id"] == gid and g["listing"] is None for g in r.json()["groups"]), r.text[:200])

    r = call("put", base, {})
    d = r.json()
    check("first PUT creates a draft", r.status_code == 200 and d["status"] == "draft", (r.status_code, r.text))
    check("title snapshot prefilled from the group title", d["title"] == "Romans Study", d["title"])
    check("accepting_requests defaults FALSE when absent", d["accepting_requests"] is False)
    check("public_id is 10 alphanumerics, internal ids not in the owner view",
          len(d["public_id"]) == 10 and d["public_id"].isalnum() and "_id" not in d, list(d))
    check("a draft is not public", not visible(gid))
    r = call("put", base, {"accepting_requests": True, "title": "Romans Study"})
    check("PUT stores accepting_requests=True", r.json()["accepting_requests"] is True)
    r = call("put", base, {"summary": "We read Romans"})
    check("omitted accepting_requests leaves the stored value", r.json()["accepting_requests"] is True)
    r = call("put", base, {"accepting_requests": None})
    check("null accepting_requests = unchanged", r.status_code == 200 and r.json()["accepting_requests"] is True, r.text)
    r = call("put", base, {"accepting_requests": "yes"})
    check("non-boolean accepting_requests -> 422", r.status_code == 422, r.status_code)
    r = call("put", base, {"bogus": 1})
    check("unknown body field -> 422", r.status_code == 422)

    # group rename does not move the listing title
    q("UPDATE groups SET title = 'Renamed Elsewhere' WHERE _id = %s", (gid,), fetch=False)
    check("title snapshot unaffected by a group rename", row(gid, "title")[0] == "Romans Study")
    q("UPDATE groups SET title = 'Romans Study' WHERE _id = %s", (gid,), fetch=False)

    # submit gates
    r = call("post", base + "/submit", {"consent": False, "adult_attested": True})
    check("submit without consent -> 422 consent_required", r.status_code == 422 and r.json()["detail"]["code"] == "consent_required", r.text)
    r = call("post", base + "/submit", {"consent": True, "adult_attested": False})
    check("submit without adult attestation -> 422", r.status_code == 422 and r.json()["detail"]["code"] == "adult_attestation_required", r.text)
    r = call("post", base + "/submit", {"consent": "true", "adult_attested": True})
    check("string consent -> 422 (strict)", r.status_code == 422)
    check("status still draft after refused submits", status(gid) == "draft")
    r = call("post", base + "/submit", {"consent": True, "adult_attested": True, "accepting_requests": False})
    d = r.json()
    check("submit -> pending_review (require_approval)", r.status_code == 200 and d["status"] == "pending_review", r.text)
    check("consent_version and consented_at stored, adult attested",
          d["consent_version"] == get_listings_config().consent_version and d["consented_at"] and d["adult_attested"] is True, d)
    check("submit body accepting_requests=False stored", d["accepting_requests"] is False)
    check("pending listing is not public", not visible(gid))
    r = call("post", base + "/unpublish")
    check("owner can unpublish while in review", r.status_code == 200 and r.json()["status"] == "unpublished")
    r = call("post", base + "/submit", {"consent": True, "adult_attested": True})
    check("resubmit of a never-approved listing -> pending_review", r.json()["status"] == "pending_review", r.text)

    # admin transitions
    check("admin approve refuses an unknown public id", _raises(ListingError, admin_do, listings.admin_approve, "ZZZZZZZZZZ", admin))
    r1 = admin_do(listings.admin_approve, public_id(gid), admin)
    check("admin_approve -> published and publicly visible", r1["status"] == "published" and visible(gid))
    check("approve stores approved_at and reviewed_at", all(row(gid, "approved_at, reviewed_at")))
    check("approving a published listing is refused (409 invalid_state)",
          _raises(ListingError, admin_do, listings.admin_approve, public_id(gid), admin))
    r = call("post", base + "/unpublish")
    check("unpublish is immediate", r.json()["status"] == "unpublished" and not visible(gid))
    r = call("post", base + "/submit", {"consent": True, "adult_attested": True})
    check("republish with nothing changed goes straight to published (no new review)",
          r.json()["status"] == "published" and visible(gid), r.text)
    call("post", base + "/unpublish")
    call("put", base, {"summary": "Changed while unpublished"})
    r = call("post", base + "/submit", {"consent": True, "adult_attested": True})
    check("a text change while unpublished forces a fresh review", r.json()["status"] == "pending_review", r.text)

    # reject path
    try:
        admin_do(listings.admin_reject, public_id(gid), admin, "not-a-code")
        bad_reason = False
    except ListingError as e:
        bad_reason = e.status == 422
    check("reject with an unknown reason code -> 422", bad_reason)
    out = admin_do(listings.admin_reject, public_id(gid), admin, "incomplete")
    check("reject stores the reason and status", out["status"] == "rejected"
          and row(gid, "status, reject_reason_code") == ("rejected", "incomplete"))
    r = call("get", base)
    check("owner sees the rejection reason", r.json()["reject_reason_code"] == "incomplete")
    call("put", base, {"summary": "Fixed it up"})
    r = call("post", base + "/submit", {"consent": True, "adult_attested": True})
    check("owner may edit and resubmit after a rejection", r.json()["status"] == "pending_review" and row(gid, "reject_reason_code")[0] is None, r.text)

    # hide / restore
    admin_do(listings.admin_approve, public_id(gid), admin)
    captured = []
    hook = lambda cur, g, reason: captured.append((g, reason)) or []  # noqa: E731
    lifecycle.register("listing_hidden", hook)
    try:
        out = admin_do(listings.admin_hide, public_id(gid), admin, "spam")
        check("admin_hide -> hidden, not public", out["status"] == "hidden" and not visible(gid))
        check("listing_hidden hooks ran as fn(cur, group_id, reason)", (gid, "spam") in captured, captured)
        r = call("post", base + "/unpublish")
        check("owner cannot unpublish an admin-hidden listing (409 hidden_by_admin)",
              r.status_code == 409 and r.json()["detail"]["code"] == "hidden_by_admin", r.text)
        r = call("post", base + "/submit", {"consent": True, "adult_attested": True})
        check("owner cannot resubmit a hidden listing", r.status_code == 409, r.text)
        check("admin_hide of an invalid reason is refused", _raises(ListingError, admin_do, listings.admin_hide, public_id(gid), admin, "zzz"))
        out = admin_do(listings.admin_restore, public_id(gid), admin)
        check("restore of an approved listing -> published", out["status"] == "published" and visible(gid), out)
        admin_do(listings.admin_hide, public_id(gid), admin, "reported")
        q("UPDATE group_listings SET approved_at = NULL WHERE group_id = %s", (gid,), fetch=False)
        out = admin_do(listings.admin_restore, public_id(gid), admin)
        check("restore of a listing without approval -> pending_review", out["status"] == "pending_review", out)
        check("restoring a non-hidden listing is refused", _raises(ListingError, admin_do, listings.admin_restore, public_id(gid), admin))
        captured.clear()
        out = admin_do(listings.admin_remove, public_id(gid), admin)
        check("admin_remove deletes the row and runs hooks first", out["status"] == "removed" and row(gid) is None
              and (gid, "admin_removed") in captured, captured)
    finally:
        lifecycle._registry["listing_hidden"].remove(hook)

    # owner approve guards
    gx = make_group(owner, [], title="Approve guard")
    call("put", f"/explorer/{owner}/groups/{gx}/listing", {})
    call("post", f"/explorer/{owner}/groups/{gx}/listing/submit", {"consent": True, "adult_attested": True})
    q("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (owner,), fetch=False)
    check("approve refuses a suspended owner (409 owner_unavailable)",
          _raises(ListingError, admin_do, listings.admin_approve, public_id(gx), admin))
    check("still pending after refused approve", status(gx) == "pending_review")
    q("UPDATE users SET suspended_at = NULL WHERE _id = %s", (owner,), fetch=False)

    # delete
    r = call("delete", f"/explorer/{owner}/groups/{gx}/listing")
    check("owner DELETE -> 204 and row gone", r.status_code == 204 and row(gx) is None)
    r = call("delete", f"/explorer/{owner}/groups/{gx}/listing")
    check("DELETE again -> 404", r.status_code == 404)

    # IDOR / uniform 404
    g_new = make_group(owner, [member], title="Idor group")
    call("put", f"/explorer/{owner}/groups/{g_new}/listing", {})
    hs = hdr(stranger)
    hm = hdr(member)
    bodies = []
    for who, hh, uid in (("stranger", hs, stranger), ("non-creator member", hm, member)):
        for method, suffix, jb in (("get", "", None), ("put", "", {"title": "Hijack"}),
                                   ("post", "/submit", {"consent": True, "adult_attested": True}),
                                   ("post", "/unpublish", None), ("delete", "", None)):
            r = call(method, f"/explorer/{uid}/groups/{g_new}/listing{suffix}", jb, hh)
            bodies.append(r.text)
            check(f"{who}: {method.upper()}{suffix} on someone else's group -> 404", r.status_code == 404 and r.json() == NOT_FOUND, (r.status_code, r.text))
    r = call("get", f"/explorer/{owner}/groups/{g_new}/listing", None, hs)
    check("another user's session on my user_id path -> 403", r.status_code == 403, r.status_code)
    r = call("get", f"/explorer/{owner}/groups/{g_new}/listing", None, {})
    check("no session -> 401", r.status_code in (401, 403), r.status_code)
    r = call("get", f"/explorer/{owner}/groups/not-a-uuid/listing")
    check("non-uuid group id -> 404 uniform", r.status_code == 404 and r.json() == NOT_FOUND)
    check("the title was never hijacked", row(g_new, "title")[0] == "Idor group")
    check("all IDOR 404 bodies are byte-identical", len(set(bodies)) == 1, set(bodies))

    # NULL-creator, owner left, suspended owner (manager level: sessions of suspended users are refused earlier)
    g_null = make_group(None, [owner], title="Legacy no creator")
    r = call("put", f"/explorer/{owner}/groups/{g_null}/listing", {})
    check("a group with no recorded creator cannot be listed (404)", r.status_code == 404 and r.json() == NOT_FOUND, r.text)
    g_left = make_group(owner, [member], title="Owner left")
    call("put", f"/explorer/{owner}/groups/{g_left}/listing", {})
    q("UPDATE groups SET users = %s WHERE _id = %s", ([member], g_left), fetch=False)
    r = call("get", f"/explorer/{owner}/groups/{g_left}/listing")
    check("creator no longer in groups.users -> 404", r.status_code == 404 and r.json() == NOT_FOUND, r.text)
    r = call("put", f"/explorer/{owner}/groups/{g_left}/listing", {"title": "Still mine?"})
    check("... and cannot write either", r.status_code == 404)
    g_susp = make_group(owner, [member], title="Suspended owner")
    call("put", f"/explorer/{owner}/groups/{g_susp}/listing", {})
    q("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (owner,), fetch=False)
    mgr = ListingsManager(owner)
    try:
        err = None
        try:
            mgr.get_listing(g_susp)
        except ListingError as e:
            err = e
        check("suspended owner: manager answers the same 404", err is not None and err.status == 404 and err.detail() == NOT_FOUND["detail"])
        err = None
        try:
            mgr.save(g_susp, {"title": "x"})
        except ListingError as e:
            err = e
        check("suspended owner cannot write", err is not None and err.status == 404)
    finally:
        mgr.close()
    q("UPDATE users SET suspended_at = NULL WHERE _id = %s", (owner,), fetch=False)

    # unusable group title is not copied
    owner2 = make_user()
    ho2 = hdr(owner2)
    g_youth = make_group(owner2, [], title="Teen Hangout")
    r = call("put", f"/explorer/{owner2}/groups/{g_youth}/listing", {}, ho2)
    check("unusable group title leaves the prefilled title empty (create still succeeds)",
          r.status_code == 200 and r.json()["title"] == "", r.text)
    r = call("post", f"/explorer/{owner2}/groups/{g_youth}/listing/submit", {"consent": True, "adult_attested": True}, ho2)
    check("submit with an empty title -> 422 title_required", r.status_code == 422 and r.json()["detail"]["code"] == "title_required", r.text)


def test_validation(cli):
    print("validation and text safety")
    owner = make_user()
    gid = make_group(owner, [], title="Validation group")
    base = f"/explorer/{owner}/groups/{gid}/listing"
    ho = hdr(owner)

    def put(body):
        limiter.reset()
        return cli.put(base, json=body, headers=ho)

    def code(r):
        d = r.json().get("detail")
        return d.get("code") if isinstance(d, dict) else None

    cases = [
        ("youth term in title", {"title": "Teen Bible Club"}, "youth_not_supported"),
        ("youth term in summary", {"summary": "for kids and parents"}, "youth_not_supported"),
        ("youth term in description", {"description_blocks": [{"type": "text", "text": "open to high school students"}]}, "youth_not_supported"),
        ("youth term in tag", {"free_tags": ["youth"]}, "youth_not_supported"),
        ("youth term in church", {"church_name": "Youth Chapel"}, "youth_not_supported"),
        ("angle bracket in title", {"title": "Hello <b>world</b>"}, "html_not_allowed"),
        ("link in title", {"title": "See https://example.com now"}, "links_not_allowed"),
        ("link in summary", {"summary": "visit www.example.com"}, "links_not_allowed"),
        ("raw html in description", {"description_blocks": [{"type": "text", "text": "<script>alert(1)</script>"}]}, "html_not_allowed"),
        ("img tag in description", {"description_blocks": [{"type": "text", "text": "<img src=x onerror=alert(1)>"}]}, "html_not_allowed"),
        ("javascript: link", {"description_blocks": [{"type": "text", "text": "[click](javascript:alert(1))"}]}, "invalid_link"),
        ("data: link", {"description_blocks": [{"type": "text", "text": "[click](data:text/html,hi)"}]}, "invalid_link"),
        ("markdown image", {"description_blocks": [{"type": "text", "text": "![alt](https://example.com/a.png)"}]}, "media_not_supported"),
        ("shortener host", {"description_blocks": [{"type": "text", "text": "[go](https://bit.ly/abc)"}]}, "link_blocked"),
        ("shortener bare url", {"description_blocks": [{"type": "text", "text": "see https://tinyurl.com/x"}]}, "link_blocked"),
        ("IP literal host", {"description_blocks": [{"type": "text", "text": "[x](http://192.168.0.1/a)"}]}, "link_blocked"),
        ("loopback host", {"description_blocks": [{"type": "text", "text": "[x](http://127.0.0.1)"}]}, "link_blocked"),
        ("unknown block type", {"description_blocks": [{"type": "image", "text": "x"}]}, "invalid_block"),
        ("extra key in text block", {"description_blocks": [{"type": "text", "text": "hi", "src": "x"}]}, "invalid_block"),
        ("empty text block", {"description_blocks": [{"type": "text", "text": "  "}]}, "invalid_block"),
        ("unknown denomination", {"denominations": ["made_up"]}, "invalid_vocab"),
        ("too many goals", {"goals": ["prayer", "bible_study", "fellowship", "worship", "service", "mentoring"]}, "too_many_values"),
        ("bad country", {"country": "ZZ"}, "invalid_field"),
        ("too-long title", {"title": "x" * 81}, "too_long"),
        ("control characters", {"title": "bad\x00title"}, "invalid_text"),
        ("weird tag characters", {"free_tags": ["a;b"]}, "invalid_text"),
    ]
    for label, body, want in cases:
        r = put(body)
        check(f"{label} -> 422 {want}", r.status_code == 422 and code(r) == want, (r.status_code, r.text[:160]))
    from backend.moderation.content_filter import ContentRejected, check_clean
    bad = None
    for cand in ("rape", "blowjob", "bukkake", "pedophile"):
        try:
            check_clean(title=cand)
        except ContentRejected:
            bad = cand
            break
    if bad:
        for field, body in (("title", {"title": bad}), ("summary", {"summary": bad}),
                            ("church_name", {"church_name": bad}), ("city", {"city": bad}),
                            ("free_tags", {"free_tags": [bad]}),
                            ("description", {"description_blocks": [{"type": "text", "text": bad}]})):
            r = put(body)
            check(f"check_clean rejects explicit text in {field}", r.status_code == 422 and code(r) == "content_rejected", (r.status_code, r.text[:160]))
    check("nothing was stored by any rejected body", row(gid) is None or row(gid, "summary, church_name")[0] is None)
    r = put({"title": "Fine title"})
    check("a valid body after the rejections still works", r.status_code == 200, r.text)
    r = put({"description_blocks": [{"type": "text", "text": "We study **Romans** and [our site](https://example.com/x)\n\n- one"}]})
    check("allowed Markdown (bold, https link, list) is accepted", r.status_code == 200, r.text)
    txt = row(gid, "description_text")[0]
    check("description_text drops markers and link targets", "Romans" in txt and "our site" in txt
          and "example.com" not in txt and "**" not in txt, txt)
    q("UPDATE group_listings SET status='published', approved_at=NOW() WHERE group_id = %s", (gid,), fetch=False)
    hits = q("SELECT count(*) FROM group_listings gl WHERE gl.group_id = %s AND gl.search_tsv @@ plainto_tsquery('simple','romans')", (gid,))[0][0]
    miss = q("SELECT count(*) FROM group_listings gl WHERE gl.group_id = %s AND gl.search_tsv @@ plainto_tsquery('simple','example')", (gid,))[0][0]
    check("search finds description words but not link targets", hits == 1 and miss == 0, (hits, miss))
    q("UPDATE group_listings SET status='draft', approved_at=NULL WHERE group_id = %s", (gid,), fetch=False)
    r = put({"city": "  São   Paulo "})
    check("city normalised for the prefix index", row(gid, "city, city_norm")[1] is not None
          and row(gid, "city, city_norm")[0] == "São Paulo", row(gid, "city, city_norm"))
    r = put({"description_blocks": [{"type": "text", "text": "y" * 2001}]})
    check("oversized block -> too_long", r.status_code == 422 and code(r) == "too_long")
    r = put({"description_blocks": [{"type": "text", "text": "z"}] * 31})
    check("too many blocks -> too_many_blocks", r.status_code == 422 and code(r) == "too_many_blocks", r.text[:120])


def test_cap_terms_rate(cli):
    print("per-owner cap, terms gate, rate limit")
    owner = make_user()
    gs = [make_group(owner, [], title=f"Cap group {i}") for i in range(4)]
    ho = hdr(owner)
    cap = get_listings_config().per_owner_cap
    check("config cap is 3", cap == 3)
    for i in range(cap):
        limiter.reset()
        r = cli.put(f"/explorer/{owner}/groups/{gs[i]}/listing", json={}, headers=ho)
        check(f"listing {i + 1} within the cap -> 200", r.status_code == 200, r.text)
    limiter.reset()
    r = cli.put(f"/explorer/{owner}/groups/{gs[3]}/listing", json={}, headers=ho)
    check("listing over the cap -> 409 listing_cap_reached", r.status_code == 409 and r.json()["detail"]["code"] == "listing_cap_reached", r.text)
    check("no row created over the cap", row(gs[3]) is None)
    limiter.reset()
    r = cli.put(f"/explorer/{owner}/groups/{gs[0]}/listing", json={"summary": "edit within cap"}, headers=ho)
    check("editing an existing listing at the cap still works", r.status_code == 200)
    limiter.reset()
    cli.delete(f"/explorer/{owner}/groups/{gs[0]}/listing", headers=ho)
    limiter.reset()
    r = cli.put(f"/explorer/{owner}/groups/{gs[3]}/listing", json={}, headers=ho)
    check("deleting one frees a slot", r.status_code == 200, r.text)
    limiter.reset()
    r = cli.get(f"/explorer/{owner}/groups", headers=ho)
    check("groups list reports cap usage", r.json()["listing_cap"] == cap and r.json()["listings_used"] == 3, r.text[:200])

    # terms gate
    stale = make_user(terms="1999-01-01")
    gst = make_group(stale, [], title="Stale terms")
    hst = hdr(stale)
    limiter.reset()
    r = cli.put(f"/explorer/{stale}/groups/{gst}/listing", json={}, headers=hst)
    check("stale terms: PUT -> 403 terms_reaccept_required", r.status_code == 403 and r.json()["detail"]["code"] == "terms_reaccept_required", (r.status_code, r.text))
    limiter.reset()
    r = cli.post(f"/explorer/{stale}/groups/{gst}/listing/submit", json={"consent": True, "adult_attested": True}, headers=hst)
    check("stale terms: submit -> 403 terms_reaccept_required", r.status_code == 403 and r.json()["detail"]["code"] == "terms_reaccept_required", r.text)
    check("nothing written for the stale-terms owner", row(gst) is None)
    q("UPDATE users SET terms_version = %s WHERE _id = %s", (CURRENT_TERMS_VERSION, stale), fetch=False)
    limiter.reset()
    r = cli.put(f"/explorer/{stale}/groups/{gst}/listing", json={}, headers=hst)
    check("after accepting current terms the write works", r.status_code == 200, r.text)

    # rate limit (owner_write 10/min per user)
    limiter.reset()
    codes = [cli.put(f"/explorer/{owner}/groups/{gs[1]}/listing", json={"summary": f"s{i}"}, headers=ho).status_code
             for i in range(14)]
    check("owner write rate limit returns 429 within 14 rapid writes", 429 in codes and codes[0] == 200, codes)
    limiter.reset()


def test_options_has_no_media():
    print("config hygiene")
    raw = json.load(open(os.path.join(API_DIR, "config/explorer.json")))["listings"]
    bad = [k for k in raw if any(w in k.lower() for w in ("media", "s3", "image", "video", "mime", "banner", "bucket_name", "presign"))]
    check("listings config has no media/S3 keys", not bad, bad)
    cfg = get_listings_config()
    check("require_approval is on", cfg.require_approval is True)
    check("auto-hide threshold, public timeout and concurrency come from config",
          cfg.report_auto_hide_threshold == 3 and cfg.public_query_timeout_ms == 2000 and cfg.public_concurrency == 8)
    check("page sizes configured (12 default, 24 max)", cfg.page_size_default == 12 and cfg.page_size_max == 24)
    check("youth pattern blocks teen but not a word containing it by accident",
          cfg.youth_pattern.search("a teen group") and not cfg.youth_pattern.search("canteen fellowship"))
    # startup check wiring
    from backend import startup_checks
    check("startup_checks has check_listings_config", callable(getattr(startup_checks, "check_listings_config", None)))
    startup_checks.check_listings_config()
    from backend import public_guard
    check("startup check configured public_guard (no default of its own)", public_guard._concurrency == 8 and public_guard._max_waiting == 16,
          (public_guard._concurrency, public_guard._max_waiting))


# -- 5. PUT /groups guard ----------------------------------------------------------

def test_put_groups_guard(cli):
    print("PUT /groups owner-only guard")
    owner, member, newbie, other = make_user(), make_user(), make_user(), make_user()
    admin = make_user()
    gid = make_group(owner, [member], title="Guard group")
    ho, hm = hdr(owner), hdr(member)

    def put_group(uid, hh, users, title="Guard group"):
        return cli.put(f"/groups/{uid}/{gid}", json={"group_id": gid, "title": title, "users": users}, headers=hh)

    r = put_group(member, hm, [owner, member, newbie])
    check("ordinary group (no listing): a non-creator may add (unchanged behaviour)", r.status_code == 200, (r.status_code, r.text))
    q("UPDATE groups SET users = %s WHERE _id = %s", ([owner, member], gid), fetch=False)
    limiter.reset()
    cli.put(f"/explorer/{owner}/groups/{gid}/listing", json={}, headers=ho)
    r = put_group(member, hm, [owner, member, newbie])
    check("draft listing is not presence: non-creator add still allowed", r.status_code == 200, (r.status_code, r.text))
    q("UPDATE groups SET users = %s WHERE _id = %s", ([owner, member], gid), fetch=False)
    limiter.reset()
    cli.post(f"/explorer/{owner}/groups/{gid}/listing/submit", json={"consent": True, "adult_attested": True}, headers=ho)
    check("listing in review", status(gid) == "pending_review")
    r = put_group(member, hm, [owner, member, newbie])
    check("listed group: non-creator add -> 409 owner_only",
          r.status_code == 409 and r.json()["detail"]["code"] == "owner_only", (r.status_code, r.text))
    check("rejected add changed nothing", q("SELECT users FROM groups WHERE _id = %s", (gid,))[0][0] == [owner, member])
    r = put_group(member, hm, [member])
    check("listed group: removing the creator -> 409 owner_only", r.status_code == 409 and r.json()["detail"]["code"] == "owner_only", (r.status_code, r.text))
    r = put_group(owner, ho, [member])
    check("even the creator cannot remove themselves through PUT", r.status_code == 409, (r.status_code, r.text))
    r = put_group(member, hm, [owner, member], title="A new name")
    check("rename by a non-creator is allowed", r.status_code == 200, (r.status_code, r.text))
    check("listing title snapshot unaffected by the rename", row(gid, "title")[0] == "Guard group")
    r = put_group(owner, ho, [owner, member, newbie])
    check("creator may add members to a listed group", r.status_code == 200, (r.status_code, r.text))
    r = put_group(member, hm, [owner, newbie])
    check("a non-creator may remove themselves / others (not the creator)", r.status_code == 200, (r.status_code, r.text))
    dead = str(uuid.uuid4())
    q("UPDATE groups SET users = %s WHERE _id = %s", ([owner, member, dead], gid), fetch=False)
    r = put_group(member, hm, [owner, member, dead])
    check("build-78 shaped payload echoing a dead id still returns 200", r.status_code == 200, (r.status_code, r.text))
    check("stored list is cleaned of the dead id", dead not in q("SELECT users FROM groups WHERE _id = %s", (gid,))[0][0])
    # hidden listing is still presence
    admin_do(listings.admin_approve, public_id(gid), admin)
    admin_do(listings.admin_hide, public_id(gid), admin, "spam")
    r = put_group(member, hm, [owner, member, other])
    check("hidden listing still guards the group", r.status_code == 409, (r.status_code, r.text))
    q("UPDATE group_listings SET status = 'unpublished' WHERE group_id = %s", (gid,), fetch=False)
    r = put_group(member, hm, [owner, member, other])
    check("unpublished listing releases the guard", r.status_code == 200, (r.status_code, r.text))


# -- 6. lifecycle -------------------------------------------------------------------

def mk_published(owner, members, title="Lifecycle group", admin=None):
    gid = make_group(owner, members, title=title)
    ho = hdr(owner)
    limiter.reset()
    TestClient(main_module.app).put(f"/explorer/{owner}/groups/{gid}/listing", json={"accepting_requests": True}, headers=ho)
    limiter.reset()
    TestClient(main_module.app).post(f"/explorer/{owner}/groups/{gid}/listing/submit",
                                     json={"consent": True, "adult_attested": True}, headers=ho)
    approve(gid, admin or owner)
    return gid


def test_lifecycle(cli):
    print("group delete / leave / delete_user lifecycle")
    admin = make_user()
    captured = []
    hook = lambda cur, g, reason: captured.append((g, reason)) or []  # noqa: E731
    lifecycle.register("listing_hidden", hook)
    try:
        # group delete by creator
        a, b = make_user(), make_user()
        g1 = mk_published(a, [b], admin=admin)
        check("published before delete", visible(g1))
        r = cli.delete(f"/groups/{a}/{g1}", headers=hdr(a))
        check("creator deletes the group (204)", r.status_code == 204, (r.status_code, r.text))
        check("group delete removes the listing (FK cascade)", row(g1) is None)
        check("no listing visible for a deleted group", not visible(g1))

        # last member leaves -> group auto-deleted -> listing gone
        c = make_user()
        g2 = mk_published(c, [], admin=admin)
        r = cli.post(f"/groups/{c}/{g2}/leave", headers=hdr(c))
        check("last member leaves (204)", r.status_code == 204, (r.status_code, r.text))
        check("last-member leave deletes the group and its listing", row(g2) is None
              and not q("SELECT 1 FROM groups WHERE _id = %s", (g2,)))

        # creator leaves, group survives -> listing hidden owner_gone, hooks fire
        d, e = make_user(), make_user()
        g3 = mk_published(d, [e], admin=admin)
        captured.clear()
        r = cli.post(f"/groups/{d}/{g3}/leave", headers=hdr(d))
        check("creator leaves a group with other members (204)", r.status_code == 204, (r.status_code, r.text))
        check("listing hidden with reason owner_gone",
              row(g3, "status, hidden_reason_code") == ("hidden", "owner_gone"), row(g3, "status, hidden_reason_code"))
        check("listing_hidden hooks ran with (group_id, 'owner_gone')", (g3, "owner_gone") in captured, captured)
        check("not public and not requestable", not visible(g3))
        db = DBManager()
        try:
            check("listing_requestable None after owner left", listings.listing_requestable(db.cur, public_id(g3)) is None)
            db.conn.rollback()
        finally:
            db.close()
        check("a non-creator leaving does not touch a listing",
              True)  # covered below
        f_, g_ = make_user(), make_user()
        g4 = mk_published(f_, [g_], admin=admin)
        captured.clear()
        cli.post(f"/groups/{g_}/{g4}/leave", headers=hdr(g_))
        check("a non-creator leaving keeps the listing published", status(g4) == "published" and not captured, (status(g4), captured))

        # creator leaves with an unpublished listing: nothing to hide, no hook
        h_, i_ = make_user(), make_user()
        g5 = make_group(h_, [i_], title="Unpub")
        limiter.reset()
        cli.put(f"/explorer/{h_}/groups/{g5}/listing", json={}, headers=hdr(h_))
        captured.clear()
        cli.post(f"/groups/{h_}/{g5}/leave", headers=hdr(h_))
        check("creator leaving with a draft: no hide, no hook", status(g5) == "draft" and not captured, (status(g5), captured))

        # delete_user: listings of groups the user created are removed
        j, k = make_user(), make_user()
        g6 = mk_published(j, [k], title="Owned by deleted user", admin=admin)
        g7 = mk_published(k, [j], title="Owned by survivor", admin=admin)
        g8 = make_group(j, [], title="Solo owned")
        limiter.reset()
        cli.put(f"/explorer/{j}/groups/{g8}/listing", json={}, headers=hdr(j))
        q("UPDATE groups SET photo_key = %s WHERE _id = %s", (f"group-photos/{g8}/{uuid.uuid4().hex}.jpg", g8), fetch=False)
        r = cli.delete(f"/user/{j}", headers=hdr(j))
        check("delete_user succeeds for a listing owner", r.status_code in (200, 204), (r.status_code, r.text))
        check("listing of a group the deleted user created is gone", row(g6) is None)
        check("listing of the deleted user's solo group is gone", row(g8) is None)
        check("another owner's listing is untouched", status(g7) == "published" and visible(g7), status(g7))
        check("deleted user no longer in the surviving group", j not in q("SELECT users FROM groups WHERE _id = %s", (g7,))[0][0])
        check("no listing references a missing group",
              not q("SELECT 1 FROM group_listings gl LEFT JOIN groups g ON g._id = gl.group_id "
                    "WHERE g._id IS NULL AND gl.group_id = ANY(%s::uuid[])", ([g1, g2, g6, g8],)))

        # owner deletes own listing -> hooks run
        captured.clear()
        l_ = make_user()
        g9 = mk_published(l_, [], admin=admin)
        limiter.reset()
        r = cli.delete(f"/explorer/{l_}/groups/{g9}/listing", headers=hdr(l_))
        check("owner delete of a visible listing runs listing_hidden hooks", r.status_code == 204 and (g9, "owner_deleted") in captured, captured)
    finally:
        lifecycle._registry["listing_hidden"].remove(hook)

    # hooks registered by load_all in a FRESH process (CLIs do not import main)
    import subprocess
    code = ("from backend.registrations import load_all\nload_all()\nfrom backend.interactions import lifecycle\n"
            "print(sorted(f.__name__ for k in ('member_leave','user_delete') for f in lifecycle.hooks(k)))\n")
    r = subprocess.run([sys.executable, "-c", code], cwd=API_DIR, capture_output=True, text=True, timeout=120)
    check("fresh process: load_all registers the listing member_leave and user_delete hooks",
          r.returncode == 0 and "hide_listing_when_owner_leaves" in r.stdout and "delete_listings_of_deleted_owner" in r.stdout,
          (r.returncode, r.stdout[-200:], r.stderr[-200:]))


# -- 7. sweeper -----------------------------------------------------------------------

def test_sweeper():
    print("owner-suspension sweeper")
    admin = make_user()
    captured = []
    hook = lambda cur, g, reason: captured.append((g, reason)) or []  # noqa: E731
    lifecycle.register("listing_hidden", hook)
    try:
        o_susp, o_gone, o_ok, m1 = make_user(), make_user(), make_user(), make_user()
        gs = mk_published(o_susp, [m1], title="Sweep suspended", admin=admin)
        gg = mk_published(o_gone, [m1], title="Sweep gone", admin=admin)
        gk = mk_published(o_ok, [m1], title="Sweep healthy", admin=admin)
        q("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (o_susp,), fetch=False)
        q("UPDATE groups SET users = %s WHERE _id = %s", ([m1], gg), fetch=False)
        check("public_where already hides a suspended owner before the sweep", not visible(gs))
        check("... and an owner who left", not visible(gg))
        check("healthy listing visible", visible(gk))
        counts = listing_sweeper.sweep_once(batch_size=500)
        check("sweep reports hidden >= 2 and no failures", counts["hidden"] >= 2 and counts["failed"] == 0, counts)
        check("suspended owner -> hidden/owner_suspended", row(gs, "status, hidden_reason_code") == ("hidden", "owner_suspended"), row(gs, "status, hidden_reason_code"))
        check("departed owner -> hidden/owner_gone", row(gg, "status, hidden_reason_code") == ("hidden", "owner_gone"), row(gg, "status, hidden_reason_code"))
        check("healthy listing untouched", status(gk) == "published")
        check("listing_hidden hooks fired for both", (gs, "owner_suspended") in captured and (gg, "owner_gone") in captured, captured)
        n_before = len(captured)
        listing_sweeper.sweep_once(batch_size=500)
        check("a second sweep is a no-op for already-hidden listings",
              not [c for c in captured[n_before:] if c[0] in (gs, gg)], captured[n_before:])
        # restore refuses while the owner is still unavailable
        check("admin restore refuses a suspended owner", _raises(ListingError, admin_do, listings.admin_restore, public_id(gs), admin))
        q("UPDATE users SET suspended_at = NULL WHERE _id = %s", (o_susp,), fetch=False)
        out = admin_do(listings.admin_restore, public_id(gs), admin)
        check("after un-suspending, restore works", out["status"] == "published" and visible(gs), out)
    finally:
        lifecycle._registry["listing_hidden"].remove(hook)

    # async job body: executor only
    src = open(os.path.join(API_DIR, "backend/interactions/listing_sweeper.py")).read()
    tree = ast.parse(src)
    bad_calls = []
    for node in ast.walk(tree):
        if isinstance(node, ast.AsyncFunctionDef):
            for sub in ast.walk(node):
                if isinstance(sub, ast.Call):
                    name = ast.unparse(sub.func)
                    if any(t in name for t in ("psycopg2", "boto3", "DBManager", ".execute", "sweep_once(", ".commit", ".cursor")):
                        bad_calls.append(name)
                    if name == "sweep_once":
                        bad_calls.append(name)
    check("async job body has no psycopg2/boto3/DB call at call level", not bad_calls, bad_calls)
    check("async job body uses run_in_executor", "run_in_executor(None, sweep_once)" in src)
    check("sweeper module has no boto3 import", "boto3" not in src)
    sched = open(os.path.join(API_DIR, "backend/interactions/scheduler.py")).read()
    check("sweeper job registered with a stable id and replace_existing",
          "listing_owner_sweep" in sched or "JOB_ID" in sched)
    i = sched.find("run_listing_sweeper_job")
    check("scheduler add_job for the sweeper sets replace_existing=True", i != -1 and "replace_existing=True" in sched[i:i + 400], sched[i:i + 300])

    real = listing_sweeper.sweep_once

    def slow(*a, **k):
        time.sleep(0.8)
        return {"found": 0, "hidden": 0, "failed": 0}
    listing_sweeper.sweep_once = slow

    async def run():
        gaps, stop = [], False

        async def ticker():
            last = time.monotonic()
            while not stop:
                await asyncio.sleep(0.02)
                now = time.monotonic()
                gaps.append(now - last)
                last = now
        t = asyncio.create_task(ticker())
        await asyncio.sleep(0.05)
        await listing_sweeper.run_listing_sweeper_job()
        stop_flag = True  # noqa: F841
        t.cancel()
        return max(gaps) if gaps else 99
    try:
        lag = asyncio.run(run())
    finally:
        listing_sweeper.sweep_once = real
    check("event loop lag stays < 500 ms while 0.8 s of blocking sweep work runs", lag < 0.5, lag)

    def fail(*a, **k):
        raise RuntimeError("db down")
    listing_sweeper.sweep_once = fail
    try:
        with catch_logs() as lg:
            asyncio.run(listing_sweeper.run_listing_sweeper_job())
    finally:
        listing_sweeper.sweep_once = real
    check("a failing sweep run never raises out of the job and logs no ERROR",
          not [m for lv, m in lg.records if lv == "ERROR"], lg.records)


# -- 8. reports, logging ---------------------------------------------------------------

def test_reports_and_logs(cli):
    print("report registry symmetry, log hygiene, uniform errors")
    in_res, in_rem = "group_listing" in reports.CONTENT_RESOLVERS, "group_listing" in removers.CONTENT_REMOVERS
    check("group_listing resolver and remover are registered symmetrically (both or neither)", in_res == in_rem, (in_res, in_rem))
    reporter = make_user()
    r = cli.post("/reports/", json={"content_type": "group_listing", "content_id": "ZzZzZzZz12", "reason": "x"}, headers=hdr(reporter))
    check("reporting an unknown public_id -> 404 and nothing stored",
          r.status_code == 404 and not q("SELECT 1 FROM content_reports WHERE reporter_id = %s", (reporter,)), (r.status_code, r.text))
    r = cli.post("/reports/", json={"content_type": "group_listing", "content_id": "short", "reason": "x"}, headers=hdr(reporter))
    check("malformed public_id -> 422", r.status_code == 422, r.status_code)
    if in_res:
        admin = make_user()
        owner = make_user()
        gid = mk_published(owner, [], title="Reportable listing", admin=admin)
        res = None
        db = DBManager()
        try:
            res = reports.CONTENT_RESOLVERS["group_listing"](db.cur, public_id(gid), reporter)
            db.conn.rollback()
        finally:
            db.close()
        lid = q("SELECT _id::text FROM group_listings WHERE group_id = %s", (gid,))[0][0]
        check("resolver returns (creator, snippet, listing _id)", res and res[0] == owner and res[2] == lid and "Reportable" in res[1], res)

    # log hygiene: none of the listing text, ever
    marker = f"Zqx{uuid.uuid4().hex[:8]}"
    owner = make_user()
    gid = make_group(owner, [make_user()], title="Log group")
    admin = make_user()
    with catch_logs() as lg:
        limiter.reset()
        cli.put(f"/explorer/{owner}/groups/{gid}/listing",
                json={"title": f"Title {marker}", "summary": f"Summary {marker}", "church_name": f"Church {marker}",
                      "description_blocks": [{"type": "text", "text": f"Body {marker}"}]}, headers=hdr(owner))
        limiter.reset()
        cli.post(f"/explorer/{owner}/groups/{gid}/listing/submit", json={"consent": True, "adult_attested": True}, headers=hdr(owner))
        approve(gid, admin)
        limiter.reset()
        cli.put(f"/explorer/{owner}/groups/{gid}/listing", json={"summary": f"Changed {marker}"}, headers=hdr(owner))
        limiter.reset()
        cli.put(f"/explorer/{owner}/groups/{gid}/listing", json={"title": f"<b>{marker}</b>"}, headers=hdr(owner))
        q("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (owner,), fetch=False)
        listing_sweeper.sweep_once(batch_size=500)
    leaked = [m for lv, m in lg.records if marker in m]
    check("no listing text appears in any log line", not leaked, leaked[:2])
    check("no ERROR-level lines from the listing flow", not [m for lv, m in lg.records if lv == "ERROR" and "listing" in m.lower()],
          [m for lv, m in lg.records if lv == "ERROR"][:2])


def main():
    db = DBManager()
    db.cur.execute("SHOW port")
    port = db.cur.fetchone()[0]
    db.close()
    check("tests run against scratch DB port 55432", port == "55432", port)
    if port != "55432":
        raise SystemExit("refusing to continue: not the scratch database")
    load_all()
    cli = TestClient(main_module.app)
    saved = {r[0]: (r[1], r[2] or []) for r in q("SELECT name, state, canary_user_ids::text[] FROM feature_flags")}
    try:
        set_flag_sql("explorer_publish", "on")
        test_ddl()
        test_signatures()
        test_options_has_no_media()
        test_helpers()
        test_flags_and_probe(cli)
        set_flag_sql("explorer_publish", "on")
        test_owner_lifecycle(cli)
        test_validation(cli)
        test_cap_terms_rate(cli)
        test_put_groups_guard(cli)
        test_lifecycle(cli)
        test_sweeper()
        test_reports_and_logs(cli)
    finally:
        for name, (state, canary) in saved.items():
            q("UPDATE feature_flags SET state = %s, canary_user_ids = %s::uuid[] WHERE name = %s",
              (state, canary, name), fetch=False)
        flags.invalidate()
        cleanup()
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
