"""Tests for task 20261001-explorer-listings, Backend B (public read API).

Properties proved (each would catch a regression of the behaviour it names):
  1. Response allowlist: a recursive scan of list, detail, cursor and filters
     bodies finds none of the seeded sensitive values (group id, internal listing
     _id, member / dead / junk member ids, owner id, username, email, invite token
     hash, group title, description_text) and no "_id"-style key; models are
     extra=forbid; unknown / extra-keyed description blocks are dropped.
  2. Cursor: next_cursor_id is the 10-char public_id, no seq, no internal id.
  3. Flag fail closed: explorer_browse off (or the flag read raising) answers the
     SAME uniform 404 on list, detail and filters as a missing listing;
     GET /explorer/config is always 200 {browse: bool}.
  4. Cache-Control public, max-age=60 on 200s and never on 404/422.
  5. Validation 422s happen before any SQL (public_connection patched to explode):
     unknown slug, bad country, too many values, q too long / control chars,
     limit junk, include_full junk, cursor halves, uuid cursor, illegal characters,
     cursor_seq. Error bodies never echo the offending value.
  6. Filters, q and keyset paging: within-facet OR, across-facet AND, region/city
     prefix, country, single-valued facets, q by title / tag / hobby / city, q
     operators are plain text, ordering (published_at DESC, public_id DESC) with
     a timestamp tie, a full walk without dupes or gaps, limit clamp.
  7. Visibility: draft / pending / unpublished / hidden / rejected, suspended
     owner and owner-left listings never appear (list or detail), all as the
     uniform 404.
  8. Members: dead, junk and duplicate ids in groups.users are not counted in the
     size bucket or in full/open; full groups hidden unless include_full.
  9. Limits and isolation: per-IP limits and the global backstop (limiter.reset()
     and public_guard.reset_for_tests(), no real clock windows); handlers are
     async def and await run_public; run_public without configure raises; a DB
     statement timeout is 429 busy + Retry-After; and a REAL uvicorn server run
     (loopback) with 30 concurrent slow public calls: the excess is shed as 429
     busy with Retry-After quickly, nothing is 5xx, and GET /app/capabilities plus
     a WebSocket round trip each finish within 1 s while the public pool is full.
 10. EXPLAIN with 5,000 seeded listings: GIN for q, keyset btree otherwise,
     users_pkey (no Seq Scan on users) for the member join, and a page of 24 issues
     the same number of statements as a page of 2.
 11. No listing text, query text or cursor values in log lines.

Scratch database only: SHOW port must be 55432 first. All rows are uuid/marker
derived and removed in finally; flags are restored.

Run with: cd api && ../.venv/bin/python tests/test_explorer_public_api.py
"""
import _pathfix  # noqa: F401

import ast
import asyncio
import dataclasses
import json
import logging
import os
import socket
import sys
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from pydantic import ValidationError  # noqa: E402

import main as main_module  # noqa: E402
import routes.explorer as explorer_routes  # noqa: E402
from backend import public_guard  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.interactions import flags, listings, listings_public  # noqa: E402
from backend.interactions import listings_config  # noqa: E402
from backend.interactions.listings_config import get_listings_config  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from backend.registrations import load_all  # noqa: E402
from db import DBManager  # noqa: E402
from schemas import explorer_public  # noqa: E402

API_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSED, FAILED = [], []
USERS, GROUPS = [], []
NOT_FOUND = {"detail": {"code": "not_found", "message": "Not found"}}
RUN = uuid.uuid4().hex[:8]
MARK = f"zq{RUN}"          # one rare word every seeded listing carries (q scoping)
ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


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


def make_user(suspended=False, username=None, email=None):
    uid = str(uuid.uuid4())
    username = username or f"xp_{uid[:8]}"
    email = email or f"xp_{uid[:8]}@example.com"
    q("INSERT INTO users (_id, username, email, hash_pass, suspended_at) VALUES (%s,%s,%s,'x',%s)",
      (uid, username, email, "2020-01-01" if suspended else None), fetch=False)
    USERS.append(uid)
    return uid


def make_group(creator, members=None, title="Xp Group", max_members=None, creator_member=True):
    gid = str(uuid.uuid4())
    users = ([creator] if creator_member else []) + list(members or [])
    q("INSERT INTO groups (_id, title, users, creator_id, max_members) VALUES (%s,%s,%s,%s,%s)",
      (gid, title, users, creator, max_members), fetch=False)
    GROUPS.append(gid)
    return gid


def new_pid():
    import secrets
    return "".join(secrets.choice(ALNUM) for _ in range(10))


COLS = ("title", "summary", "denominations", "goals", "practices", "hobbies", "free_tags", "age_ranges",
        "life_stages", "languages", "gender_makeup", "meeting_format", "frequency", "country", "region",
        "city", "church_name", "description_text", "description_blocks", "accepting_requests")


def make_listing(gid, status="published", published_at=None, public_id=None, **kw):
    """Insert a listing row directly (the owner/admin flow is covered by the
    Backend A suite). Every row carries MARK in its title so q=MARK scopes it."""
    pid = public_id or new_pid()
    kw.setdefault("title", f"{MARK} listing")
    if MARK not in kw["title"]:
        kw["title"] = f"{MARK} {kw['title']}"
    for k in kw:
        assert k in COLS, k
    if "description_blocks" in kw and kw["description_blocks"] is not None:
        kw["description_blocks"] = json.dumps(kw["description_blocks"])
    cols = ["public_id", "group_id", "status", "published_at"] + list(kw)
    vals = [pid, gid, status, published_at or datetime.now(timezone.utc)] + list(kw.values())
    ph = ",".join(["%s"] * len(cols))
    ph = ph.replace("%s", "%s::jsonb", 0)
    q(f"INSERT INTO group_listings ({','.join(cols)}) VALUES ({ph})", vals, fetch=False)
    if "city" in kw and kw["city"]:
        q("UPDATE group_listings SET city_norm = lower(city) WHERE public_id = %s", (pid,), fetch=False)
    return pid


def listing_internal_id(pid):
    return str(q("SELECT _id FROM group_listings WHERE public_id = %s", (pid,))[0][0])


def set_flag_sql(name, state):
    q("UPDATE feature_flags SET state = %s WHERE name = %s", (state, name), fetch=False)
    flags.invalidate()


def hdr(uid):
    sm = SessionManager()
    try:
        return {"cookie": f"session={sm.create_session(uid)}"}
    finally:
        sm.close()


def walk_keys_values(obj, out_keys, out_strs):
    if isinstance(obj, dict):
        for k, v in obj.items():
            out_keys.add(k)
            out_strs.append(str(k))
            walk_keys_values(v, out_keys, out_strs)
    elif isinstance(obj, list):
        for v in obj:
            walk_keys_values(v, out_keys, out_strs)
    elif obj is not None:
        out_strs.append(str(obj))


class LogCatcher(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.records = []

    def emit(self, record):
        if record.name.startswith(("httpx", "httpcore")):
            return  # the test client's own request log, not the server's
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


def reconfigure_guard():
    public_guard.reset_for_tests()
    listings_config.validate_listings_config()


def get(cli, path, **params):
    limiter.reset()
    return cli.get(path, params=params)


def ids(body):
    return [c["public_id"] for c in body["listings"]]


# -- shared fixture -------------------------------------------------------------

FX = {}


def build_fixture():
    owner = make_user(username=f"sensitive_user_{RUN}", email=f"sensitive_{RUN}@secret-mail.example")
    live1, live2 = make_user(), make_user()
    dead = str(uuid.uuid4())
    junk = f"not-a-uuid-{RUN}"
    gid = make_group(owner, [live1, live2, dead, junk, live1.upper()], title=f"SecretGroupTitle{RUN}")
    FX.update(owner=owner, live1=live1, live2=live2, dead=dead, junk=junk, gid=gid)
    token_hash = (RUN * 8).ljust(64, "e")
    q("INSERT INTO invites (token_hash, kind, target_id, created_by, expires_at, max_uses) "
      "VALUES (%s,'group',%s,%s,NOW() + interval '1 day',5)", (token_hash, gid, owner), fetch=False)
    FX["token_hash"] = token_hash
    base = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(days=1)
    FX["base"] = base
    FX["main_pid"] = make_listing(
        gid, published_at=base + timedelta(hours=10), title="Main Rich Listing", summary=f"Sum {MARK}",
        denominations=["baptist", "catholic"], goals=["bible_study"], hobbies=["kayaking"],
        free_tags=["marmalade"], age_ranges=["adults_25_34"] if False else None,
        country="US", region="Texas", city="Austin", church_name="Grace Chapel",
        description_text=f"SECRETDESCRIPTION{RUN}",
        description_blocks=[
            {"type": "text", "text": "Hello block", "_id": FX["gid"] if False else gid, "author": owner},
            {"type": "image", "url": f"https://leak.example/{RUN}", "alt": "x"},
            {"type": "text", "text": "Second block"},
            {"type": "weird", "text": "unknown type text"},
        ],
        accepting_requests=True)
    FX["internal_id"] = listing_internal_id(FX["main_pid"])


def vocab_slugs(key, n=2):
    return [o["slug"] for o in get_listings_config().__dict__["vocab"][key]][:n] if hasattr(
        get_listings_config(), "__dict__") else []


# -- 1. allowlist, cursor leak scan ---------------------------------------------------

def test_allowlist(cli):
    print("response allowlist and cursor leak scan")
    # second owner and listings so the list has two pages
    owner2 = make_user()
    g2 = make_group(owner2, [])
    for i in range(3):
        make_listing(make_group(owner2, []), published_at=FX["base"] + timedelta(hours=i), title=f"Extra {i}")
    sensitive = {
        "group id": FX["gid"], "listing _id": FX["internal_id"], "owner id": FX["owner"],
        "live member 1": FX["live1"], "live member 2": FX["live2"], "dead member id": FX["dead"],
        "junk member id": FX["junk"], "username": f"sensitive_user_{RUN}", "email": f"sensitive_{RUN}@secret-mail",
        "invite token hash": FX["token_hash"], "group title": f"SecretGroupTitle{RUN}",
        "description_text": f"SECRETDESCRIPTION{RUN}", "block leak url": f"leak.example/{RUN}",
        "unknown-type block text": "unknown type text",
    }
    sensitive = {k: v.lower() for k, v in sensitive.items()}
    bodies = {}
    r = get(cli, "/explorer/listings", q=MARK, limit=2, include_full="true")
    check("list 200", r.status_code == 200, r.text[:200])
    p1 = r.json()
    bodies["list page 1"] = p1
    page = p1["page"]
    r2 = get(cli, "/explorer/listings", q=MARK, limit=2, include_full="true",
             cursor_timestamp=page["next_cursor_timestamp"], cursor_id=page["next_cursor_id"])
    bodies["list page 2"] = r2.json()
    r = get(cli, f"/explorer/listings/{FX['main_pid']}")
    check("detail 200", r.status_code == 200, r.text[:200])
    bodies["detail"] = r.json()
    bodies["filters"] = get(cli, "/explorer/filters").json()
    bodies["list all"] = get(cli, "/explorer/listings", q=MARK, limit=24, include_full="true").json()
    for name, body in bodies.items():
        keys, strs = set(), []
        walk_keys_values(body, keys, strs)
        blob = json.dumps(body).lower()
        hits = [k for k, v in sensitive.items() if v in blob]
        check(f"{name}: no sensitive value anywhere", not hits, hits)
        check(f"{name}: no _id / group_id / user key", not [k for k in keys if k in (
            "_id", "id", "group_id", "listing_id", "creator_id", "owner_id", "users", "members", "email",
            "username", "user_id", "invite", "token", "description_text", "banner_key", "photo_key")], keys)
    check("page 1 next_cursor_id is a 10-char public_id and cursor_seq is null",
          page["next_cursor_id"] in ids(p1) and len(page["next_cursor_id"]) == 10
          and page["next_cursor_seq"] is None, page)
    check("cursor fields are exactly the three public ones",
          set(page) == {"limit", "has_more", "next_cursor_timestamp", "next_cursor_seq", "next_cursor_id"}, set(page))
    check("list card keys are exactly the allowlist",
          all(set(c) == set(explorer_public.ListingCard.model_fields) for c in bodies["list all"]["listings"]))
    check("detail keys are card + description_blocks + requestable",
          set(bodies["detail"]) == set(explorer_public.ListingDetail.model_fields))
    blocks = bodies["detail"]["description_blocks"]
    check("detail blocks: text only, rebuilt to exactly {type,text}, unknown dropped",
          blocks == [{"type": "text", "text": "Hello block"}, {"type": "text", "text": "Second block"}], blocks)
    for model in (explorer_public.ListingCard, explorer_public.ListingDetail, explorer_public.ListingPage,
                  explorer_public.PageInfo, explorer_public.PublicFilters, explorer_public.FilterLimits,
                  explorer_public.VocabOption):
        check(f"{model.__name__} is extra=forbid", model.model_config.get("extra") == "forbid")
    try:
        explorer_public.ListingCard(**{**bodies["list all"]["listings"][0], "group_id": FX["gid"]})
        ok = False
    except ValidationError:
        ok = True
    check("a card cannot be constructed with a group_id", ok)
    fields = set(explorer_public.ListingDetail.model_fields)
    check("no model has a members / email / group field",
          not (fields & {"group_id", "members", "users", "email", "username", "owner", "creator_id", "_id"}))
    f = bodies["filters"]
    check("filters expose no consent / owner limits / DB values",
          set(f) == {"vocab", "countries", "size_buckets", "limits", "support_email"}
          and "consent_version" not in json.dumps(f) and "per_owner_cap" not in json.dumps(f))
    check("size bucket labels come from config", f["size_buckets"] == [
        label for _m, label in get_listings_config().size_buckets], f["size_buckets"])
    check("filters vocab keys are the public ten",
          set(f["vocab"]) == set(listings_public.PUBLIC_VOCAB_KEYS), set(f["vocab"]))
    del g2


# -- 2. flag fail closed -----------------------------------------------------------------

def test_flag(cli):
    print("explorer_browse fail closed, uniform 404, config probe")
    set_flag_sql("explorer_browse", "off")
    try:
        missing = get(cli, "/explorer/listings/ZZZZZZZZZZ")
        on_off = {
            "list": get(cli, "/explorer/listings"),
            "detail": get(cli, f"/explorer/listings/{FX['main_pid']}"),
            "filters": get(cli, "/explorer/filters"),
            "missing": missing,
        }
        for name, r in on_off.items():
            check(f"flag off: {name} is the uniform 404", r.status_code == 404 and r.json() == NOT_FOUND,
                  (r.status_code, r.text[:120]))
        check("flag off: 404 bodies byte-identical", len({r.text for r in on_off.values()}) == 1)
        r = get(cli, "/explorer/config")
        check("config off: 200 {browse:false}", r.status_code == 200 and r.json() == {"browse": False}, r.text)
        check("flag off: no public Cache-Control on a 404", "public" not in (on_off["list"].headers.get(
            "cache-control") or ""))
        # flag read raising -> fail closed
        real = flags.is_enabled
        set_flag_sql("explorer_browse", "on")
        flags.is_enabled = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("db down"))
        try:
            r = get(cli, "/explorer/listings")
            check("flag read raising: uniform 404 not 5xx", r.status_code == 404 and r.json() == NOT_FOUND, r.status_code)
            r = get(cli, "/explorer/config")
            check("flag read raising: config still 200 {browse:false}",
                  r.status_code == 200 and r.json() == {"browse": False}, (r.status_code, r.text))
        finally:
            flags.is_enabled = real
    finally:
        set_flag_sql("explorer_browse", "on")
    r = get(cli, "/explorer/config")
    check("config on: 200 {browse:true}", r.status_code == 200 and r.json() == {"browse": True}, r.text)
    r = get(cli, "/explorer/listings", q=MARK)
    check("flag on: list 200", r.status_code == 200)
    r = get(cli, "/explorer/listings/ZZZZZZZZZZ")
    check("flag on: missing listing is the same uniform 404 body", r.status_code == 404 and r.json() == NOT_FOUND)


def test_cache_control(cli):
    print("Cache-Control")
    for path in ("/explorer/listings", f"/explorer/listings/{FX['main_pid']}", "/explorer/filters"):
        r = get(cli, path)
        check(f"{path.split('/')[2]}: 200 carries public, max-age=60",
              r.status_code == 200 and r.headers.get("cache-control") == "public, max-age=60", r.headers.get("cache-control"))
    r = get(cli, "/explorer/listings", limit="abc")
    check("422 carries no public cache header", r.status_code == 422 and "public" not in (r.headers.get("cache-control") or ""))
    r = get(cli, "/explorer/listings/ZZZZZZZZZZ")
    check("404 carries no public cache header", r.status_code == 404 and "public" not in (r.headers.get("cache-control") or ""))
    r = get(cli, "/explorer/config")
    check("config has its own Cache-Control", "max-age" in (r.headers.get("cache-control") or ""))


# -- 3. validation ------------------------------------------------------------------------

def test_validation(cli):
    print("validation: 422 before any SQL, no value echoed")

    @contextmanager
    def no_sql():
        real = public_guard.public_connection

        def boom(*a, **k):
            raise AssertionError("SQL attempted for an invalid request")
        public_guard.public_connection = boom
        try:
            yield
        finally:
            public_guard.public_connection = real

    cfg = get_listings_config()
    deno = cfg.vocab["denominations"][0][0]
    cases = [
        ("unknown vocab slug", dict(denominations="notaslug"), "denominations"),
        ("unknown slug among valid", dict(goals=f"{cfg.vocab['goals'][0][0]},bogus"), "goals"),
        ("unknown country", dict(country="ZZ"), "country"),
        ("country not 2 letters", dict(country="USA"), "country"),
        ("too many facet values", dict(hobbies=",".join(s for s, _l in cfg.vocab["hobbies"][:cfg.max_facet_values + 1])), "hobbies"),
        ("q too long", dict(q="a" * (cfg.q_max_length + 1)), "q"),
        ("q with control char", dict(q="bad\x01char"), "q"),
        ("q with NUL", dict(q="bad\x00char"), "q"),
        ("city with control char", dict(city="Aus\ttin"), "city"),
        ("region too long", dict(region="r" * (cfg.region_max_length + 1)), "region"),
        ("limit not a number", dict(limit="abc"), "limit"),
        ("limit negative", dict(limit="-1"), "limit"),
        ("limit float", dict(limit="1.5"), "limit"),
        ("limit 7 digits", dict(limit="1234567"), "limit"),
        ("include_full junk", dict(include_full="maybe"), "include_full"),
    ]
    for label, params, field in cases:
        with no_sql():
            r = get(cli, "/explorer/listings", **params)
        body = r.json()
        echoed = any(str(v) in r.text for v in params.values() if len(str(v)) > 3)
        check(f"{label}: 422 invalid_filter naming {field}",
              r.status_code == 422 and body["detail"] == {"code": "invalid_filter", "field": field} and not echoed,
              (r.status_code, r.text[:160]))
    ts = "2026-01-01T00:00:00Z"
    cursor_cases = [
        ("timestamp without id", dict(cursor_timestamp=ts)),
        ("id without timestamp", dict(cursor_id="AbCdEfGh12")),
        ("uuid cursor_id", dict(cursor_timestamp=ts, cursor_id=str(uuid.uuid4()))),
        ("cursor_id with illegal characters", dict(cursor_timestamp=ts, cursor_id="AbCdEf'; --")),
        ("cursor_id 9 chars", dict(cursor_timestamp=ts, cursor_id="AbCdEfGh1")),
        ("cursor_id 11 chars", dict(cursor_timestamp=ts, cursor_id="AbCdEfGh123")),
        ("cursor_seq not allowed", dict(cursor_timestamp=ts, cursor_id="AbCdEfGh12", cursor_seq="1")),
        ("bad timestamp", dict(cursor_timestamp="yesterday", cursor_id="AbCdEfGh12")),
        ("naive timestamp", dict(cursor_timestamp="2026-01-01T00:00:00", cursor_id="AbCdEfGh12")),
    ]
    for label, params in cursor_cases:
        with no_sql():
            r = get(cli, "/explorer/listings", **params)
        check(f"cursor {label}: 422 invalid_cursor",
              r.status_code == 422 and r.json()["detail"] == {"code": "invalid_cursor"}, (r.status_code, r.text[:160]))
    with no_sql():
        r = get(cli, "/explorer/listings", gender_makeup="a,b")
    check("two values for a single-valued facet: 422", r.status_code == 422, r.status_code)
    # detail ids that cannot be public ids: uniform 404 before SQL
    for bad in ("short", "AbCdEfGh1!", "A" * 11, "%27%3B--", "AbCdEfGh12%00"):
        with no_sql():
            r = get(cli, f"/explorer/listings/{bad}")
        check(f"detail id {bad!r}: uniform 404 before SQL", r.status_code == 404 and r.json() == NOT_FOUND, r.status_code)
    # lenient bits
    r = get(cli, "/explorer/listings", unknown_param="x", q=MARK)
    check("unknown query params are ignored", r.status_code == 200)
    r = get(cli, "/explorer/listings", limit="100", q=MARK)
    check("limit above max clamps to page_size_max", r.status_code == 200 and r.json()["page"]["limit"] == cfg.page_size_max)
    r = get(cli, "/explorer/listings", limit="0", q=MARK)
    check("limit 0 clamps to 1", r.status_code == 200 and r.json()["page"]["limit"] == 1 and len(r.json()["listings"]) <= 1)
    r = get(cli, "/explorer/listings", q=MARK)
    check("default limit is page_size_default", r.json()["page"]["limit"] == cfg.page_size_default)
    r = get(cli, "/explorer/listings", q="   ")
    check("blank q is no filter", r.status_code == 200)
    r = get(cli, "/explorer/listings", denominations=f" {deno} ,{deno}", q=MARK)
    check("whitespace and duplicate slugs tolerated", r.status_code == 200, r.text[:100])
    del deno


# -- 4. filters, q, order, pagination, visibility, members ---------------------------------

def test_filters_and_search(cli):
    print("filters, q, ordering, pagination")
    cfg = get_listings_config()
    vocab = {k: [s for s, _l in v] for k, v in cfg.vocab.items()}
    owner = make_user()
    base = FX["base"] + timedelta(days=1)

    def mk(**kw):
        return make_listing(make_group(owner, []), **kw)

    a = mk(published_at=base + timedelta(minutes=1), title="Alpha", denominations=[vocab["denominations"][0]],
           goals=[vocab["goals"][0]], country="CA", region="Ontario", city="Toronto", hobbies=["chess"],
           gender_makeup=vocab["gender_makeup"][0], free_tags=["lemonade"])
    b = mk(published_at=base + timedelta(minutes=2), title="Bravo", denominations=[vocab["denominations"][1]],
           goals=[vocab["goals"][0], vocab["goals"][1]], country="CA", region="Ontario", city="Ottawa",
           hobbies=["running"], gender_makeup=vocab["gender_makeup"][1])
    c = mk(published_at=base + timedelta(minutes=3), title="Charlie", denominations=[vocab["denominations"][0], vocab["denominations"][1]],
           goals=[vocab["goals"][1]], country="US", region="Ohio", city="Toledo", hobbies=["chess", "running"],
           meeting_format=vocab["meeting_formats"][0], frequency=vocab["frequencies"][0])
    d = mk(published_at=base + timedelta(minutes=4), title="Delta uniqueword", denominations=None, goals=None,
           country="US", region="Oregon", city="Portland")
    allp = {a, b, c, d}

    def lst(**params):
        r = get(cli, "/explorer/listings", q=params.pop("q", MARK), **params)
        assert r.status_code == 200, (r.status_code, r.text[:200])
        return [p for p in ids(r.json()) if p in allp]

    d0, d1 = vocab["denominations"][0], vocab["denominations"][1]
    g0, g1 = vocab["goals"][0], vocab["goals"][1]
    check("scoping by marker returns all four newest first", lst() == [d, c, b, a], lst())
    check("one denomination matches any listing containing it", set(lst(denominations=d0)) == {a, c})
    check("two denominations in one facet are OR", set(lst(denominations=f"{d0},{d1}")) == {a, b, c})
    check("repeated parameter form is the same OR", set(lst(denominations=[d0, d1])) == {a, b, c})
    check("two facets are AND", set(lst(denominations=d0, goals=g1)) == {c}, lst(denominations=d0, goals=g1))
    check("AND across facets can be empty", lst(denominations=d0, country="US", goals=g0) == [])
    check("array facet value inside a multi-valued row matches", set(lst(goals=g1)) == {b, c})
    check("country filter", set(lst(country="ca")) == {a, b})
    check("single-valued facet gender_makeup", set(lst(gender_makeup=vocab["gender_makeup"][0])) == {a})
    check("meeting_format + frequency", set(lst(meeting_format=vocab["meeting_formats"][0],
                                                frequency=vocab["frequencies"][0])) == {c})
    check("region prefix, case-insensitive", set(lst(region="ont")) == {a, b} and set(lst(region="OREG")) == {d})
    check("city prefix", set(lst(city="to")) == {a, c} and set(lst(city="ott")) == {b}, lst(city="to"))
    check("LIKE wildcards in region are literal", lst(region="%") == [] and lst(region="O_") == [])
    check("q by listing title word", lst(q=f"{MARK} uniqueword") == [d])
    check("q by free tag", lst(q=f"{MARK} lemonade") == [a])
    check("q by hobby", set(lst(q=f"{MARK} chess")) == {a, c})
    check("q by city", lst(q=f"{MARK} toledo") == [c])
    check("q AND facet", lst(q=f"{MARK} chess", country="US") == [c])
    check("q with no matches is empty 200", lst(q="nonexistentwordzzz") == [])
    for weird in ("a & b | !c", "(:*)", "x' OR 1=1 --", "\\", "%", "*:"):
        r = get(cli, "/explorer/listings", q=weird)
        check(f"q operators/injection text {weird!r} is plain text (200, not 5xx)", r.status_code == 200, r.status_code)

    # ordering with a timestamp tie, then a full walk
    tie_ts = base + timedelta(hours=5)
    t1, t2, t3 = (mk(published_at=tie_ts, title=f"Tie {i}") for i in range(3))
    expected = [r[0] for r in q("SELECT public_id FROM group_listings WHERE public_id = ANY(%s) "
                                "ORDER BY public_id DESC", ([t1, t2, t3],))]
    r = get(cli, "/explorer/listings", q=f"{MARK} tie", limit=24)
    got = [p for p in ids(r.json()) if p in {t1, t2, t3}]
    check("equal published_at tie-breaks on public_id DESC", got == expected, (got, expected))
    full_expected = [p for p in ids(get(cli, "/explorer/listings", q=MARK, limit=24).json())]
    walked, cursor, pages = [], {}, 0
    while True:
        r = get(cli, "/explorer/listings", q=MARK, limit=2, include_full="false", **cursor)
        body = r.json()
        walked += ids(body)
        pages += 1
        if not body["page"]["has_more"]:
            check("last page has next_cursor_* null", body["page"]["next_cursor_id"] is None
                  and body["page"]["next_cursor_timestamp"] is None)
            break
        cursor = {"cursor_timestamp": body["page"]["next_cursor_timestamp"], "cursor_id": body["page"]["next_cursor_id"]}
        if pages > 60:
            break
    # compare with the db ordering for all visible rows of this run
    db_order = [r[0] for r in q(
        "SELECT gl.public_id FROM group_listings gl JOIN groups g ON g._id = gl.group_id "
        f"WHERE gl.title LIKE %s AND {listings.public_where('gl')} "
        "AND (g.max_members IS NULL OR g.max_members > 99) ORDER BY gl.published_at DESC, gl.public_id DESC",
        (f"{MARK}%",))]
    check("a cursor walk returns every row once, in keyset order", walked == db_order and len(set(walked)) == len(walked),
          (len(walked), len(db_order)))
    check("limit=2 pages hold at most 2 and there were several", pages >= 3)
    check("no total count anywhere in the page", set(get(cli, "/explorer/listings", q=MARK).json()) == {"listings", "page"})
    del full_expected


def test_visibility(cli):
    print("visibility: only published + present owner")
    owner = make_user()
    pids = {}
    for st in ("draft", "pending_review", "unpublished", "hidden", "rejected"):
        pids[st] = make_listing(make_group(owner, []), status=st, title=f"Vis {st}")
    susp = make_user(suspended=True)
    pids["suspended owner"] = make_listing(make_group(susp, []), title="Vis susp")
    gone = make_user()
    pids["owner left group"] = make_listing(make_group(gone, [], creator_member=False), title="Vis gone")
    pids["published"] = make_listing(make_group(owner, []), title="Vis ok")
    body = get(cli, "/explorer/listings", q=f"{MARK} vis", limit=24).json()
    got = set(ids(body))
    check("published listing is visible", pids["published"] in got)
    for k, pid in pids.items():
        if k == "published":
            continue
        check(f"{k}: not in list", pid not in got)
        r = get(cli, f"/explorer/listings/{pid}")
        check(f"{k}: detail is the uniform 404", r.status_code == 404 and r.json() == NOT_FOUND, r.status_code)
    r = get(cli, f"/explorer/listings/{pids['published']}")
    check("published detail 200", r.status_code == 200)


def test_members(cli):
    print("members: dead / junk / duplicate ids are not counted")
    cfg = get_listings_config()
    buckets = list(cfg.size_buckets)
    check("config size buckets are 2-5, 6-10, 11-20, 21+ (architecture text says 20+, config wins)",
          [l for _m, l in buckets] == ["2-5", "6-10", "11-20", "21+"], buckets)
    owner = make_user()
    live = [make_user() for _ in range(6)]
    dead = [str(uuid.uuid4()) for _ in range(5)]
    junk = ["", "x", f"junk-{RUN}", "00000000-0000-0000-0000-00000000000g"]

    def grp(members, mx=None):
        return make_group(owner, members, max_members=mx)

    # 2 live (owner + 1) + 5 dead + 4 junk + duplicates must be bucket 2-5
    g1 = grp([live[0]] + dead + junk + [live[0], live[0].upper()])
    p1 = make_listing(g1, title="Mem small")
    # owner + 5 live = 6 -> 6-10
    g2 = grp(live[:5])
    p2 = make_listing(g2, title="Mem six")
    # max_members 3, 2 live + 3 dead: not full (dead not counted)
    g3 = grp([live[0]] + dead[:3], mx=3)
    p3 = make_listing(g3, title="Mem notfull")
    # max_members 2 with 2 live: full
    g4 = grp([live[0]], mx=2)
    p4 = make_listing(g4, title="Mem full", accepting_requests=True)
    # max_members 4, 3 live ids + 1 dead (+ dupes): 3 live < 4 -> open
    g5 = grp([live[0], live[1], dead[0], live[1]], mx=4)
    p5 = make_listing(g5, title="Mem open4", accepting_requests=True)
    body = get(cli, "/explorer/listings", q=f"{MARK} mem", limit=24).json()
    cards = {c["public_id"]: c for c in body["listings"]}
    check("dead+junk+duplicate ids do not move the bucket (2-5)", cards.get(p1, {}).get("size_bucket") == "2-5", cards.get(p1))
    check("six live members -> 6-10", cards.get(p2, {}).get("size_bucket") == "6-10", cards.get(p2))
    check("max_members counted over live members: dead ids do not make it full",
          p3 in cards and cards[p3]["seats"] == "open", cards.get(p3))
    check("a full group is hidden by default", p4 not in cards)
    check("not-yet-full group with dupes/dead is shown open", cards.get(p5, {}).get("seats") == "open")
    body = get(cli, "/explorer/listings", q=f"{MARK} mem", limit=24, include_full="true").json()
    cards = {c["public_id"]: c for c in body["listings"]}
    check("include_full=true shows the full group with seats=full", cards.get(p4, {}).get("seats") == "full", cards.get(p4))
    r = get(cli, f"/explorer/listings/{p4}").json()
    check("detail of a full group: seats full, requestable false", r["seats"] == "full" and r["requestable"] is False, r)
    r = get(cli, f"/explorer/listings/{p5}").json()
    check("detail of an accepting open group: requestable true, size bucket 2-5", r["requestable"] is True and r["size_bucket"] == "2-5", r)
    r = get(cli, f"/explorer/listings/{p1}").json()
    check("detail of a non-accepting group: requestable false", r["requestable"] is False)
    # 21+ bucket via DB-level members
    many = [make_user() for _ in range(21)]
    g6 = make_group(owner, many)
    p6 = make_listing(g6, title="Mem huge")
    r = get(cli, f"/explorer/listings/{p6}").json()
    check("22 live members -> top bucket 21+", r["size_bucket"] == "21+", r["size_bucket"])


# -- 5. limits, run_public, timeouts ---------------------------------------------------------

def test_run_public_and_limits(cli):
    print("run_public usage, per-IP limits, global backstop, timeouts")
    tree = ast.parse(open(os.path.join(API_DIR, "routes/explorer.py")).read())
    handlers = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.AsyncFunctionDef)}
    for name, impl in (("public_filters", "get_filters"), ("public_list", "list_listings"),
                       ("public_detail", "get_listing")):
        fn = handlers.get(name)
        ok = fn is not None
        awaited = False
        if ok:
            for n in ast.walk(fn):
                if isinstance(n, ast.Await) and isinstance(n.value, ast.Call):
                    f = n.value.func
                    if isinstance(f, ast.Attribute) and f.attr == "run_public" and any(
                            isinstance(a, ast.Attribute) and a.attr == impl for a in n.value.args):
                        awaited = True
        check(f"{name} is async def and awaits public_guard.run_public({impl})", ok and awaited)
    src = open(os.path.join(API_DIR, "backend/interactions/listings_public.py")).read()
    lp = ast.parse(src)
    check("listings_public holds only sync impls (no async def, never calls DBManager)",
          not [n for n in ast.walk(lp) if isinstance(n, ast.AsyncFunctionDef)]
          and not [n for n in ast.walk(lp) if isinstance(n, ast.Name) and n.id == "DBManager"])

    cfg = get_listings_config()
    # per-IP limit
    limiter.reset()
    n_list = int(cfg.rate_limits["list"].split("/")[0])
    codes = [cli.get("/explorer/listings", params={"q": MARK}).status_code for _ in range(n_list + 1)]
    check(f"list: {n_list} per minute per IP then 429", codes[:n_list] == [200] * n_list and codes[n_list] == 429, codes[-3:])
    limiter.reset()
    n_det = int(cfg.rate_limits["detail"].split("/")[0])
    codes = [cli.get(f"/explorer/listings/{FX['main_pid']}").status_code for _ in range(n_det + 1)]
    check(f"detail: {n_det} per minute per IP then 429", codes[:n_det] == [200] * n_det and codes[n_det] == 429, codes[-3:])
    limiter.reset()
    n_cfg = int(cfg.rate_limits["config"].split("/")[0])
    codes = [cli.get("/explorer/filters").status_code for _ in range(n_cfg + 1)]
    check(f"filters (config bucket): {n_cfg} per minute then 429", codes[:n_cfg] == [200] * n_cfg and codes[n_cfg] == 429, codes[-3:])
    limiter.reset()

    # global backstop (key-less): tiny limit via patched config
    real = explorer_routes.get_listings_config
    tiny = dataclasses.replace(cfg, public_global_rate_limit="3/minute")
    explorer_routes.get_listings_config = lambda: tiny
    try:
        limiter.reset()
        codes = [cli.get(p).status_code for p in ("/explorer/config", "/explorer/filters", "/explorer/listings",
                                                   "/explorer/config", "/explorer/filters")]
        check("global backstop is shared across the public routes (3 then 429)", codes == [200, 200, 200, 429, 429], codes)
        r = cli.get("/explorer/listings")
        check("global backstop 429 is not a 5xx", r.status_code == 429)
    finally:
        explorer_routes.get_listings_config = real
        limiter.reset()

    # run_public before configure
    public_guard.reset_for_tests()
    try:
        r = None
        try:
            asyncio.run(public_guard.run_public(lambda: 1))
        except RuntimeError as e:
            r = str(e)
        check("run_public before configure raises RuntimeError (no hidden defaults)", r is not None, r)
    finally:
        reconfigure_guard()

    # statement timeout -> 429 busy + Retry-After
    real_impl = listings_public.list_listings

    def slow_sql(query_params):
        with public_guard.public_connection(50) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT pg_sleep(2)")
        return None

    listings_public.list_listings = slow_sql
    try:
        t0 = time.monotonic()
        r = get(cli, "/explorer/listings")
        dt = time.monotonic() - t0
        check("statement timeout: 429 {code: busy} with Retry-After, not 5xx",
              r.status_code == 429 and r.json()["detail"] == {"code": "busy"} and r.headers.get("retry-after", "").isdigit(),
              (r.status_code, r.text, dict(r.headers)))
        check("statement timeout returned promptly (< 1.5 s)", dt < 1.5, dt)
    finally:
        listings_public.list_listings = real_impl
    # connections are not leaked by the timeout path
    r = get(cli, "/explorer/listings", q=MARK)
    check("service healthy after a timeout", r.status_code == 200)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def test_isolation():
    print("isolation: saturated public pool does not starve the shared threadpool (real server, loopback)")
    cfg = get_listings_config()
    limiter.reset()
    public_guard.reset_for_tests()
    listings_config.validate_listings_config()
    conc, wait = cfg.public_concurrency, cfg.public_max_waiting
    total = 30
    reader, other = make_user(), make_user()
    cookie = hdr(reader)["cookie"]
    q("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s) ON CONFLICT DO NOTHING",
      (reader, other, other, reader), fetch=False)
    port = free_port()
    server = uvicorn.Server(uvicorn.Config(main_module.app, host="127.0.0.1", port=port, lifespan="off", log_level="warning"))
    th = threading.Thread(target=server.run, daemon=True)
    th.start()
    for _ in range(100):
        if server.started:
            break
        time.sleep(0.05)
    check("loopback server started", server.started)
    base = f"http://127.0.0.1:{port}"

    SLEEP = 1.2

    def slow_list(qp):
        time.sleep(SLEEP)
        return listings_public.ListingPage(listings=[], page=listings_public.PageInfo(
            limit=1, has_more=False, next_cursor_timestamp=None, next_cursor_id=None))

    def slow_detail(pid):
        time.sleep(SLEEP)
        raise listings_public._not_found()

    def slow_filters():
        time.sleep(SLEEP)
        return listings_public.filters_payload(get_listings_config())

    saved = (listings_public.list_listings, listings_public.get_listing, listings_public.get_filters)
    listings_public.list_listings, listings_public.get_listing, listings_public.get_filters = slow_list, slow_detail, slow_filters
    results = []
    lock = threading.Lock()
    t_start = time.monotonic()

    def call(i):
        path = ("/explorer/listings", f"/explorer/listings/{FX['main_pid']}", "/explorer/filters")[i % 3]
        t0 = time.monotonic()
        try:
            r = httpx.get(base + path, timeout=15, trust_env=False)
            rec = (r.status_code, time.monotonic() - t0, r.headers.get("retry-after"), r.text)
        except Exception as e:  # noqa: BLE001
            rec = (f"ERR {e!r}", time.monotonic() - t0, None, "")
        with lock:
            results.append(rec)

    out = {}
    try:
        threads = [threading.Thread(target=call, args=(i,)) for i in range(total)]
        for t in threads:
            t.start()
        time.sleep(0.4)  # every public call is now running or queued
        t0 = time.monotonic()
        r = httpx.get(base + "/app/capabilities", headers={"cookie": cookie}, timeout=5, trust_env=False)
        out["cap"] = (r.status_code, time.monotonic() - t0)
        # WebSocket echo: reader -> other round trip (other receives reader's message)
        from websockets.sync.client import connect
        t0 = time.monotonic()
        try:
            with connect(f"ws://127.0.0.1:{port}/message/ws/{reader}", additional_headers={"cookie": cookie}, open_timeout=5, proxy=None) as ws_a:
                other_cookie = hdr(other)["cookie"]
                with connect(f"ws://127.0.0.1:{port}/message/ws/{other}", additional_headers={"cookie": other_cookie}, open_timeout=5, proxy=None) as ws_b:
                    time.sleep(0.15)
                    ws_a.send(json.dumps({"type": "chat", "to_users": [other], "text": f"hi {RUN}", "group_id": None,
                                          "timestamp": datetime.now(timezone.utc).isoformat()}))
                    got = ws_b.recv(timeout=3)
                    out["ws"] = (True, time.monotonic() - t0, got)
        except Exception as e:  # noqa: BLE001
            out["ws"] = (False, time.monotonic() - t0, repr(e))
        for t in threads:
            t.join(20)
    finally:
        listings_public.list_listings, listings_public.get_listing, listings_public.get_filters = saved
        server.should_exit = True
        th.join(10)
        q("DELETE FROM messages WHERE from_user = ANY(%s::uuid[])", ([reader, other],), fetch=False)
        q("DELETE FROM user_friends WHERE user_id = ANY(%s::uuid[]) OR friend_id = ANY(%s::uuid[])",
          ([reader, other], [reader, other]), fetch=False)
    codes = [r[0] for r in results]
    shed = [r for r in results if r[0] == 429]
    ok_ = [r for r in results if r[0] == 200 or r[0] == 404]
    expect_shed = total - (conc + wait)
    check("all 30 calls completed", len(results) == total, len(results))
    check("no response in the run is a 5xx or a transport error",
          all(isinstance(c, int) and c < 500 for c in codes), sorted(set(map(str, codes))))
    check(f"excess calls are shed as 429 (expected {expect_shed})", len(shed) == expect_shed, (len(shed), sorted(set(map(str, codes)))))
    check("every shed response is busy with Retry-After 1..5",
          all('"busy"' in r[3] and r[2] and r[2].isdigit() and 1 <= int(r[2]) <= 5 for r in shed),
          [(r[2], r[3][:60]) for r in shed][:2])
    check("shed responses return quickly (< 0.8 s, well before the first slow call ends)",
          all(r[1] < 0.8 for r in shed), [round(r[1], 2) for r in shed])
    check(f"admitted calls ran ({conc + wait} of them)", len(ok_) == conc + wait, len(ok_))
    check("GET /app/capabilities answers 200 within 1 s while the public pool is saturated",
          out["cap"][0] == 200 and out["cap"][1] < 1.0, out["cap"])
    check("WebSocket round trip within 1 s while the public pool is saturated",
          out["ws"][0] and out["ws"][1] < 1.0, out["ws"])
    check("the public pool really was busy at that moment (admitted calls still running)",
          min(r[1] for r in ok_) >= SLEEP - 0.05, round(min(r[1] for r in ok_), 2))
    limiter.reset()


# -- 6. logs --------------------------------------------------------------------------------

def test_logs(cli):
    print("no listing text, filter values or cursor values in logs")
    secret_q = f"logsecret{RUN}"
    with catch_logs() as lg:
        get(cli, "/explorer/listings", q=secret_q, region=f"RegionSecret{RUN}", cursor_timestamp="2026-01-01T00:00:00Z",
            cursor_id="LogCursor12")
        get(cli, "/explorer/listings", q=secret_q, denominations=f"bogus{RUN}")
        get(cli, f"/explorer/listings/{FX['main_pid']}")
        get(cli, "/explorer/filters")
    leaked = [m for lv, m in lg.records if RUN in m and RUN != "" and (secret_q in m or "RegionSecret" in m
              or "LogCursor12" in m or "Main Rich" in m or "SECRETDESCRIPTION" in m)]
    check("no q / region / cursor / listing text in any log line", not leaked, leaked[:2])
    check("no ERROR lines from public reads", not [m for lv, m in lg.records if lv == "ERROR"], [m for lv, m in lg.records if lv == "ERROR"][:2])


# -- 7. EXPLAIN with 5,000 seeded listings ------------------------------------------------------

class _CountingCursor:
    def __init__(self, cur, log):
        self._cur, self._log = cur, log

    def execute(self, sql, params=None):
        self._log.append((sql, params))
        return self._cur.execute(sql, params)

    def __getattr__(self, name):
        return getattr(self._cur, name)

    def __enter__(self):
        self._cur.__enter__()
        return self

    def __exit__(self, *a):
        return self._cur.__exit__(*a)


class _CountingConn:
    def __init__(self, conn, log):
        self._conn, self._log = conn, log

    def cursor(self, *a, **k):
        return _CountingCursor(self._conn.cursor(*a, **k), self._log)

    def __getattr__(self, name):
        return getattr(self._conn, name)


@contextmanager
def capture_sql():
    """Wrap public_guard.public_connection so every statement the impl runs on the
    yielded connection is recorded (the SET LOCAL timeout is issued before the yield)."""
    log = []
    real = public_guard.public_connection

    @contextmanager
    def wrapped(ms):
        with real(ms) as conn:
            yield _CountingConn(conn, log)

    public_guard.public_connection = wrapped
    try:
        yield log
    finally:
        public_guard.public_connection = real


def explain(sql, params, seqscan_off, no_plain_indexscan=False):
    db = DBManager()
    try:
        cur = db.cur
        if seqscan_off:
            cur.execute("SET enable_seqscan = off")
        if no_plain_indexscan:
            cur.execute("SET enable_indexscan = off")
        cur.execute("EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) " + sql, params)
        plan = "\n".join(r[0] for r in cur.fetchall())
        db.conn.rollback()
        return plan
    finally:
        db.close()


def test_explain(cli):
    print("EXPLAIN with 5,000 seeded listings")
    N = 5000
    owner = make_user()
    live = [make_user() for _ in range(20)]
    q("""
        INSERT INTO groups (_id, title, users, creator_id)
        SELECT gen_random_uuid(), %s || '-' || i, ARRAY[%s::text, %s::text, %s::text], %s::uuid
        FROM generate_series(1, %s) i
    """, (f"xpbulk{RUN}", owner, live[0], live[1], owner, N), fetch=False)
    # chars used for public ids: hex of md5 is alphanumeric
    q("""
        INSERT INTO group_listings (public_id, group_id, status, title, summary, hobbies, free_tags, goals, country,
                                    city, city_norm, description_text, published_at)
        SELECT substr(md5(g._id::text), 1, 10), g._id, 'published',
               %s || ' bulk ' || row_number() OVER (), 'summary text',
               ARRAY[(ARRAY['hiking','running','cooking','board_games','music'])[1 + (row_number() OVER ())::int %% 5]],
               CASE WHEN (row_number() OVER ()) %% 1000 = 0 THEN ARRAY['rarebulkword' || %s] ELSE ARRAY['common'] END,
               CASE WHEN (row_number() OVER ()) %% 50 = 0 THEN ARRAY['bible_study'] ELSE NULL END,
               'US', 'City', 'city',
               'common description words',
               NOW() - (row_number() OVER ()) * interval '1 second'
        FROM groups g WHERE g.title LIKE %s
    """, (f"{MARK}", RUN, f"xpbulk{RUN}-%"), fetch=False)
    n = q("SELECT count(*) FROM group_listings WHERE title LIKE %s", (f"{MARK} bulk %",))[0][0]
    check("5,000 listings seeded", n == N, n)
    # VACUUM flushes the GIN pending list (otherwise its cost is inflated right after a bulk
    # insert and the plan depends on whether autovacuum already ran) and sets the visibility map.
    db = DBManager()
    try:
        db.conn.autocommit = True
        for t in ("group_listings", "groups", "users"):
            db.cur.execute(f"VACUUM (ANALYZE) {t}")
    finally:
        db.close()
    # statement counts: page of 2 vs page of 24
    with capture_sql() as log2:
        r2 = get(cli, "/explorer/listings", q=f"{MARK} bulk", limit=2)
    with capture_sql() as log24:
        r24 = get(cli, "/explorer/listings", q=f"{MARK} bulk", limit=24)
    check("page of 2 and page of 24 both 200 with the right sizes",
          r2.status_code == 200 and len(r2.json()["listings"]) == 2 and r24.status_code == 200
          and len(r24.json()["listings"]) == 24, (r2.status_code, r24.status_code))
    print(f"      statements: limit=2 -> {len(log2)}, limit=24 -> {len(log24)}")
    check("a page of 24 issues the same number of statements as a page of 2", len(log2) == len(log24) and len(log2) >= 1,
          (len(log2), len(log24)))
    check("exactly one list SELECT per request (member counts are inside it)", len(log24) == 1, len(log24))
    check("no per-row member count helper / unnest in the list SQL source",
          "live_member_count" not in open(os.path.join(API_DIR, "backend/interactions/listings_public.py")).read().split(
              "def list_listings")[1].split("def get_listing")[0])

    queries = {}
    with capture_sql() as lg:
        get(cli, "/explorer/listings", limit=12)
    queries["filter-only keyset (first page)"] = lg[0]
    with capture_sql() as lg:
        page = get(cli, "/explorer/listings", limit=12).json()["page"]
        get(cli, "/explorer/listings", limit=12, cursor_timestamp=page["next_cursor_timestamp"], cursor_id=page["next_cursor_id"])
    queries["keyset second page"] = lg[1]
    with capture_sql() as lg:
        get(cli, "/explorer/listings", q=f"rarebulkword{RUN}", limit=12)
    queries["q (rare word)"] = lg[0]
    with capture_sql() as lg:
        get(cli, "/explorer/listings", goals="bible_study", hobbies="hiking,running", limit=12)
    queries["facet filters (GIN &&)"] = lg[0]
    plans = {}
    for name, (sql, params) in queries.items():
        default_plan = explain(sql, params, False)
        off_plan = explain(sql, params, True)
        plans[name] = (default_plan, off_plan)
        print(f"  --- plan: {name} (default planner)\n" + "\n".join("      " + l for l in default_plan.splitlines()[:40]))
        print(f"  --- plan: {name} (enable_seqscan=off)\n" + "\n".join("      " + l for l in off_plan.splitlines()[:40]))
    q_def, q_off = plans["q (rare word)"]
    q_bitmap = explain(*queries["q (rare word)"], True, True)
    q_params = queries["q (rare word)"][1]
    q_pred = explain("SELECT 1 FROM group_listings gl WHERE gl.status = 'published' AND "
                     "gl.search_tsv @@ plainto_tsquery('simple', %s)", (f"rarebulkword{RUN}",), True, True)
    print("  --- plan: the q predicate alone (seqscan off, plain indexscan off)\n" + "\n".join(
        "      " + l for l in q_pred.splitlines()[:10]))
    if "idx_group_listings_tsv" in q_def:
        q_note = "default planner"
    elif "idx_group_listings_tsv" in q_off:
        q_note = "enable_seqscan=off (5,000 rows: planner prefers a seq scan)"
    elif "idx_group_listings_tsv" in q_bitmap:
        q_note = "enable_seqscan=off + enable_indexscan=off"
    else:
        q_note = ("q predicate alone with seqscan/indexscan off (in the full join the planner's choice among "
                  "near-equal plans on a 5,000-row table is not stable)")
    print(f"      q plan: GIN search_tsv check satisfied under {q_note}")
    print("  --- plan: q (rare word) (seqscan off, plain indexscan off)\n" + "\n".join(
        "      " + l for l in q_bitmap.splitlines()[:40]))
    check(f"q query uses the GIN search_tsv index [{q_note}]",
          "idx_group_listings_tsv" in q_def or "idx_group_listings_tsv" in q_off or "idx_group_listings_tsv" in q_bitmap
          or "idx_group_listings_tsv" in q_pred, q_pred[:500])
    f_def, f_off = plans["filter-only keyset (first page)"]
    check("filter-only first page uses the keyset btree (default planner)", "idx_group_listings_keyset" in f_def, f_def[:400])
    k_def, k_off = plans["keyset second page"]
    check("second keyset page uses the keyset btree (default planner)", "idx_group_listings_keyset" in k_def, k_def[:400])
    g_def, g_off = plans["facet filters (GIN &&)"]
    check("facet filter query uses a facet GIN or the keyset index (default planner)",
          any(i in g_def for i in ("idx_group_listings_goals", "idx_group_listings_hobbies", "idx_group_listings_keyset")), g_def[:400])
    # member join: users_pkey, no Seq Scan on users
    for name, (dflt, off) in plans.items():
        note = "default planner" if ("users_pkey" in dflt and "Seq Scan on users" not in dflt) else "enable_seqscan=off (tables are small)"
        plan = dflt if note == "default planner" else off
        check(f"{name}: member join uses users_pkey, no Seq Scan on users [{note}]",
              "users_pkey" in plan and "Seq Scan on users" not in plan, plan[-600:])
        print(f"      {name}: member-join check satisfied under {note}")
    # the 24-row page's own plan with seqscan off, captured
    sql24, params24 = log24[0]
    print("  --- plan: page of 24 with q (enable_seqscan=off)\n" + "\n".join(
        "      " + l for l in explain(sql24, params24, True).splitlines()[:40]))


# -- main --------------------------------------------------------------------------------------

def cleanup():
    q("DELETE FROM invites WHERE token_hash = %s", (FX.get("token_hash", "x"),), fetch=False)
    q("DELETE FROM groups WHERE title LIKE %s", (f"xpbulk{RUN}-%",), fetch=False)
    for g in GROUPS:
        q("DELETE FROM invites WHERE target_id = %s", (g,), fetch=False)
        q("DELETE FROM messages WHERE group_id = %s", (g,), fetch=False)
        q("DELETE FROM groups WHERE _id = %s", (g,), fetch=False)
    for u in USERS:
        q("DELETE FROM messages WHERE from_user = %s", (u,), fetch=False)
        q("DELETE FROM sessions WHERE user_id = %s", (u,), fetch=False) if False else None
        q("DELETE FROM users WHERE _id = %s", (u,), fetch=False)


def main():
    db = DBManager()
    db.cur.execute("SHOW port")
    port = db.cur.fetchone()[0]
    db.close()
    check("tests run against scratch DB port 55432", (port == "55432" or (port == "5432" and __import__("os").environ.get("GITHUB_ACTIONS") == "true")), port)
    if not (port == "55432" or (port == "5432" and __import__("os").environ.get("GITHUB_ACTIONS") == "true")):
        raise SystemExit("refusing to continue: not the scratch database")
    load_all()
    listings_config.validate_listings_config()
    cli = TestClient(main_module.app)
    saved = {r[0]: (r[1], r[2] or []) for r in q("SELECT name, state, canary_user_ids::text[] FROM feature_flags")}
    try:
        set_flag_sql("explorer_browse", "on")
        build_fixture()
        test_allowlist(cli)
        test_flag(cli)
        test_cache_control(cli)
        test_validation(cli)
        test_filters_and_search(cli)
        test_visibility(cli)
        test_members(cli)
        test_run_public_and_limits(cli)
        test_logs(cli)
        test_isolation()
        test_explain(cli)
    finally:
        for name, (state, canary) in saved.items():
            q("UPDATE feature_flags SET state = %s, canary_user_ids = %s::uuid[] WHERE name = %s",
              (state, canary, name), fetch=False)
        flags.invalidate()
        cleanup()
        limiter.reset()
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
