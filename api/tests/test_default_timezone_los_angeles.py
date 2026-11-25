"""Task 20261125-default-timezone-los-angeles: new users default to
America/Los_Angeles instead of UTC; existing rows are never rewritten.

Real app (main.app, lifespan included) + real Postgres, no mocks.

Covers:
  1. constants.DEFAULT_TIMEZONE value.
  2. Fresh-row behavior: a user INSERTed without timezone gets LA from the
     column default.
  3. Existing-DB migration: simulate a legacy DB (column default 'UTC', with a
     'UTC' user, a non-UTC user and an empty-string user), run create_tables()
     twice (idempotent), assert default is now LA and NO existing row changed.
  4. Real /signup with no timezone -> LA; explicit timezone honored; invalid
     timezone -> 422 (unchanged).
  5. Fallback sites: user_reminders._local_now(None/"") -> LA, invalid -> None
     (fail closed); activity_calendar fallback -> LA.
  6. Source guard: no remaining user-tz "UTC" fallback in api/ (excluding
     tests, affiliates.py, the invalid-name except path in agent.py).

Run:  cd api && ../.venv/bin/python tests/test_default_timezone_los_angeles.py
"""
import _pathfix  # noqa: F401,E402

import os
import re
import sys
import uuid
from datetime import datetime, timezone as tzmod

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager, create_tables  # noqa: E402
from constants import DEFAULT_TIMEZONE  # noqa: E402
import main as main_module  # noqa: E402

PASSED, FAILED = [], []
LA = "America/Los_Angeles"


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def q(sqltext, params=None, commit=False):
    db = DBManager()
    try:
        db.cur.execute(sqltext, params)
        rows = db.cur.fetchall() if db.cur.description else None
        if commit:
            db.conn.commit()
        return rows
    finally:
        db.close()


def insert_user(tz=None, explicit_tz=True):
    uid = str(uuid.uuid4())
    name = f"dtz_{uid[:8]}"
    if explicit_tz:
        q("INSERT INTO users (_id, username, email, hash_pass, timezone) VALUES (%s,%s,%s,'x',%s)",
          (uid, name, f"{name}@example.com", tz), commit=True)
    else:
        q("INSERT INTO users (_id, username, email, hash_pass) VALUES (%s,%s,%s,'x')",
          (uid, name, f"{name}@example.com"), commit=True)
    return uid


def tz_of(uid):
    return q("SELECT timezone FROM users WHERE _id=%s", (uid,))[0][0]


def column_default():
    return q("SELECT column_default FROM information_schema.columns "
             "WHERE table_name='users' AND column_name='timezone'")[0][0]


def run_create_tables():
    db = DBManager()
    try:
        create_tables(db.conn.cursor())
        db.conn.commit()
    finally:
        db.close()


def main():
    uids = []
    try:
        print("=== 1. constant ===")
        check("DEFAULT_TIMEZONE is America/Los_Angeles", DEFAULT_TIMEZONE == LA, DEFAULT_TIMEZONE)

        with TestClient(main_module.app) as client:
            print("=== 2. column default for fresh rows ===")
            check("column default is LA after app boot", LA in (column_default() or ""), column_default())
            u = insert_user(explicit_tz=False); uids.append(u)
            check("user inserted without timezone gets LA", tz_of(u) == LA, tz_of(u))

            print("=== 3. legacy DB: SET DEFAULT migration never rewrites rows ===")
            q("ALTER TABLE users ALTER COLUMN timezone SET DEFAULT 'UTC'", commit=True)
            check("simulated legacy default is UTC", "UTC" in (column_default() or ""), column_default())
            utc_u = insert_user("UTC"); tokyo_u = insert_user("Asia/Tokyo"); empty_u = insert_user("")
            uids += [utc_u, tokyo_u, empty_u]
            before = {x: tz_of(x) for x in (utc_u, tokyo_u, empty_u, u)}
            run_create_tables(); run_create_tables()  # idempotent
            check("default flipped to LA by init", LA in (column_default() or ""), column_default())
            after = {x: tz_of(x) for x in before}
            check("existing UTC user unchanged", after[utc_u] == "UTC", after[utc_u])
            check("existing Tokyo user unchanged", after[tokyo_u] == "Asia/Tokyo", after[tokyo_u])
            check("existing empty-string user unchanged (not rewritten)", after[empty_u] == "", repr(after[empty_u]))
            check("all rows identical before/after init", before == after, f"{before} vs {after}")
            n = insert_user(explicit_tz=False); uids.append(n)
            check("new row after migration gets LA", tz_of(n) == LA, tz_of(n))

            print("=== 4. real signup path ===")
            def signup(body_extra):
                name = f"dtz_{uuid.uuid4().hex[:8]}"
                r = client.post("/signup", json={"username": name, "email": f"{name}@example.com",
                                                 "plain_pass": "TestPass123!", "terms_accepted": True,
                                                 **body_extra})
                return r
            r = signup({})
            check("signup w/o timezone -> 201", r.status_code == 201, r.text)
            if r.status_code == 201:
                uids.append(r.json()["user_id"])
                check("signup response timezone is LA", r.json().get("timezone") == LA, r.text)
                check("signup persisted LA in Postgres", tz_of(r.json()["user_id"]) == LA)
            # SignUp has no timezone field (pre-existing): an explicit zone is
            # set afterwards via PUT /user/{id}; that path must be unchanged.
            r = signup({}); tok = r.cookies.get("session"); uid2 = r.json()["user_id"]; uids.append(uid2)
            hdr = {"cookie": f"session={tok}"}
            r = client.put(f"/user/{uid2}", json={"timezone": "Europe/London"}, headers=hdr)
            check("explicit timezone via PUT -> 200", r.status_code == 200, r.text)
            check("explicit timezone honored over LA default", tz_of(uid2) == "Europe/London", tz_of(uid2))
            r = client.put(f"/user/{uid2}", json={"timezone": "Not/AZone"}, headers=hdr)
            check("invalid timezone still 422", r.status_code == 422, f"{r.status_code} {r.text}")
            check("row unchanged after rejected update", tz_of(uid2) == "Europe/London")

        print("=== 5. fallback sites ===")
        from backend.interactions.user_reminders import _local_now
        now = datetime(2026, 1, 15, 12, 0, tzinfo=tzmod.utc)
        la_now = _local_now(LA, now)
        check("reminders: None tz -> LA", _local_now(None, now) == la_now and la_now.utcoffset().total_seconds() == -8 * 3600)
        check("reminders: empty tz -> LA", _local_now("", now) == la_now)
        check("reminders: invalid tz -> None (fail closed)", _local_now("Bad/Zone", now) is None)
        check("reminders: explicit UTC still UTC", _local_now("UTC", now).utcoffset().total_seconds() == 0)
        import backend.interactions.activity_calendar as ac
        check("activity_calendar _FALLBACK_TZ is LA", ac._FALLBACK_TZ == LA, ac._FALLBACK_TZ)

        print("=== 6. source guard ===")
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        pat = re.compile(r"""(or\s+["']UTC["']|COALESCE\([^)]*,\s*["']{1,2}UTC["']{1,2}\)|DEFAULT\s+["']{1,2}UTC["']{1,2}|_FALLBACK_TZ\s*=\s*["']UTC["'])""")
        hits = []
        for dp, dn, fn in os.walk(root):
            if "tests" in dp.split(os.sep) or "__pycache__" in dp:
                continue
            for f in fn:
                if f.endswith(".py"):
                    for i, line in enumerate(open(os.path.join(dp, f), encoding="utf-8"), 1):
                        if pat.search(line) and not line.lstrip().startswith("#"):
                            hits.append(f"{f}:{i}:{line.strip()}")
        check("no user-tz 'UTC' fallback left in api/", not hits, "; ".join(hits))
    finally:
        for x in uids:
            q("DELETE FROM users WHERE _id=%s", (x,), commit=True)
        q("ALTER TABLE users ALTER COLUMN timezone SET DEFAULT %s" % ("'" + LA + "'"), commit=True)

    print("\n" + "=" * 60)
    print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
    for l, d in FAILED:
        print(f"  X {l} -- {d}")
    print("STATUS:", "PASS" if not FAILED else "FAIL")
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
