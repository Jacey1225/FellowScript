"""Tests for the private activity calendar (task 20261114-activity-calendar).

Needs a THROWAWAY Postgres. db.py hardcodes port 5432 (the live DB), so this
script refuses to run unless TEST_PG_PORT is set to a different port, then
redirects every psycopg2 connection to it. Run:

  TEST_PG_PORT=54329 DB_PASSWORD=x ../.venv/bin/python tests/test_activity_calendar.py
"""
import _pathfix  # noqa: F401
import os
import sys

# GitHub Actions runs a throwaway Postgres service on 5432 (build-push.yml), so
# port 5432 is allowed there only; everywhere else 5432 may be the live DB.
_IN_CI = os.environ.get("GITHUB_ACTIONS") == "true"
_PORT = os.environ.get("TEST_PG_PORT", "") or ("5432" if _IN_CI else "")
if not _PORT or (_PORT == "5432" and not _IN_CI):
    print("SKIP: set TEST_PG_PORT to a scratch Postgres port (never 5432)")
    sys.exit(0)
os.environ.setdefault("DB_PASSWORD", "x")

import uuid
from datetime import datetime, timezone
from unittest import mock

import psycopg2

_real_connect = psycopg2.connect
psycopg2.connect = lambda *a, **k: _real_connect(*a, **{**k, "port": int(_PORT)})

from fastapi import FastAPI
from fastapi.testclient import TestClient

import db as dbmod
from db import DBManager, create_tables
from backend.auth.dependencies import get_current_user
from routes.activity_calendar import activity_calendar_router

_conn = dbmod._connect()
_conn.autocommit = True
create_tables(_conn.cursor())
_conn.close()

app = FastAPI()
app.include_router(activity_calendar_router)
client = TestClient(app)

USERS = []


def q(sql, params=()):
    d = DBManager()
    try:
        d.cur.execute(sql, params)
        try:
            return d.cur.fetchall()
        except psycopg2.ProgrammingError:
            return []
        finally:
            d.conn.commit()
    finally:
        d.close()


def make_user(tz="UTC"):
    uid = str(uuid.uuid4())
    q("INSERT INTO users (_id, username, email, hash_pass, timezone) VALUES (%s,%s,%s,'x',%s)",
      (uid, f"t_{uid[:8]}", f"t_{uid[:8]}@example.com", tz))
    USERS.append(uid)
    return uid


def as_user(uid):
    app.dependency_overrides[get_current_user] = lambda: uid


def month(uid, y, m):
    as_user(uid)
    r = client.get(f"/activity-calendar/month?year={y}&month={m}")
    assert r.status_code == 200, (r.status_code, r.text)
    return r.json()


def note(uid, ts, created=None, **extra):
    cols = {"_id": str(uuid.uuid4()), "user_id": uid, "title": "t", "text": "SECRET-NOTE",
            "timestamp": ts, "created_at": created or ts}
    cols.update(extra)
    q(f"INSERT INTO notes ({','.join(cols)}) VALUES ({','.join(['%s'] * len(cols))})", tuple(cols.values()))


def cleanup():
    for uid in USERS:
        q("DELETE FROM thread_messages WHERE from_user=%s", (uid,))
        q("DELETE FROM messages WHERE from_user=%s", (uid,))
        q("DELETE FROM notes WHERE user_id=%s", (uid,))
        q("DELETE FROM users WHERE _id=%s", (uid,))


def utc(*a):
    return datetime(*a, tzinfo=timezone.utc)


def t_auth():
    app.dependency_overrides.clear()
    assert client.get("/activity-calendar/month?year=2026&month=1").status_code == 401
    assert client.post("/activity-calendar/bible-day").status_code == 401
    # no user_id parameter exists: supplying one cannot select another user
    a, b = make_user(), make_user()
    note(b, utc(2026, 1, 5, 12))
    as_user(a)
    r = client.get(f"/activity-calendar/month?year=2026&month=1&user_id={b}")
    assert r.status_code == 200 and r.json()["days"] == {}, r.json()
    # real session path (no override): a valid cookie resolves to its own user
    from backend.auth.sessions import SessionManager
    app.dependency_overrides.clear()
    sm = SessionManager()
    try:
        tok = sm.create_session(b)
    finally:
        sm.close()
    if True:
        r = client.get("/activity-calendar/month?year=2026&month=1", cookies={"session": tok})
        assert r.status_code == 200 and r.json()["days"] == {"2026-01-05": ["note"]}, r.json()
    print("ok auth / owner-only")


def t_validation():
    as_user(make_user())
    for qs in ("year=1999&month=1", "year=2101&month=1", "year=2026&month=0", "year=2026&month=13",
               "year=abc&month=1", "month=1", "year=2026"):
        assert client.get(f"/activity-calendar/month?{qs}").status_code == 422, qs
    print("ok input validation 422")


def t_shape_and_cache():
    uid = make_user()
    note(uid, utc(2026, 5, 10, 12))
    as_user(uid)
    r = client.get("/activity-calendar/month?year=2026&month=5")
    assert r.headers["cache-control"] == "private, no-store"
    j = r.json()
    assert set(j) == {"year", "month", "timezone", "days"} and j["timezone"] == "UTC"
    assert j["days"] == {"2026-05-10": ["note"]}
    assert "SECRET-NOTE" not in r.text
    assert month(uid, 2026, 6)["days"] == {}
    print("ok shape, no counts, no content, no-store")


def t_chat_sources_and_exclusions():
    uid, other = make_user(), make_user()
    q("INSERT INTO agents (_id, user_id) VALUES (%s,%s)", (aid := str(uuid.uuid4()), uid))
    ins = "INSERT INTO agent_messages (title, agent_id, user_id, timestamp, content) VALUES (%s,%s,%s,%s,'SECRET')"
    q(ins, ("user", aid, uid, utc(2026, 4, 2, 10)))        # counts: Apr 2
    q(ins, ("assistant", aid, uid, utc(2026, 4, 3, 10)))   # assistant line: excluded
    q("INSERT INTO messages (from_user, text, timestamp) VALUES (%s,'hi',%s)", (uid, utc(2026, 4, 4, 10)))  # Apr 4
    q("INSERT INTO messages (from_user, text, timestamp, deleted_at) VALUES (%s,'hi',%s,NOW())",
      (uid, utc(2026, 4, 5, 10)))                           # deleted: excluded
    q("INSERT INTO messages (from_user, text, timestamp, system_kind) VALUES (%s,'pin',%s,'pin')",
      (uid, utc(2026, 4, 6, 10)))                           # system: excluded
    q("INSERT INTO messages (from_user, text, timestamp) VALUES (%s,'hi',%s)", (other, utc(2026, 4, 7, 10)))  # someone else's
    tid = str(uuid.uuid4())
    gid = str(uuid.uuid4())
    q("INSERT INTO groups (_id, title) VALUES (%s,'g')", (gid,))
    q("INSERT INTO threads (_id, group_id, title) VALUES (%s,%s,'t')", (tid, gid))
    q("INSERT INTO thread_messages (thread_id, from_user, text, created_at) VALUES (%s,%s,'x',%s)",
      (tid, uid, utc(2026, 4, 8, 10)))                      # counts: Apr 8
    q("INSERT INTO thread_messages (thread_id, from_user, text, created_at, deleted_at) VALUES (%s,%s,'x',%s,NOW())",
      (tid, uid, utc(2026, 4, 9, 10)))                      # deleted: excluded
    q("INSERT INTO thread_messages (thread_id, from_user, text, created_at) VALUES (%s,%s,'x',%s)",
      (tid, other, utc(2026, 4, 10, 10)))                   # someone else's
    days = month(uid, 2026, 4)["days"]
    assert days == {"2026-04-02": ["chat"], "2026-04-04": ["chat"], "2026-04-08": ["chat"]}, days
    assert month(other, 2026, 4)["days"] == {"2026-04-07": ["chat"], "2026-04-10": ["chat"]}
    q("DELETE FROM groups WHERE _id=%s", (gid,))
    print("ok chat sources + exclusions (assistant, deleted, system, others')")


def t_notes_rules():
    uid = make_user()
    note(uid, utc(2026, 7, 1, 12))                                              # plain
    note(uid, utc(2026, 7, 2, 12), is_reply=True)                              # reply counts
    note(uid, utc(2026, 7, 3, 12), summary_dedupe_key=f"sessionsum:{uuid.uuid4()}")  # fan-out: excluded
    note(uid, utc(2026, 7, 4, 12), theme="prayer")                             # heartbeat: excluded
    note(uid, utc(2026, 7, 5, 12), theme="")                                   # empty theme: counts
    # legacy row: created_at = migration time (later), timestamp = true time
    note(uid, utc(2026, 7, 6, 12), created=utc(2026, 11, 1, 0))
    # new row skewed the other way: created_at earlier wins
    note(uid, utc(2026, 7, 8, 12), created=utc(2026, 7, 7, 12))
    days = month(uid, 2026, 7)["days"]
    assert days == {"2026-07-01": ["note"], "2026-07-02": ["note"], "2026-07-05": ["note"],
                    "2026-07-06": ["note"], "2026-07-07": ["note"]}, days
    # legacy row must NOT appear in the migration month
    assert month(uid, 2026, 11)["days"] == {}
    print("ok notes: replies count, fan-out/themed excluded, LEAST() legacy handling")
    print("   documented limitation: heartbeat note with EMPTY theme is counted")


def t_tz_boundaries():
    uid = make_user("America/Los_Angeles")
    # month boundary: 2026-03-01 07:30Z = Feb 28 23:30 PST
    note(uid, utc(2026, 3, 1, 7, 30))
    assert month(uid, 2026, 2)["days"] == {"2026-02-28": ["note"]}
    assert month(uid, 2026, 3)["days"] == {}
    # spring-forward 2026-03-08 (02:00 PST -> PDT at 10:00Z)
    note(uid, utc(2026, 3, 8, 7, 59))   # Mar 7 23:59 PST
    note(uid, utc(2026, 3, 8, 8, 0))    # Mar 8 00:00 PST
    note(uid, utc(2026, 3, 9, 6, 59))   # Mar 8 23:59 PDT
    note(uid, utc(2026, 3, 9, 7, 0))    # Mar 9 00:00 PDT
    d = month(uid, 2026, 3)["days"]
    assert d == {"2026-03-07": ["note"], "2026-03-08": ["note"], "2026-03-09": ["note"]}, d
    # a 23-hour local day: Mar 8 contains both 08:00Z and 06:59Z next day only
    # fall-back 2026-11-01 (PDT -> PST at 09:00Z); local day is 25h
    note(uid, utc(2026, 11, 1, 6, 59))  # Oct 31 23:59 PDT
    note(uid, utc(2026, 11, 1, 7, 0))   # Nov 1 00:00 PDT
    note(uid, utc(2026, 11, 2, 7, 59))  # Nov 1 23:59 PST
    note(uid, utc(2026, 11, 2, 8, 0))   # Nov 2 00:00 PST
    assert month(uid, 2026, 10)["days"].get("2026-10-31") == ["note"]
    d = month(uid, 2026, 11)["days"]
    assert d == {"2026-11-01": ["note"], "2026-11-02": ["note"]}, d
    # year boundary + month=12 path: Jan 1 UTC 03:00 = Dec 31 19:00 EST
    e = make_user("America/New_York")
    note(e, utc(2027, 1, 1, 3))
    assert month(e, 2026, 12)["days"] == {"2026-12-31": ["note"]}
    assert month(e, 2027, 1)["days"] == {}
    # east-of-UTC zone: Sydney rolls to next day early
    s = make_user("Australia/Sydney")
    note(s, utc(2026, 6, 30, 14, 30))  # Jul 1 00:30 AEST
    assert month(s, 2026, 7)["days"] == {"2026-07-01": ["note"]} and month(s, 2026, 6)["days"] == {}
    # leap day
    l = make_user("UTC")
    note(l, utc(2028, 2, 29, 23, 59))
    assert month(l, 2028, 2)["days"] == {"2028-02-29": ["note"]}
    print("ok timezone: month/day/DST/year/leap boundaries")


def t_tz_fallback_and_rebucket():
    uid = make_user("Not/AZone")
    note(uid, utc(2026, 8, 1, 3))
    r = month(uid, 2026, 8)
    assert r["timezone"] == "UTC" and r["days"] == {"2026-08-01": ["note"]}
    q("UPDATE users SET timezone='America/Los_Angeles' WHERE _id=%s", (uid,))
    r = month(uid, 2026, 8)  # re-buckets: Jul 31 20:00 PDT
    assert r["days"] == {} and month(uid, 2026, 7)["days"] == {"2026-07-31": ["note"]}
    # SQL-injection-ish zone value is rejected by the whitelist, falls back
    q("UPDATE users SET timezone=%s WHERE _id=%s", ("UTC'; DROP TABLE notes;--", uid))
    assert month(uid, 2026, 8)["timezone"] == "UTC"
    assert q("SELECT to_regclass('notes')")[0][0] == "notes"
    print("ok timezone fallback, re-bucketing, injection value harmless")


def t_naive_agent_timestamp():
    """agent_messages.timestamp is written as a naive datetime.now() by the app.
    Postgres reads a naive value in the SESSION time zone, so the stored instant
    equals the server-local wall clock. Correct iff the server zone matches the
    zone of the process writing it. Limitation is documented, behaviour pinned."""
    uid = make_user("UTC")
    q("INSERT INTO agents (_id, user_id) VALUES (%s,%s)", (aid := str(uuid.uuid4()), uid))
    naive = datetime.now().replace(microsecond=0)
    q("INSERT INTO agent_messages (title, agent_id, user_id, timestamp) VALUES ('user',%s,%s,%s)",
      (aid, uid, naive))
    stored = q("SELECT timestamp FROM agent_messages WHERE user_id=%s", (uid,))[0][0]
    assert stored == naive.astimezone(), (stored, naive.astimezone())  # local-zone interpretation
    expect = stored.astimezone(timezone.utc).date().isoformat()
    d = month(uid, stored.year, stored.month)["days"]
    assert d == {expect: ["chat"]}, (d, expect)
    print("ok naive agent_messages timestamp: interpreted in session zone (limitation documented)")


def t_bible():
    uid, other = make_user("Pacific/Auckland"), make_user()
    as_user(uid)
    for _ in range(3):  # idempotent
        r = client.post("/activity-calendar/bible-day")
        assert r.status_code == 204 and r.content == b""
    # body / query attempts to supply a day or another user are ignored
    r = client.post(f"/activity-calendar/bible-day?day=2020-01-01&user_id={other}", json={"day": "2020-01-01"})
    assert r.status_code == 204
    rows = q("SELECT user_id::text, day FROM bible_reading_days WHERE user_id IN (%s,%s)", (uid, other))
    assert len(rows) == 1 and rows[0][0] == uid, rows
    today_nz = q("SELECT (NOW() AT TIME ZONE 'Pacific/Auckland')::date")[0][0]
    assert rows[0][1] == today_nz, (rows, today_nz)
    r = month(uid, today_nz.year, today_nz.month)
    assert r["days"][today_nz.isoformat()] == ["bible"] and r["timezone"] == "Pacific/Auckland"
    assert month(other, today_nz.year, today_nz.month)["days"] == {}
    # only day stored
    cols = [r[0] for r in q("SELECT column_name FROM information_schema.columns WHERE table_name='bible_reading_days' ORDER BY 1")]
    assert cols == ["day", "user_id"], cols
    # combined kinds sorted on one day
    note(uid, datetime.combine(today_nz, datetime.min.time()).replace(hour=12, tzinfo=timezone.utc))
    kinds = month(uid, today_nz.year, today_nz.month)["days"][today_nz.isoformat()]
    assert kinds == sorted(kinds) and "bible" in kinds, kinds
    print("ok bible: 204, idempotent, server-computed day in user tz, owner-only, day-only storage")


def t_cascade():
    uid = make_user()
    as_user(uid)
    client.post("/activity-calendar/bible-day")
    assert q("SELECT 1 FROM bible_reading_days WHERE user_id=%s", (uid,))
    q("DELETE FROM users WHERE _id=%s", (uid,))
    assert not q("SELECT 1 FROM bible_reading_days WHERE user_id=%s", (uid,))
    print("ok account deletion cascades to bible_reading_days")


def t_fail_closed():
    uid = make_user()
    as_user(uid)
    from backend.interactions import activity_calendar as ac
    with mock.patch.object(ac.ActivityCalendarManager, "month_activity", side_effect=RuntimeError("SECRET-boom")):
        r = client.get("/activity-calendar/month?year=2026&month=1")
    assert r.status_code == 500 and "SECRET" not in r.text, r.text
    with mock.patch.object(ac.ActivityCalendarManager, "record_bible_day", side_effect=RuntimeError("x")):
        assert client.post("/activity-calendar/bible-day").status_code == 500
    # a real SQL failure (table missing) surfaces as 500, not an empty calendar
    c = DBManager(); c.cur.execute("ALTER TABLE bible_reading_days RENAME TO brd_x"); c.conn.commit(); c.close()
    try:
        r = client.get("/activity-calendar/month?year=2026&month=1")
        assert r.status_code == 500, r.status_code
    finally:
        c = DBManager(); c.cur.execute("ALTER TABLE brd_x RENAME TO bible_reading_days"); c.conn.commit(); c.close()
    assert client.get("/activity-calendar/month?year=2026&month=1").status_code == 200
    print("ok fail-closed: 500 never empty calendar, no detail leak, recovers")


def t_logs_no_details():
    import logging
    uid = make_user()
    as_user(uid)
    from backend.interactions import activity_calendar as ac
    h = []
    class H(logging.Handler):
        def emit(self, rec): h.append(rec.getMessage())
    lg = logging.getLogger(); hd = H(); lg.addHandler(hd)
    try:
        with mock.patch.object(ac.ActivityCalendarManager, "month_activity", side_effect=RuntimeError("SECRET-boom")):
            client.get("/activity-calendar/month?year=2026&month=1")
    finally:
        lg.removeHandler(hd)
    assert any("ACTIVITY_CALENDAR_READ_FAILED" in m for m in h) and not any("SECRET" in m or uid in m for m in h), h
    print("ok logs carry only fixed marker")


def t_main_app_wiring():
    import main
    paths = {getattr(r, "path", "") for r in main.app.routes}
    assert "/activity-calendar/month" in paths and "/activity-calendar/bible-day" in paths
    from fastapi.testclient import TestClient as TC
    c = TC(main.app)  # no lifespan: only wiring + auth dependency
    assert c.get("/activity-calendar/month?year=2026&month=1").status_code == 401
    assert c.post("/activity-calendar/bible-day").status_code == 401
    print("ok real main.app registers routes and enforces auth")


if __name__ == "__main__":
    try:
        for name, fn in list(globals().items()):
            if name.startswith("t_"):
                fn()
        print("✅ all activity-calendar tests passed")
    except Exception:
        import traceback
        traceback.print_exc()
        print("❌ FAIL")
        sys.exit(1)
    finally:
        app.dependency_overrides.clear()
        cleanup()
