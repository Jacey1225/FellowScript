"""Regression coverage for task 20260920-session-join-window-gating.

Feature: /devotions/join and /devotions/join-call now enforce a server-side
join-window check (`DevotionManager.is_join_window_open`,
api/backend/interactions/devotion.py) on top of the pre-existing
`is_authorized` membership check, per the binding contract at
.claude/pipeline/20260920-session-join-window-gating/join-window-contract.md
section 2. This file proves each branch of that contract against the real
route (not just the manager method in isolation), for an already-authorized
caller in every case -- these are all window-boundary tests, not membership
tests (test_group_session_join_regression.py already covers membership):

  1. In-window join is allowed (time_start in the past, time_end in the
     future) -- the ordinary case must keep working.
  2. Before-window join (time_start well in the future, beyond the grace
     period) is denied with the documented detail string.
  3. Early join within the SESSION_JOIN_GRACE_MINUTES grace period is
     allowed (time_start a few minutes in the future, inside the grace
     window).
  4. After-window join (time_end in the past) is denied.
  5. Missing time_start fails closed -- denied, never "always open"
     (contract section 2, point 2).
  6. Missing/empty time_end is open-ended once time_start has passed --
     allowed, no synthesized duration (contract section 2, point 4).
  7. The already-live-call bypass: once a session's chime_meeting_id is a
     real, server-set value (via a first successful join-call), a *second*,
     different authorized member can still join-call even after time_end
     has passed -- this is also the mechanism the ring-invite path relies
     on (contract section 5), so it is proven here at the shared-helper
     level rather than needing a dedicated ring-specific test.

Run with: cd api && ../.venv/bin/python tests/test_session_join_window_gating.py
"""
import _pathfix  # noqa: F401

import os
import uuid
from datetime import datetime, timedelta, timezone

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
import routes.devotion as devotion_module  # noqa: E402
from db import DBManager  # noqa: E402

PASSED, FAILED = [], []

_NOT_OPEN_DETAIL = "This session isn't open yet."


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def cookie_header(token: str):
    return {"cookie": f"session={token}"} if token else {}


def signup(client, username):
    fake_ip = f"203.0.113.{uuid.uuid4().int % 250 + 1}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def cleanup(*user_ids, group_ids=(), devotion_ids=()):
    db = DBManager()
    try:
        for did in devotion_ids:
            db.cur.execute("DELETE FROM devotions WHERE _id = %s", (did,))
        for gid in group_ids:
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM devotions WHERE creator_id = %s", (uid,))
            db.cur.execute("DELETE FROM groups WHERE %s = ANY(users)", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


class FakeChimeClient:
    """Same fake pattern as test_group_session_join_regression.py -- exercises
    only the window-check branch of join_call, not real AWS calls."""

    def create_meeting(self, **kwargs):
        return {"Meeting": {
            "MeetingId": str(uuid.uuid4()),
            "ExternalMeetingId": kwargs.get("ExternalMeetingId", ""),
            "MediaRegion": "us-east-1",
            "MediaPlacement": {},
        }}

    def create_attendee(self, **kwargs):
        return {"Attendee": {
            "AttendeeId": str(uuid.uuid4()),
            "ExternalUserId": kwargs.get("ExternalUserId", ""),
            "JoinToken": "fake-join-token",
        }}


def create_group(client, token, owner_uid, member_uids):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner_uid}", json={
        "group_id": gid, "title": "Join-window group", "users": [owner_uid, *member_uids],
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def create_session(client, token, creator_uid, group_id, time_start=None, time_end=None):
    """Creates a devotion with an explicit (or omitted) time_start/time_end so
    each test controls the window precisely. Omitting a key relies on
    DevotionPlan's own "" default -- the same shape a malformed/legacy client
    payload with no time fields at all would take, which is exactly what
    `is_join_window_open`'s missing-time_start branch must handle."""
    devo_id = str(uuid.uuid4())
    devotion = {
        "id": devo_id, "title": "Join-window session", "creator_id": creator_uid,
        "participants": [], "group_id": group_id, "prompts": ["p1"], "verses": [],
    }
    if time_start is not None:
        devotion["time_start"] = time_start
    if time_end is not None:
        devotion["time_end"] = time_end
    payload = {"devotion_id": devo_id, "user_id": creator_uid, "devotion": devotion}
    r = client.post("/devotions/", json=payload, headers=cookie_header(token))
    assert r.status_code == 201, f"create_devotion failed: {r.status_code} {r.text}"
    return devo_id


def iso(dt: datetime) -> str:
    return dt.isoformat()


def join_devotion(client, token, session_id, user_id):
    return client.post(
        "/devotions/join",
        params={"session_id": session_id, "user_id": user_id},
        headers=cookie_header(token),
    )


def join_call(client, token, session_id, user_id):
    return client.post(
        "/devotions/join-call",
        params={"session_id": session_id, "user_id": user_id},
        headers=cookie_header(token),
    )


def test_in_window_join_allowed(client):
    print("\n== In-window join is allowed (time_start in past, time_end in future) ==")
    uid, tok = signup(client, f"jw_inwin_{uuid.uuid4().hex[:8]}")
    gid = devo_id = None
    try:
        gid = create_group(client, tok, uid, [])
        now = datetime.now(timezone.utc)
        devo_id = create_session(
            client, tok, uid, gid,
            time_start=iso(now - timedelta(minutes=5)),
            time_end=iso(now + timedelta(hours=1)),
        )
        r = join_devotion(client, tok, devo_id, uid)
        check("in-window join -> 200", r.status_code == 200, str(r.status_code) + " " + r.text)
    finally:
        cleanup(uid, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def test_before_window_join_denied(client):
    print("\n== Before-window join (time_start well in the future) is denied ==")
    uid, tok = signup(client, f"jw_early_{uuid.uuid4().hex[:8]}")
    gid = devo_id = None
    try:
        gid = create_group(client, tok, uid, [])
        now = datetime.now(timezone.utc)
        devo_id = create_session(
            client, tok, uid, gid,
            time_start=iso(now + timedelta(hours=2)),
            time_end=iso(now + timedelta(hours=3)),
        )
        r = join_devotion(client, tok, devo_id, uid)
        check("far-future time_start join -> 403", r.status_code == 403, str(r.status_code) + " " + r.text)
        check("403 detail is the documented not-open-yet message",
              r.status_code == 403 and r.json().get("detail") == _NOT_OPEN_DETAIL, r.text)
    finally:
        cleanup(uid, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def test_grace_period_early_join_allowed(client):
    print("\n== Early join inside SESSION_JOIN_GRACE_MINUTES is allowed ==")
    uid, tok = signup(client, f"jw_grace_{uuid.uuid4().hex[:8]}")
    gid = devo_id = None
    try:
        gid = create_group(client, tok, uid, [])
        now = datetime.now(timezone.utc)
        # SESSION_JOIN_GRACE_MINUTES is deployed as 10 in this dev env's
        # .env; 5 minutes early is comfortably inside that grace window
        # without the test being coupled to the exact configured value.
        devo_id = create_session(
            client, tok, uid, gid,
            time_start=iso(now + timedelta(minutes=5)),
            time_end=iso(now + timedelta(hours=1)),
        )
        r = join_devotion(client, tok, devo_id, uid)
        check("join 5 minutes before time_start -> 200 (within grace)",
              r.status_code == 200, str(r.status_code) + " " + r.text)
    finally:
        cleanup(uid, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def test_after_window_join_denied(client):
    print("\n== After-window join (time_end in the past) is denied ==")
    uid, tok = signup(client, f"jw_late_{uuid.uuid4().hex[:8]}")
    gid = devo_id = None
    try:
        gid = create_group(client, tok, uid, [])
        now = datetime.now(timezone.utc)
        devo_id = create_session(
            client, tok, uid, gid,
            time_start=iso(now - timedelta(hours=2)),
            time_end=iso(now - timedelta(hours=1)),
        )
        r = join_devotion(client, tok, devo_id, uid)
        check("past time_end join -> 403", r.status_code == 403, str(r.status_code) + " " + r.text)
        check("403 detail is the documented not-open message",
              r.status_code == 403 and r.json().get("detail") == _NOT_OPEN_DETAIL, r.text)
    finally:
        cleanup(uid, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def test_missing_time_start_fails_closed(client):
    print("\n== Missing time_start fails closed (never treated as always-open) ==")
    uid, tok = signup(client, f"jw_notime_{uuid.uuid4().hex[:8]}")
    gid = devo_id = None
    try:
        gid = create_group(client, tok, uid, [])
        # Neither time_start nor time_end supplied -- DevotionPlan defaults
        # both to "", exactly the malformed/legacy-data shape the contract's
        # missing-time_start branch exists for.
        devo_id = create_session(client, tok, uid, gid)
        r = join_devotion(client, tok, devo_id, uid)
        check("missing time_start join -> 403 (fail closed, not fail open)",
              r.status_code == 403, str(r.status_code) + " " + r.text)
        check("403 detail is the documented not-open message",
              r.status_code == 403 and r.json().get("detail") == _NOT_OPEN_DETAIL, r.text)
    finally:
        cleanup(uid, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def test_open_ended_time_end_allowed(client):
    print("\n== Missing/empty time_end is open-ended once time_start has passed ==")
    uid, tok = signup(client, f"jw_openend_{uuid.uuid4().hex[:8]}")
    gid = devo_id = None
    try:
        gid = create_group(client, tok, uid, [])
        now = datetime.now(timezone.utc)
        # time_start resolved and already past; time_end omitted entirely.
        devo_id = create_session(
            client, tok, uid, gid,
            time_start=iso(now - timedelta(hours=3)),
        )
        r = join_devotion(client, tok, devo_id, uid)
        check("started session with no time_end -> 200 (open-ended, no synthesized duration)",
              r.status_code == 200, str(r.status_code) + " " + r.text)
    finally:
        cleanup(uid, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def test_live_call_bypass_survives_past_time_end(client):
    print("\n== Already-live-call bypass: a second authorized member can still "
          "join-call after time_end once chime_meeting_id is set ==")
    uid_creator, tok_creator = signup(client, f"jw_live_creator_{uuid.uuid4().hex[:8]}")
    uid_member, tok_member = signup(client, f"jw_live_member_{uuid.uuid4().hex[:8]}")
    gid = devo_id = None
    try:
        gid = create_group(client, tok_creator, uid_creator, [uid_member])
        now = datetime.now(timezone.utc)
        # Window is open right now so the *first* join-call (which lazily
        # creates the Chime meeting) legitimately succeeds.
        devo_id = create_session(
            client, tok_creator, uid_creator, gid,
            time_start=iso(now - timedelta(minutes=5)),
            time_end=iso(now + timedelta(minutes=5)),
        )
        r = join_call(client, tok_creator, devo_id, uid_creator)
        check("creator's first join-call opens the meeting -> 200", r.status_code == 200,
              str(r.status_code) + " " + r.text)
        check("chime_meeting_id was actually set by that call",
              bool(r.json().get("Meeting", {}).get("MeetingId")), r.text)

        # Now push time_end into the past directly (simulating time passing
        # well beyond the original window) while the call is still "live"
        # per chime_meeting_id being set.
        db = DBManager()
        try:
            db.cur.execute(
                "UPDATE devotions SET time_end = %s WHERE _id = %s",
                (now - timedelta(hours=1), devo_id),
            )
            db.conn.commit()
        finally:
            db.close()

        r = join_call(client, tok_member, devo_id, uid_member)
        check("different authorized member's join-call after time_end -> 200 "
              "(chime_meeting_id bypass, not blocked by the expired window)",
              r.status_code == 200, str(r.status_code) + " " + r.text)
    finally:
        cleanup(uid_creator, uid_member, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def main():
    with TestClient(main_module.app) as client:
        original_chime = devotion_module.chime
        devotion_module.chime = FakeChimeClient()
        try:
            test_in_window_join_allowed(client)
            test_before_window_join_denied(client)
            test_grace_period_early_join_allowed(client)
            test_after_window_join_denied(client)
            test_missing_time_start_fails_closed(client)
            test_open_ended_time_end_allowed(client)
            test_live_call_bypass_survives_past_time_end(client)
        finally:
            devotion_module.chime = original_chime

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        raise SystemExit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
