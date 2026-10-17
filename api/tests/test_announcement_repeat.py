"""Backend coverage for task 20261016-announcement-recurring-reminder (testing step 3).

Real routes, real scheduler job function, real Postgres (scratch DB only; the
script refuses to run on port 5432 unless GITHUB_ACTIONS=true). Only
``send_push`` is faked (capturing), so no APNs call is made.

  A. Pure rules: interval/tz allowlists, repeat_until parsing (naive, past,
     > 365 days, before publish), month-end clamping without drift, DST
     (wall clock kept, spring-forward gap, fall-back no double), forward-only
     first_occurrence_after, end/occurrence-cap stop in next_armed.
  B. Migration: create_tables twice is a no-op, columns + partial index exist,
     DB CHECK rejects an unknown interval.
  C. Flag OFF (the shipped default): non-null repeat_interval is 422, null is
     accepted, responses carry no repeat_* keys, the job claims/sends nothing.
  D. Validation (flag on): bad interval/tz/until, naive/past/too-far/too-soon
     until, until or tz without an interval -> 422, never 500.
  E. Serialization: member-visible fields, repeat_tz editor-only, internal
     counters never exposed.
  F. Authorization: member 403, outsider 403, group creator may edit.
  G. Firing: one push per eligible recipient, "Reminder: {title}", group title,
     ids-only payload, no description; per-occurrence atomic dedup (re-tick and
     6 concurrent claimers -> exactly one winner).
  H. No back-fill: stale occurrence advanced without a push; recent one pushes
     once; next occurrence strictly in the future.
  I. Stops: past end date, 365-day horizon, 52 pushes, deleted (restore re-arms
     forward only), not yet published, author left/suspended, bad stored tz or
     missing state (disarm, fail closed).
  J. Caps: 3 repeating per group (409, edit of an existing one still fine),
     lifetime 52 (409 and not bypassable by off/on), per-group push budget
     (skip + advance), per-tick row cap, _over_cap counts repeat pushes.
  K. Recipients: author/members with token only; muted, blocked, opted-out
     (announcement_reminder) and token-less skipped; failing token isolated.
  L. Edit: clearing, switching interval, end-date-only edits, forward-only
     recompute, title edit sends nothing, repeat editable after publish while
     publish_at stays locked, reschedule of unpublished moves the anchor.
  M. Scheduler job announcement_repeat_fire registered via the real lifespan.

Run: cd api && DB_PASSWORD=... ../.venv/bin/python tests/test_announcement_repeat.py
"""
import _pathfix  # noqa: F401

import asyncio
import os
import threading
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import backend.interactions.announcement_notifier as notifier  # noqa: E402
import backend.interactions.announcement_repeat as repeat_job  # noqa: E402
import backend.interactions.announcement_repeat_rules as rules  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from db import DBManager, create_tables  # noqa: E402

UTC = timezone.utc
PASSED, FAILED = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def ck(token):
    return {"cookie": f"session={token}"} if token else {}


def signup(client, username):
    fake_ip = f"203.0.113.{uuid.uuid4().int % 250 + 1}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def sql(query, params=(), fetch=False):
    db = DBManager()
    try:
        db.cur.execute(query, params)
        out = db.cur.fetchall() if fetch else None
        db.conn.commit()
        return out
    finally:
        db.close()


def cleanup(user_ids, group_ids, sub_ids=()):
    db = DBManager()
    try:
        for gid in group_ids:
            db.cur.execute("DELETE FROM group_announcements WHERE group_id = %s", (gid,))
            db.cur.execute("DELETE FROM group_mutes WHERE group_id = %s", (gid,))
            db.cur.execute("DELETE FROM messages WHERE group_id = %s", (gid,))
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM group_announcements WHERE creator_id = %s", (uid,))
            db.cur.execute("DELETE FROM blocked_users WHERE blocker_id = %s OR blocked_id = %s", (uid, uid))
            db.cur.execute("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM push_preferences WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM messages WHERE from_user = %s", (uid,))
            db.cur.execute("DELETE FROM groups WHERE %s = ANY(users)", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        for sid in sub_ids:
            db.cur.execute("DELETE FROM subscriptions WHERE _id = %s", (sid,))
        db.conn.commit()
    finally:
        db.close()


def create_group(client, token, owner, members):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner}", json={"group_id": gid, "title": "Repeat Group", "users": [owner, *members]},
                    headers=ck(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def make_paid(uid):
    sid = str(uuid.uuid4())
    sql("INSERT INTO subscriptions (_id, user_id, plan_type, status, current_period_end) "
        "VALUES (%s,%s,'group','active', now() + interval '20 days')", (sid, uid))
    sql("UPDATE users SET subscription_id = %s WHERE _id = %s", (sid, uid))
    return sid


def base(u, g):
    return f"/groups/{u}/{g}/announcements"


def iso_in(**delta):
    return (datetime.now(UTC) + timedelta(**delta)).isoformat()


def set_token(uid, token):
    sql("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) "
        "ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token", (uid, token))


def tick():
    asyncio.run(repeat_job.fire_due_announcement_repeats())


def state(aid):
    r = sql("SELECT repeat_interval, repeat_until, repeat_tz, repeat_started_at, next_repeat_at, "
            "repeat_push_count, last_repeat_push_at, deleted_at FROM group_announcements WHERE _id=%s",
            (aid,), fetch=True)
    keys = ("interval", "until", "tz", "started", "next", "count", "last_push", "deleted")
    return dict(zip(keys, r[0])) if r else None


def make_due(aid, ago="1 minute"):
    sql("UPDATE group_announcements SET next_repeat_at = now() - %s::interval WHERE _id=%s", (ago, aid))


def now():
    return datetime.now(UTC)


SENT = []
FAIL_TOKENS = set()
_real_send_push = push_module.send_push


async def fake_send_push(device_token, title, body, data=None):
    if device_token in FAIL_TOKENS:
        raise RuntimeError("simulated APNs failure")
    SENT.append({"token": device_token, "title": title, "body": body, "data": data})
    return True


def pushes_for(gid):
    return [p for p in SENT if p["data"] and p["data"].get("group_id") == gid]


class World:
    """author a (paid, token), m1 (token), m2 (muted), m3 (blocked by author),
    m4 (no token), m5 (token, push fails), m6 (token, opted out of
    announcement_reminder), outsider o."""

    def __init__(self, client):
        tag = uuid.uuid4().hex[:8]
        self.users = {}
        for name in ("a", "m1", "m2", "m3", "m4", "m5", "m6", "o"):
            self.users[name] = signup(client, f"rp_{name}_{tag}")
        self.sids = [make_paid(self.users["a"][0])]
        self.tok = {n: f"tok-{n}-{tag}" for n in ("a", "m1", "m2", "m3", "m5", "m6")}
        for n, t in self.tok.items():
            set_token(self.users[n][0], t)
        self.gid = create_group(client, self.users["a"][1], self.users["a"][0],
                                [self.users[n][0] for n in ("m1", "m2", "m3", "m4", "m5", "m6")])
        sql("INSERT INTO group_mutes (group_id, user_id) VALUES (%s,%s)", (self.gid, self.users["m2"][0]))
        sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)",
            (self.users["a"][0], self.users["m3"][0]))
        sql("INSERT INTO push_preferences (user_id, announcement_reminder) VALUES (%s, FALSE)",
            (self.users["m6"][0],))
        self.client = client

    @property
    def a(self):
        return self.users["a"]

    def raw_post(self, who="a", **body):
        limiter.reset()
        body.setdefault("title", "Weekly standup")
        body.setdefault("description", "SECRET-DESCRIPTION-TEXT")
        uid, tok = self.users[who]
        return self.client.post(base(uid, self.gid), json=body, headers=ck(tok))

    def post(self, **body):
        r = self.raw_post(**body)
        assert r.status_code == 201, f"{r.status_code} {r.text}"
        return r.json()["id"]

    def put(self, aid, who="a", **body):
        limiter.reset()
        uid, tok = self.users[who]
        return self.client.put(f"{base(uid, self.gid)}/{aid}", json=body, headers=ck(tok))

    def get(self, aid, who="a"):
        limiter.reset()
        uid, tok = self.users[who]
        r = self.client.get(f"{base(uid, self.gid)}/{aid}", headers=ck(tok))
        assert r.status_code == 200, f"{r.status_code} {r.text}"
        return r.json()

    def repeating(self, interval="daily", **extra):
        """A published, repeating announcement (flag must be on)."""
        return self.post(repeat_interval=interval, repeat_tz="UTC", **extra)

    def close(self):
        cleanup([u for u, _ in self.users.values()], [self.gid], self.sids)


# ── A. pure rules ───────────────────────────────────────────────────────────
def test_rules():
    print("\n== A. pure rules ==")
    check("interval allowlist accepts daily/weekly/monthly/None",
          [rules.normalize_repeat_interval(v) for v in ("daily", "weekly", "monthly", None)]
          == ["daily", "weekly", "monthly", None])
    for bad in ("DAILY", "hourly", "", " daily", 5, ["daily"]):
        try:
            rules.normalize_repeat_interval(bad)
            check(f"interval {bad!r} rejected", False, "accepted")
        except ValueError:
            check(f"interval {bad!r} rejected", True)
    check("tz known name accepted / None accepted",
          rules.normalize_repeat_tz("America/New_York") == "America/New_York" and rules.normalize_repeat_tz(None) is None)
    for bad in ("Mars/Phobos", "", "x" * 65, 5, "../etc/passwd"):
        try:
            rules.normalize_repeat_tz(bad)
            check(f"tz {bad!r} rejected", False, "accepted")
        except ValueError:
            check(f"tz {bad!r} rejected", True)

    pub = now()
    n = now()

    def until_err(v, publish=pub):
        try:
            rules.parse_repeat_until(v, publish_at=publish, now=n)
            return None
        except ValueError as e:
            return str(e)
    check("until naive rejected", until_err((n + timedelta(days=3)).replace(tzinfo=None).isoformat()) is not None)
    check("until garbage rejected", until_err("tomorrow") is not None)
    check("until past rejected", until_err((n - timedelta(days=1)).isoformat()) is not None)
    check("until in the past rejected even when after an old publish time (rule-level)",
          until_err((n - timedelta(days=1)).isoformat(), publish=n - timedelta(days=10)) is not None)
    check("until before publish rejected",
          until_err((n + timedelta(days=2)).isoformat(), publish=n + timedelta(days=5)) is not None)
    check("until 366 days ahead rejected", until_err((n + timedelta(days=366)).isoformat()) is not None)
    check("until 364 days ahead accepted", until_err((n + timedelta(days=364)).isoformat()) is None)
    check("until Z suffix accepted", until_err((n + timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ")) is None)
    check("until None passes through", rules.parse_repeat_until(None, publish_at=pub) is None)

    # month-end clamping without drift (anchored to the original day)
    a = datetime(2027, 1, 31, 12, 0, tzinfo=UTC)
    got = [rules.occurrence(a, "monthly", None, k).date().isoformat() for k in (1, 2, 3, 4)]
    check("monthly Jan31 -> Feb28, Mar31, Apr30 (no drift)",
          got == ["2027-02-28", "2027-03-31", "2027-04-30", "2027-05-31"], str(got))
    leap = datetime(2027, 12, 31, 12, 0, tzinfo=UTC)
    check("monthly Dec31 + 2 -> Feb 2028 leap (29th)",
          rules.occurrence(leap, "monthly", None, 2).date().isoformat() == "2028-02-29")
    check("daily +1 day / weekly +7 days",
          rules.occurrence(a, "daily", None, 1) - a == timedelta(days=1)
          and rules.occurrence(a, "weekly", None, 2) - a == timedelta(days=14))

    # DST: 09:00 New York every day across spring-forward (2027-03-14) keeps 09:00 local
    ny = ZoneInfo("America/New_York")
    anchor = datetime(2027, 3, 12, 9, 0, tzinfo=ny).astimezone(UTC)
    locs = [rules.occurrence(anchor, "daily", "America/New_York", k).astimezone(ny) for k in (1, 2, 3)]
    check("daily across spring-forward keeps 09:00 local, one per day",
          [(d.day, d.hour) for d in locs] == [(13, 9), (14, 9), (15, 9)], str(locs))
    utc_hours = {rules.occurrence(anchor, "daily", "America/New_York", k).hour for k in (1, 2, 3)}
    check("UTC hour shifts across DST (14 -> 13), proving wall-clock anchoring", utc_hours == {14, 13}, str(utc_hours))
    # nonexistent 02:30 on 2027-03-14
    gap_anchor = datetime(2027, 3, 13, 2, 30, tzinfo=ny).astimezone(UTC)
    gap = rules.occurrence(gap_anchor, "daily", "America/New_York", 1).astimezone(ny)
    check("spring-forward gap time resolves to the instant after the gap (>= 03:00 local, same day)",
          gap.day == 14 and gap.hour >= 3, str(gap))
    # fall-back 2027-11-07: no duplicate instants across consecutive days
    fb = datetime(2027, 11, 5, 1, 30, tzinfo=ny).astimezone(UTC)
    inst = [rules.occurrence(fb, "daily", "America/New_York", k) for k in (1, 2, 3)]
    check("fall-back days produce strictly increasing distinct instants (no double fire)",
          inst[0] < inst[1] < inst[2] and len(set(inst)) == 3)
    check("fall-back occurrences are exactly 24h/25h apart on the local wall clock",
          (inst[1] - inst[0]) in (timedelta(hours=24), timedelta(hours=25)))
    check("different tz gives a different instant (tz is honoured)",
          rules.occurrence(anchor, "daily", "America/New_York", 5) != rules.occurrence(anchor, "daily", "Asia/Tokyo", 5))
    try:
        rules.occurrence(a, "hourly", None, 1)
        check("occurrence unknown interval raises", False)
    except ValueError:
        check("occurrence unknown interval raises", True)

    # forward only
    pa = datetime(2027, 1, 1, 9, 0, tzinfo=UTC)
    after = datetime(2027, 3, 20, 10, 0, tzinfo=UTC)
    for itv in ("daily", "weekly", "monthly"):
        nxt = rules.first_occurrence_after(pa, itv, None, after)
        check(f"first_occurrence_after {itv}: strictly after, no missed one skipped back",
              nxt > after and nxt - after <= timedelta(days=32)
              and (itv != "daily" or nxt == datetime(2027, 3, 21, 9, 0, tzinfo=UTC)), str(nxt))
    check("first_occurrence_after exactly at an occurrence is strictly later",
          rules.first_occurrence_after(pa, "daily", None, datetime(2027, 1, 5, 9, 0, tzinfo=UTC))
          == datetime(2027, 1, 6, 9, 0, tzinfo=UTC))

    end = pa + timedelta(days=10)
    check("next_armed returns next when within end",
          rules.next_armed(pa, "daily", None, pa + timedelta(hours=1), end, 0) == pa + timedelta(days=1))
    check("next_armed None past the end date",
          rules.next_armed(pa, "daily", None, pa + timedelta(days=10, hours=1), end, 3) is None)
    check("next_armed None at the occurrence cap",
          rules.next_armed(pa, "daily", None, pa, end, rules.ANNOUNCEMENT_REPEAT_MAX_OCCURRENCES) is None)
    check("next_armed None when end unknown", rules.next_armed(pa, "daily", None, pa, None, 0) is None)
    check("effective_end: until wins; else started+365d; else None",
          rules.effective_end(end, pa) == end and rules.effective_end(None, pa) == pa + timedelta(days=365)
          and rules.effective_end(None, None) is None)


# ── B. migration ────────────────────────────────────────────────────────────
def test_migration():
    print("\n== B. migration ==")
    db = DBManager()
    try:
        create_tables(db.cur)
        create_tables(db.cur)
        db.conn.commit()
        check("create_tables() twice without error", True)
    except Exception as e:
        db.conn.rollback()
        check("create_tables() twice without error", False, repr(e))
    finally:
        db.close()
    cols = {r[0]: r for r in sql(
        "SELECT column_name, is_nullable, column_default FROM information_schema.columns "
        "WHERE table_name='group_announcements'", fetch=True)}
    want = {"repeat_interval", "repeat_until", "repeat_tz", "repeat_started_at", "next_repeat_at",
            "repeat_push_count", "last_repeat_push_at"}
    check("all 7 repeat columns exist", want <= set(cols), str(want - set(cols)))
    check("repeat_push_count NOT NULL default 0",
          cols["repeat_push_count"][1] == "NO" and "0" in str(cols["repeat_push_count"][2]))
    check("repeat_interval nullable (existing rows unchanged: NULL = no repeat)", cols["repeat_interval"][1] == "YES")
    idx = sql("SELECT indexdef FROM pg_indexes WHERE tablename='group_announcements'", fetch=True)
    check("partial due-index exists", any("idx_group_announcements_repeat_due" in r[0] and "WHERE" in r[0] for r in idx))


def test_db_check(w):
    aid = w.post(title="check constraint")
    db = DBManager()
    try:
        try:
            db.cur.execute("UPDATE group_announcements SET repeat_interval='hourly' WHERE _id=%s", (aid,))
            db.conn.commit()
            check("DB CHECK rejects unknown repeat_interval", False, "accepted")
        except Exception:
            db.conn.rollback()
            check("DB CHECK rejects unknown repeat_interval", True)
    finally:
        db.close()


# ── C. flag off ─────────────────────────────────────────────────────────────
def test_flag_off(client):
    print("\n== C. flag off (forced; shipped default is now True) ==")
    check("ANNOUNCEMENT_REPEAT_ENABLED ships True (enabled by Jacey 2026-10-17)", rules.ANNOUNCEMENT_REPEAT_ENABLED is True)
    rules.ANNOUNCEMENT_REPEAT_ENABLED = False
    w = World(client)
    try:
        r = w.raw_post(repeat_interval="daily")
        check("flag off: non-null repeat_interval -> 422", r.status_code == 422, f"{r.status_code} {r.text}")
        check("flag off: 422 detail is the 'not available' message",
              "not available" in str(r.json().get("detail")), r.text)
        r = w.raw_post(repeat_interval="daily", repeat_until=iso_in(days=10), repeat_tz="UTC")
        check("flag off: full repeat payload -> 422", r.status_code == 422)
        r = w.raw_post(repeat_interval=None)
        check("flag off: explicit null repeat_interval accepted", r.status_code == 201, r.text)
        aid = r.json()["id"]
        check("flag off: response has no repeat_* keys", not [k for k in r.json() if k.startswith("repeat_")], str(r.json()))
        check("flag off: GET has no repeat_* keys", not [k for k in w.get(aid) if k.startswith("repeat_")])
        lr = w.client.get(base(w.a[0], w.gid), headers=ck(w.a[1]))
        check("flag off: list items have no repeat_* keys",
              lr.status_code == 200 and "repeat_" not in lr.text, lr.text[:200])
        r = w.put(aid, repeat_interval="weekly")
        check("flag off: PUT non-null repeat_interval -> 422", r.status_code == 422, r.text)
        r = w.put(aid, repeat_interval=None)
        check("flag off: PUT null repeat_interval accepted (clear is always allowed)", r.status_code == 200, r.text)
        check("flag off: row untouched (no repeat state)", state(aid)["interval"] is None and state(aid)["next"] is None)

        # job: even a forcibly-armed row sends nothing and is not claimed
        sql("UPDATE group_announcements SET repeat_interval='daily', repeat_started_at=now(), "
            "next_repeat_at = now() - interval '1 minute' WHERE _id=%s", (aid,))
        before = state(aid)["next"]
        SENT.clear()
        tick()
        check("flag off: job sends nothing", pushes_for(w.gid) == [])
        check("flag off: job takes no claim (state untouched)",
              state(aid)["next"] == before and state(aid)["count"] == 0)
        rules.ANNOUNCEMENT_REPEAT_ENABLED = True
        old = notifier.ANNOUNCEMENT_PUSH_ENABLED
        notifier.ANNOUNCEMENT_PUSH_ENABLED = False
        try:
            SENT.clear()
            tick()
            check("repeat flag on but push flag off: nothing sent, no claim",
                  pushes_for(w.gid) == [] and state(aid)["next"] == before)
        finally:
            notifier.ANNOUNCEMENT_PUSH_ENABLED = old
            rules.ANNOUNCEMENT_REPEAT_ENABLED = False
        sql("DELETE FROM group_announcements WHERE _id=%s", (aid,))
    finally:
        rules.ANNOUNCEMENT_REPEAT_ENABLED = False
        w.close()


# ── D. validation ───────────────────────────────────────────────────────────
def test_validation(w):
    print("\n== D. validation (flag on) ==")
    cases = {
        "unknown interval": dict(repeat_interval="hourly"),
        "uppercase interval": dict(repeat_interval="DAILY"),
        "numeric interval": dict(repeat_interval=5),
        "bad tz": dict(repeat_interval="daily", repeat_tz="Mars/Phobos"),
        "huge tz": dict(repeat_interval="daily", repeat_tz="x" * 500),
        "naive until": dict(repeat_interval="daily", repeat_until=(now() + timedelta(days=5)).replace(tzinfo=None).isoformat()),
        "garbage until": dict(repeat_interval="daily", repeat_until="next friday"),
        "past until": dict(repeat_interval="daily", repeat_until=iso_in(days=-1)),
        "until 400d ahead": dict(repeat_interval="daily", repeat_until=iso_in(days=400)),
        "until too soon for one reminder (daily, 1h)": dict(repeat_interval="daily", repeat_until=iso_in(hours=1)),
        "until without interval": dict(repeat_until=iso_in(days=5)),
        "tz without interval": dict(repeat_tz="UTC"),
        "until with null interval": dict(repeat_interval=None, repeat_until=iso_in(days=5)),
    }
    for label, body in cases.items():
        r = w.raw_post(title=f"v {label}"[:40], **body)
        check(f"create: {label} -> 422 (not 500)", r.status_code == 422, f"{r.status_code} {r.text[:120]}")
    n = sql("SELECT count(*) FROM group_announcements WHERE group_id=%s", (w.gid,), fetch=True)[0][0]
    check("no row created by any rejected request", n == 0, str(n))

    r = w.raw_post(repeat_interval="weekly", repeat_until=iso_in(days=30), repeat_tz="America/New_York")
    check("valid weekly + until + tz -> 201", r.status_code == 201, r.text)
    aid = r.json()["id"]
    s = state(aid)
    check("stored interval/tz/until + armed next in the future",
          s["interval"] == "weekly" and s["tz"] == "America/New_York" and s["until"] is not None
          and s["next"] is not None and s["next"] > now(), str(s))
    check("weekly next occurrence within 7 days of now", s["next"] - now() <= timedelta(days=7, minutes=1))
    check("repeat_started_at stamped", s["started"] is not None)
    for label, body in cases.items():
        if label in ("until without interval", "tz without interval"):
            continue  # on PUT these are legitimate partial edits of an existing repeat (section L)
        r = w.put(aid, **body)
        check(f"update: {label} -> 422", r.status_code == 422, f"{r.status_code} {r.text[:100]}")
    check("rejected updates left state untouched", state(aid)["interval"] == "weekly" and state(aid)["tz"] == "America/New_York")
    r = w.raw_post(repeat_interval="monthly", repeat_until=None)
    check("explicit null until accepted (no end date)", r.status_code == 201, r.text)
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))


# ── E. serialization ────────────────────────────────────────────────────────
def test_serialization(w):
    print("\n== E. member-visible fields ==")
    until = iso_in(days=20)
    aid = w.post(title="serial", repeat_interval="daily", repeat_until=until, repeat_tz="America/Chicago")
    ed = w.get(aid, "a")
    mem = w.get(aid, "m1")
    check("editor sees repeat_tz", ed.get("repeat_tz") == "America/Chicago", str(ed))
    check("member does NOT see repeat_tz", "repeat_tz" not in mem, str(mem))
    for k in ("repeat_interval", "repeat_until", "repeat_ends_at", "repeat_auto_stops", "repeat_active"):
        check(f"member sees {k}", k in mem, str(sorted(mem)))
    check("member: interval daily, active true, auto_stops false with explicit end",
          mem["repeat_interval"] == "daily" and mem["repeat_active"] is True and mem["repeat_auto_stops"] is False)
    check("repeat_ends_at == repeat_until when explicit",
          datetime.fromisoformat(mem["repeat_ends_at"]) == datetime.fromisoformat(mem["repeat_until"]))
    for k in ("next_repeat_at", "repeat_push_count", "repeat_started_at", "last_repeat_push_at"):
        check(f"{k} never exposed (editor or member)", k not in ed and k not in mem)
    aid2 = w.post(title="serial2", repeat_interval="weekly")
    m2 = w.get(aid2, "m1")
    check("no end date: repeat_until null, auto_stops true, ends_at ~ now+365d",
          m2["repeat_until"] is None and m2["repeat_auto_stops"] is True
          and abs((datetime.fromisoformat(m2["repeat_ends_at"]) - (now() + timedelta(days=365))).total_seconds()) < 300)
    plain = w.get(w.post(title="plain"), "m1")
    check("non-repeating: interval null, active false, ends_at null, auto_stops false",
          plain["repeat_interval"] is None and plain["repeat_active"] is False
          and plain["repeat_ends_at"] is None and plain["repeat_auto_stops"] is False)
    sql("UPDATE group_announcements SET next_repeat_at=NULL WHERE _id=%s", (aid2,))
    check("disarmed (next NULL): repeat_active false", w.get(aid2, "m1")["repeat_active"] is False)
    lst = w.client.get(base(w.users["m1"][0], w.gid), headers=ck(w.users["m1"][1])).json()
    items = lst if isinstance(lst, list) else lst.get("announcements", lst.get("items", []))
    check("list items for members expose repeat_interval and not repeat_tz",
          items and all("repeat_interval" in i and "repeat_tz" not in i for i in items), str(items)[:200])
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))


# ── F. authorization ────────────────────────────────────────────────────────
def test_authz(w):
    print("\n== F. authorization ==")
    aid = w.post(title="authz", repeat_interval="daily")
    r = w.put(aid, who="m1", repeat_interval=None)
    check("non-author member cannot clear repeat -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
    r = w.put(aid, who="m1", repeat_interval="weekly")
    check("non-author member cannot change repeat -> 403", r.status_code == 403)
    check("repeat unchanged after denied edits", state(aid)["interval"] == "daily")
    r = w.raw_post(who="m1", title="member repeating", repeat_interval="daily")
    check("plain member may create (existing rule) and sets own repeat -> 201 or 403, never 500",
          r.status_code in (201, 403), str(r.status_code))
    if r.status_code == 201:
        check("member-authored repeat is owned by that member", state(r.json()["id"])["interval"] == "daily")
    r = w.client.put(f"{base(w.users['o'][0], w.gid)}/{aid}", json={"repeat_interval": None}, headers=ck(w.users["o"][1]))
    check("outsider cannot edit repeat -> 403/404", r.status_code in (403, 404), str(r.status_code))
    r = w.client.put(f"{base(w.a[0], w.gid)}/{aid}", json={"repeat_interval": None})
    check("unauthenticated cannot edit repeat -> 401/403", r.status_code in (401, 403), str(r.status_code))
    r = w.client.put(f"{base(w.users['m1'][0], w.gid)}/{aid}", json={"repeat_interval": None}, headers=ck(w.a[1]))
    check("cookie/user mismatch rejected", r.status_code in (401, 403), str(r.status_code))
    # group creator may edit a member's announcement repeat
    mid = sql("SELECT _id FROM group_announcements WHERE group_id=%s AND creator_id=%s",
              (w.gid, w.users["m1"][0]), fetch=True)
    if mid:
        r = w.put(str(mid[0][0]), who="a", repeat_interval=None)
        check("group creator can clear a member's repeat (existing _require_editable)", r.status_code == 200, r.text)
    r = w.client.post(base(w.users["o"][0], w.gid), json={"title": "x", "repeat_interval": "daily"},
                      headers=ck(w.users["o"][1]))
    check("outsider cannot create repeating announcement -> 403/404", r.status_code in (403, 404), str(r.status_code))
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))


# ── G. firing, dedup ────────────────────────────────────────────────────────
def test_firing(w):
    print("\n== G. firing + per-occurrence atomic dedup ==")
    FAIL_TOKENS.add(w.tok["m5"])
    aid = w.repeating("daily", title="Pay dues")
    s0 = state(aid)
    SENT.clear()
    tick()
    check("tick before the occurrence sends nothing", pushes_for(w.gid) == [])
    make_due(aid)
    SENT.clear()
    tick()
    got = pushes_for(w.gid)
    want = sorted(w.tok[n] for n in ("a", "m1"))
    check("one push per eligible recipient (author + m1; muted/blocked/opted-out/no-token/failing skipped)",
          sorted(p["token"] for p in got) == want, f"{sorted(p['token'] for p in got)} vs {want}")
    p = got[0] if got else {}
    check("title = group title, body = 'Reminder: {title}'",
          p.get("title") == "Repeat Group" and p.get("body") == "Reminder: Pay dues", str(p))
    check("payload identifiers only",
          p.get("data") == {"action": "announcement", "group_id": w.gid, "announcement_id": aid}, str(p.get("data")))
    check("description never in push", all("SECRET-DESCRIPTION" not in str(x) for x in got))
    s1 = state(aid)
    check("count incremented to 1 and last_repeat_push_at set", s1["count"] == 1 and s1["last_push"] is not None, str(s1))
    check("next_repeat_at advanced strictly into the future", s1["next"] > now(), str(s1["next"]))
    check("next occurrence is the daily slot (<= 24h + slack from now)", s1["next"] - now() <= timedelta(days=1, minutes=2))
    SENT.clear()
    tick()
    tick()
    check("re-tick of the same occurrence sends nothing (dedup)", pushes_for(w.gid) == [])
    check("count still 1 after re-ticks", state(aid)["count"] == 1)

    # concurrent claimers
    make_due(aid)
    results = []
    barrier = threading.Barrier(6)

    def worker():
        db = DBManager()
        try:
            barrier.wait()
            results.append([str(r[0]) for r in repeat_job._claim_due(db)])
        finally:
            db.close()

    ts = [threading.Thread(target=worker) for _ in range(6)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    winners = [r for r in results if aid in r]
    check("6 concurrent claimers -> exactly one winner for the occurrence", len(winners) == 1, str(results))
    check("count incremented exactly once (2 total)", state(aid)["count"] == 2, str(state(aid)))

    # overlapping full ticks
    make_due(aid)
    SENT.clear()
    ths = [threading.Thread(target=tick) for _ in range(4)]
    [t.start() for t in ths]
    [t.join() for t in ths]
    n = len([p for p in pushes_for(w.gid) if p["token"] == w.tok["m1"]])
    check("4 overlapping job runs deliver exactly one push to a member", n == 1, str(n))

    # failing APNs is not retried
    FAIL_TOKENS.add(w.tok["m1"])
    FAIL_TOKENS.add(w.tok["a"])
    make_due(aid)
    c = state(aid)["count"]
    SENT.clear()
    tick()
    check("all-sends-fail: counted (claim before send), not retried", state(aid)["count"] == c + 1)
    FAIL_TOKENS.discard(w.tok["m1"])
    FAIL_TOKENS.discard(w.tok["a"])
    tick()
    check("failed occurrence is not retried on the next tick", pushes_for(w.gid) == [])
    FAIL_TOKENS.clear()
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))


# ── H. no back-fill ─────────────────────────────────────────────────────────
def test_no_backfill(w):
    print("\n== H. no back-fill ==")
    aid = w.repeating("daily", title="Backfill")
    sql("UPDATE group_announcements SET publish_at = now() - interval '10 days' WHERE _id=%s", (aid,))
    make_due(aid, "5 days")
    SENT.clear()
    tick()
    s = state(aid)
    check("5-day-stale occurrence: no push", pushes_for(w.gid) == [], str(len(pushes_for(w.gid))))
    check("stale: count not incremented", s["count"] == 0)
    check("stale: next advanced to first occurrence strictly after now", s["next"] is not None and s["next"] > now(), str(s["next"]))
    check("stale: next within one interval (not 5 queued pushes)", s["next"] - now() <= timedelta(days=1, minutes=2))
    SENT.clear()
    tick()
    check("stale: following tick still sends nothing", pushes_for(w.gid) == [])

    # a recent miss (inside the stale window) fires exactly once even though several days elapsed since publish
    make_due(aid, "10 minutes")
    SENT.clear()
    tick()
    check("recent occurrence (10 min late) pushes exactly once per recipient",
          sorted(p["token"] for p in pushes_for(w.gid)) == sorted(w.tok[n] for n in ("a", "m1", "m5")))
    s = state(aid)
    check("after a recent fire, next is again strictly in the future, count 1", s["next"] > now() and s["count"] == 1)

    # boundary around STALE_AFTER_SECONDS
    sql("UPDATE group_announcements SET next_repeat_at = now() - make_interval(secs => %s) WHERE _id=%s",
        (rules.ANNOUNCEMENT_REPEAT_STALE_AFTER_SECONDS + 120, aid))
    SENT.clear()
    tick()
    check("just past the stale threshold: skipped", pushes_for(w.gid) == [])
    # flag turned on late for a long-armed row: stale -> skip not burst
    weekly = w.repeating("weekly", title="Weekly late")
    sql("UPDATE group_announcements SET publish_at = now() - interval '60 days' WHERE _id=%s", (weekly,))
    make_due(weekly, "30 days")
    SENT.clear()
    tick()
    ws = state(weekly)
    check("weekly 30 days overdue: skipped, next within 7 days and in the future",
          pushes_for(w.gid) == [] and ws["next"] > now() and ws["next"] - now() <= timedelta(days=7, minutes=2), str(ws))
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))


# ── I. stops ────────────────────────────────────────────────────────────────
def test_stops(w):
    print("\n== I. stop conditions ==")

    def fired(aid, **sets):
        if sets:
            cols = ", ".join(f"{k} = %s" for k in sets)
            sql(f"UPDATE group_announcements SET {cols} WHERE _id=%s", (*sets.values(), aid))
        # keep the per-group push budget out of the way: these cases are about the stop
        # rules, so a "no push" result must come from the rule, not from the group cap
        sql("UPDATE group_announcements SET push_sent_at=NULL, creation_push_sent_at=NULL, "
            "last_repeat_push_at=NULL WHERE group_id=%s AND _id<>%s", (w.gid, aid))
        make_due(aid)
        SENT.clear()
        tick()
        return len([p for p in pushes_for(w.gid)]) > 0

    # positive control: with the same helper a plain live repeater DOES push, so
    # every "no push" below is attributable to its stop rule
    ctl = w.repeating("daily", title="Control")
    check("control: live repeater pushes through the stop-test helper", fired(ctl))
    sql("DELETE FROM group_announcements WHERE _id=%s", (ctl,))

    # end date passed
    aid = w.repeating("daily", title="Ends", repeat_until=iso_in(days=3))
    f = fired(aid, repeat_until=now() - timedelta(minutes=5))
    check("past repeat_until: no push", not f)
    check("past repeat_until: disarmed (next NULL), row kept", state(aid)["next"] is None and state(aid)["interval"] == "daily")
    SENT.clear()
    tick()
    check("disarmed row never fires again", pushes_for(w.gid) == [])
    check("disarmed row reports repeat_active false", w.get(aid)["repeat_active"] is False)

    # 365-day horizon with no end date
    aid = w.repeating("daily", title="Horizon")
    f = fired(aid, repeat_started_at=now() - timedelta(days=366))
    check("no end date + started 366d ago: no push, disarmed", not f and state(aid)["next"] is None)

    # 52 pushes
    aid = w.repeating("daily", title="Cap52")
    f = fired(aid, repeat_push_count=rules.ANNOUNCEMENT_REPEAT_MAX_OCCURRENCES)
    check("52 pushes done: no push, disarmed", not f and state(aid)["next"] is None)
    aid = w.repeating("daily", title="Cap51")
    f = fired(aid, repeat_push_count=rules.ANNOUNCEMENT_REPEAT_MAX_OCCURRENCES - 1)
    s = state(aid)
    check("51 pushes done: the 52nd is sent", f and s["count"] == 52, str(s))
    check("after the 52nd, nothing more is armed", s["next"] is None, str(s["next"]))

    # deleted
    aid = w.repeating("daily", title="Deleted")
    sql("UPDATE group_announcements SET deleted_at = now() WHERE _id=%s", (aid,))
    f = fired(aid)
    check("deleted row never fires", not f)
    check("deleted row's claim untouched (not consumed)", state(aid)["next"] is not None and state(aid)["count"] == 0)
    # restore through the real route re-arms forward only
    sql("UPDATE group_announcements SET next_repeat_at = now() - interval '3 days' WHERE _id=%s", (aid,))
    r = w.client.post(f"{base(w.a[0], w.gid)}/{aid}/restore", headers=ck(w.a[1]))
    check("restore route 200", r.status_code == 200, f"{r.status_code} {r.text}")
    s = state(aid)
    check("restore re-arms forward only (next strictly in the future)", s["next"] is not None and s["next"] > now(), str(s["next"]))
    SENT.clear()
    tick()
    check("restored: nothing back-filled", pushes_for(w.gid) == [])

    # delete via route then ensure deleted
    aid = w.repeating("daily", title="Del route")
    r = w.client.delete(f"{base(w.a[0], w.gid)}/{aid}", headers=ck(w.a[1]))
    check("delete route ok", r.status_code in (200, 204), str(r.status_code))
    check("deleted via route: no push", not fired(aid))

    # not yet published
    aid = w.post(title="Future", publish_at=iso_in(days=2), repeat_interval="daily", repeat_tz="UTC")
    s = state(aid)
    check("future-dated repeating: armed for after publish", s["next"] is not None and s["next"] > now() + timedelta(days=2))
    check("not yet published: never fires even if forced due", not fired(aid))

    # author left the group
    aid = w.repeating("daily", title="Author left")
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (w.a[0], w.gid))
    f = fired(aid)
    check("author no longer a member: no push", not f)
    check("author left: disarmed, row kept", state(aid)["next"] is None and state(aid)["interval"] == "daily")
    sql("UPDATE groups SET users = array_append(users, %s) WHERE _id=%s", (w.a[0], w.gid))
    SENT.clear()
    tick()
    check("author rejoining does not auto re-arm", pushes_for(w.gid) == [])

    # author suspended
    aid = w.repeating("daily", title="Suspended")
    sql("UPDATE users SET suspended_at = now() WHERE _id=%s", (w.a[0],))
    try:
        f = fired(aid)
        check("suspended author: no push, disarmed", not f and state(aid)["next"] is None)
    finally:
        sql("UPDATE users SET suspended_at = NULL WHERE _id=%s", (w.a[0],))

    # fail closed on invalid state
    aid = w.repeating("daily", title="Bad tz")
    f = fired(aid, repeat_tz="Not/AZone")
    check("invalid stored tz: no push, disarmed", not f and state(aid)["next"] is None)
    aid = w.repeating("daily", title="No state")
    f = fired(aid, repeat_started_at=None)
    check("no end date and no started_at (unparseable state): no push, disarmed", not f and state(aid)["next"] is None)
    aid = w.repeating("daily", title="Null interval row")
    sql("UPDATE group_announcements SET repeat_interval=NULL WHERE _id=%s", (aid,))
    check("repeat_interval NULL with stale next: never selected", not fired(aid))
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))


# ── J. caps ─────────────────────────────────────────────────────────────────
def test_caps(w):
    print("\n== J. caps ==")
    ids = [w.repeating("weekly", title=f"R{i}") for i in range(rules.ANNOUNCEMENT_REPEAT_MAX_ACTIVE_PER_GROUP)]
    r = w.raw_post(title="fourth", repeat_interval="daily")
    check("4th active repeating announcement -> 409", r.status_code == 409, f"{r.status_code} {r.text}")
    check("409 detail names the limit", "at most 3" in str(r.json().get("detail")), r.text)
    r = w.raw_post(title="fourth plain")
    check("non-repeating announcements still unrestricted", r.status_code == 201)
    r = w.put(ids[0], repeat_interval="monthly")
    check("editing an existing repeater at the cap is allowed (excludes itself)", r.status_code == 200, r.text)
    plain = r2 = w.raw_post(title="to repeat").json()["id"]
    r = w.put(plain, repeat_interval="daily")
    check("enabling repeat on a 4th via PUT -> 409", r.status_code == 409, f"{r.status_code} {r.text}")
    sql("UPDATE group_announcements SET deleted_at=now() WHERE _id=%s", (ids[1],))
    r = w.put(plain, repeat_interval="daily")
    check("deleted repeater frees a slot", r.status_code == 200, r.text)
    sql("UPDATE group_announcements SET next_repeat_at=NULL WHERE _id=%s", (ids[2],))
    r = w.raw_post(title="slot via disarm", repeat_interval="daily")
    check("disarmed repeater frees a slot", r.status_code == 201, r.text)
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))

    # lifetime cap
    aid = w.repeating("daily", title="Life")
    sql("UPDATE group_announcements SET repeat_push_count=52 WHERE _id=%s", (aid,))
    r = w.put(aid, repeat_interval="weekly")
    check("PUT repeat at lifetime cap -> 409", r.status_code == 409, f"{r.status_code} {r.text}")
    check("409 detail says reminder limit", "reminder limit" in str(r.json().get("detail")))
    r = w.put(aid, repeat_interval=None)
    check("turning off at the cap is allowed", r.status_code == 200)
    check("off/on does not reset the lifetime counter", state(aid)["count"] == 52)
    r = w.put(aid, repeat_interval="daily")
    check("re-enabling after off at the cap -> 409 (cap not bypassable by editing)", r.status_code == 409, r.text)
    check("count still 52", state(aid)["count"] == 52)
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))

    # per-group push budget
    aid = w.repeating("daily", title="Budgeted")
    others = [w.post(title=f"other{i}") for i in range(rules.ANNOUNCEMENT_REPEAT_GROUP_CAP)]
    SENT.clear()
    # "other" posts have push_sent_at recent (immediate publish pushes)
    recent_others = sql("SELECT count(*) FROM group_announcements WHERE group_id=%s AND _id<>%s AND "
                        "(push_sent_at > now()-interval '1 day' OR creation_push_sent_at > now()-interval '1 day')",
                        (w.gid, aid), fetch=True)[0][0]
    check("setup: other announcements consumed the group budget", recent_others >= rules.ANNOUNCEMENT_REPEAT_GROUP_CAP, str(recent_others))
    make_due(aid)
    SENT.clear()
    tick()
    s = state(aid)
    check("at the group cap: repeat push skipped", [p for p in pushes_for(w.gid)] == [], str(len(pushes_for(w.gid))))
    check("at the group cap: occurrence advanced (not retried every tick), not counted",
          s["next"] > now() and s["count"] == 0, str(s))
    # below cap: clear marks on all but cap-1 others
    cap = rules.ANNOUNCEMENT_REPEAT_GROUP_CAP
    sql("UPDATE group_announcements SET push_sent_at=NULL, creation_push_sent_at=NULL "
        "WHERE group_id=%s AND _id<>%s AND _id <> ALL(%s::uuid[])",
        (w.gid, aid, others[:cap - 1]))
    sql("UPDATE group_announcements SET push_sent_at=now() WHERE _id = ANY(%s::uuid[])", (others[:cap - 1],))
    sql("UPDATE group_announcements SET push_sent_at=NULL, creation_push_sent_at=NULL WHERE _id = ANY(%s::uuid[])", (others[cap - 1:],))
    make_due(aid)
    SENT.clear()
    tick()
    check("one below the group cap: repeat push goes out", len(pushes_for(w.gid)) == 3, str(len(pushes_for(w.gid))))
    check("below cap: counted", state(aid)["count"] == 1)
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))

    # a repeater's own prior pushes do not starve it
    aid = w.repeating("daily", title="Self")
    sql("UPDATE group_announcements SET last_repeat_push_at=now(), push_sent_at=now() WHERE _id=%s", (aid,))
    make_due(aid)
    SENT.clear()
    tick()
    check("its own recent pushes don't count against its group budget", len(pushes_for(w.gid)) == 3)
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))

    # existing hourly _over_cap now counts repeat pushes
    db = DBManager()
    try:
        before = notifier._over_cap(db, w.gid)
        for _ in range(notifier.ANNOUNCEMENT_PUSH_GROUP_HOURLY_CAP + 1):
            sql("INSERT INTO group_announcements (group_id, creator_id, title, publish_at, last_repeat_push_at) "
                "VALUES (%s,%s,'cap row', now(), now())", (w.gid, w.a[0]))
        after = notifier._over_cap(db, w.gid)
        check("notifier._over_cap counts last_repeat_push_at", before is False and after is True, f"{before} {after}")
    finally:
        db.close()
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))

    # per-tick row cap
    old = rules.ANNOUNCEMENT_REPEAT_MAX_ROWS_PER_TICK
    ids = []
    sql("UPDATE group_announcements SET next_repeat_at=NULL WHERE group_id=%s", (w.gid,))
    for i in range(3):
        a = w.repeating("daily", title=f"tickcap{i}") if i < 3 else None
        ids.append(a)
    rules.ANNOUNCEMENT_REPEAT_MAX_ROWS_PER_TICK = 2
    try:
        for a in ids:
            make_due(a)
        db = DBManager()
        try:
            claimed = repeat_job._claim_due(db)
        finally:
            db.close()
        mine = [r for r in claimed if str(r[0]) in ids]
        check("per-tick row cap limits the batch", len(mine) <= 2, str(len(mine)))
        left = sql("SELECT count(*) FROM group_announcements WHERE group_id=%s AND next_repeat_at <= now()",
                   (w.gid,), fetch=True)[0][0]
        check("remaining due row is left for the next tick", left >= 1, str(left))
    finally:
        rules.ANNOUNCEMENT_REPEAT_MAX_ROWS_PER_TICK = old
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))


# ── K. recipients ───────────────────────────────────────────────────────────
def test_recipients(w):
    print("\n== K. recipients ==")
    aid = w.repeating("daily", title="Who gets it")
    make_due(aid)
    SENT.clear()
    FAIL_TOKENS.add(w.tok["m5"])
    tick()
    toks = {p["token"] for p in pushes_for(w.gid)}
    check("muted member skipped", w.tok["m2"] not in toks)
    check("blocked-with-author member skipped", w.tok["m3"] not in toks)
    check("announcement_reminder opt-out skipped", w.tok["m6"] not in toks)
    check("failing recipient doesn't stop the others", {w.tok["a"], w.tok["m1"]} <= toks)
    check("outsider never pushed", all(p["token"] != "x" for p in SENT))
    FAIL_TOKENS.clear()
    # a toggle flip takes effect at the next occurrence
    sql("DELETE FROM push_preferences WHERE user_id=%s", (w.users["m6"][0],))
    make_due(aid)
    SENT.clear()
    tick()
    check("re-enabling the toggle includes the member next occurrence", w.tok["m6"] in {p["token"] for p in pushes_for(w.gid)})
    sql("INSERT INTO push_preferences (user_id, announcement_reminder) VALUES (%s, FALSE)", (w.users["m6"][0],))
    # long title truncation
    aid2 = w.repeating("daily", title="T" * 150)
    make_due(aid2)
    SENT.clear()
    tick()
    bodies = [p["body"] for p in pushes_for(w.gid) if p["data"]["announcement_id"] == aid2]
    check("body truncated to push max", bodies and all(len(b) <= notifier.ANNOUNCEMENT_PUSH_BODY_MAX for b in bodies), str(bodies))
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))


# ── L. edit ─────────────────────────────────────────────────────────────────
def test_edit(w):
    print("\n== L. edit semantics ==")
    aid = w.repeating("daily", title="Editable", repeat_until=iso_in(days=30))
    r = w.put(aid, repeat_interval=None)
    s = state(aid)
    check("PUT null interval clears the whole rule",
          r.status_code == 200 and s["interval"] is None and s["until"] is None and s["tz"] is None
          and s["next"] is None and s["started"] is None, str(s))
    check("response after clear: repeat_active false", r.json().get("repeat_active") is False)
    SENT.clear()
    make_due(aid)
    tick()
    check("cleared repeat never fires (takes effect before next claim)", pushes_for(w.gid) == [])

    # published long ago, then repeat is set: forward only
    old = w.post(title="Old post")
    sql("UPDATE group_announcements SET publish_at = now() - interval '10 days' WHERE _id=%s", (old,))
    SENT.clear()
    r = w.put(old, repeat_interval="weekly", repeat_tz="UTC")
    check("repeat can be set after publish (publish_at locked)", r.status_code == 200, r.text)
    s = state(old)
    check("setting repeat on an old post arms strictly forward (no back-fill)",
          s["next"] > now() and s["next"] - now() <= timedelta(days=7, minutes=2), str(s["next"]))
    check("setting repeat sends no push", pushes_for(w.gid) == [])
    r = w.put(old, publish_at=iso_in(days=3))
    check("publish_at stays locked after publish -> 422", r.status_code == 422, f"{r.status_code} {r.text}")

    r = w.put(old, repeat_until=iso_in(days=-1))
    check("end date in the past (but after an old publish time) -> 422", r.status_code == 422, f"{r.status_code} {r.text}")
    check("rejected past end date left state untouched", state(old)["until"] is None and state(old)["interval"] == "weekly")

    before = state(old)["next"]
    r = w.put(old, repeat_interval="daily")
    s = state(old)
    check("changing interval recomputes next from now (daily slot within 24h)",
          r.status_code == 200 and s["next"] > now() and s["next"] - now() <= timedelta(days=1, minutes=2), str(s["next"]))
    check("changing interval re-stamps repeat_started_at", s["started"] is not None)

    # keep cadence, only end date
    r = w.put(old, repeat_until=iso_in(days=20))
    s = state(old)
    check("send only repeat_until: interval kept, until set",
          r.status_code == 200 and s["interval"] == "daily" and s["until"] is not None and s["tz"] == "UTC", str(s))
    r = w.put(old, repeat_until=None)
    check("null until removes the end date, keeps repeat", r.status_code == 200 and state(old)["until"] is None
          and state(old)["interval"] == "daily")
    r = w.put(old, repeat_tz="Asia/Tokyo")
    check("tz-only edit keeps the interval", r.status_code == 200 and state(old)["tz"] == "Asia/Tokyo" and state(old)["interval"] == "daily")
    r = w.put(old, repeat_interval=None, repeat_until=iso_in(days=4))
    check("clearing the interval while sending an end date -> 422", r.status_code == 422, r.text)

    # title edit: no push, no schedule change
    nxt = state(old)["next"]
    SENT.clear()
    r = w.put(old, title="Renamed")
    check("title edit 200", r.status_code == 200)
    check("title edit sends no push", pushes_for(w.gid) == [])
    check("title edit leaves the schedule alone", state(old)["next"] == nxt)
    make_due(old)
    SENT.clear()
    tick()
    check("renamed title used in the next repeat body",
          [p["body"] for p in pushes_for(w.gid)][:1] == ["Reminder: Renamed"])

    # reschedule an unpublished repeating announcement moves its anchor
    fut = w.post(title="Resched", publish_at=iso_in(days=2), repeat_interval="daily", repeat_tz="UTC")
    n1 = state(fut)["next"]
    r = w.put(fut, publish_at=iso_in(days=6))
    n2 = state(fut)["next"]
    check("rescheduling an unpublished repeater moves the next occurrence later",
          r.status_code == 200 and n2 > n1 and n2 > now() + timedelta(days=6), f"{n1} {n2}")

    # past until stored can't be silently kept
    sql("UPDATE group_announcements SET repeat_until = now() - interval '1 hour' WHERE _id=%s", (old,))
    r = w.put(old, repeat_tz="UTC")
    check("editing a repeater whose end date already passed is rejected, not silently re-armed", r.status_code == 422, r.text)
    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))


# ── M. scheduler registration ───────────────────────────────────────────────
def test_scheduler_registered():
    print("\n== M. scheduler job registered ==")
    import backend.interactions.scheduler as sched
    src = open(sched.__file__).read()
    check("announcement_repeat_fire registered in scheduler source",
          'id="announcement_repeat_fire"' in src and "fire_due_announcement_repeats" in src)
    check("registered with replace_existing=True",
          "announcement_repeat_fire" in src and src[src.index("announcement_repeat_fire") - 400:src.index("announcement_repeat_fire") + 200].count("replace_existing=True") >= 1)
    check("poll interval 60s", rules.ANNOUNCEMENT_REPEAT_POLL_INTERVAL_SECONDS == 60)

    async def _start_and_list():
        sched.start_scheduler()
        try:
            job = sched.scheduler.get_job("announcement_repeat_fire")
            return job
        finally:
            sched.scheduler.shutdown(wait=False)

    job = asyncio.run(_start_and_list())
    check("job present on the live scheduler after start_scheduler()", job is not None)
    check("job interval trigger is 60s", job is not None and job.trigger.interval == timedelta(seconds=60), str(job and job.trigger))


def guard_port():
    port = sql("SHOW port", fetch=True)[0][0]
    ok = port != "5432" or os.environ.get("GITHUB_ACTIONS") == "true"
    check(f"tests run against a scratch DB (port {port}, never prod 5432)", ok, port)
    if not ok:
        raise SystemExit("refusing to run against port 5432")


def main():
    guard_port()
    push_module.send_push = fake_send_push
    try:
        test_rules()
        test_migration()
        if True:
            # The real lifespan needs production-only config (APNs keys etc.); schema
            # is created by test_migration's create_tables, so plain TestClient is enough.
            client = TestClient(main_module.app)
            test_flag_off(client)
            rules.ANNOUNCEMENT_REPEAT_ENABLED = True
            try:
                w = World(client)
                try:
                    test_db_check(w)
                    sql("DELETE FROM group_announcements WHERE group_id=%s", (w.gid,))
                    test_validation(w)
                    test_serialization(w)
                    test_authz(w)
                    test_firing(w)
                    test_no_backfill(w)
                    test_stops(w)
                    test_caps(w)
                    test_recipients(w)
                    test_edit(w)
                finally:
                    w.close()
                test_scheduler_registered()
            finally:
                rules.ANNOUNCEMENT_REPEAT_ENABLED = True
    finally:
        push_module.send_push = _real_send_push

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
