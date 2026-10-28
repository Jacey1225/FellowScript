"""Tests for task 20261028-dm-direct-call (testing step 5, backend).

Covers the 1:1 DM "call right away" backend and the shared ring lifecycle:

  1. POST /devotions/dm-call: verified mutual non-blocked friends get one
     marked ad hoc row (call_kind='dm_call', sorted room key, time_end NULL,
     no chime_meeting_id); idempotent per room (either side gets the same
     row); denies non-friends, blocked pairs (both directions), a forged
     user_id, a '|' peer_id, and self (all 403, fail closed).
  2. Legacy scheduled DM rows (call_kind NULL, '|' in group_id) are inert but
     never mutated: 410 on join / join-call / ring / PUT / POST-create with a
     '|' group_id, and on /chime/{id} + /chime/{id}/{uid}/attend; hidden from
     GET /devotions/contact/{room}; the dm-call row is hidden there too;
     group sessions are unchanged (create + join-call still work).
  3. /chime routes (security step 4 fix): a non-roster user on a dm_call row
     gets 403 (join-call too), a roster member gets 200, a legacy row 410.
  4. Scheduler / limits exclusions: the auto-delete and recurring-advance jobs
     never delete/advance legacy DM rows or the dm_call row; the reminder scan
     never claims them (a plain group-style row IS still claimed, proving the
     job ran); the free-plan session cap ignores both DM kinds.
  5. Ring lifecycle (shared by DM and group rings): /ring records a
     'ringing' state; /ring/status shows it to the caller only; target
     answered/declined, caller canceled; wrong-party 403; no ring 404;
     idempotent changed:false once ended; caller cancel sends the VoIP
     ring_cancel push (VoIP mode) and nothing in plain mode; join-call marks
     the joiner's ring answered; server-side expiry times a ring out exactly
     once and pushes ring_cancel; ring disabled -> 404; a group session ring
     is recorded by the same path.

Run with: cd api && ../.venv/bin/python tests/test_dm_direct_call.py
"""
import _pathfix  # noqa: F401,E402

import asyncio
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone as tzmod

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from dotenv import load_dotenv  # noqa: E402
load_dotenv()

os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

# Read at import time of backend.interactions.devotion: force ring ON and VoIP
# ON (the VoIP-mode paths are the ones that store a token / send cancels).
os.environ["RING_FEATURE_ENABLED"] = "true"
os.environ["RING_COOLDOWN_MINUTES"] = "5"
os.environ["RING_VOIP_ENABLED"] = "true"
os.environ.setdefault("RING_TIMEOUT_SECONDS", "45")

from fastapi.testclient import TestClient  # noqa: E402

from db import DBManager  # noqa: E402
from _plan_common import grant_paid  # noqa: E402
import main as main_module  # noqa: E402
import routes.devotion as devotion_module  # noqa: E402
import routes.messaging as messaging_module  # noqa: E402
import backend.interactions.devotion as devotion_backend_module  # noqa: E402
import backend.interactions.scheduler as scheduler_module  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402
from backend.interactions.devotion import DevotionManager  # noqa: E402
from backend.interactions import ring_lifecycle  # noqa: E402
from backend.subscription.limits import LimitsManager  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def ck(token):
    return {"cookie": f"session={token}"} if token else {}


_n = 0


def signup(client, prefix, paid=True):
    global _n
    _n += 1
    username = f"{prefix}_{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com",
        "plain_pass": "TestPass123!", "terms_accepted": True,
    }, headers={"cf-connecting-ip": f"203.0.118.{_n % 250 + 1}"})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    if paid:
        grant_paid(r.json()["user_id"])
    return r.json()["user_id"], r.cookies.get("session")


def make_friends(a, b):
    db = DBManager()
    try:
        db.insertion("user_friends", {"user_id": a, "friend_id": b})
        db.insertion("user_friends", {"user_id": b, "friend_id": a})
    finally:
        db.close()


def unfriend(a, b):
    db = DBManager()
    try:
        db.cur.execute("DELETE FROM user_friends WHERE (user_id=%s AND friend_id=%s) OR (user_id=%s AND friend_id=%s)", (a, b, b, a))
        db.conn.commit()
    finally:
        db.close()


def make_blocked(blocker, blocked):
    db = DBManager()
    try:
        db.insertion("blocked_users", {"blocker_id": blocker, "blocked_id": blocked})
    finally:
        db.close()


def clear_blocks(*uids):
    db = DBManager()
    try:
        for u in uids:
            db.cur.execute("DELETE FROM blocked_users WHERE blocker_id=%s OR blocked_id=%s", (u, u))
        db.conn.commit()
    finally:
        db.close()


def room(a, b):
    return "|".join(sorted([a, b]))


def sql_one(query, params=()):
    db = DBManager()
    try:
        db.cur.execute(query, params)
        return db.cur.fetchone()
    finally:
        db.close()


def sql_exec(query, params=()):
    db = DBManager()
    try:
        db.cur.execute(query, params)
        db.conn.commit()
    finally:
        db.close()


def insert_legacy_dm_row(creator, other, *, recurring=False, time_start=None, time_end=None,
                         reminder_sent_at=None):
    """Pre-existing scheduled DM session: group_id is the uidA|uidB key and
    call_kind is NULL (exactly what old clients created)."""
    sid = str(uuid.uuid4())
    sql_exec(
        "INSERT INTO devotions (_id, title, time_start, time_end, recurring, group_id, creator_id, "
        "participants, verses, prompts, chime_meeting_id, reminder_sent_at) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
        (sid, "Old DM session", time_start, time_end, recurring, room(creator, other), creator,
         [creator, other], [], [], "", reminder_sent_at),
    )
    return sid


def insert_plain_row(creator, *, time_start=None, time_end=None, recurring=False, group_id=None):
    sid = str(uuid.uuid4())
    sql_exec(
        "INSERT INTO devotions (_id, title, time_start, time_end, recurring, group_id, creator_id, "
        "participants, verses, prompts, chime_meeting_id) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
        (sid, "Plain session", time_start, time_end, recurring, group_id, creator, [], [], [], ""),
    )
    return sid


def devotion_row(sid):
    return sql_one(
        "SELECT call_kind, group_id, creator_id, time_start, time_end, recurring, chime_meeting_id, "
        "reminder_sent_at, title FROM devotions WHERE _id=%s", (sid,))


def dm_call(client, token, uid, peer, user_id=None):
    return client.post("/devotions/dm-call", json={"user_id": user_id or uid, "peer_id": peer}, headers=ck(token))


def set_voip_token(uid, tok):
    sql_exec("INSERT INTO voip_device_tokens (user_id, token) VALUES (%s,%s) "
             "ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token", (uid, tok))


def set_plain_token(uid, tok):
    sql_exec("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) "
             "ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token", (uid, tok))


def set_live_call(sid):
    db = DevotionManager()
    try:
        db.save_chime_meeting(sid, f"meeting-{uuid.uuid4()}", {"MeetingId": "fake"})
    finally:
        db.close()


def ring(client, token, uid, sid, targets):
    return client.post("/devotions/ring", json={"devotion_id": sid, "user_id": uid, "target_ids": targets}, headers=ck(token))


def respond(client, token, uid, sid, target, outcome):
    return client.post("/devotions/ring/respond", json={
        "devotion_id": sid, "user_id": uid, "target_id": target, "outcome": outcome}, headers=ck(token))


def ring_status(client, token, uid, sid):
    return client.get("/devotions/ring/status", params={"devotion_id": sid, "user_id": uid}, headers=ck(token))


def ring_row(sid, target):
    return sql_one("SELECT status, caller_id, voip_token FROM ring_states WHERE devotion_id=%s AND target_id=%s", (sid, target))


class FakeChime:
    def create_meeting(self, **kw):
        return {"Meeting": {"MeetingId": str(uuid.uuid4()), "ExternalMeetingId": kw.get("ExternalMeetingId", ""),
                            "MediaRegion": "us-east-1", "MediaPlacement": {}}}

    def create_attendee(self, **kw):
        return {"Attendee": {"AttendeeId": str(uuid.uuid4()), "ExternalUserId": kw.get("ExternalUserId", ""),
                             "JoinToken": "fake-join-token"}}


class CapturePush:
    def __init__(self, result=True):
        self.calls = []
        self.result = result

    async def __call__(self, token, *a, **kw):
        data = kw.get("data")
        if data is None and a and isinstance(a[-1], dict):
            data = a[-1]
        self.calls.append((token, data or {}))
        return self.result

    def of(self, action):
        return [c for c in self.calls if c[1].get("action") == action]


def cleanup(*uids, group_ids=()):
    db = DBManager()
    try:
        for uid in uids:
            db.cur.execute("DELETE FROM ring_states WHERE caller_id=%s OR target_id=%s", (uid, uid))
            db.cur.execute("DELETE FROM ring_cooldowns WHERE sender_id=%s OR recipient_id=%s", (uid, uid))
            db.cur.execute("DELETE FROM devotions WHERE creator_id=%s", (uid,))
            db.cur.execute("DELETE FROM blocked_users WHERE blocker_id=%s OR blocked_id=%s", (uid, uid))
            db.cur.execute("DELETE FROM user_friends WHERE user_id=%s OR friend_id=%s", (uid, uid))
            db.cur.execute("DELETE FROM device_tokens WHERE user_id=%s", (uid,))
            db.cur.execute("DELETE FROM voip_device_tokens WHERE user_id=%s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id=%s", (uid,))
        for gid in group_ids:
            db.cur.execute("DELETE FROM groups WHERE _id=%s", (gid,))
        db.conn.commit()
    finally:
        db.close()


# ── 1. POST /devotions/dm-call ──────────────────────────────────────────────

def test_dm_call_creation_and_authz(client):
    print("=== 1. POST /devotions/dm-call: creation, idempotence, authorization ===")
    a, ta = signup(client, "dmc_a")
    b, tb = signup(client, "dmc_b")
    s, ts = signup(client, "dmc_stranger")
    try:
        r = dm_call(client, ta, a, b)
        check("non-friends -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        check("no row created for a denied pair",
              sql_one("SELECT 1 FROM devotions WHERE group_id=%s", (room(a, b),)) is None)

        make_friends(a, b)
        r = dm_call(client, ta, a, b)
        check("verified mutual friends -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
        body = r.json()
        sid = body["id"]
        check("response carries id, peer_id and session", body["peer_id"] == b and body["session"]["id"] == sid, str(body))
        row = devotion_row(sid)
        check("row is marked call_kind='dm_call' with the sorted room key",
              row[0] == "dm_call" and row[1] == room(a, b), str(row))
        check("row is open-ended (time_end NULL, not recurring) with an empty chime_meeting_id",
              row[4] is None and row[5] is False and (row[6] or "") == "", str(row))
        check("time_start is set (join window opens now) and reminder is pre-claimed",
              row[3] is not None and row[7] is not None, str(row))
        check("creator is the authenticated caller", str(row[2]) == a, str(row))

        r2 = dm_call(client, ta, a, b)
        check("second call by the same user returns the same row", r2.status_code == 200 and r2.json()["id"] == sid, r2.text)
        r3 = dm_call(client, tb, b, a)
        check("the peer calling back gets the SAME row (one per room)", r3.status_code == 200 and r3.json()["id"] == sid, r3.text)
        n = sql_one("SELECT COUNT(*) FROM devotions WHERE group_id=%s AND call_kind='dm_call'", (room(a, b),))[0]
        check("exactly one dm_call row exists for the room", n == 1, str(n))

        r = dm_call(client, ta, a, b, user_id=b)
        check("forged user_id (not the caller) -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        r = dm_call(client, ta, a, a)
        check("calling yourself -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        r = dm_call(client, ta, a, f"{b}|{s}")
        check("peer_id containing '|' -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        r = client.post("/devotions/dm-call", json={"user_id": a, "peer_id": b})
        check("unauthenticated -> 401/403", r.status_code in (401, 403), f"{r.status_code}")
        r = dm_call(client, ts, s, b)
        check("a stranger cannot open a row against someone else's friend -> 403", r.status_code == 403, f"{r.status_code} {r.text}")

        # Block in either direction undoes the friendship for call purposes.
        c, tc = signup(client, "dmc_c")
        d, td = signup(client, "dmc_d")
        make_friends(c, d)
        make_blocked(d, c)
        r = dm_call(client, tc, c, d)
        check("friends where the PEER blocked the caller -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        r = dm_call(client, td, d, c)
        check("friends where the CALLER blocked the peer -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        check("no row created for blocked pair",
              sql_one("SELECT 1 FROM devotions WHERE group_id=%s", (room(c, d),)) is None)
        cleanup(c, d)
    finally:
        cleanup(a, b, s)


# ── 2. Legacy DM rows: inert, never mutated; group sessions unchanged ───────

def test_legacy_dm_rows_inert_and_group_unchanged(client):
    print("\n=== 2. Legacy scheduled DM rows -> 410 and untouched; group sessions unchanged ===")
    a, ta = signup(client, "leg_a")
    b, tb = signup(client, "leg_b")
    g, tg = signup(client, "leg_g")
    gid = None
    orig_chime_d, orig_chime_m = devotion_module.chime, messaging_module.chime
    devotion_module.chime = messaging_module.chime = FakeChime()
    try:
        make_friends(a, b)
        now = datetime.now(tzmod.utc)
        legacy = insert_legacy_dm_row(a, b, time_start=now - timedelta(minutes=1), time_end=now + timedelta(hours=1))
        before = devotion_row(legacy)

        for label, resp in [
            ("POST /devotions/join on a legacy DM row", client.post("/devotions/join", params={"user_id": a, "session_id": legacy}, headers=ck(ta))),
            ("POST /devotions/join-call on a legacy DM row", client.post("/devotions/join-call", params={"user_id": a, "session_id": legacy}, headers=ck(ta))),
            ("POST /devotions/ring on a legacy DM row", ring(client, ta, a, legacy, [b])),
            ("POST /chime/{id} on a legacy DM row", client.post(f"/chime/{legacy}", headers=ck(ta))),
            ("POST /chime/{id}/{uid}/attend on a legacy DM row", client.post(f"/chime/{legacy}/{a}/attend", headers=ck(ta))),
        ]:
            check(f"{label} -> 410", resp.status_code == 410, f"{resp.status_code} {resp.text}")

        put = client.put("/devotions/", json={"devotion_id": legacy, "user_id": a, "devotion": {
            "id": legacy, "title": "edited", "creator_id": a, "group_id": room(a, b), "prompts": ["p"]}}, headers=ck(ta))
        check("PUT /devotions/ on a legacy DM row -> 410", put.status_code == 410, f"{put.status_code} {put.text}")

        new_id = str(uuid.uuid4())
        post = client.post("/devotions/", json={"devotion_id": new_id, "user_id": a, "devotion": {
            "id": new_id, "title": "new dm session", "creator_id": a, "group_id": room(a, b), "prompts": ["p"]}}, headers=ck(ta))
        check("POST /devotions/ creating a '|' group_id session -> 410", post.status_code == 410, f"{post.status_code} {post.text}")
        check("...and no row was created for it", sql_one("SELECT 1 FROM devotions WHERE _id=%s", (new_id,)) is None)

        check("legacy row is byte-for-byte unchanged after all of the above (never mutated or deleted)",
              devotion_row(legacy) == before, f"{before} -> {devotion_row(legacy)}")

        # Hidden from the contact list; the dm_call row is hidden too.
        call_id = dm_call(client, ta, a, b).json()["id"]
        lst = client.get(f"/devotions/contact/{room(a, b)}", headers=ck(ta))
        ids = [s.get("id") for s in lst.json().get("sessions", [])] if lst.status_code == 200 else None
        check("GET /devotions/contact/{room} lists neither the legacy row nor the dm_call row",
              lst.status_code == 200 and legacy not in ids and call_id not in ids, f"{lst.status_code} {ids}")
        check("legacy row and dm_call row are distinct", call_id != legacy)
        check("get-or-create did not touch the legacy row", devotion_row(legacy) == before)

        # dm_call row cannot be edited via PUT.
        put2 = client.put("/devotions/", json={"devotion_id": call_id, "user_id": a, "devotion": {
            "id": call_id, "title": "x", "creator_id": a, "group_id": room(a, b), "prompts": ["p"]}}, headers=ck(ta))
        check("PUT /devotions/ on the dm_call row -> 403", put2.status_code == 403, f"{put2.status_code} {put2.text}")

        # Group sessions: unchanged behaviour (create, list, join-call all work).
        gid = str(uuid.uuid4())
        rg = client.post(f"/groups/{g}", json={"group_id": gid, "title": "G", "users": [g, a]}, headers=ck(tg))
        assert rg.status_code == 201, rg.text
        gs = str(uuid.uuid4())
        start = (now - timedelta(minutes=1)).isoformat()
        end = (now + timedelta(hours=1)).isoformat()
        rc = client.post("/devotions/", json={"devotion_id": gs, "user_id": g, "devotion": {
            "id": gs, "title": "Group session", "creator_id": g, "group_id": gid, "prompts": ["p"],
            "time_start": start, "time_end": end}}, headers=ck(tg))
        check("group session create still 201", rc.status_code == 201, f"{rc.status_code} {rc.text}")
        gl = client.get(f"/devotions/contact/{gid}", headers=ck(tg))
        check("group session still listed", gl.status_code == 200 and gs in [s.get("id") for s in gl.json()["sessions"]], gl.text[:200])
        rj = client.post("/devotions/join-call", params={"user_id": a, "session_id": gs}, headers=ck(ta))
        check("group member join-call still 200", rj.status_code == 200 and "Attendee" in rj.json(), f"{rj.status_code} {rj.text[:200]}")
        rj2 = client.post("/devotions/join", params={"user_id": a, "session_id": gs}, headers=ck(ta))
        check("group member join still works (not 410)", rj2.status_code != 410, f"{rj2.status_code} {rj2.text[:200]}")
    finally:
        devotion_module.chime, messaging_module.chime = orig_chime_d, orig_chime_m
        cleanup(a, b, g, group_ids=[gid] if gid else ())


# ── 3. join-call and /chime on the dm_call row ──────────────────────────────

def test_dm_call_join_and_chime_authz(client):
    print("\n=== 3. dm_call row: join-call and /chime require the verified roster ===")
    a, ta = signup(client, "chm_a")
    b, tb = signup(client, "chm_b")
    x, tx = signup(client, "chm_x")
    orig_chime_d, orig_chime_m = devotion_module.chime, messaging_module.chime
    devotion_module.chime = messaging_module.chime = FakeChime()
    try:
        make_friends(a, b)
        sid = dm_call(client, ta, a, b).json()["id"]

        r = client.post("/devotions/join-call", params={"user_id": a, "session_id": sid}, headers=ck(ta))
        check("caller join-call on dm_call row -> 200 immediately (no scheduled window)",
              r.status_code == 200 and "Meeting" in r.json() and "Attendee" in r.json(), f"{r.status_code} {r.text[:200]}")
        r = client.post("/devotions/join-call", params={"user_id": b, "session_id": sid}, headers=ck(tb))
        check("peer join-call on the same row -> 200 (same Chime meeting)", r.status_code == 200, f"{r.status_code} {r.text[:200]}")

        r = client.post(f"/chime/{sid}", headers=ck(tb))
        check("roster member /chime/{id} -> 200", r.status_code == 200 and "Meeting" in r.json(), f"{r.status_code} {r.text[:200]}")
        r = client.post(f"/chime/{sid}/{b}/attend", headers=ck(tb))
        check("roster member /chime/{id}/{uid}/attend -> 200", r.status_code == 200 and "Attendee" in r.json(), f"{r.status_code} {r.text[:200]}")

        # Outsider (not creator/participant/room member): denied up front.
        r = client.post(f"/chime/{sid}", headers=ck(tx))
        check("outsider /chime/{id} on a dm_call row -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        r = client.post("/devotions/join-call", params={"user_id": x, "session_id": sid}, headers=ck(tx))
        check("outsider join-call on a dm_call row -> 403", r.status_code == 403, f"{r.status_code} {r.text}")

        # The security-gate case: the row's CREATOR (passes is_authorized by
        # creator_id) after the friendship was undone is NOT in the roster.
        unfriend(a, b)
        for label, resp in [
            ("/chime/{id}", client.post(f"/chime/{sid}", headers=ck(ta))),
            ("/chime/{id}/{uid}/attend", client.post(f"/chime/{sid}/{a}/attend", headers=ck(ta))),
            ("/devotions/join-call", client.post("/devotions/join-call", params={"user_id": a, "session_id": sid}, headers=ck(ta))),
            ("/chime/{id} (peer side)", client.post(f"/chime/{sid}", headers=ck(tb))),
        ]:
            check(f"unfriended member (non-roster) on dm_call row via {label} -> 403", resp.status_code == 403, f"{resp.status_code} {resp.text}")

        make_friends(a, b)
        make_blocked(b, a)
        r = client.post(f"/chime/{sid}", headers=ck(ta))
        check("blocked pair (non-roster) /chime/{id} -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        clear_blocks(a, b)
        r = client.post(f"/chime/{sid}", headers=ck(ta))
        check("restored friendship -> /chime/{id} 200 again (fail-closed check is live, not sticky)", r.status_code == 200, f"{r.status_code} {r.text}")
    finally:
        devotion_module.chime, messaging_module.chime = orig_chime_d, orig_chime_m
        cleanup(a, b, x)


# ── 4. Scheduler jobs and free-plan cap ignore DM rows ──────────────────────

def test_scheduler_and_limits_exclusions(client):
    print("\n=== 4. Scheduler jobs and the free-plan cap exclude DM rows ===")
    a, ta = signup(client, "sch_a", paid=False)
    b, tb = signup(client, "sch_b")
    try:
        make_friends(a, b)
        now = datetime.now(tzmod.utc)
        old = now - timedelta(days=3)
        legacy_ended = insert_legacy_dm_row(a, b, time_start=old, time_end=old)
        legacy_recur = insert_legacy_dm_row(a, b, recurring=True, time_start=old, time_end=old)
        legacy_unreminded = insert_legacy_dm_row(a, b, time_start=old, time_end=now + timedelta(days=1))
        call_id = dm_call(client, ta, a, b).json()["id"]
        # Age the dm_call row so every scan would pick it up if not excluded.
        sql_exec("UPDATE devotions SET time_start=%s, time_end=%s, reminder_sent_at=NULL WHERE _id=%s", (old, old, call_id))
        before = {i: devotion_row(i) for i in (legacy_ended, legacy_recur, legacy_unreminded, call_id)}
        # Controls: ordinary (non-DM) rows the jobs must still handle.
        ctrl_end = insert_plain_row(b, time_start=old, time_end=old)
        ctrl_remind = insert_plain_row(b, time_start=old, time_end=now + timedelta(days=1))

        asyncio.run(scheduler_module._auto_delete_expired_sessions())
        for name, i in (("ended legacy DM row", legacy_ended), ("recurring legacy DM row", legacy_recur),
                        ("dm_call row", call_id)):
            check(f"auto-delete job does not delete the {name}", devotion_row(i) is not None)
        check("auto-delete job still deletes an ordinary expired session (job ran)", devotion_row(ctrl_end) is None)

        asyncio.run(scheduler_module._advance_recurring_sessions())
        check("recurring-advance job leaves the recurring legacy DM row unchanged", devotion_row(legacy_recur) == before[legacy_recur],
              f"{before[legacy_recur]} -> {devotion_row(legacy_recur)}")

        asyncio.run(scheduler_module._fire_due_session_reminders())
        for name, i in (("legacy DM row", legacy_unreminded), ("dm_call row", call_id)):
            row = devotion_row(i)
            check(f"reminder scan does not claim the {name} (reminder_sent_at stays NULL)", row[7] is None, str(row))
        check("reminder scan still claims an ordinary due session (job ran)", devotion_row(ctrl_remind)[7] is not None, str(devotion_row(ctrl_remind)))
        for i in (legacy_ended, legacy_recur, legacy_unreminded, call_id):
            check(f"row {i[:8]} intact after all three jobs", devotion_row(i)[:7] == before[i][:7], str(devotion_row(i)))

        # Free-plan cap: only the user's real (non-DM) sessions count.
        lm = LimitsManager()
        try:
            v0 = lm.check(a, "sessions")
            used = lm._count("sessions", a)
        finally:
            lm.close()
        check("free-plan session count ignores legacy DM rows and the dm_call row (free user may still create a session)",
              used == 0 and v0["allowed"] is True and v0["used"] == 0, f"counted {used} {v0}")
        sid = insert_plain_row(a, time_start=now, time_end=now + timedelta(days=1))
        lm = LimitsManager()
        try:
            used2 = lm._count("sessions", a)
            verdict = lm.check(a, "sessions")
        finally:
            lm.close()
        check("an ordinary active session still counts exactly 1 (cap is live)", used2 == 1 and verdict["allowed"] is False, f"{used2} {verdict}")
    finally:
        cleanup(a, b)


# ── 5. Ring lifecycle ───────────────────────────────────────────────────────

def test_ring_lifecycle_dm(client):
    print("\n=== 5. Ring lifecycle on a DM call (VoIP mode) ===")
    a, ta = signup(client, "rl_a")
    b, tb = signup(client, "rl_b")
    x, tx = signup(client, "rl_x")
    orig_voip, orig_send = push_module.send_voip_push, push_module.send_push
    voip = CapturePush(True)
    push_module.send_voip_push = voip
    push_module.send_push = CapturePush(True)
    orig_chime_d = devotion_module.chime
    devotion_module.chime = FakeChime()
    try:
        make_friends(a, b)
        set_voip_token(b, f"voip-{b}")
        sid = dm_call(client, ta, a, b).json()["id"]

        r = ring(client, ta, a, sid, [b])
        check("ring before a live call -> no_active_call (unchanged gate)",
              r.status_code == 200 and r.json()["results"][b]["reason"] == "no_active_call", r.text)
        check("no ring state recorded for a refused ring", ring_row(sid, b) is None)

        set_live_call(sid)
        r = ring(client, ta, a, sid, [b])
        check("ring a DM peer after the call is live -> sent", r.status_code == 200 and r.json()["results"][b]["sent"] is True, r.text)
        check("exactly one VoIP ring push, to the peer's VoIP token",
              len(voip.of("ring")) == 1 and voip.calls[0][0] == f"voip-{b}", str(voip.calls))
        row = ring_row(sid, b)
        check("ring_states row is 'ringing' for the right caller with the VoIP token stored",
              row is not None and row[0] == "ringing" and str(row[1]) == a and row[2] == f"voip-{b}", str(row))
        exp = sql_one("SELECT expires_at - created_at FROM ring_states WHERE devotion_id=%s AND target_id=%s", (sid, b))[0]
        check("expiry window equals RING_TIMEOUT_SECONDS",
              int(exp.total_seconds()) == devotion_backend_module.ring_timeout_seconds(), str(exp))

        st = ring_status(client, ta, a, sid).json()["rings"]
        check("caller /ring/status shows the target ringing with seconds_left > 0",
              st.get(b, {}).get("status") == "ringing" and st[b]["seconds_left"] > 0, str(st))
        st_b = ring_status(client, tb, b, sid).json()["rings"]
        check("the target's own /ring/status does not expose the caller's rings", st_b == {}, str(st_b))
        r = client.get("/devotions/ring/status", params={"devotion_id": sid, "user_id": a}, headers=ck(tb))
        check("/ring/status for someone else's user_id -> 403", r.status_code == 403, f"{r.status_code}")

        # Authorization matrix on respond.
        check("caller cannot answer their own ring -> 403", respond(client, ta, a, sid, b, "answered").status_code == 403)
        check("caller cannot decline their own ring -> 403", respond(client, ta, a, sid, b, "declined").status_code == 403)
        check("target cannot cancel the caller's ring -> 403", respond(client, tb, b, sid, b, "canceled").status_code == 403)
        check("third party cannot answer -> 403", respond(client, tx, x, sid, b, "answered").status_code == 403)
        check("third party cannot cancel -> 403", respond(client, tx, x, sid, b, "canceled").status_code == 403)
        check("forged user_id on respond -> 403", respond(client, tx, b, sid, b, "declined").status_code == 403)
        check("ring still 'ringing' after all the denied attempts", ring_row(sid, b)[0] == "ringing")
        r = respond(client, tb, b, sid, x, "declined")
        check("respond for a target that was never rung -> 404", r.status_code == 404, f"{r.status_code} {r.text}")

        # Decline.
        r = respond(client, tb, b, sid, b, "declined")
        check("target declines -> 200 changed:true", r.status_code == 200 and r.json() == {"status": "declined", "changed": True}, r.text)
        check("declined state persisted", ring_row(sid, b)[0] == "declined")
        r = respond(client, tb, b, sid, b, "answered")
        check("a second response is idempotent: changed:false and the status stays 'declined'",
              r.status_code == 200 and r.json() == {"status": "declined", "changed": False}, r.text)
        r = respond(client, ta, a, sid, b, "canceled")
        check("caller hang-up after decline is a no-op (changed:false, no cancel push)",
              r.status_code == 200 and r.json()["changed"] is False and len(voip.of("ring_cancel")) == 0, f"{r.text} {voip.calls}")
        st = ring_status(client, ta, a, sid).json()["rings"]
        check("caller sees 'declined' in /ring/status", st[b]["status"] == "declined" and st[b]["seconds_left"] == 0, str(st))

        # Re-ring (cooldown released so the second ring can go out), caller hangs up.
        sql_exec("DELETE FROM ring_cooldowns WHERE sender_id=%s AND recipient_id=%s", (a, b))
        r = ring(client, ta, a, sid, [b])
        check("a fresh ring after a decline resets the state to ringing",
              r.json()["results"][b]["sent"] is True and ring_row(sid, b)[0] == "ringing", r.text)
        r = respond(client, ta, a, sid, b, "canceled")
        check("caller hang-up -> 200 changed:true", r.status_code == 200 and r.json() == {"status": "canceled", "changed": True}, r.text)
        cancels = voip.of("ring_cancel")
        check("hang-up sent exactly one VoIP ring_cancel push to the target's token with reason=canceled",
              len(cancels) == 1 and cancels[0][0] == f"voip-{b}" and cancels[0][1].get("reason") == "canceled"
              and cancels[0][1].get("devotion_id") == sid and cancels[0][1].get("caller_id") == a, str(cancels))
        r = respond(client, ta, a, sid, b, "canceled")
        check("second hang-up is idempotent and sends no second cancel push",
              r.json()["changed"] is False and len(voip.of("ring_cancel")) == 1, f"{r.text} {voip.calls}")

        # Joining the call answers the ring server-side.
        sql_exec("DELETE FROM ring_cooldowns WHERE sender_id=%s AND recipient_id=%s", (a, b))
        ring(client, ta, a, sid, [b])
        check("ringing again", ring_row(sid, b)[0] == "ringing")
        rj = client.post("/devotions/join-call", params={"user_id": b, "session_id": sid}, headers=ck(tb))
        check("target joins the call -> 200", rj.status_code == 200, f"{rj.status_code} {rj.text[:200]}")
        check("join-call marked the target's ring 'answered'", ring_row(sid, b)[0] == "answered", str(ring_row(sid, b)))
        check("answering sends no cancel push (target's own device handled it)", len(voip.of("ring_cancel")) == 1)

        # Ring feature disabled -> respond 404 like the ring route.
        orig = devotion_backend_module.RING_FEATURE_ENABLED
        devotion_backend_module.RING_FEATURE_ENABLED = False
        try:
            r = respond(client, tb, b, sid, b, "declined")
            check("ring disabled -> /ring/respond 404", r.status_code == 404, f"{r.status_code}")
        finally:
            devotion_backend_module.RING_FEATURE_ENABLED = orig
    finally:
        push_module.send_voip_push, push_module.send_push = orig_voip, orig_send
        devotion_module.chime = orig_chime_d
        cleanup(a, b, x)


def test_ring_expiry_and_plain_mode_and_group(client):
    print("\n=== 5b. Server-side expiry, plain (non-VoIP) mode, group-session ring ===")
    a, ta = signup(client, "rx_a")
    b, tb = signup(client, "rx_b")
    g1, tg1 = signup(client, "rx_g1")
    g2, tg2 = signup(client, "rx_g2")
    gid = None
    orig_voip, orig_send = push_module.send_voip_push, push_module.send_push
    voip = CapturePush(True)
    plain = CapturePush(True)
    push_module.send_voip_push = voip
    push_module.send_push = plain
    try:
        make_friends(a, b)
        set_voip_token(b, f"voip-{b}")
        sid = dm_call(client, ta, a, b).json()["id"]
        set_live_call(sid)
        ring(client, ta, a, sid, [b])
        check("ringing recorded", ring_row(sid, b)[0] == "ringing")

        n0 = asyncio.run(ring_lifecycle.expire_due_rings())
        check("sweep before the deadline expires nothing from this ring", ring_row(sid, b)[0] == "ringing" and len(voip.of("ring_cancel")) == 0, f"{n0}")
        sql_exec("UPDATE ring_states SET expires_at = NOW() - INTERVAL '1 second' WHERE devotion_id=%s AND target_id=%s", (sid, b))
        asyncio.run(ring_lifecycle.expire_due_rings())
        check("past the deadline the sweep marks the ring 'timed_out'", ring_row(sid, b)[0] == "timed_out", str(ring_row(sid, b)))
        c = voip.of("ring_cancel")
        check("expiry sent one VoIP ring_cancel (reason=timed_out) to the target",
              len(c) == 1 and c[0][0] == f"voip-{b}" and c[0][1].get("reason") == "timed_out", str(c))
        asyncio.run(ring_lifecycle.expire_due_rings())
        check("a second sweep does not expire or cancel the same ring again", len(voip.of("ring_cancel")) == 1)
        st = ring_status(client, ta, a, sid).json()["rings"]
        check("caller /ring/status reports 'timed_out' (no answer)", st[b]["status"] == "timed_out", str(st))
        r = respond(client, tb, b, sid, b, "answered")
        check("answering after the timeout cannot revive it (changed:false, still timed_out)",
              r.json() == {"status": "timed_out", "changed": False}, r.text)
        r = respond(client, ta, a, sid, b, "canceled")
        check("hang-up after timeout sends no extra cancel", r.json()["changed"] is False and len(voip.of("ring_cancel")) == 1)

        # The status route itself expires due rings (backstop when the job is late).
        sql_exec("DELETE FROM ring_cooldowns WHERE sender_id=%s AND recipient_id=%s", (a, b))
        ring(client, ta, a, sid, [b])
        sql_exec("UPDATE ring_states SET expires_at = NOW() - INTERVAL '1 second' WHERE devotion_id=%s AND target_id=%s", (sid, b))
        st = ring_status(client, ta, a, sid).json()["rings"]
        check("/ring/status expires a due ring lazily before reading", st[b]["status"] == "timed_out", str(st))

        # Scheduler registration of the expiry job.
        # (the app lifespan of the TestClient already started the scheduler)
        job = scheduler_module.scheduler.get_job("ring_expiry")
        check("app boot registers the ring_expiry scheduler job", job is not None)

        # Plain (RING_VOIP_ENABLED=false) mode: state tracked, no token stored, no cancel push.
        orig_voip_flag = devotion_backend_module.RING_VOIP_ENABLED
        devotion_backend_module.RING_VOIP_ENABLED = False
        try:
            set_plain_token(b, f"plain-{b}")
            sql_exec("DELETE FROM ring_cooldowns WHERE sender_id=%s AND recipient_id=%s", (a, b))
            before_cancels = len(voip.of("ring_cancel"))
            r = ring(client, ta, a, sid, [b])
            check("plain-mode ring sent via the alert push", r.json()["results"][b]["sent"] is True and len(plain.calls) == 1, r.text)
            row = ring_row(sid, b)
            check("plain-mode ring is still recorded ringing, with NO voip token stored", row[0] == "ringing" and row[2] is None, str(row))
            r = respond(client, ta, a, sid, b, "canceled")
            check("plain-mode hang-up resolves the state without any cancel push",
                  r.json()["changed"] is True and len(voip.of("ring_cancel")) == before_cancels, f"{r.text} {voip.calls}")
        finally:
            devotion_backend_module.RING_VOIP_ENABLED = orig_voip_flag

        # Group session rings share the same lifecycle path.
        gid = str(uuid.uuid4())
        rg = client.post(f"/groups/{g1}", json={"group_id": gid, "title": "G", "users": [g1, g2]}, headers=ck(tg1))
        assert rg.status_code == 201, rg.text
        gs = str(uuid.uuid4())
        rc = client.post("/devotions/", json={"devotion_id": gs, "user_id": g1, "devotion": {
            "id": gs, "title": "Group ring", "creator_id": g1, "group_id": gid, "prompts": ["p"]}}, headers=ck(tg1))
        assert rc.status_code == 201, rc.text
        set_live_call(gs)
        set_voip_token(g2, f"voip-{g2}")
        r = ring(client, tg1, g1, gs, [g2])
        check("group session ring still sends", r.json()["results"][g2]["sent"] is True, r.text)
        check("group session ring is recorded in the same ring_states table", ring_row(gs, g2)[0] == "ringing")
        r = respond(client, tg2, g2, gs, g2, "declined")
        check("group target can decline through the same route", r.json() == {"status": "declined", "changed": True}, r.text)
    finally:
        push_module.send_voip_push, push_module.send_push = orig_voip, orig_send
        cleanup(a, b, g1, g2, group_ids=[gid] if gid else ())


def main():
    with TestClient(main_module.app) as client:
        test_dm_call_creation_and_authz(client)
        test_legacy_dm_rows_inert_and_group_unchanged(client)
        test_dm_call_join_and_chime_authz(client)
        test_scheduler_and_limits_exclusions(client)
        test_ring_lifecycle_dm(client)
        test_ring_expiry_and_plain_mode_and_group(client)

    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
