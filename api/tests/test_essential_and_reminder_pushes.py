"""Backend coverage for task 20261016-push-notifications-and-ui (testing step 4).

Real routes, real notifier / scheduler job functions, real Postgres (scratch
DB only: ``require_scratch_db`` asserts port 55432); only ``send_push`` is
faked (capturing), so no APNs call is made.

  A. Friend-request push (essential): recipient pushed on a NEW request only,
     generic text (no sender name), payload action only, sender never pushed,
     ignores every preference, skips blocked (both directions) / suspended /
     no-token, repeat request does not re-push, both routes wired, a failing
     APNs call never fails the request.
  B. Member-joined push (essential): existing members minus the joiner, minus
     blocked-with-joiner (both directions), suspended, no-token and muted;
     ignores preferences; generic body; cap; per-recipient isolation; one push
     per recipient for a multi-add; all three add paths (member-list edit,
     invite redeem, join-request approval) wired; removals / title-only edits /
     group creation do not push.
  C. Prayer / check-in / deep-question reminders: default OFF (no row, no push),
     only explicit opt-in, user-chosen local time in the user's timezone,
     inside [time, time+60min) only, at most once per local day (atomic claim,
     concurrent scans), per-type independence, suspended / no-token / bad
     timezone skipped, deep question from the fixed pool and deterministic per
     local date, generic copy naming no friend, fail closed on DB error.
  D. Announcement one-hour reminder: only inside the final hour, only if
     scheduled >= 1h ahead at creation, not deleted / published, own toggle
     (default ON, opt-out respected, independent of ``announcements``), once
     (atomic claim, concurrent), reschedule re-arms / suppresses, payload ids
     only and body never the description.
  E. Scheduler jobs registered.

Run: cd api && python tests/test_essential_and_reminder_pushes.py
"""
import _pathfix  # noqa: F401

import asyncio
import json
import os
import threading
import uuid
from datetime import date, datetime, time as dtime, timedelta, timezone
from zoneinfo import ZoneInfo

os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

import _jrq_common as J  # noqa: E402  (imports _thr_common helpers, scratch-db guard)
from _thr_common import (  # noqa: E402
    FAILED, GROUPS, PASSED, USERS, check, cookie, make_group, make_user, require_scratch_db, sql,
)
import backend.interactions.announcement_reminder as areminder  # noqa: E402
import backend.interactions.friend_request_notifier as frn  # noqa: E402
import backend.interactions.invites_config as ic  # noqa: E402
import backend.interactions.member_joined_notifier as mjn  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402
import backend.interactions.scheduler as scheduler_module  # noqa: E402
import backend.interactions.user_reminders as ur  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402

SENT: list[dict] = []
MODE = {"fail_tokens": set(), "raise_all": False}


async def fake_send_push(token, title, body, data=None):
    if MODE["raise_all"] or token in MODE["fail_tokens"]:
        raise RuntimeError("apns exploded with secret")
    SENT.append({"token": token, "title": title, "body": body, "data": data})
    return True


def tokens():
    return {s["token"] for s in SENT}


def token_for(uid):
    tok = f"tok-{uid}"
    sql("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) "
        "ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token", (uid, tok))
    return tok


def all_prefs_off(uid):
    cols = ("messages", "pins", "reactions", "friend_highlight", "announcements", "session_reminders",
            "reminders", "friend_activity", "announcement_reminder", "join_requests")
    sets = ", ".join(f"{c} = FALSE" for c in cols)
    sql(f"INSERT INTO push_preferences (user_id) VALUES (%s) ON CONFLICT (user_id) DO UPDATE SET {sets}", (uid,))
    sql(f"UPDATE push_preferences SET {sets} WHERE user_id = %s", (uid,))


def block(blocker, blocked):
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (blocker, blocked))


def uname(uid):
    return sql("SELECT username FROM users WHERE _id = %s", (uid,))[0][0]


# ------------------------------------------------------------------ A. friend request

def test_friend_request(cli):
    print("A. friend-request push")
    sender, rcpt = make_user("fr_s"), make_user("fr_r")
    t_s, t_r = token_for(sender), token_for(rcpt)
    all_prefs_off(rcpt)  # essential: no preference may suppress it

    limiter.reset()
    SENT.clear()
    r = cli.post(f"/friends/{sender}/request", params={"friend_username": uname(rcpt)}, headers=cookie(sender))
    check("request accepted (200)", r.status_code == 200, r.text)
    check("recipient pushed exactly once, sender not", len(SENT) == 1 and tokens() == {t_r} and t_s not in tokens(), SENT)
    p = SENT[0] if SENT else {}
    check("payload is exactly {action: friend_request}", p.get("data") == {"action": "friend_request"}, p.get("data"))
    check("alert text is generic: no sender name or id",
          uname(sender) not in (p.get("title", "") + p.get("body", "")) and sender not in str(p),
          (p.get("title"), p.get("body")))
    check("pushed even though every preference (incl. legacy join_requests) is off", len(SENT) == 1)

    SENT.clear()
    limiter.reset()
    r = cli.post(f"/friends/{sender}/request", params={"friend_username": uname(rcpt)}, headers=cookie(sender))
    check("repeat tap on the same pending request does NOT re-push (idempotent)", r.status_code == 200 and SENT == [], SENT)

    # second route: POST /message/friend-request
    s2, r2 = make_user("fr_s2"), make_user("fr_r2")
    token_for(s2)
    t_r2 = token_for(r2)
    SENT.clear()
    limiter.reset()
    r = cli.post("/message/friend-request", params={"user_id": s2, "friend_user": uname(r2)}, headers=cookie(s2))
    check("/message/friend-request route also pushes the recipient", r.status_code in (200, 204) and tokens() == {t_r2}, (r.status_code, r.text, SENT))

    # skip conditions (each via the real route)
    for label, setup in (
        ("recipient blocked the sender", lambda s, rc: block(rc, s)),
        ("sender blocked the recipient", lambda s, rc: block(s, rc)),
        ("recipient suspended", lambda s, rc: sql("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (rc,))),
        ("recipient has no device token", lambda s, rc: sql("DELETE FROM device_tokens WHERE user_id = %s", (rc,))),
    ):
        s, rc = make_user("fr_xs"), make_user("fr_xr")
        token_for(s)
        token_for(rc)
        setup(s, rc)
        SENT.clear()
        limiter.reset()
        r = cli.post(f"/friends/{s}/request", params={"friend_username": uname(rc)}, headers=cookie(s))
        check(f"no push when {label}" + ("" if label.endswith("token") else " (request outcome unaffected)"),
              SENT == [] and r.status_code in (200, 404), (r.status_code, SENT))

    # nonexistent user / self: no push, no crash
    SENT.clear()
    limiter.reset()
    r = cli.post(f"/friends/{sender}/request", params={"friend_username": uname(sender)}, headers=cookie(sender))
    check("self request: error, no push", r.status_code == 404 and SENT == [])
    r = cli.post(f"/friends/{sender}/request", params={"friend_username": "no_such_user_zzz"}, headers=cookie(sender))
    check("unknown user: 404, no push", r.status_code == 404 and SENT == [])

    # failure isolation
    s3, r3 = make_user("fr_s3"), make_user("fr_r3")
    token_for(s3)
    token_for(r3)
    MODE["raise_all"] = True
    try:
        SENT.clear()
        limiter.reset()
        r = cli.post(f"/friends/{s3}/request", params={"friend_username": uname(r3)}, headers=cookie(s3))
        check("APNs raising never fails the friend request", r.status_code == 200, r.text)
        check("the request row was still stored",
              sql("SELECT COUNT(*) FROM friend_requests WHERE to_user_id=%s AND from_user_id=%s", (r3, s3))[0][0] == 1)
    finally:
        MODE["raise_all"] = False
    # notifier never raises even if the DB lookup blows up
    real = frn._prepare
    frn._prepare = lambda *a: (_ for _ in ()).throw(RuntimeError("db down"))
    try:
        asyncio.run(frn.notify_friend_request(r3, s3))
        ok = True
    except Exception:  # noqa: BLE001
        ok = False
    finally:
        frn._prepare = real
    check("notify_friend_request swallows an internal DB error", ok)


# ------------------------------------------------------------------ B. member joined

def mk_members(n, prefix="mj"):
    users = [make_user(prefix) for _ in range(n)]
    toks = [token_for(u) for u in users]
    return users, toks


def test_member_joined_unit():
    print("B1. member-joined notifier")
    owner, a, b, joiner, blocked_by, blocked_of, susp, notok, muted = (
        make_user("mj_o"), make_user("mj_a"), make_user("mj_b"), make_user("mj_j"),
        make_user("mj_bb"), make_user("mj_bo"), make_user("mj_su"), make_user("mj_nt"), make_user("mj_mu"))
    gid = make_group([owner, a, b, joiner, blocked_by, blocked_of, susp, notok, muted], creator=owner)
    sql("UPDATE groups SET title = %s WHERE _id = %s", ("Quokka Study Group", gid))
    tk = {u: token_for(u) for u in (owner, a, b, joiner, blocked_by, blocked_of, susp, muted)}
    sql("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (susp,))
    block(blocked_by, joiner)   # an existing member blocked the joiner
    block(joiner, blocked_of)   # the joiner blocked an existing member
    sql("INSERT INTO group_mutes (user_id, group_id) VALUES (%s,%s)", (muted, gid))
    for u in (owner, a):
        all_prefs_off(u)        # essential: preferences never suppress it

    SENT.clear()
    asyncio.run(mjn.notify_members_of_new_members(gid, [joiner]))
    got = tokens()
    check("existing members (incl. ones with every preference off) are pushed", {tk[owner], tk[a], tk[b]} <= got, SENT)
    check("the joiner is not pushed", tk[joiner] not in got)
    check("member who blocked the joiner skipped", tk[blocked_by] not in got)
    check("member the joiner blocked skipped", tk[blocked_of] not in got)
    check("suspended member skipped", tk[susp] not in got)
    check("muted member skipped", tk[muted] not in got)
    check("member without a device token silently skipped; exactly 3 pushes", len(SENT) == 3, len(SENT))
    p = SENT[0]
    check("payload carries only action + group_id", p["data"] == {"action": "member_joined", "group_id": gid}, p["data"])
    check("title is the group title, body names nobody",
          p["title"] == "Quokka Study Group" and p["body"] == mjn.BODY and uname(joiner) not in str(p), (p["title"], p["body"]))

    # multi-add: one push per recipient, none to either joiner
    SENT.clear()
    asyncio.run(mjn.notify_members_of_new_members(gid, [joiner, a]))
    ts = [s["token"] for s in SENT]
    check("two joiners: still one push per remaining recipient, none to either joiner",
          sorted(ts) == sorted({tk[owner], tk[b]}) and tk[a] not in ts, ts)

    # nothing to send / bad input
    SENT.clear()
    solo = make_user("mj_solo")
    token_for(solo)
    g2 = make_group([solo], creator=solo)
    asyncio.run(mjn.notify_members_of_new_members(g2, [solo]))
    asyncio.run(mjn.notify_members_of_new_members("not-a-uuid", [joiner]))
    asyncio.run(mjn.notify_members_of_new_members(gid, []))
    asyncio.run(mjn.notify_members_of_new_members(str(uuid.uuid4()), [joiner]))
    check("only the joiner in group / bad ids / empty list / unknown group: no push, no raise", SENT == [])
    asyncio.run(mjn.notify_members_of_approved_request("nope"))
    asyncio.run(mjn.notify_members_of_approved_request(str(uuid.uuid4())))
    check("approved-request wrapper tolerates bad / unknown request ids", SENT == [])

    # per-recipient isolation
    MODE["fail_tokens"] = {tk[owner]}
    try:
        SENT.clear()
        asyncio.run(mjn.notify_members_of_new_members(gid, [joiner]))
        check("one failing recipient does not abort the others", tokens() == {tk[a], tk[b]}, SENT)
    finally:
        MODE["fail_tokens"] = set()

    # cap
    big, _ = mk_members(6, "mj_big")
    newbie = make_user("mj_new")
    gbig = make_group(big + [newbie], creator=big[0])
    real_cap = mjn.MEMBER_JOINED_MAX_RECIPIENTS
    mjn.MEMBER_JOINED_MAX_RECIPIENTS = 4
    try:
        SENT.clear()
        asyncio.run(mjn.notify_members_of_new_members(gbig, [newbie]))
        check("recipient cap enforced", len(SENT) == 4, len(SENT))
    finally:
        mjn.MEMBER_JOINED_MAX_RECIPIENTS = real_cap
    SENT.clear()
    asyncio.run(mjn.notify_members_of_new_members(gbig, [newbie]))
    check("all 6 existing members pushed under the real cap (500)", len(SENT) == 6, len(SENT))

    # mute lookup failure fails open
    real_exec = None
    import db as db_module
    orig_cls = mjn.DBManager

    class MuteBoom(db_module.DBManager):
        def __init__(self, *a, **k):
            super().__init__(*a, **k)
            real_cur = self.cur

            class Cur:
                def __getattr__(self_, n):
                    return getattr(real_cur, n)

                def execute(self_, q, *a2, **k2):
                    if "group_mutes" in q:
                        raise RuntimeError("mutes table gone")
                    return real_cur.execute(q, *a2, **k2)
            self.cur = Cur()

    mjn.DBManager = MuteBoom
    try:
        SENT.clear()
        asyncio.run(mjn.notify_members_of_new_members(gid, [joiner]))
        check("mute lookup failure fails open (muted member pushed, others unaffected)",
              tk[muted] in tokens() and tk[a] in tokens(), SENT)
    finally:
        mjn.DBManager = orig_cls


def test_member_joined_routes(cli):
    print("B2. member-joined wiring on every add path")
    # --- direct member-list edit
    owner, m1, newcomer, other = make_user("mr_o"), make_user("mr_m"), make_user("mr_n"), make_user("mr_x")
    t = {u: token_for(u) for u in (owner, m1, newcomer, other)}
    gid = make_group([owner, m1], creator=owner)
    sql("UPDATE groups SET title = 'Edit Group' WHERE _id = %s", (gid,))
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s),(%s,%s),(%s,%s) ON CONFLICT DO NOTHING",
        (owner, newcomer, newcomer, owner, owner, other, other, owner))

    def put(users, title="Edit Group"):
        limiter.reset()
        return cli.put(f"/groups/{owner}/{gid}", json={"group_id": gid, "title": title, "users": users}, headers=cookie(owner))

    SENT.clear()
    r = put([owner, m1, newcomer])
    check("member-list edit adding a user: 200", r.status_code == 200, r.text)
    check("existing members pushed, the newcomer and the editor's own device excluded as joiner only",
          tokens() == {t[owner], t[m1]} and t[newcomer] not in tokens(), SENT)
    SENT.clear()
    r = put([owner, m1, newcomer], title="Renamed")
    check("title-only edit: no push", r.status_code == 200 and SENT == [], (r.status_code, SENT))
    SENT.clear()
    r = put([owner, m1])
    check("removing a member: no push", r.status_code == 200 and SENT == [], (r.status_code, SENT))
    SENT.clear()
    r = put([owner, m1, newcomer, other])
    check("adding two at once: one push per existing member (3), none to the two joiners",
          r.status_code == 200 and sorted(s["token"] for s in SENT) == sorted([t[owner], t[m1]]), SENT)
    SENT.clear()
    limiter.reset()
    gnew = str(uuid.uuid4())
    GROUPS.append(gnew)
    r = cli.post(f"/groups/{owner}", json={"group_id": gnew, "title": "Brand New", "users": [owner, m1]}, headers=cookie(owner))
    check("creating a group is not a 'join': no push", r.status_code == 201 and SENT == [], (r.status_code, SENT))

    # --- join-request approval
    jo, ja = make_user("mr_jo"), make_user("mr_ja")
    existing = make_user("mr_je")
    t_jo, t_ja, t_je = token_for(jo), token_for(ja), token_for(existing)
    J.set_flags(jo, push="on")  # the requester approval notice keeps its flag; member_joined has none
    jgid, pid = J.make_listing(jo, members=[existing], title="Approval Group")
    limiter.reset()
    r = J.req(cli, ja, pid)
    check("join request created", r.status_code == 201, r.text)
    rid = r.json()["id"]
    SENT.clear()
    r = J.decide(cli, jo, jgid, rid, "approve")
    check("approve ok", r.status_code == 200, r.text)
    got = {s["token"]: s for s in SENT}
    check("approval: requester gets the approval notice AND existing members get member_joined",
          t_ja in got and t_jo in got and t_je in got, SENT)
    check("approval: member_joined payload to existing members, none to the joiner as member_joined",
          all(s["data"].get("action") == "member_joined" for tk_, s in got.items() if tk_ in (t_jo, t_je))
          and t_ja in got and got[t_ja]["data"].get("action") != "member_joined", got)
    # denied request: no member_joined
    ja2 = make_user("mr_ja2")
    token_for(ja2)
    limiter.reset()
    rid2 = J.req(cli, ja2, pid).json()["id"]
    SENT.clear()
    r = J.decide(cli, jo, jgid, rid2, "deny")
    check("deny: no member_joined push", r.status_code == 200 and not any(
        s["data"].get("action") == "member_joined" for s in SENT), SENT)

    # --- invite redeem
    import json as _json
    raw = _json.loads(open(ic.CONFIG_PATH).read())
    raw["enabled"] = True
    ic.set_invites_config_for_tests(ic.parse_invites_config(raw))
    try:
        io, im, ij, ij2 = make_user("mr_io"), make_user("mr_im"), make_user("mr_ij"), make_user("mr_ij2")
        t_io, t_im, t_ij = token_for(io), token_for(im), token_for(ij)
        ig = make_group([io, im], creator=io)
        sql("UPDATE groups SET title = 'Invite Group' WHERE _id = %s", (ig,))
        limiter.reset()
        r = cli.post(f"/invites/{io}/groups/{ig}", headers=cookie(io))
        check("invite link created", r.status_code in (200, 201), r.text)
        link = r.json()["token"]
        SENT.clear()
        limiter.reset()
        r = cli.post(f"/invites/{ij}/redeem", json={"token": link}, headers=cookie(ij))
        check("redeem joins", r.status_code == 200 and r.json().get("joined") is True, r.text)
        check("redeem: existing members pushed, the redeemer is not",
              tokens() == {t_io, t_im} and all(s["data"]["action"] == "member_joined" for s in SENT), SENT)
        SENT.clear()
        limiter.reset()
        r = cli.post(f"/invites/{ij}/redeem", json={"token": link}, headers=cookie(ij))
        check("second redeem by an existing member (already_member): no push", r.status_code == 200 and SENT == [], (r.status_code, SENT))
        SENT.clear()
        limiter.reset()
        r = cli.post(f"/invites/{io}/redeem", json={"token": link}, headers=cookie(io))
        check("creator redeeming own link: no push", r.status_code == 200 and SENT == [], (r.status_code, SENT))
        # APNs failure never fails the join
        MODE["raise_all"] = True
        try:
            token_for(ij2)
            limiter.reset()
            r = cli.post(f"/invites/{ij2}/redeem", json={"token": link}, headers=cookie(ij2))
            check("APNs raising never fails the invite join", r.status_code == 200 and r.json().get("joined") is True, r.text)
        finally:
            MODE["raise_all"] = False
    finally:
        ic.set_invites_config_for_tests(None)


# ------------------------------------------------------------------ C. user reminders

def enable(uid, key, hhmm=None, tz=None, sent=None):
    sql(f"INSERT INTO push_preferences (user_id) VALUES (%s) ON CONFLICT DO NOTHING", (uid,))
    sql(f"UPDATE push_preferences SET {key} = TRUE WHERE user_id = %s", (uid,))
    if hhmm:
        sql(f"UPDATE push_preferences SET {key}_time = %s WHERE user_id = %s", (hhmm, uid))
    if sent is not None:
        sql(f"UPDATE push_preferences SET {key}_sent_date = %s WHERE user_id = %s", (sent, uid))
    if tz:
        sql("UPDATE users SET timezone = %s WHERE _id = %s", (tz, uid))


def scan_for(now_utc, users):
    users = set(users)
    return [x for x in ur._scan(now_utc) if x[0] in users]


def test_is_due():
    print("C1. is_due window logic")
    day = date(2026, 10, 16)
    tz = ZoneInfo("UTC")

    def at(h, m):
        return datetime(2026, 10, 16, h, m, tzinfo=tz)
    t = dtime(8, 0)
    check("before the chosen time: not due", not ur.is_due(at(7, 59), t, None))
    check("exactly at the time: due", ur.is_due(at(8, 0), t, None))
    check("inside window: due", ur.is_due(at(8, 59), t, None))
    check("window end (time+60m) exclusive: not due", not ur.is_due(at(9, 0), t, None))
    check("already sent today (local date): not due", not ur.is_due(at(8, 5), t, day))
    check("sent yesterday: due", ur.is_due(at(8, 5), t, day - timedelta(days=1)))
    check("23:30 time: window clipped at local midnight (23:59 due)", ur.is_due(at(23, 59), dtime(23, 30), None))
    check("deep questions: fixed pool of 30 distinct non-empty strings",
          len(ur.DEEP_QUESTIONS) == 30 and len(set(ur.DEEP_QUESTIONS)) == 30 and all(q.strip() for q in ur.DEEP_QUESTIONS))
    check("deep question deterministic per date and rotates daily",
          ur.deep_question_for(day) == ur.deep_question_for(day) and ur.deep_question_for(day) != ur.deep_question_for(day + timedelta(days=1)))
    check("deep question rotation covers the pool over 30 days",
          len({ur.deep_question_for(day + timedelta(days=i)) for i in range(30)}) == 30)


def test_user_reminders():
    print("C2. user reminders against Postgres")
    # 15:30 UTC on 2026-10-16: New York (EDT, UTC-4) is 11:30, Los Angeles 08:30, Tokyo 00:30 (17th)
    now = datetime(2026, 10, 16, 15, 30, tzinfo=timezone.utc)

    nobody = make_user("ur_none")
    token_for(nobody)
    check("user with no preferences row is never selected", scan_for(now, [nobody]) == [])
    sql("INSERT INTO push_preferences (user_id) VALUES (%s)", (nobody,))
    check("row with every reminder at its default (OFF) is never selected", scan_for(now, [nobody]) == [])
    all_prefs_off(nobody)
    check("other toggles being on/off never enables a reminder", scan_for(now, [nobody]) == [])

    la = make_user("ur_la")
    tok_la = token_for(la)
    enable(la, "prayer_reminder", "08:00", "America/Los_Angeles")
    r = scan_for(now, [la])
    check("LA user, prayer at 08:00 local (it is 08:30 there): due, claimed",
          len(r) == 1 and r[0][1] == tok_la and r[0][4] == "reminder_prayer", r)
    check("claim marker written with the user's LOCAL date",
          sql("SELECT prayer_reminder_sent_date FROM push_preferences WHERE user_id=%s", (la,))[0][0] == date(2026, 10, 16))
    check("same day, next scan: not sent again (at most once per local day)", scan_for(now + timedelta(minutes=5), [la]) == [])
    check("still not sent again 20 min later", scan_for(now + timedelta(minutes=20), [la]) == [])
    nxt = now + timedelta(days=1)
    check("next local day: due again", len(scan_for(nxt, [la])) == 1)

    ny = make_user("ur_ny")
    token_for(ny)
    enable(ny, "prayer_reminder", "08:00", "America/New_York")
    check("NY user (11:30 local) with 08:00 time: past the 60-min window, not sent", scan_for(now, [ny]) == [])
    sql("UPDATE push_preferences SET prayer_reminder_time = '11:00' WHERE user_id=%s", (ny,))
    check("NY user with 11:00 time (11:30 local): due", len(scan_for(now, [ny])) == 1)

    tk = make_user("ur_tk")
    token_for(tk)
    enable(tk, "check_in_reminder", "00:00", "Asia/Tokyo")
    r = scan_for(now, [tk])
    check("Tokyo user (00:30 on the 17th), 00:00 time: due, marker is the LOCAL date 2026-10-17",
          len(r) == 1 and sql("SELECT check_in_reminder_sent_date FROM push_preferences WHERE user_id=%s", (tk,))[0][0] == date(2026, 10, 17), r)

    # per-type independence
    multi = make_user("ur_multi")
    token_for(multi)
    enable(multi, "prayer_reminder", "08:00", "America/Los_Angeles")
    enable(multi, "deep_question_reminder", "08:15")
    r = scan_for(now, [multi])
    check("two enabled types both due: both sent, check_in (off) is not",
          sorted(x[4] for x in r) == ["reminder_deep_question", "reminder_prayer"], r)
    dq = [x for x in r if x[4] == "reminder_deep_question"][0]
    local_d = now.astimezone(ZoneInfo("America/Los_Angeles")).date()
    check("deep question text comes from the fixed pool for the local date",
          dq[3] == ur.deep_question_for(local_d) and dq[3] in ur.DEEP_QUESTIONS, dq[3])

    # generic copy for the nudges
    pr = [x for x in scan_for(nxt, [multi]) if x[4] == "reminder_prayer"][0]
    check("prayer copy is generic", pr[2] == "Time to pray" and "friend" not in pr[3].lower())
    ci = make_user("ur_ci")
    token_for(ci)
    enable(ci, "check_in_reminder", "08:00", "America/Los_Angeles")
    cx = scan_for(now, [ci])[0]
    check("check-in copy names no friend/user", cx[2] == "Check in with someone" and ci not in cx[3] and "@" not in cx[3], cx)

    # skip conditions
    su = make_user("ur_su")
    token_for(su)
    enable(su, "prayer_reminder", "08:00", "America/Los_Angeles")
    sql("UPDATE users SET suspended_at = NOW() WHERE _id=%s", (su,))
    nt = make_user("ur_nt")
    enable(nt, "prayer_reminder", "08:00", "America/Los_Angeles")
    bz = make_user("ur_bz")
    token_for(bz)
    enable(bz, "prayer_reminder", "08:00", "Not/AZone")
    check("suspended / no-token / invalid-timezone users are skipped and not claimed",
          scan_for(now, [su, nt, bz]) == []
          and sql("SELECT prayer_reminder_sent_date FROM push_preferences WHERE user_id=%s", (nt,))[0][0] is None)
    # disabling after enabling stops it
    dis = make_user("ur_dis")
    token_for(dis)
    enable(dis, "prayer_reminder", "08:00", "America/Los_Angeles")
    sql("UPDATE push_preferences SET prayer_reminder = FALSE WHERE user_id=%s", (dis,))
    check("user who turned the reminder back off is not sent", scan_for(now, [dis]) == [])

    # concurrent scans: exactly one winner
    cc = make_user("ur_cc")
    token_for(cc)
    enable(cc, "prayer_reminder", "08:00", "America/Los_Angeles")
    results = []

    def run():
        results.append(scan_for(now, [cc]))
    ths = [threading.Thread(target=run) for _ in range(6)]
    [t.start() for t in ths]
    [t.join() for t in ths]
    check("6 concurrent scans claim the reminder exactly once", sum(len(x) for x in results) == 1, [len(x) for x in results])

    # end to end through the async job with the clock fixed
    e2e = make_user("ur_e2e")
    t_e2e = token_for(e2e)
    enable(e2e, "prayer_reminder", "08:00", "America/Los_Angeles")
    real_dt = ur.datetime

    class FixedDT(datetime):
        @classmethod
        def now(cls, tz=None):
            return now.astimezone(tz) if tz else now.replace(tzinfo=None)
    ur.datetime = FixedDT
    try:
        SENT.clear()
        asyncio.run(ur.fire_due_user_reminders())
        mine = [s for s in SENT if s["token"] == t_e2e]
        check("fire_due_user_reminders pushes the due user with data {action: reminder_prayer}",
              len(mine) == 1 and mine[0]["data"] == {"action": "reminder_prayer"}, SENT)
        SENT.clear()
        asyncio.run(ur.fire_due_user_reminders())
        check("second job run sends nothing more to that user", not [s for s in SENT if s["token"] == t_e2e])
        # failing APNs does not abort the job or re-send later
        e2 = make_user("ur_e2b")
        t2 = token_for(e2)
        enable(e2, "check_in_reminder", "08:00", "America/Los_Angeles")
        MODE["raise_all"] = True
        try:
            asyncio.run(ur.fire_due_user_reminders())
        finally:
            MODE["raise_all"] = False
        SENT.clear()
        asyncio.run(ur.fire_due_user_reminders())
        check("a failed send is not retried (claim-before-send, at-most-once)", not [s for s in SENT if s["token"] == t2])

        # fail closed on DB error: nothing sent, no raise
        real_scan = ur._scan
        ur._scan = lambda n: (_ for _ in ()).throw(RuntimeError("db down"))
        try:
            SENT.clear()
            asyncio.run(ur.fire_due_user_reminders())
            check("DB error: job aborts without sending and without raising", SENT == [])
        finally:
            ur._scan = real_scan
    finally:
        ur.datetime = real_dt


# ------------------------------------------------------------------ D. announcement reminder

def mk_announcement(gid, creator, publish_in, created_ago, title="Potluck Dinner", deleted=False, published=False):
    aid = str(uuid.uuid4())
    sql("INSERT INTO group_announcements (_id, group_id, creator_id, title, description, publish_at, created_at, "
        "deleted_at, push_sent_at) VALUES (%s,%s,%s,%s,%s, NOW() + make_interval(mins => %s), "
        "NOW() - make_interval(mins => %s), CASE WHEN %s THEN NOW() ELSE NULL END, CASE WHEN %s THEN NOW() ELSE NULL END)",
        (aid, gid, creator, title, "SECRET description text", publish_in, created_ago, deleted, published))
    return aid


def marker(aid):
    return sql("SELECT reminder_push_sent_at FROM group_announcements WHERE _id = %s", (aid,))[0][0]


def run_reminder_job():
    SENT.clear()
    asyncio.run(areminder.fire_due_announcement_reminders())


def test_announcement_reminder():
    print("D. announcement reminder")
    owner, m1, m2, off = make_user("ar_o"), make_user("ar_m1"), make_user("ar_m2"), make_user("ar_off")
    t = {u: token_for(u) for u in (owner, m1, m2, off)}
    gid = make_group([owner, m1, m2, off], creator=owner)
    sql("UPDATE groups SET title = 'Reminder Group' WHERE _id = %s", (gid,))
    sql("INSERT INTO push_preferences (user_id, announcement_reminder) VALUES (%s, FALSE)", (off,))
    sql("INSERT INTO push_preferences (user_id, announcements) VALUES (%s, FALSE) ON CONFLICT (user_id) DO UPDATE SET announcements = FALSE", (m2,))

    # drain anything left behind by other rows from earlier tests
    run_reminder_job()

    a_due = mk_announcement(gid, owner, publish_in=50, created_ago=120, title="Potluck Dinner")
    run_reminder_job()
    got = tokens()
    check("scheduled >=1h ahead, now inside the last hour: members with the toggle ON are reminded",
          {t[owner], t[m1], t[m2]} <= got, SENT)
    check("member who turned announcement_reminder OFF is skipped", t[off] not in got)
    check("the separate 'announcements' toggle being off does not suppress the reminder (m2 got it)", t[m2] in got)
    p = SENT[0]
    check("payload ids only; description never in the alert",
          p["data"] == {"action": "announcement", "group_id": gid, "announcement_id": a_due}
          and "SECRET" not in p["title"] + p["body"] and "Potluck Dinner" in p["body"] and p["title"] == "Reminder Group", p)
    check("marker claimed", marker(a_due) is not None)
    run_reminder_job()
    check("next tick: not sent again (once)", SENT == [], SENT)

    a_far = mk_announcement(gid, owner, publish_in=300, created_ago=120)
    run_reminder_job()
    check("publish 5h away: too early, nothing, marker untouched", SENT == [] and marker(a_far) is None)
    sql("UPDATE group_announcements SET publish_at = NOW() + interval '59 minutes', created_at = NOW() - interval '120 minutes' WHERE _id = %s", (a_far,))
    run_reminder_job()
    check("once it enters the last hour it fires", len(SENT) >= 1 and marker(a_far) is not None, SENT)

    a_late = mk_announcement(gid, owner, publish_in=30, created_ago=0)
    run_reminder_job()
    check("created with under an hour to go (policy): no reminder, marker untouched", SENT == [] and marker(a_late) is None)

    a_del = mk_announcement(gid, owner, publish_in=50, created_ago=120, deleted=True)
    a_pub = mk_announcement(gid, owner, publish_in=50, created_ago=120, published=True)
    a_past = mk_announcement(gid, owner, publish_in=-10, created_ago=120)
    run_reminder_job()
    check("deleted / already-published / past-due announcements are never reminded",
          SENT == [] and marker(a_del) is None and marker(a_pub) is None and marker(a_past) is None, SENT)

    # immediate-create announcements carry publish_at = now: nothing
    a_now = mk_announcement(gid, owner, publish_in=0, created_ago=0)
    run_reminder_job()
    check("immediate (publish_at ~ created_at) announcement: no reminder", SENT == [] and marker(a_now) is None)

    # delete between create and reminder
    a_race = mk_announcement(gid, owner, publish_in=50, created_ago=120)
    sql("UPDATE group_announcements SET deleted_at = NOW() WHERE _id = %s", (a_race,))
    run_reminder_job()
    check("deleted before the reminder time: cancelled", SENT == [] and marker(a_race) is None)

    # atomic claim under concurrency
    a_cc = mk_announcement(gid, owner, publish_in=50, created_ago=120, title="Concurrent")
    counts = []

    def runner():
        loop = asyncio.new_event_loop()
        try:
            loop.run_until_complete(areminder.fire_due_announcement_reminders())
        finally:
            loop.close()
    SENT.clear()
    ths = [threading.Thread(target=runner) for _ in range(5)]
    [x.start() for x in ths]
    [x.join() for x in ths]
    mine = [s for s in SENT if s["data"].get("announcement_id") == a_cc]
    check("5 concurrent job runs: exactly one winner (3 recipients pushed once)", len(mine) == 3, len(mine))

    # reschedule through the real update path
    from backend.interactions.announcements import AnnouncementsManager as Announcements
    a_rs = mk_announcement(gid, owner, publish_in=50, created_ago=120, title="Moves")
    run_reminder_job()
    check("setup: reminder fired for the to-be-rescheduled row", marker(a_rs) is not None)

    def reschedule(aid, minutes):
        mgr = Announcements(owner, gid)
        try:
            mgr.update_announcement(aid, {"publish_at": datetime.now(timezone.utc) + timedelta(minutes=minutes)})
        finally:
            mgr.close()
    reschedule(a_rs, 300)
    check("rescheduled far out: marker cleared (re-armed)", marker(a_rs) is None)
    run_reminder_job()
    check("re-armed row not reminded while still >1h away", SENT == [])
    reschedule(a_rs, 20)
    check("rescheduled to under an hour away: marker set => no reminder for the short notice", marker(a_rs) is not None)
    run_reminder_job()
    check("... and nothing is sent", not [s for s in SENT if s["data"].get("announcement_id") == a_rs])

    # feature flags / failures
    a_flag = mk_announcement(gid, owner, publish_in=50, created_ago=120)
    real_flag = areminder.notifier.ANNOUNCEMENT_PUSH_ENABLED
    areminder.notifier.ANNOUNCEMENT_PUSH_ENABLED = False
    try:
        run_reminder_job()
        check("announcement push disabled: no push and no claim taken", SENT == [] and marker(a_flag) is None)
    finally:
        areminder.notifier.ANNOUNCEMENT_PUSH_ENABLED = real_flag
    MODE["fail_tokens"] = {t[owner]}
    try:
        run_reminder_job()
        check("one failing recipient does not abort the others", {t[m1], t[m2]} <= tokens() and t[owner] not in tokens(), SENT)
    finally:
        MODE["fail_tokens"] = set()

    # block / mute use the creator rules of announcement_notifier
    blk = make_user("ar_blk")
    tb = token_for(blk)
    g2 = make_group([owner, blk], creator=owner)
    block(blk, owner)
    mk_announcement(g2, owner, publish_in=50, created_ago=120)
    run_reminder_job()
    check("member who blocked the author is not reminded", tb not in tokens(), SENT)

    # no member opted in at all: marker still claimed, nothing sent, no raise
    lone = make_user("ar_lone")
    token_for(lone)
    sql("INSERT INTO push_preferences (user_id, announcement_reminder) VALUES (%s, FALSE)", (lone,))
    g3 = make_group([lone], creator=lone)
    a_none = mk_announcement(g3, lone, publish_in=50, created_ago=120)
    run_reminder_job()
    check("all members opted out: nothing sent, no raise", SENT == [])


def test_scheduler_registration():
    print("E. scheduler jobs")
    import inspect
    src = inspect.getsource(scheduler_module.start_scheduler)
    check("announcement_reminder_fire job registered", 'id="announcement_reminder_fire"' in src)
    check("user_reminders_fire job registered", 'id="user_reminders_fire"' in src)
    check("announcement reminder poll is <= 60s", areminder.ANNOUNCEMENT_REMINDER_POLL_INTERVAL_SECONDS <= 60)


def main():
    cli, _cap = J.start()
    push_module.send_push = fake_send_push
    import traceback
    try:
        for fn, args in ((test_friend_request, (cli,)), (test_member_joined_unit, ()),
                         (test_member_joined_routes, (cli,)), (test_is_due, ()),
                         (test_user_reminders, ()), (test_announcement_reminder, ()),
                         (test_scheduler_registration, ())):
            try:
                fn(*args)
            except Exception:  # noqa: BLE001 - an exception is a test failure, never a silent pass
                FAILED.append((f"{fn.__name__} raised", traceback.format_exc()[-600:]))
                print(f"  FAIL {fn.__name__} raised\n{traceback.format_exc()}")
    finally:
        J.restore_cfg()
        for gid in GROUPS:
            try:
                sql("DELETE FROM group_announcements WHERE group_id=%s", (gid,))
                sql("DELETE FROM group_join_requests WHERE group_id=%s", (gid,))
                sql("DELETE FROM group_listings WHERE group_id=%s", (gid,))
                sql("DELETE FROM invites WHERE target_id=%s", (gid,))
            except Exception:  # noqa: BLE001
                pass
        for u in USERS:
            try:
                sql("DELETE FROM friend_requests WHERE to_user_id=%s OR from_user_id=%s", (u, u))
                sql("DELETE FROM push_preferences WHERE user_id=%s", (u,))
                sql("DELETE FROM group_join_requests WHERE user_id=%s", (u,))
            except Exception:  # noqa: BLE001
                pass
        try:
            from _thr_common import cleanup
            cleanup()
        except Exception:  # noqa: BLE001
            pass

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
