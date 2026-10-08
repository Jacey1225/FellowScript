"""Backend tests for task 20261002-home-announcement-headline, step 2 (testing).

Home announcement headline: GET /app/home-message plus admin CRUD under
/admin/home-messages, through the fully booted ``main.app`` (so the real limiter,
middleware and require_admin wiring are exercised).

Properties proved (each would catch a regression of the behaviour it names):
  1. Selection: priority desc, then newest; disabled rows never served; empty -> null.
  2. Window: before starts_at / at-or-after ends_at never served; boundary semantics
     (starts_at inclusive, ends_at exclusive); window evaluated per request even
     while the enabled-row list is cached.
  3. Cap: enabling beyond max_enabled is a 409 (create-enabled and PATCH-enable);
     re-saving an already-enabled row does not trip it; a disabled create is always ok.
  4. Validation: strips control/format chars, collapses whitespace, rejects empty,
     over-length (config cap), markup/links/entities; unknown body keys, bad window
     (naive, end<=start), null text/priority/enabled, empty PATCH are 422; bad id 404.
     New messages default to disabled.
  5. Auth: every admin route 401 unauthenticated / 403 non-admin; the read route is 401
     unauthenticated and 200 for any authenticated user (no admin needed).
  6. Rate limit: read route 429 past the configured read limit.
  7. Cache: rows are cached for the TTL, writers invalidate, a DB failure answers
     null (fail-soft, never raises) and is not cached.
  8. Audit: create/update/enable/disable/delete each emit one admin_audit line with
     admin_id + message_id and never the free text; refusals audited as *_refused.
  9. Config: shipped JSON validates; bad/missing/unknown keys fail closed;
     check_home_messages_config is registered in startup_checks.CHECKS; DDL module
     registered in db.DDL_MODULES; destination CHECK only allows 'none'.

Scratch DB only (port 55432, or 5432 under GITHUB_ACTIONS=true); no AWS.
Run: cd api && ../.venv/bin/python tests/test_home_messages.py
"""
import _pathfix  # noqa: F401

import json
import logging
import os
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import db as db_module  # noqa: E402
from backend.interactions import home_messages as hm  # noqa: E402
from backend.interactions import home_messages_config as hmc  # noqa: E402
from backend import startup_checks  # noqa: E402
from backend.config_loader import ConfigSectionError  # noqa: E402
from _thr_common import check, require_scratch_db, sql, FAILED, PASSED  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402

ADMIN, NON_ADMIN = [], []
UTC = timezone.utc


def mk_user(is_admin):
    uid = str(uuid.uuid4())
    sql("INSERT INTO users (_id, username, email, hash_pass, is_admin, mfa_enabled) VALUES (%s,%s,%s,'x',%s,%s)",
        (uid, f"hm_{uid[:8]}", f"hm_{uid[:8]}@example.com", is_admin, is_admin))
    (ADMIN if is_admin else NON_ADMIN).append(uid)
    sm = SessionManager()
    try:
        return uid, sm.create_session(uid)
    finally:
        sm.close()


class Audit(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.INFO)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


def clear_rows():
    sql("DELETE FROM home_messages")
    hm.invalidate()


def as_(client, token):
    client.cookies.clear()
    if token:
        client.cookies.set("session", token)


def read(client, token):
    as_(client, token)
    return client.get("/app/home-message")


def mk(client, admin_tok, text, **kw):
    as_(client, admin_tok)
    r = client.post("/admin/home-messages", json={"text": text, **kw})
    return r


def raw_insert(text, enabled=True, priority=0, starts=None, ends=None, created=None):
    rows = sql(
        "INSERT INTO home_messages (text, enabled, priority, starts_at, ends_at, created_at) "
        "VALUES (%s,%s,%s,%s,%s,COALESCE(%s, NOW())) RETURNING _id::text",
        (text, enabled, priority, starts, ends, created))
    hm.invalidate()
    return rows[0][0]


def main():
    require_scratch_db()
    cfg = hmc.get_home_messages_config()
    cap, limit = cfg.max_enabled, cfg.text_max_length
    admin_uid, admin_tok = mk_user(True)
    _, user_tok = mk_user(False)
    audit = Audit()
    al = logging.getLogger("admin_audit")
    al.addHandler(audit)
    prior_level = al.level
    al.setLevel(logging.INFO)
    client = TestClient(main_module.app)
    clear_rows()
    try:
        # ---------------- 5. auth ----------------
        print("auth")
        mid0 = raw_insert("auth probe", enabled=False)
        probes = [("GET", "/admin/home-messages", None),
                  ("POST", "/admin/home-messages", {"text": "x"}),
                  ("PATCH", f"/admin/home-messages/{mid0}", {"enabled": True}),
                  ("DELETE", f"/admin/home-messages/{mid0}", None)]
        for method, path, body in probes:
            as_(client, None)
            check(f"{method} {path[:24]} anon -> 401", client.request(method, path, json=body).status_code == 401)
            as_(client, user_tok)
            check(f"{method} {path[:24]} non-admin -> 403", client.request(method, path, json=body).status_code == 403)
        check("auth probes changed nothing",
              sql("SELECT enabled FROM home_messages WHERE _id=%s", (mid0,))[0][0] is False
              and sql("SELECT COUNT(*) FROM home_messages")[0][0] == 1)
        check("read anon -> 401", read(client, None).status_code == 401)
        r = read(client, user_tok)
        check("read as plain user -> 200 {v:1,message:null}", r.status_code == 200 and r.json() == {"v": 1, "message": None}, r.text)
        check("read Cache-Control private max-age=ttl",
              r.headers.get("cache-control") == f"private, max-age={cfg.cache_ttl_seconds}", r.headers.get("cache-control"))
        clear_rows()

        # ---------------- 1. selection ----------------
        print("selection")
        old = datetime.now(UTC) - timedelta(days=2)
        raw_insert("low old", priority=1, created=old)
        raw_insert("low new", priority=1)
        raw_insert("disabled top", enabled=False, priority=100)
        r = read(client, user_tok).json()
        check("equal priority -> newest wins", r["message"]["text"] == "low new", r)
        raw_insert("high old", priority=5, created=old)
        check("higher priority beats newer", read(client, user_tok).json()["message"]["text"] == "high old")
        check("disabled never served even at top priority",
              all(m["text"] != "disabled top" for m in [read(client, user_tok).json()["message"]]))
        msg = read(client, user_tok).json()["message"]
        check("payload shape {id,text,destination:'none'} only", set(msg) == {"id", "text", "destination"} and msg["destination"] == "none", msg)
        clear_rows()
        check("empty bucket -> message null", read(client, user_tok).json() == {"v": 1, "message": None})
        raw_insert("only disabled", enabled=False)
        check("only-disabled -> null", read(client, user_tok).json()["message"] is None)
        clear_rows()
        # tie on priority and created_at is deterministic (id tiebreak)
        ts = datetime.now(UTC) - timedelta(hours=1)
        raw_insert("tie a", created=ts)
        raw_insert("tie b", created=ts)
        first = read(client, user_tok).json()["message"]["text"]
        hm.invalidate()
        check("full tie is deterministic", read(client, user_tok).json()["message"]["text"] == first)
        clear_rows()

        # ---------------- 2. window ----------------
        print("window")
        now = datetime.now(UTC)
        raw_insert("future", starts=now + timedelta(hours=1))
        raw_insert("expired", ends=now - timedelta(hours=1), starts=now - timedelta(hours=3))
        check("future and expired never served", read(client, user_tok).json()["message"] is None)
        raw_insert("current", starts=now - timedelta(hours=1), ends=now + timedelta(hours=1), priority=-5)
        check("in-window served", read(client, user_tok).json()["message"]["text"] == "current")
        b = datetime(2030, 1, 1, tzinfo=UTC)
        clear_rows()
        raw_insert("bounded", starts=b, ends=b + timedelta(hours=1))
        cm = hm.current_message
        check("starts_at inclusive", (cm(now=b) or {}).get("text") == "bounded")
        check("one second before start -> none", cm(now=b - timedelta(seconds=1)) is None)
        check("just before ends_at served", (cm(now=b + timedelta(minutes=59, seconds=59)) or {}).get("text") == "bounded")
        check("ends_at exclusive", cm(now=b + timedelta(hours=1)) is None)
        clear_rows()
        # window evaluated per request although rows are cached
        raw_insert("expires soon", ends=datetime.now(UTC) + timedelta(seconds=2))
        check("served before expiry (rows now cached)", read(client, user_tok).json()["message"] is not None)
        time.sleep(2.3)
        check("stops being served at ends_at even within cache TTL", read(client, user_tok).json()["message"] is None)
        clear_rows()

        # ---------------- 4. validation / defaults ----------------
        print("validation")
        r = mk(client, admin_tok, "  Invite   your friends,\n get 50% off\t ")
        j = r.json()
        check("create -> 201", r.status_code == 201, r.text)
        check("new message defaults to disabled", j["enabled"] is False and j["destination"] == "none", j)
        check("whitespace collapsed + trimmed", j["text"] == "Invite your friends, get 50% off", j["text"])
        check("created_by recorded", sql("SELECT created_by FROM home_messages WHERE _id=%s", (j["id"],))[0][0] == admin_uid)
        check("disabled create never served", read(client, user_tok).json()["message"] is None)
        r = mk(client, admin_tok, "Zero​width\x00and\x07bell‮!")
        check("control/format/bidi chars stripped", r.status_code == 201 and r.json()["text"] == "Zerowidthandbell!", r.text)
        check("exactly-at-limit ok", mk(client, admin_tok, "a" * limit).status_code == 201)
        r = mk(client, admin_tok, "a" * (limit + 1))
        check("limit+1 -> 422", r.status_code == 422, r.text)
        check("over transport bound (2001) -> 422", mk(client, admin_tok, "a" * 2001).status_code == 422)
        for bad in ["", "   ", "​\x00", "\n\t"]:
            check(f"empty-after-clean {bad!r} -> 422", mk(client, admin_tok, bad).status_code == 422)
        for bad in ["<b>hi</b>", "a < b", "x > y", "see https://evil.test", "go www.evil.test",
                    "javascript:alert(1)", "data:text/html,x", "&#60;script", "[click](http://x)", "ftp://x",
                    "JAVASCRIPT:x", "HTTPS://X"]:
            check(f"markup/link {bad!r} -> 422", mk(client, admin_tok, bad).status_code == 422)
        check("text not a string -> 422", mk(client, admin_tok, 123).status_code == 422)
        check("missing text -> 422", (as_(client, admin_tok) or client.post("/admin/home-messages", json={})).status_code == 422)
        as_(client, admin_tok)
        check("unknown key (destination) -> 422",
              client.post("/admin/home-messages", json={"text": "x", "destination": "account"}).status_code == 422)
        check("unknown key (id) -> 422", client.post("/admin/home-messages", json={"text": "x", "id": "1"}).status_code == 422)
        check("priority out of range -> 422", mk(client, admin_tok, "x", priority=1001).status_code == 422)
        check("priority non-int -> 422", mk(client, admin_tok, "x", priority="high").status_code == 422)
        check("naive start -> 422", mk(client, admin_tok, "x", starts_at="2030-01-01T00:00:00").status_code == 422)
        check("naive end -> 422", mk(client, admin_tok, "x", ends_at="2030-01-01T00:00:00").status_code == 422)
        check("end == start -> 422", mk(client, admin_tok, "x", starts_at="2030-01-01T00:00:00Z", ends_at="2030-01-01T00:00:00Z").status_code == 422)
        check("end < start -> 422", mk(client, admin_tok, "x", starts_at="2030-01-02T00:00:00Z", ends_at="2030-01-01T00:00:00Z").status_code == 422)
        r = mk(client, admin_tok, "windowed", starts_at="2030-01-01T00:00:00Z", ends_at="2030-02-01T00:00:00Z", priority=7)
        check("valid window + priority stored", r.status_code == 201 and r.json()["priority"] == 7 and datetime.fromisoformat(r.json()["starts_at"]) == datetime(2030, 1, 1, tzinfo=UTC), r.text)
        wid = r.json()["id"]
        # PATCH validation
        as_(client, admin_tok)
        for body, label in [({}, "empty PATCH"), ({"text": None}, "null text"), ({"priority": None}, "null priority"),
                            ({"enabled": None}, "null enabled"), ({"text": "<i>x</i>"}, "markup text"),
                            ({"text": "a" * (limit + 1)}, "over-length text"), ({"bogus": 1}, "unknown key"),
                            ({"ends_at": "2029-01-01T00:00:00Z"}, "end before existing start")]:
            check(f"PATCH {label} -> 422", client.patch(f"/admin/home-messages/{wid}", json=body).status_code == 422)
        r = client.patch(f"/admin/home-messages/{wid}", json={"ends_at": None, "starts_at": None})
        check("PATCH may null the window", r.status_code == 200 and r.json()["starts_at"] is None and r.json()["ends_at"] is None, r.text)
        check("PATCH unknown id (valid uuid) -> 404", client.patch(f"/admin/home-messages/{uuid.uuid4()}", json={"enabled": False}).status_code == 404)
        check("PATCH malformed id -> 404", client.patch("/admin/home-messages/not-a-uuid", json={"enabled": False}).status_code == 404)
        check("DELETE unknown id -> 404", client.delete(f"/admin/home-messages/{uuid.uuid4()}").status_code == 404)
        check("DELETE malformed id -> 404", client.delete("/admin/home-messages/nope").status_code == 404)
        check("rejected writes inserted nothing extra",
              sql("SELECT COUNT(*) FROM home_messages WHERE text IN ('x','<b>hi</b>')")[0][0] == 0)
        # SQL-injection-ish text is stored/served verbatim as data, not executed
        r = mk(client, admin_tok, "Robert'); DROP TABLE home_messages;--", enabled=True)
        check("quote/SQL text stored as inert data", r.status_code == 201 and sql("SELECT COUNT(*) FROM home_messages")[0][0] > 0)
        clear_rows()

        # ---------------- 3. cap ----------------
        print("cap")
        ids = []
        for i in range(cap):
            r = mk(client, admin_tok, f"on {i}", enabled=True, priority=i)
            check(f"enabled create #{i + 1} (<= cap) -> 201", r.status_code == 201, r.text)
            ids.append(r.json()["id"])
        r = mk(client, admin_tok, "over cap", enabled=True)
        check("enabled create beyond cap -> 409 with clear detail", r.status_code == 409 and str(cap) in r.json()["detail"], r.text)
        check("409 create inserted nothing", sql("SELECT COUNT(*) FROM home_messages")[0][0] == cap)
        r = mk(client, admin_tok, "parked")
        check("disabled create at cap ok", r.status_code == 201 and r.json()["enabled"] is False)
        parked = r.json()["id"]
        as_(client, admin_tok)
        r = client.patch(f"/admin/home-messages/{parked}", json={"enabled": True})
        check("PATCH enable beyond cap -> 409", r.status_code == 409, r.text)
        check("parked still disabled", sql("SELECT enabled FROM home_messages WHERE _id=%s", (parked,))[0][0] is False)
        r = client.patch(f"/admin/home-messages/{ids[0]}", json={"text": "edited while at cap", "priority": 50})
        check("editing an already-enabled row at cap ok", r.status_code == 200, r.text)
        r = client.patch(f"/admin/home-messages/{ids[0]}", json={"enabled": True})
        check("re-enabling an already-enabled row at cap ok", r.status_code == 200, r.text)
        check("winner is the edited top priority", read(client, user_tok).json()["message"]["text"] == "edited while at cap")
        as_(client, admin_tok)
        check("disable frees a slot", client.patch(f"/admin/home-messages/{ids[1]}", json={"enabled": False}).status_code == 200)
        check("enable parked now ok", client.patch(f"/admin/home-messages/{parked}", json={"enabled": True}).status_code == 200)
        check("enabled count == cap", sql("SELECT COUNT(*) FROM home_messages WHERE enabled")[0][0] == cap)
        check("delete frees a slot too",
              client.delete(f"/admin/home-messages/{ids[2]}").status_code == 200
              and mk(client, admin_tok, "after delete", enabled=True).status_code == 201)
        # concurrent enables cannot both pass the count (advisory lock)
        clear_rows()
        for i in range(cap - 1):
            raw_insert(f"base {i}", enabled=True)
        cand = [raw_insert(f"cand {i}", enabled=False) for i in range(4)]
        import threading
        codes = []

        def enable(mid):
            c = TestClient(main_module.app)
            c.cookies.set("session", admin_tok)
            codes.append(c.patch(f"/admin/home-messages/{mid}", json={"enabled": True}).status_code)
        ts_ = [threading.Thread(target=enable, args=(m,)) for m in cand]
        [t.start() for t in ts_]
        [t.join() for t in ts_]
        check("concurrent enables: exactly one wins", sorted(codes) == [200, 409, 409, 409], codes)
        check("concurrent enables: cap holds in DB", sql("SELECT COUNT(*) FROM home_messages WHERE enabled")[0][0] == cap)
        clear_rows()

        # ---------------- 7. cache ----------------
        print("cache")
        raw_insert("cached one", priority=1)
        check("first read loads", read(client, user_tok).json()["message"]["text"] == "cached one")
        sql("UPDATE home_messages SET text='mutated behind cache'")  # no invalidate
        check("served from cache within TTL (no DB hit)", read(client, user_tok).json()["message"]["text"] == "cached one")
        with mock.patch.object(hm, "_load_enabled", side_effect=AssertionError("DB hit while cached")):
            check("cached read does not touch DB", read(client, user_tok).status_code == 200)
        # TTL expiry
        hm._cache_at = time.monotonic() - cfg.cache_ttl_seconds - 1
        check("after TTL reloads from DB", read(client, user_tok).json()["message"]["text"] == "mutated behind cache")
        # writer invalidates
        r = mk(client, admin_tok, "fresh winner", enabled=True, priority=99)
        check("admin write invalidates cache immediately", read(client, user_tok).json()["message"]["text"] == "fresh winner")
        as_(client, admin_tok)
        client.delete(f"/admin/home-messages/{r.json()['id']}")
        check("delete invalidates cache immediately", read(client, user_tok).json()["message"]["text"] == "mutated behind cache")
        # fail-soft
        hm.invalidate()
        with mock.patch.object(hm, "_load_enabled", side_effect=RuntimeError("db down")):
            r = read(client, user_tok)
            check("DB failure -> 200 {v:1,message:null}", r.status_code == 200 and r.json() == {"v": 1, "message": None}, r.text)
            check("failure not cached", hm._cache is None)
            check("current_message never raises", hm.current_message() is None)
        check("recovers next call", read(client, user_tok).json()["message"] is not None)
        clear_rows()

        # ---------------- 8. audit ----------------
        print("audit")
        audit.lines.clear()
        secret = "AuditSecretPhraseXYZ"
        r = mk(client, admin_tok, secret)
        mid = r.json()["id"]
        as_(client, admin_tok)
        client.patch(f"/admin/home-messages/{mid}", json={"enabled": True})
        client.patch(f"/admin/home-messages/{mid}", json={"enabled": False})
        client.patch(f"/admin/home-messages/{mid}", json={"text": secret + " 2", "priority": 3})
        client.delete(f"/admin/home-messages/{mid}")
        joined = "\n".join(audit.lines)
        for action in ("create", "enable", "disable", "update", "delete"):
            ln = [x for x in audit.lines if f"action=home_message_{action} " in x]
            check(f"audit line for {action} (1x, admin_id+message_id)",
                  len(ln) == 1 and f"admin_id={admin_uid}" in ln[0] and f"message_id={mid}" in ln[0], audit.lines)
        check("audit never contains free text", secret not in joined, joined)
        audit.lines.clear()
        mk(client, admin_tok, "<b>bad</b>")
        check("refused create audited as _refused with status",
              any("action=home_message_create_refused" in x and "status=422" in x and f"admin_id={admin_uid}" in x for x in audit.lines), audit.lines)
        check("refused create has no success line", not any("action=home_message_create " in x for x in audit.lines))
        audit.lines.clear()
        as_(client, admin_tok)
        client.delete(f"/admin/home-messages/{uuid.uuid4()}")
        check("refused delete audited", any("action=home_message_delete_refused" in x and "status=404" in x for x in audit.lines), audit.lines)
        audit.lines.clear()
        as_(client, user_tok)
        client.post("/admin/home-messages", json={"text": "x"})
        check("403 non-admin emits no home_message audit line", not any("home_message" in x for x in audit.lines))

        # admin list
        clear_rows()
        for i in range(3):
            raw_insert(f"l{i}", enabled=False)
        as_(client, admin_tok)
        r = client.get("/admin/home-messages")
        j = r.json()
        check("admin list returns items + caps, no-store",
              r.status_code == 200 and len(j["items"]) == 3 and j["text_max_length"] == limit and j["max_enabled"] == cap
              and r.headers.get("cache-control") == "no-store", r.text)
        check("admin list includes disabled rows", all(i["enabled"] is False for i in j["items"]))
        clear_rows()

        # ---------------- 9. config / wiring ----------------
        print("config + wiring")
        check("check_home_messages_config registered", startup_checks.check_home_messages_config in startup_checks.CHECKS)
        startup_checks.check_home_messages_config()
        check("shipped config validates", True)
        check("'home_messages' in db.DDL_MODULES", "home_messages" in [getattr(m, "__name__", str(m)).split(".")[-1] for m in db_module.DDL_MODULES]
              or "home_messages" in map(str, db_module.DDL_MODULES), str(db_module.DDL_MODULES)[:200])
        routes = {getattr(r_, "path", "") for r_ in main_module.app.routes}
        check("routes mounted", {"/app/home-message", "/admin/home-messages", "/admin/home-messages/{message_id}"} <= routes)
        src = json.loads(hmc.CONFIG_PATH.read_text())

        def with_cfg(mutate):
            data = json.loads(json.dumps(src))
            mutate(data["home_messages"])
            tmp = Path(os.environ.get("TMPDIR", "/tmp")) / f"hm_cfg_{uuid.uuid4().hex}.json"
            tmp.write_text(json.dumps(data))
            try:
                with mock.patch.object(hmc, "CONFIG_PATH", tmp):
                    hmc.reset_for_tests()
                    try:
                        hmc.validate_home_messages_config()
                        return None
                    except ConfigSectionError as e:
                        return e
            finally:
                tmp.unlink(missing_ok=True)
                hmc.reset_for_tests()
        check("valid mutation passes (control)", with_cfg(lambda d: d.update(max_enabled=5)) is None)
        check("missing key rejected", with_cfg(lambda d: d.pop("cache_ttl_seconds")) is not None)
        check("unknown key rejected", with_cfg(lambda d: d.update(surprise=1)) is not None)
        check("wrong type rejected", with_cfg(lambda d: d.update(max_enabled="3")) is not None)
        check("text_max_length 0 rejected", with_cfg(lambda d: d.update(text_max_length=0)) is not None)
        check("text_max_length > column (501) rejected", with_cfg(lambda d: d.update(text_max_length=501)) is not None)
        check("max_enabled 0 rejected", with_cfg(lambda d: d.update(max_enabled=0)) is not None)
        check("negative ttl rejected", with_cfg(lambda d: d.update(cache_ttl_seconds=-1)) is not None)
        check("bad rate string rejected", with_cfg(lambda d: d["rate_limits"].update(read="lots")) is not None)
        check("missing rate key rejected", with_cfg(lambda d: d["rate_limits"].pop("admin")) is not None)
        check("extra rate key rejected", with_cfg(lambda d: d["rate_limits"].update(other="1/minute")) is not None)
        hmc.reset_for_tests()
        # DDL: destination CHECK + window CHECK + defaults
        for bad_sql, label in [
            ("INSERT INTO home_messages (text, destination) VALUES ('x','account')", "destination != none rejected by DB"),
            ("INSERT INTO home_messages (text, starts_at, ends_at) VALUES ('x', NOW(), NOW() - interval '1 hour')", "end<=start rejected by DB"),
            (f"INSERT INTO home_messages (text) VALUES ('{'a' * 501}')", "text > 500 rejected by DB"),
        ]:
            try:
                sql(bad_sql)
                check(label, False, "insert succeeded")
            except Exception:
                check(label, True)
        sql("INSERT INTO home_messages (text) VALUES ('defaults')")
        row = sql("SELECT enabled, priority, destination FROM home_messages")[0]
        check("DB defaults: disabled, priority 0, destination none", tuple(row) == (False, 0, "none"), row)
        clear_rows()

        # ---------------- 6. rate limit (last: exhausts the read budget) ----------------
        print("rate limit")
        main_module.app.state.limiter.reset()  # earlier reads in this minute count too
        n = int(hmc.get_home_messages_config().rate_limits["read"].split("/")[0])
        codes = [read(client, user_tok).status_code for _ in range(n + 5)]
        check(f"first {n} reads within window not limited", 429 not in codes[:n], codes[:n].count(429))
        check("reads beyond the configured limit -> 429", codes[-1] == 429, codes[-5:])
    finally:
        al.removeHandler(audit)
        al.setLevel(prior_level)
        clear_rows()
        for uid in ADMIN + NON_ADMIN:
            sql("DELETE FROM sessions WHERE user_id=%s", (uid,)) if False else None
            sql("DELETE FROM users WHERE _id=%s", (uid,))
    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    for f in FAILED:
        print("  FAILED:", f)
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
