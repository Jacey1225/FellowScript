"""Tests for task 20261002-shared-foundation (Backend A): DDL module runner,
DB-backed feature flags, PUT /admin/flags/{name}, GET /app/capabilities, the
shared keyset cursor codec, terms gating, startup checks/config loader and
the FEATURE_SUMMARY counters.

Properties proved (not a smoke test):
  1. DDL runner: unknown/invalid/no-apply names raise BEFORE any module runs;
     a second create_tables leaves seeded flag rows (and an admin's edits)
     untouched (ON CONFLICT DO NOTHING).
  2. Flags fail CLOSED: a DB error answers off for every flag, never a stale
     "on"; unknown flag is off; canary is per-user; explorer_browse (no_canary)
     treats a stored canary as off; the 10s cache is dropped by invalidate().
  3. Admin PUT: 401 no session, 403 non-admin, 404 unknown flag, 422 for bad
     state / canary on explorer_browse / canary ids that are not users; audit
     line carries counts only (no canary ids) at INFO.
  4. /app/capabilities: per-user canary evaluation, booleans only, no-store,
     links.explore only when explorer_browse is on, terms_current false for a
     stale terms_version.
  5. Cursor codec: naive / malformed timestamps, bad ids, seq out of range
     are 422 and the error body never echoes the offending value.
  6. config_loader / startup_checks / feature_summary behaviours.

Run with: cd api && ../.venv/bin/python tests/test_shared_foundation.py
"""
import _pathfix  # noqa: F401

import json
import logging
import os
import sys
import tempfile
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi import HTTPException  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import db as db_module  # noqa: E402
import schema_ddl  # noqa: E402
from db import DBManager  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.interactions import flags, paging  # noqa: E402
from backend.auth import terms as terms_mod  # noqa: E402
from backend import config_loader, startup_checks  # noqa: E402
from backend.observability import feature_summary as fs  # noqa: E402
from schemas.users import CURRENT_TERMS_VERSION  # noqa: E402

PASSED, FAILED = [], []


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


def make_user(is_admin=False, terms_version=CURRENT_TERMS_VERSION) -> str:
    uid = str(uuid.uuid4())
    dbm = DBManager()
    try:
        dbm.insertion("users", {
            "_id": uid, "username": f"sf_{uid[:8]}", "email": f"sf_{uid[:8]}@example.com",
            "hash_pass": "x", "is_admin": is_admin, "terms_version": terms_version,
        })
    finally:
        dbm.close()
    return uid


def session_for(uid) -> dict:
    sm = SessionManager()
    try:
        return {"cookie": f"session={sm.create_session(uid)}"}
    finally:
        sm.close()


def delete_users(*uids):
    dbm = DBManager()
    try:
        for u in uids:
            dbm.delete("users", {"_id": u})
    finally:
        dbm.close()


def raw_flag(name):
    dbm = DBManager()
    try:
        dbm.cur.execute("SELECT state, canary_user_ids::text[], updated_by FROM feature_flags WHERE name=%s", (name,))
        return dbm.cur.fetchone()
    finally:
        dbm.close()


def set_raw(name, state, canary=()):
    """Write a row directly (bypasses the validating writer) then drop the cache."""
    dbm = DBManager()
    try:
        dbm.cur.execute(
            "INSERT INTO feature_flags (name,state,canary_user_ids) VALUES (%s,%s,%s::uuid[]) "
            "ON CONFLICT (name) DO UPDATE SET state=EXCLUDED.state, canary_user_ids=EXCLUDED.canary_user_ids",
            (name, state, list(canary)))
        dbm.conn.commit()
    finally:
        dbm.close()
    flags.invalidate()


class Capture(logging.Handler):
    def __init__(self):
        super().__init__()
        self.lines = []

    def emit(self, record):
        self.lines.append((record.levelname, record.getMessage()))


def main():
    client = TestClient(main_module.app)
    admin = make_user(is_admin=True)
    plain = make_user()
    stale = make_user(terms_version="1999-01-01")
    h_admin, h_plain, h_stale = session_for(admin), session_for(plain), session_for(stale)
    saved = {}
    dbm = DBManager()
    try:
        dbm.cur.execute("SELECT name, state, canary_user_ids::text[] FROM feature_flags")
        saved = {r[0]: (r[1], r[2] or []) for r in dbm.cur.fetchall()}
    finally:
        dbm.close()

    try:
        # ---- 0. connection is the scratch DB
        dbm = DBManager()
        dbm.cur.execute("SHOW port")
        port = dbm.cur.fetchone()[0]
        dbm.close()
        check("tests run against scratch DB port 55432", port == "55432", port)
        if port != "55432":
            raise SystemExit("refusing to continue: not the scratch database")

        # ---- 1. DDL runner
        print("DDL modules")
        ran = []
        orig_load = schema_ddl._load
        for bad in ("nope_missing", "Bad-Name", "../x", "", "flags; drop"):
            c = DBManager()
            try:
                try:
                    schema_ddl.apply_modules(c.cur, ["flags", bad])
                    check(f"apply_modules rejects {bad!r}", False, "no error")
                except schema_ddl.DDLModuleError:
                    check(f"apply_modules rejects {bad!r}", True)
            finally:
                c.conn.rollback()
                c.close()
        # a module without apply()
        import types
        sys.modules["schema_ddl.noapply_t"] = types.ModuleType("schema_ddl.noapply_t")
        c = DBManager()
        try:
            try:
                schema_ddl.apply_modules(c.cur, ["noapply_t"])
                check("module without apply raises", False)
            except schema_ddl.DDLModuleError:
                check("module without apply raises", True)
        finally:
            c.close()
            del sys.modules["schema_ddl.noapply_t"]
        # resolve-all-first: bad name after a good one runs nothing
        calls = []
        sys.modules["schema_ddl.probe_t"] = types.SimpleNamespace(apply=lambda cur: calls.append(1))
        c = DBManager()
        try:
            try:
                schema_ddl.apply_modules(c.cur, ["probe_t", "nope_missing"])
            except schema_ddl.DDLModuleError:
                pass
            check("unknown name raises before any earlier module ran", calls == [], calls)
            schema_ddl.apply_modules(c.cur, ["probe_t", "probe_t"])
            check("modules run in order, each name once per listing", calls == [1, 1], calls)
            c.conn.rollback()
        finally:
            c.close()
            del sys.modules["schema_ddl.probe_t"]
        check("db.DDL_MODULES lists flags and outbox",
              "flags" in db_module.DDL_MODULES and "outbox" in db_module.DDL_MODULES, db_module.DDL_MODULES)

        # idempotent: edit a seeded row, re-run apply, edit survives, nothing duplicated
        set_raw("threads", "on")
        c = DBManager()
        try:
            schema_ddl.apply_modules(c.cur, db_module.DDL_MODULES)
            schema_ddl.apply_modules(c.cur, db_module.DDL_MODULES)
            c.conn.commit()
            c.cur.execute("SELECT count(*) FROM feature_flags WHERE name = ANY(%s)", (list(flags.registry()),))
            n = c.cur.fetchone()[0]
        finally:
            c.close()
        check("re-applying DDL keeps an edited flag row", raw_flag("threads")[0] == "on", raw_flag("threads"))
        check("re-applying DDL adds no duplicate seed rows", n == len(flags.registry()), n)
        set_raw("threads", "off")
        from schema_ddl.flags import SEED_FLAG_NAMES
        check("every seed flag exists and is registered",
              all(raw_flag(n) is not None for n in SEED_FLAG_NAMES)
              and set(SEED_FLAG_NAMES) <= set(flags.registry()))

        # ---- 2. flag reader
        print("flag reader")
        for n in flags.registry():
            set_raw(n, "off")
        check("off flag is off", not flags.is_enabled("threads", plain))
        check("unknown flag is off", not flags.is_enabled("does_not_exist", plain))
        set_raw("threads", "on")
        check("on flag is on (no user)", flags.is_enabled("threads"))
        set_raw("threads", "canary", [plain])
        check("canary on for listed user", flags.is_enabled("threads", plain))
        check("canary off for other user", not flags.is_enabled("threads", admin))
        check("canary off with no user", not flags.is_enabled("threads"))
        check("canary match is case-insensitive", flags.is_enabled("threads", plain.upper()))
        set_raw("explorer_browse", "canary", [plain])
        check("no_canary flag stored as canary reads off even for listed user",
              not flags.is_enabled("explorer_browse", plain))
        set_raw("explorer_browse", "on")
        check("no_canary flag on is on", flags.is_enabled("explorer_browse", plain))

        # cache: direct DB edit invisible until invalidate
        set_raw("threads", "off")
        flags.is_enabled("threads")  # prime
        dbm = DBManager()
        dbm.cur.execute("UPDATE feature_flags SET state='on' WHERE name='threads'")
        dbm.conn.commit()
        dbm.close()
        check("snapshot is cached between reads", not flags.is_enabled("threads"))
        flags.invalidate()
        check("invalidate() drops the cache", flags.is_enabled("threads"))

        # fail closed: primed "on" snapshot, then break the DB read
        set_raw("threads", "on")
        flags.is_enabled("threads")
        real_load = flags._load_snapshot
        handler = Capture()
        flags.logger.addHandler(handler)
        flags.logger.setLevel(logging.DEBUG)

        def boom():
            raise RuntimeError("db down")
        flags._load_snapshot = boom
        try:
            flags.invalidate()
            flags._last_warn = 0.0
            results = [flags.is_enabled("threads", plain) for _ in range(5)]
            check("DB error answers off for every flag (never stale on)", not any(results), results)
            check("evaluate_all is all-False on DB error", not any(flags.evaluate_all(plain).values()))
            warns = [l for l in handler.lines if l[0] == "WARNING"]
            check("fail-closed logs exactly one WARNING per minute", len(warns) == 1, handler.lines)
            check("fail-closed log never uses the bare word ERROR",
                  all("ERROR" not in m and lv != "ERROR" for lv, m in handler.lines), handler.lines)
        finally:
            flags._load_snapshot = real_load
            flags.logger.removeHandler(handler)
            flags.invalidate()
        check("reader recovers when DB returns", flags.is_enabled("threads"))

        # ---- 3. admin PUT
        print("admin PUT /admin/flags")
        body = {"state": "on"}
        check("PUT without session is 401", client.put("/admin/flags/threads", json=body).status_code == 401)
        check("PUT as non-admin is 403",
              client.put("/admin/flags/threads", json=body, headers=h_plain).status_code == 403)
        check("PUT unknown flag is 404",
              client.put("/admin/flags/nope", json=body, headers=h_admin).status_code == 404)
        check("PUT bad state is 422",
              client.put("/admin/flags/threads", json={"state": "maybe"}, headers=h_admin).status_code == 422)
        check("PUT canary on explorer_browse is 422",
              client.put("/admin/flags/explorer_browse", json={"state": "canary"}, headers=h_admin).status_code == 422)
        check("PUT canary ids on explorer_browse is 422",
              client.put("/admin/flags/explorer_browse", json={"state": "on", "canary_user_ids": [plain]},
                         headers=h_admin).status_code == 422)
        check("PUT canary ids that are not users is 422",
              client.put("/admin/flags/threads",
                         json={"state": "canary", "canary_user_ids": [str(uuid.uuid4())]},
                         headers=h_admin).status_code == 422)
        check("PUT malformed canary id is 422",
              client.put("/admin/flags/threads", json={"state": "canary", "canary_user_ids": ["x"]},
                         headers=h_admin).status_code == 422)
        check("PUT canary list over the cap is 422",
              client.put("/admin/flags/threads",
                         json={"state": "canary", "canary_user_ids": [str(uuid.uuid4())] * (flags.MAX_CANARY_IDS + 1)},
                         headers=h_admin).status_code == 422)
        check("rejected PUTs changed nothing", raw_flag("threads")[0] == "on" and raw_flag("explorer_browse")[0] == "on")

        audit = Capture()
        flags.audit_logger.addHandler(audit)
        flags.audit_logger.setLevel(logging.DEBUG)
        try:
            r = client.put("/admin/flags/threads", json={"state": "canary", "canary_user_ids": [plain, plain.upper()]},
                           headers=h_admin)
        finally:
            flags.audit_logger.removeHandler(audit)
        check("PUT canary with existing user is 200", r.status_code == 200, r.text)
        check("PUT response has name/state/canary_count (dedup)",
              r.json() == {"name": "threads", "state": "canary", "canary_count": 1}, r.text)
        check("PUT persisted state, canary list and actor",
              raw_flag("threads") == ("canary", [plain], admin), raw_flag("threads"))
        check("PUT invalidates cache: reader sees change immediately",
              flags.is_enabled("threads", plain) and not flags.is_enabled("threads", admin))
        flag_lines = [m for lv, m in audit.lines if m.startswith("FLAG_CHANGE")]
        check("audit line logged once at INFO", len(flag_lines) == 1
              and [lv for lv, m in audit.lines if m.startswith("FLAG_CHANGE")] == ["INFO"], audit.lines)
        check("audit line has name/state/actor/canary_count and no canary ids",
              flag_lines and "name=threads" in flag_lines[0] and "state=canary" in flag_lines[0]
              and f"actor={admin}" in flag_lines[0] and "canary_count=1" in flag_lines[0]
              and plain not in flag_lines[0], flag_lines)
        r = client.put("/admin/flags/threads", json={"state": "on"}, headers=h_admin)
        check("omitting canary_user_ids keeps the stored list",
              r.status_code == 200 and r.json()["canary_count"] == 1 and raw_flag("threads")[1] == [plain], r.text)
        r = client.put("/admin/flags/threads", json={"state": "off", "canary_user_ids": []}, headers=h_admin)
        check("empty canary list clears it", r.status_code == 200 and raw_flag("threads")[1] == [], r.text)
        r = client.put("/admin/flags/explorer_browse", json={"state": "on"}, headers=h_admin)
        check("explorer_browse on/off accepted", r.status_code == 200, r.text)

        # CLI writer shares set_flag
        check("CLI module imports", __import__("backend.admin_flags") is not None)

        # ---- 4. capabilities
        print("GET /app/capabilities")
        for n in flags.registry():
            set_raw(n, "off")
        check("capabilities without session is 401", client.get("/app/capabilities").status_code == 401)
        r = client.get("/app/capabilities", headers=h_plain)
        j = r.json()
        check("capabilities 200 + Cache-Control no-store",
              r.status_code == 200 and r.headers.get("cache-control") == "no-store", r.headers)
        check("capabilities shape v/features/links/terms_current",
              j["v"] == 1 and set(j) == {"v", "features", "links", "terms_current"}, j)
        check("features keys come from the registry",
              set(j["features"]) == {n for n, s in flags.registry().items() if s.exposed_in_capabilities}, j["features"])
        check("features are booleans only", all(isinstance(v, bool) for v in j["features"].values()))
        check("all flags off -> all features false, no explore link",
              not any(j["features"].values()) and j["links"] == {"explore": None})
        check("terms_current true for current terms", j["terms_current"] is True)
        check("terms_current false for stale terms_version",
              client.get("/app/capabilities", headers=h_stale).json()["terms_current"] is False)
        set_raw("threads", "canary", [plain])
        jp = client.get("/app/capabilities", headers=h_plain).json()
        ja = client.get("/app/capabilities", headers=h_admin).json()
        check("canary flag true for listed user only", jp["features"]["threads"] and not ja["features"]["threads"])
        check("response leaks no ids or state strings",
              plain not in json.dumps(jp) and "canary" not in json.dumps(jp))
        set_raw("explorer_browse", "on")
        je = client.get("/app/capabilities", headers=h_plain).json()
        check("explorer_browse on adds links.explore",
              je["features"]["explorer_browse"] and isinstance(je["links"]["explore"], str)
              and je["links"]["explore"].endswith("/#/explore"), je)
        set_raw("explorer_browse", "off")
        check("explorer_browse off removes links.explore",
              client.get("/app/capabilities", headers=h_plain).json()["links"]["explore"] is None)

        # ---- 5. terms helper
        print("terms")
        c = DBManager()
        try:
            check("terms_current true", terms_mod.terms_current(c.cur, plain) is True)
            check("terms_current false for stale", terms_mod.terms_current(c.cur, stale) is False)
            check("terms_current false for missing user", terms_mod.terms_current(c.cur, str(uuid.uuid4())) is False)
            terms_mod.require_current_terms(c.cur, plain)
            try:
                terms_mod.require_current_terms(c.cur, stale)
                check("require_current_terms 403 on stale", False)
            except HTTPException as e:
                check("require_current_terms 403 terms_reaccept_required",
                      e.status_code == 403 and e.detail == {"code": "terms_reaccept_required"}, e.detail)
        finally:
            c.close()

        # ---- 6. paging
        print("paging")
        TS = "2026-10-01T12:00:00Z"
        UID = str(uuid.uuid4())

        def dec(d, **kw):
            try:
                return paging.decode_cursor(d, **kw)
            except HTTPException as e:
                return e

        check("no cursor params -> None", dec({}) is None)
        cur = dec({"cursor_timestamp": TS, "cursor_id": UID.upper(), "cursor_seq": "7"})
        check("valid uuid cursor round-trips (lower-case id, seq int)",
              cur.id == UID and cur.seq == 7 and cur.timestamp == "2026-10-01T12:00:00.000000Z" and cur.id_sql == "%s::uuid", cur)
        cur = dec({"cursor_timestamp": "2026-10-01T14:00:00+02:00", "cursor_id": UID})
        check("offset timestamp normalised to UTC Z", cur.timestamp == "2026-10-01T12:00:00.000000Z", cur)
        check("seq defaults to 0 when with_seq and absent", cur.seq == 0 and cur.params()[1] == 0)
        cur = dec({"cursor_timestamp": TS, "cursor_id": "aB3dE5gH7j"}, id_type="text", with_seq=False)
        check("valid text-id cursor, no seq", cur.id == "aB3dE5gH7j" and cur.seq is None and cur.id_sql == "%s::text", cur)
        evil = "x'; DROP TABLE users;--"
        bad_cases = {
            "naive timestamp": {"cursor_timestamp": "2026-10-01T12:00:00", "cursor_id": UID},
            "garbage timestamp": {"cursor_timestamp": evil, "cursor_id": UID},
            "empty timestamp": {"cursor_timestamp": "", "cursor_id": UID},
            "padded timestamp": {"cursor_timestamp": " " + TS, "cursor_id": UID},
            "overlong timestamp": {"cursor_timestamp": TS + "0" * 80, "cursor_id": UID},
            "timestamp without id": {"cursor_timestamp": TS},
            "id without timestamp": {"cursor_id": UID},
            "seq only": {"cursor_seq": "1"},
            "uuid junk id": {"cursor_timestamp": TS, "cursor_id": evil},
            "uuid braces form": {"cursor_timestamp": TS, "cursor_id": "{" + UID + "}"},
            "uuid no-dash form": {"cursor_timestamp": TS, "cursor_id": UID.replace("-", "")},
            "uuid trailing newline": {"cursor_timestamp": TS, "cursor_id": UID + "\n"},
            "negative seq": {"cursor_timestamp": TS, "cursor_id": UID, "cursor_seq": "-1"},
            "float seq": {"cursor_timestamp": TS, "cursor_id": UID, "cursor_seq": "1.5"},
            "seq > bigint": {"cursor_timestamp": TS, "cursor_id": UID, "cursor_seq": str(2 ** 63)},
            "seq 20 digits": {"cursor_timestamp": TS, "cursor_id": UID, "cursor_seq": "1" * 20},
            "unicode digit seq": {"cursor_timestamp": TS, "cursor_id": UID, "cursor_seq": "٣"},
        }
        for label, params in bad_cases.items():
            e = dec(params)
            ok = isinstance(e, HTTPException) and e.status_code == 422
            leaked = ok and any(str(v) and str(v) in json.dumps(e.detail) for v in params.values())
            check(f"422 for {label}", ok, e)
            check(f"422 body does not echo value ({label})", ok and not leaked, e.detail if ok else "")
        check("seq max bigint accepted",
              dec({"cursor_timestamp": TS, "cursor_id": UID, "cursor_seq": str(2 ** 63 - 1)}).seq == 2 ** 63 - 1)
        for label, params in {
            "text id 9 chars": "abcdefghi", "text id 11 chars": "abcdefghijk",
            "text id punctuation": "abcdef-hij", "text id trailing newline": "abcdefghij\n",
            "text id unicode": "abcdefghié",
        }.items():
            e = dec({"cursor_timestamp": TS, "cursor_id": params}, id_type="text")
            check(f"422 for {label}", isinstance(e, HTTPException) and e.status_code == 422, e)
        e = dec({"cursor_timestamp": TS, "cursor_id": UID, "cursor_seq": "1"}, with_seq=False)
        check("seq sent to a list without seq is 422", isinstance(e, HTTPException) and e.status_code == 422)
        try:
            paging.decode_cursor({}, id_type="int")
            check("unknown id_type is a programmer error", False)
        except ValueError:
            check("unknown id_type is a programmer error", True)

        from datetime import datetime, timezone, timedelta
        enc = paging.encode_cursor(datetime(2026, 10, 1, 12, 0, 0, 5, tzinfo=timezone(timedelta(hours=-5))), 3, uuid.UUID(UID))
        check("encode_cursor UTC micro Z + lower id",
              enc == {"next_cursor_timestamp": "2026-10-01T17:00:00.000005Z", "next_cursor_seq": 3,
                      "next_cursor_id": UID}, enc)
        enc2 = paging.encode_cursor(datetime(2026, 10, 1, 12), None, "aB3dE5gH7j")
        check("encode_cursor naive taken as UTC, seq None, text id kept",
              enc2["next_cursor_timestamp"] == "2026-10-01T12:00:00.000000Z" and enc2["next_cursor_seq"] is None
              and enc2["next_cursor_id"] == "aB3dE5gH7j", enc2)
        rt = dec({"cursor_timestamp": enc["next_cursor_timestamp"], "cursor_id": enc["next_cursor_id"],
                  "cursor_seq": str(enc["next_cursor_seq"])})
        check("encode -> decode round trip", rt.timestamp == enc["next_cursor_timestamp"] and rt.seq == 3 and rt.id == UID)
        check("clamp_limit None -> default", paging.clamp_limit(None, 20, 50) == 20)
        check("clamp_limit bounds", (paging.clamp_limit(0, 20, 50), paging.clamp_limit(-5, 20, 50),
                                     paging.clamp_limit(999, 20, 50), paging.clamp_limit(7, 20, 50)) == (1, 1, 50, 7))
        for d, m in ((0, 5), (10, 5)):
            try:
                paging.clamp_limit(None, d, m)
                check(f"clamp_limit invalid bounds {d},{m} raises", False)
            except ValueError:
                check(f"clamp_limit invalid bounds {d},{m} raises", True)
        env = paging.envelope("items", [1], 20, True, enc)
        check("envelope has_more carries cursor", env["items"] == [1] and env["page"]["next_cursor_id"] == UID
              and env["page"]["has_more"] is True and env["page"]["limit"] == 20, env)
        env = paging.envelope("items", [], 20, False, enc)
        check("envelope cursor fields null unless has_more",
              env["page"]["next_cursor_id"] is None and env["page"]["next_cursor_timestamp"] is None
              and env["page"]["next_cursor_seq"] is None and env["page"]["has_more"] is False, env)
        # DB binding sanity: the Z microsecond timestamp and ::text id bind in real SQL
        c = DBManager()
        try:
            c.cur.execute("SELECT %s::timestamptz, %s::bigint, %s::text, %s::uuid",
                          ("2026-10-01T12:00:00.000005Z", 3, "aB3dE5gH7j", UID))
            row = c.cur.fetchone()
        finally:
            c.close()
        check("cursor values bind in SQL casts", row[1] == 3 and row[2] == "aB3dE5gH7j" and str(row[3]) == UID)

        # ---- 7. config loader
        print("config_loader / startup_checks")
        with tempfile.TemporaryDirectory() as td:
            def write(obj, name="c.json"):
                p = os.path.join(td, name)
                with open(p, "w") as f:
                    f.write(obj if isinstance(obj, str) else json.dumps(obj))
                return p

            kw = dict(required_keys=("n", "rate"), types={"n": int, "rate": str}, rate_keys=("rate",))
            good = write({"s": {"n": 5, "rate": "10/minute"}})
            check("load_section returns the section", config_loader.load_section(good, "s", **kw) == {"n": 5, "rate": "10/minute"})

            def bad(label, path, section="s", **over):
                try:
                    config_loader.load_section(path, section, **{**kw, **over})
                    check(label, False, "no error")
                except config_loader.ConfigSectionError:
                    check(label, True)

            bad("missing file rejected", os.path.join(td, "nope.json"))
            bad("invalid JSON rejected", write("{nope", "j.json"))
            bad("non-object top level rejected", write("[1]", "l.json"))
            bad("missing section rejected", good, section="other")
            bad("missing key rejected (no implicit defaults)", write({"s": {"n": 5}}, "m.json"))
            bad("unknown key rejected", write({"s": {"n": 5, "rate": "1/second", "x": 1}}, "u.json"))
            bad("wrong type rejected", write({"s": {"n": "5", "rate": "1/second"}}, "t.json"))
            bad("bool rejected where int declared", write({"s": {"n": True, "rate": "1/second"}}, "b.json"))
            bad("invalid rate string rejected", write({"s": {"n": 1, "rate": "lots"}}, "r.json"))
            bad("non-string rate rejected", write({"s": {"n": 1, "rate": 5}}, "r2.json"), types={"n": int, "rate": (str, int)})
            try:
                config_loader.load_section(good, "s", ("n",), {})
                check("types missing for a key is a programmer error", False)
            except ValueError:
                check("types missing for a key is a programmer error", True)

        startup_checks.validate_all()
        check("validate_all passes on the shipped registry/seed", True)
        saved_spec = flags._REGISTRY["explorer_browse"]
        flags._REGISTRY["explorer_browse"] = flags.FlagSpec("explorer_browse", no_canary=False)
        try:
            startup_checks.validate_all()
            check("startup check fails if explorer_browse loses no_canary", False)
        except RuntimeError:
            check("startup check fails if explorer_browse loses no_canary", True)
        finally:
            flags._REGISTRY["explorer_browse"] = saved_spec
        saved_reg = dict(flags._REGISTRY)
        flags._REGISTRY.pop("threads")
        try:
            startup_checks.validate_all()
            check("startup check fails if a seeded flag is unregistered", False)
        except RuntimeError:
            check("startup check fails if a seeded flag is unregistered", True)
        finally:
            flags._REGISTRY.clear()
            flags._REGISTRY.update(saved_reg)
        check("startup_checks wired into the lifespan",
              "validate_all" in open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "main.py")).read())

        # ---- 8. feature summary
        print("feature_summary")
        fs.snapshot_and_reset()
        fs.incr("public_404")
        fs.incr("public_404", 2)
        fs.incr("not_registered")
        fs.register_gauge("pending_join_requests", lambda: 4)
        fs.register_gauge("bad_gauge", lambda: 1 / 0)
        line = fs.build_line()
        check("line is FEATURE_SUMMARY with counters and gauges",
              line.startswith("FEATURE_SUMMARY ") and "public_404=3" in line and "pending_join_requests=4" in line
              and "outbox_backlog=" in line, line)
        check("unregistered counter ignored, failing gauge reads -1",
              "not_registered" not in line and "bad_gauge=-1" in line, line)
        check("counters reset after each line", "public_404=0" in fs.build_line())
        check("line has no ERROR word", "ERROR" not in line)
        fs.register_gauge("pending_join_requests", lambda: 0)
        fs._gauges.pop("bad_gauge", None)
        for fn, nm in ((fs.register_counter, "Bad-Name"), (lambda n: fs.register_gauge(n, lambda: 0), "9x")):
            try:
                fn(nm)
                check(f"invalid metric name {nm!r} rejected", False)
            except ValueError:
                check(f"invalid metric name {nm!r} rejected", True)
        import asyncio
        cap = Capture()
        fs.logger.addHandler(cap)
        fs.logger.setLevel(logging.INFO)
        try:
            asyncio.run(fs.run_feature_summary_job())
        finally:
            fs.logger.removeHandler(cap)
        check("async job emits one INFO FEATURE_SUMMARY line",
              len(cap.lines) == 1 and cap.lines[0][0] == "INFO" and cap.lines[0][1].startswith("FEATURE_SUMMARY"), cap.lines)
        from backend.interactions import scheduler as sched_mod
        src = open(sched_mod.__file__).read()
        check("scheduler registers the feature_summary job", 'id="feature_summary"' in src)
    finally:
        # restore flag rows and remove test users
        dbm = DBManager()
        try:
            for n, (st, ids) in saved.items():
                dbm.cur.execute("UPDATE feature_flags SET state=%s, canary_user_ids=%s::uuid[] WHERE name=%s",
                                (st, ids, n))
            dbm.cur.execute("UPDATE feature_flags SET updated_by=NULL WHERE updated_by = ANY(%s)", ([admin],))
            dbm.conn.commit()
        finally:
            dbm.close()
        delete_users(admin, plain, stale)
        flags.invalidate()

    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    for label, detail in FAILED:
        print(f"  FAILED: {label} -- {detail}")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
