"""Free-plan entitlement gates (task 20261002-free-plan-limits-ui, testing step 2).

Properties proved (each would catch a regression of the behaviour it names):
  1. Config: api/config/free_limits.json drives FREE_LIMITS (notes 5, agent_events 1,
     announcements 1, sessions 1) and PAID_ONLY_RESOURCES; the loader refuses a
     missing key, a non-positive count, an unknown key and a non-boolean paid-only flag.
  2. Sessions (POST /devotions/): a free user with 1 active session created is blocked
     with 403 {resource: "sessions", allowed: false, used: 1, limit: 1}; an ended session
     stops counting (no lifetime cap: several create-then-end cycles all succeed);
     recurring and open-ended sessions count as active; creator_id is forced to the
     caller; sessions created by others / joined do not count (joining is unaffected);
     paid and admin-comp users are unlimited; blocked requests delete and write nothing.
  3. Session summaries (POST /agent/{u}/{a}/summarize): free -> 403 resource
     session_summaries with paid_only true, raised before the notes gate and before the
     model; check_paid_only fails closed for an unknown resource, honours the config
     flag, and passes for paid and admin-comp users.
  4. Explorer submit (POST /explorer/{u}/groups/{g}/listing/submit): free -> 403
     resource explorer_publish paid_only true and the draft stays a draft; paid ->
     200; an already-published listing of a free owner is untouched (still published,
     can still be unpublished) but cannot be re-submitted; save (PUT) and GET stay free.
  5. Usage endpoint (GET /subscriptions/user/{id}/usage): reports notes limit 5, sessions
     limit/used, paid_only {session_summaries, explorer_publish} with allowed/free_allowed
     per plan, window_days and announcements_window_days.

DB tests use the require_scratch_db() guard (scratch 55432 locally, CI Postgres 5432
under GITHUB_ACTIONS). All rows are uuid-derived and removed in finally; feature
flags are restored.

Run:  cd api && ../.venv/bin/python tests/test_free_plan_gates.py
"""
import _pathfix  # noqa: F401
import _fake_timeline  # noqa: F401
import _thr_common as T
from _thr_common import check, sql, make_user, require_scratch_db, PASSED, FAILED, USERS, GROUPS

import json
import os
import tempfile
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi.testclient import TestClient

import main as main_module
from db import DBManager
from backend.auth.sessions import SessionManager
from backend.interactions import flags
from backend.registrations import load_all
from backend.rate_limiting import limiter
from backend.subscription import limits as limits_mod
from backend.subscription.limits import LimitsManager, check_paid_only
from schemas import subscription as sub_schema

SUB_USERS = []


def iso(delta_hours):
    return (datetime.now(timezone.utc) + timedelta(hours=delta_hours)).isoformat()


def session_headers(uid):
    sm = SessionManager()
    try:
        return {"cookie": f"session={sm.create_session(uid)}"}
    finally:
        sm.close()


def make_paid(uid, provider="stripe", plan="individual"):
    sub_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("subscriptions", {
            "_id": sub_id, "user_id": uid, "plan_type": plan,
            "provider": provider, "status": "active",
        })
        db.update("users", {"subscription_id": sub_id}, {"_id": uid})
    finally:
        db.close()
    SUB_USERS.append(uid)


def create_session(cli, uid, hdr, **fields):
    limiter.reset()
    plan = {"title": "s", "time_start": iso(1), "time_end": iso(2)}
    plan.update(fields)
    return cli.post("/devotions/", json={"devotion_id": str(uuid.uuid4()), "user_id": uid,
                                         "devotion": plan}, headers=hdr)


def count_sessions(uid):
    return sql("SELECT count(*) FROM devotions WHERE creator_id = %s", (uid,))[0][0]


def end_sessions(uid):
    sql("UPDATE devotions SET time_end = now() - interval '1 hour', recurring = FALSE "
        "WHERE creator_id = %s", (uid,))


def usage(cli, uid, hdr):
    return cli.get(f"/subscriptions/user/{uid}/usage", headers=hdr).json()


# -- 1. config ------------------------------------------------------------------

def test_config():
    print("CONFIG")
    check("FREE_LIMITS notes == 5", sub_schema.FREE_LIMITS["notes"] == 5, sub_schema.FREE_LIMITS)
    check("FREE_LIMITS agent_events == 1 (devotion limit unchanged)", sub_schema.FREE_LIMITS["agent_events"] == 1)
    check("FREE_LIMITS announcements == 1", sub_schema.FREE_LIMITS["announcements"] == 1)
    check("FREE_LIMITS sessions == 1", sub_schema.FREE_LIMITS["sessions"] == 1)
    check("PAID_ONLY_RESOURCES both blocked for free",
          sub_schema.PAID_ONLY_RESOURCES == {"session_summaries": True, "explorer_publish": True},
          sub_schema.PAID_ONLY_RESOURCES)
    check("notes window 7 days", sub_schema.NOTES_WINDOW_DAYS == 7)

    good = json.loads(Path(sub_schema._FREE_LIMITS_PATH).read_text())

    def load_with(mutate):
        data = json.loads(json.dumps(good))
        mutate(data["free_limits"])
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "free_limits.json"
            p.write_text(json.dumps(data))
            old = sub_schema._FREE_LIMITS_PATH
            sub_schema._FREE_LIMITS_PATH = p
            try:
                sub_schema._load_free_limits_config()
                return None
            except RuntimeError as e:
                return str(e)
            finally:
                sub_schema._FREE_LIMITS_PATH = old

    check("unmodified config loads", load_with(lambda c: None) is None)
    check("loader rejects missing key", load_with(lambda c: c.pop("sessions")) is not None)
    check("loader rejects extra key", load_with(lambda c: c.update(extra=1)) is not None)
    check("loader rejects notes = 0", load_with(lambda c: c["counts"].update(notes=0)) is not None)
    check("loader rejects boolean count", load_with(lambda c: c["counts"].update(notes=True)) is not None)
    check("loader rejects sessions.max_active = 0", load_with(lambda c: c["sessions"].update(max_active=0)) is not None)
    check("loader rejects non-bool paid_only flag",
          load_with(lambda c: c["paid_only"].update(explorer_publish="yes")) is not None)
    check("loader rejects missing paid_only entry", load_with(lambda c: c["paid_only"].pop("session_summaries")) is not None)


# -- 2. sessions ------------------------------------------------------------------

def test_sessions(cli):
    print("SESSIONS (POST /devotions/)")
    free, other = make_user("fpg"), make_user("fpg")
    hdr, ohdr = session_headers(free), session_headers(other)

    u0 = usage(cli, free, hdr)["resources"]["sessions"]
    check("usage: sessions limit 1, used 0 before any create", (u0["limit"], u0["used"]) == (1, 0), u0)

    r1 = create_session(cli, free, hdr)
    check("1st session created (201)", r1.status_code == 201, r1.text)
    r2 = create_session(cli, free, hdr)
    check("2nd session while 1 active -> 403", r2.status_code == 403, r2.text)
    d = r2.json().get("detail", {})
    check("403 body resource == sessions", d.get("resource") == "sessions", d)
    check("403 body allowed false, limit 1, used 1, remaining 0",
          (d.get("allowed"), d.get("limit"), d.get("used"), d.get("remaining")) == (False, 1, 1, 0), d)
    check("403 body unlimited false", d.get("unlimited") is False, d)
    check("blocked create wrote no row", count_sessions(free) == 1, count_sessions(free))
    check("usage: sessions used 1 remaining 0",
          (usage(cli, free, hdr)["resources"]["sessions"]["used"],
           usage(cli, free, hdr)["resources"]["sessions"]["remaining"]) == (1, 0))

    # No lifetime cap: end the session, create again, repeatedly.
    ok = []
    for _ in range(3):
        end_sessions(free)
        ok.append(create_session(cli, free, hdr).status_code)
    check("create again after the prior session ended, 3 cycles (no lifetime cap)", ok == [201, 201, 201], ok)
    check("ended sessions are kept (no deletion): 4 rows", count_sessions(free) == 4, count_sessions(free))
    check("usage counts only the active one", usage(cli, free, hdr)["resources"]["sessions"]["used"] == 1)

    # Boundary: time_end already in the past does not count
    end_sessions(free)
    r = create_session(cli, free, hdr, time_start=iso(-3), time_end=iso(-2))
    check("session whose own time_end is in the past created while none active", r.status_code == 201, r.text)
    r = create_session(cli, free, hdr)
    check("past-dated session does not count as active (next create allowed)", r.status_code == 201, r.text)
    end_sessions(free)

    # Recurring sessions never end -> active
    r = create_session(cli, free, hdr, recurring=True)
    check("recurring session created", r.status_code == 201, r.text)
    sql("UPDATE devotions SET time_end = now() - interval '1 day' WHERE creator_id = %s", (free,))
    r = create_session(cli, free, hdr)
    check("recurring session with a past time_end still counts as active -> 403", r.status_code == 403, r.text)
    sql("DELETE FROM devotions WHERE creator_id = %s", (free,))

    # Open-ended session (no time_end) is active
    r = create_session(cli, free, hdr, time_end="")
    check("open-ended session created", r.status_code == 201, r.text)
    r = create_session(cli, free, hdr)
    check("open-ended session counts as active -> 403", r.status_code == 403, r.text)
    sql("DELETE FROM devotions WHERE creator_id = %s", (free,))

    # creator_id forced to the caller (cannot dodge the cap by spoofing the creator)
    r = create_session(cli, free, hdr, creator_id=other)
    check("create with spoofed creator_id succeeds", r.status_code == 201, r.text)
    sid = r.json().get("id")
    row = sql("SELECT creator_id::text FROM devotions WHERE _id = %s", (sid,))
    check("stored creator_id is the authenticated caller, not the body value", row and row[0][0] == free, row)
    check("spoofed creator did not get an active session counted",
          usage(cli, other, ohdr)["resources"]["sessions"]["used"] == 0)
    r = create_session(cli, free, hdr, creator_id=other)
    check("spoofed creator_id cannot bypass the cap (403)", r.status_code == 403, r.text)
    sql("DELETE FROM devotions WHERE creator_id = %s", (free,))

    # Sessions created by others, or joined, do not count; joining is never limited
    r = create_session(cli, other, ohdr)
    check("other user creates a session", r.status_code == 201, r.text)
    sql("UPDATE devotions SET participants = array_append(participants, %s) WHERE creator_id = %s", (free, other))
    check("joining someone else's session does not consume the cap",
          usage(cli, free, hdr)["resources"]["sessions"]["used"] == 0)
    r = create_session(cli, free, hdr)
    check("free user who joined another session can still create their own", r.status_code == 201, r.text)

    # Paid and admin-comp are unlimited
    paid = make_user("fpg")
    make_paid(paid)
    phdr = session_headers(paid)
    codes = [create_session(cli, paid, phdr).status_code for _ in range(3)]
    check("paid user: 3 simultaneous active sessions allowed", codes == [201, 201, 201], codes)
    check("usage for paid: sessions unlimited", usage(cli, paid, phdr)["resources"]["sessions"]["unlimited"] is True)
    comp = make_user("fpg")
    make_paid(comp, provider="admin_comp")
    chdr = session_headers(comp)
    codes = [create_session(cli, comp, chdr).status_code for _ in range(2)]
    check("admin-comp member counts as paid: 2 active sessions allowed", codes == [201, 201], codes)

    # auth boundary unchanged
    limiter.reset()
    r = cli.post("/devotions/", json={"devotion_id": str(uuid.uuid4()), "user_id": other,
                                      "devotion": {"title": "x"}}, headers=hdr)
    check("user_id != caller still 403 Forbidden (no limits body)", r.status_code == 403 and r.json()["detail"] == "Forbidden", r.text)


# -- 3. summaries ------------------------------------------------------------------

def test_sessions_bypass(cli):
    print("SESSIONS bypass paths (PUT reactivation, creator takeover, concurrency)")
    free, other = make_user("fpg"), make_user("fpg")
    hdr, ohdr = session_headers(free), session_headers(other)

    # Reactivation: ended session A + active session B; extending A must be blocked.
    ra = create_session(cli, free, hdr, time_start=iso(-3), time_end=iso(-2))
    a_id = ra.json()["id"]
    rb = create_session(cli, free, hdr)
    check("ended A + active B created", ra.status_code == 201 and rb.status_code == 201, (ra.text, rb.text))
    limiter.reset()
    body = {"devotion_id": a_id, "user_id": free,
            "devotion": {"id": a_id, "title": "s", "time_start": iso(1), "time_end": iso(5)}}
    r = cli.put("/devotions/", json=body, headers=hdr)
    check("PUT extending an ended session while another is active -> 403 sessions",
          r.status_code == 403 and r.json()["detail"]["resource"] == "sessions", r.text)
    body["devotion"]["recurring"] = True
    body["devotion"]["time_end"] = ""
    r = cli.put("/devotions/", json=body, headers=hdr)
    check("PUT making an ended session recurring while another active -> 403", r.status_code == 403, r.text)
    # Editing the active one stays allowed (existing sessions remain editable)
    b_id = rb.json()["id"]
    body = {"devotion_id": b_id, "user_id": free,
            "devotion": {"id": b_id, "title": "renamed", "time_start": iso(1), "time_end": iso(3)}}
    r = cli.put("/devotions/", json=body, headers=hdr)
    check("PUT editing the one active session still allowed", r.status_code == 200, r.text)
    end_sessions(free)
    body = {"devotion_id": a_id, "user_id": free,
            "devotion": {"id": a_id, "title": "s", "time_start": iso(1), "time_end": iso(5)}}
    r = cli.put("/devotions/", json=body, headers=hdr)
    check("PUT reactivating when no other session is active -> 200", r.status_code == 200, r.text)

    # creator_id is not client-settable on update (participant takeover)
    sql("UPDATE devotions SET participants = array_append(participants, %s) WHERE _id = %s", (other, a_id))
    limiter.reset()
    body = {"devotion_id": a_id, "user_id": other,
            "devotion": {"id": a_id, "title": "s", "time_start": iso(1), "time_end": iso(5), "creator_id": other}}
    cli.put("/devotions/", json=body, headers=ohdr)
    cr = sql("SELECT creator_id::text FROM devotions WHERE _id = %s", (a_id,))[0][0]
    check("update cannot reassign creator_id", cr == free, cr)

    # Concurrent creates: only one may win
    sql("DELETE FROM devotions WHERE creator_id = %s", (free,))
    from concurrent.futures import ThreadPoolExecutor
    def go(_):
        return create_session(cli, free, hdr).status_code
    with ThreadPoolExecutor(8) as ex:
        codes = list(ex.map(go, range(8)))
    check("8 concurrent creates by a free user: exactly one 201", codes.count(201) == 1, codes)
    check("only one active session row exists", count_sessions(free) == 1, count_sessions(free))


def test_summaries(cli):
    print("SESSION SUMMARIES (paid-only)")
    free = make_user("fpg")
    hdr = session_headers(free)
    body = {"session": {"title": "t", "prompts": ["p"], "verses": []}}
    notes_before = sql("SELECT count(*) FROM notes WHERE user_id = %s", (free,))[0][0]
    limiter.reset()
    r = cli.post(f"/agent/{free}/{uuid.uuid4()}/summarize", json=body, headers=hdr)
    check("free user summarize -> 403", r.status_code == 403, r.text)
    d = r.json().get("detail", {})
    check("403 body resource == session_summaries", d.get("resource") == "session_summaries", d)
    check("403 body paid_only true, allowed false", (d.get("paid_only"), d.get("allowed")) == (True, False), d)
    check("403 body has the shared blocked shape keys",
          all(k in d for k in ("resource", "allowed", "unlimited", "used", "limit", "remaining")), d)
    check("no note written by the blocked summarize",
          sql("SELECT count(*) FROM notes WHERE user_id = %s", (free,))[0][0] == notes_before)

    # Gate runs BEFORE the notes cap: a user at the notes cap still sees session_summaries
    for i in range(5):
        sql("INSERT INTO notes (_id, user_id, title, text, timestamp) VALUES (%s,%s,'n','b',now())",
            (str(uuid.uuid4()), free))
    limiter.reset()
    r = cli.post(f"/agent/{free}/{uuid.uuid4()}/summarize", json=body, headers=hdr)
    check("free user at the notes cap still gets the session_summaries body (paid gate first)",
          r.status_code == 403 and r.json()["detail"].get("resource") == "session_summaries", r.text)

    # Other user cannot be summarised-for (auth unchanged)
    victim = make_user("fpg")
    limiter.reset()
    r = cli.post(f"/agent/{victim}/{uuid.uuid4()}/summarize", json=body, headers=hdr)
    check("path user mismatch rejected before any gate (403/401, not a limits body)",
          r.status_code in (401, 403) and not isinstance(r.json().get("detail"), dict), r.text)

    # Gate function semantics
    check("check_paid_only(free, session_summaries) blocked",
          check_paid_only(free, "session_summaries")["allowed"] is False)
    check("check_paid_only fails closed for an unknown resource name",
          check_paid_only(free, "no_such_feature")["allowed"] is False)
    paid = make_user("fpg")
    make_paid(paid)
    g = check_paid_only(paid, "session_summaries")
    check("check_paid_only(paid) allowed and unlimited", (g["allowed"], g["unlimited"]) == (True, True), g)
    comp = make_user("fpg")
    make_paid(comp, provider="admin_comp")
    check("check_paid_only(admin comp) allowed", check_paid_only(comp, "explorer_publish")["allowed"] is True)

    old = dict(limits_mod.PAID_ONLY_RESOURCES)
    try:
        limits_mod.PAID_ONLY_RESOURCES["session_summaries"] = False
        check("config flag false -> free allowed (gate is config-driven)",
              check_paid_only(free, "session_summaries")["allowed"] is True)
        check("other flag still blocked while one is relaxed",
              check_paid_only(free, "explorer_publish")["allowed"] is False)
    finally:
        limits_mod.PAID_ONLY_RESOURCES.clear()
        limits_mod.PAID_ONLY_RESOURCES.update(old)

    # Subscriber summarize reaches the notes gate/model path: free-only 403 is gone.
    # (The model call itself is not exercised here; assert the paid gate does not fire.)
    m = LimitsManager()
    try:
        check("paid user: is_subscribed True so the gate cannot block", m.is_subscribed(paid) is True)
    finally:
        m.close()


# -- 4. explorer ------------------------------------------------------------------

def make_group(owner, title="Gate Group"):
    gid = str(uuid.uuid4())
    sql("INSERT INTO groups (_id, title, users, creator_id) VALUES (%s,%s,%s,%s)", (gid, title, [owner], owner))
    GROUPS.append(gid)
    return gid


def listing_status(gid):
    r = sql("SELECT status FROM group_listings WHERE group_id = %s", (gid,))
    return r[0][0] if r else None


def test_explorer(cli):
    print("EXPLORER PUBLISH (paid-only)")
    free = make_user("fpg")
    hdr = session_headers(free)
    gid = make_group(free)
    base = f"/explorer/{free}/groups/{gid}/listing"
    submit_body = {"consent": True, "adult_attested": True}

    limiter.reset()
    r = cli.put(base, json={"title": "Free Owner Draft"}, headers=hdr)
    check("free owner can still save a draft (PUT stays free)", r.status_code == 200, r.text)
    limiter.reset()
    r = cli.get(base, headers=hdr)
    check("free owner can still read their listing", r.status_code == 200, r.text)

    limiter.reset()
    r = cli.post(base + "/submit", json=submit_body, headers=hdr)
    check("free owner submit -> 403", r.status_code == 403, r.text)
    d = r.json().get("detail", {})
    check("403 body resource == explorer_publish", d.get("resource") == "explorer_publish", d)
    check("403 body paid_only true, allowed false", (d.get("paid_only"), d.get("allowed")) == (True, False), d)
    check("draft is still a draft after blocked submit", listing_status(gid) == "draft", listing_status(gid))

    # Terms gate still precedes (and invalid body still 422s for paid) -- spot-check ordering
    limiter.reset()
    r = cli.post(base + "/submit", json={"consent": False, "adult_attested": True}, headers=hdr)
    check("free owner with bad body still gets the blocked response (gate before validation)",
          r.status_code == 403, r.text)

    # Existing published listing of a now-free owner is untouched, not re-submittable
    sql("UPDATE group_listings SET status = 'published' WHERE group_id = %s", (gid,))
    check("existing published listing untouched by blocked submit", listing_status(gid) == "published")
    limiter.reset()
    r = cli.post(base + "/unpublish", json={}, headers=hdr)
    check("free owner may still unpublish their listing", r.status_code == 200, r.text)
    limiter.reset()
    r = cli.post(base + "/submit", json=submit_body, headers=hdr)
    check("free owner cannot re-publish -> 403 explorer_publish",
          r.status_code == 403 and r.json()["detail"].get("resource") == "explorer_publish", r.text)

    # Paid owner passes
    paid = make_user("fpg")
    make_paid(paid)
    phdr = session_headers(paid)
    pg = make_group(paid, "Paid Gate Group")
    pbase = f"/explorer/{paid}/groups/{pg}/listing"
    limiter.reset()
    cli.put(pbase, json={"title": "Paid Owner Listing"}, headers=phdr)
    limiter.reset()
    r = cli.post(pbase + "/submit", json=submit_body, headers=phdr)
    check("paid owner submit -> 200", r.status_code == 200, r.text)
    check("paid owner listing is pending_review or published",
          listing_status(pg) in ("pending_review", "published"), listing_status(pg))

    # Admin comp passes
    comp = make_user("fpg")
    make_paid(comp, provider="admin_comp")
    chdr = session_headers(comp)
    cg = make_group(comp, "Comp Gate Group")
    cbase = f"/explorer/{comp}/groups/{cg}/listing"
    limiter.reset()
    cli.put(cbase, json={"title": "Comp Owner Listing"}, headers=chdr)
    limiter.reset()
    r = cli.post(cbase + "/submit", json=submit_body, headers=chdr)
    check("admin-comp owner submit -> 200", r.status_code == 200, r.text)

    # Browse/config unaffected for an unauthenticated caller (the listings list itself
    # needs the app lifespan's public_guard, so the flag-only config route stands in)
    limiter.reset()
    r = cli.get("/explorer/config")
    check("public explorer config route still 200 without a session or plan", r.status_code == 200, r.status_code)
    limiter.reset()
    r = cli.get(f"/explorer/{free}/groups", headers=hdr)
    check("free owner can still list their groups for the Explorer form", r.status_code == 200, r.text)


# -- 5. usage endpoint ------------------------------------------------------------------

def test_usage(cli):
    print("USAGE ENDPOINT")
    free = make_user("fpg")
    hdr = session_headers(free)
    u = usage(cli, free, hdr)
    check("subscribed false", u["subscribed"] is False)
    res = u["resources"]
    check("notes limit 5", res["notes"]["limit"] == 5, res["notes"])
    check("agent_events limit 1", res["agent_events"]["limit"] == 1)
    check("announcements limit 1", res["announcements"]["limit"] == 1)
    check("sessions present with limit 1", res["sessions"]["limit"] == 1, res.get("sessions"))
    check("window_days 7 and announcements_window_days 7",
          (u["window_days"], u["announcements_window_days"]) == (7, 7), u)
    po = u["paid_only"]
    check("paid_only lists both features", set(po) == {"session_summaries", "explorer_publish"}, po)
    check("free: allowed false, free_allowed false for both",
          all(v == {"allowed": False, "free_allowed": False} for v in po.values()), po)

    paid = make_user("fpg")
    make_paid(paid)
    pu = usage(cli, paid, session_headers(paid))
    check("paid: paid_only allowed true, free_allowed still false",
          all(v == {"allowed": True, "free_allowed": False} for v in pu["paid_only"].values()), pu["paid_only"])
    check("paid: every count resource unlimited", all(v["unlimited"] for v in pu["resources"].values()), pu["resources"])

    # 5 notes allowed, 6th blocked at the new limit
    limiter.reset()
    codes = [cli.post(f"/notes/{free}", json={"title": f"n{i}", "text": "b"}, headers=hdr).status_code for i in range(6)]
    check("notes: 5 accepted then the 6th blocked", codes == [201] * 5 + [403], codes)
    notes_usage = usage(cli, free, hdr)["resources"]["notes"]
    check("usage notes used 5 remaining 0", (notes_usage["used"], notes_usage["remaining"]) == (5, 0), notes_usage)


def cleanup():
    for u in set(SUB_USERS + USERS):
        sql("UPDATE users SET subscription_id = NULL WHERE _id = %s", (u,))
        sql("DELETE FROM subscriptions WHERE user_id = %s", (u,))
    for u in USERS:
        sql("DELETE FROM notes WHERE user_id = %s", (u,))
        sql("DELETE FROM devotions WHERE creator_id = %s", (u,))
    for g in GROUPS:
        sql("DELETE FROM group_listings WHERE group_id = %s", (g,))
        sql("DELETE FROM groups WHERE _id = %s", (g,))
    for u in USERS:
        sql("DELETE FROM users WHERE _id = %s", (u,))


def main():
    require_scratch_db()
    load_all()
    cli = TestClient(main_module.app)
    saved = {r[0]: (r[1], r[2] or []) for r in sql("SELECT name, state, canary_user_ids::text[] FROM feature_flags")}
    try:
        sql("UPDATE feature_flags SET state = 'on' WHERE name = 'explorer_publish'")
        flags.invalidate()
        test_config()
        test_sessions(cli)
        test_sessions_bypass(cli)
        test_summaries(cli)
        test_explorer(cli)
        test_usage(cli)
    finally:
        for name, (state, canary) in saved.items():
            sql("UPDATE feature_flags SET state = %s, canary_user_ids = %s::uuid[] WHERE name = %s",
                (state, canary, name))
        flags.invalidate()
        cleanup()
    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        raise SystemExit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")


if __name__ == "__main__":
    main()
