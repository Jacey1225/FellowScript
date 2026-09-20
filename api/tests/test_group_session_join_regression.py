"""Regression coverage for task 20260916-group-session-join-failure.

Bug: a non-creator member of a group could not join a Chime call attached to
a session created inside that group -- the iOS client surfaced a generic
"cannot join the session" error. Backend step 1's live reproduction (real
Postgres, real signup+group+devotion rows) confirmed:

  1. `DevotionManager.is_authorized`'s happy-path group-membership lookup
     (api/backend/interactions/devotion.py) is correct for a well-formed
     group_id -- a genuine non-creator group member IS granted access. This
     had no prior dedicated regression test (codegraph flags zero covering
     tests for `is_authorized`/`get_session`), so a future change could
     silently reintroduce a membership-lookup regression with nothing to
     catch it.
  2. The concrete failure mode matching the reported symptom: a
     syntactically-invalid `group_id` (not valid `uuid` text -- the column
     has no format constraint and is free-form client-supplied text all the
     way from iOS) made Postgres raise `invalid input syntax for type uuid`
     inside `is_authorized`'s `try` block. This was being caught by a bare
     `except Exception` and logged at `warning` level, indistinguishable
     from an ordinary "not a member" denial -- which is why static review
     alone couldn't isolate the root cause. The landed fix (commit
     1d567bf9) upgrades this to `logger.exception` at ERROR severity while
     leaving the fail-closed `return False` completely unchanged (Q14).

This file proves:
  - A genuine non-creator group member CAN join a session/call created by
    someone else in their group (the actual bug -- must now pass).
  - The session creator's own join is unaffected (regression guard).
  - A real outsider (not creator, not participant, not in the group) is
    still correctly denied (the fix must not weaken authorization).
  - A malformed group_id still 403s (fail-closed preserved) AND now emits an
    ERROR-level log record with a traceback -- not the old warning-level,
    traceback-free line -- locking in the diagnosability fix per backend's
    recommendation so a regression to the old silent-warning behavior would
    be caught here.

Run with: cd api && ../.venv/bin/python tests/test_group_session_join_regression.py
"""
import _pathfix  # noqa: F401

import logging
import os
import uuid
from datetime import datetime, timedelta, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
# Real S3/GIF config may not be present in every dev environment; a
# placeholder is sufficient since this file never exercises either
# subsystem -- it only needs main.app's lifespan config validation to pass
# so the real HTTP routes can boot (see test_devotion_summarize_roundtrip.py
# for the same precedent). Must be set before importing main/_fake_timeline.
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import routes.devotion as devotion_module  # noqa: E402
from db import DBManager  # noqa: E402

PASSED, FAILED = [], []


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
    """Minimal stand-in for the boto3 chime-sdk-meetings client -- always
    succeeds, so these tests exercise only the authorization branch of
    join_call, not real AWS calls (see test_chime_error_handling.py for the
    ClientError-path coverage of this same fake pattern)."""

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


class _CapturingHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records: list[logging.LogRecord] = []

    def emit(self, record):
        self.records.append(record)

    def formatted(self):
        return "\n".join(self.format(r) for r in self.records)


def create_group(client, token, owner_uid, member_uids):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner_uid}", json={
        "group_id": gid, "title": "Regression group", "users": [owner_uid, *member_uids],
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def create_group_session(client, token, creator_uid, group_id):
    """A session created inside a group -- creator is NOT added as an
    explicit participant, matching the real flow: joining is meant to be
    granted purely via group membership (is_authorized's group_id branch),
    not because the joiner happens to already be listed as a participant.

    Task 20260920-session-join-window-gating (testing step 4, fixing the
    fixture gap testing itself flagged in its prior bounce): gives the
    session a real, currently-in-window time_start/time_end so
    is_join_window_open's new fail-closed-on-missing-time_start rule
    doesn't deny these otherwise-legitimate group-membership joins. Window
    is centered on "now" with generous slack on both sides (well within
    SESSION_JOIN_GRACE_MINUTES on the early side, and not expiring mid-test
    on the late side) rather than any exact boundary value -- this fixture
    is regression coverage for group-membership authorization, not for the
    join-window boundary itself (see the dedicated boundary tests below)."""
    devo_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    time_start = (now - timedelta(minutes=1)).isoformat()
    time_end = (now + timedelta(hours=1)).isoformat()
    payload = {
        "devotion_id": devo_id, "user_id": creator_uid,
        "devotion": {
            "id": devo_id, "title": "Group session", "creator_id": creator_uid,
            "participants": [], "group_id": group_id, "prompts": ["p1"], "verses": [],
            "time_start": time_start, "time_end": time_end,
        },
    }
    r = client.post("/devotions/", json=payload, headers=cookie_header(token))
    assert r.status_code == 201, f"create_devotion failed: {r.status_code} {r.text}"
    return devo_id


def join_call(client, token, session_id, user_id):
    return client.post(
        "/devotions/join-call",
        params={"session_id": session_id, "user_id": user_id},
        headers=cookie_header(token),
    )


def test_non_creator_group_member_can_join_session(client, chime_fake):
    print("\n== Regression: non-creator group member CAN join a session created by someone else in the group ==")
    uid_creator, tok_creator = signup(client, f"gj_creator_{uuid.uuid4().hex[:8]}")
    uid_member, tok_member = signup(client, f"gj_member_{uuid.uuid4().hex[:8]}")
    gid = None
    devo_id = None
    try:
        gid = create_group(client, tok_creator, uid_creator, [uid_member])
        devo_id = create_group_session(client, tok_creator, uid_creator, gid)

        # The actual bug: a genuine non-creator group member joins a session
        # they didn't create.
        r = join_call(client, tok_member, devo_id, uid_member)
        check("non-creator group member join-call -> 200 (not 403)",
              r.status_code == 200, str(r.status_code) + " " + r.text)
        body = r.json() if r.status_code == 200 else {}
        check("response contains a real MeetingId and AttendeeId",
              bool(body.get("Meeting", {}).get("MeetingId")) and bool(body.get("Attendee", {}).get("AttendeeId")),
              str(body))

        # Creator's own join/start continues to work unchanged.
        r = join_call(client, tok_creator, devo_id, uid_creator)
        check("creator's own join-call still -> 200 (unaffected by the fix)",
              r.status_code == 200, str(r.status_code) + " " + r.text)
    finally:
        cleanup(uid_creator, uid_member, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def test_genuine_outsider_still_denied(client, chime_fake):
    print("\n== Regression guard: a real non-member is still correctly denied ==")
    uid_creator, tok_creator = signup(client, f"gj_owner2_{uuid.uuid4().hex[:8]}")
    uid_outsider, tok_outsider = signup(client, f"gj_outsider_{uuid.uuid4().hex[:8]}")
    gid = None
    devo_id = None
    try:
        gid = create_group(client, tok_creator, uid_creator, [])
        devo_id = create_group_session(client, tok_creator, uid_creator, gid)

        r = join_call(client, tok_outsider, devo_id, uid_outsider)
        check("non-member join-call -> 403 (fix must not weaken authorization)",
              r.status_code == 403, str(r.status_code) + " " + r.text)
    finally:
        cleanup(uid_creator, uid_outsider, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def test_malformed_group_id_fails_closed_and_logs_error(client, chime_fake):
    print("\n== Diagnosability regression: malformed group_id still 403s, but now logs ERROR with traceback ==")
    uid, tok = signup(client, f"gj_malformed_{uuid.uuid4().hex[:8]}")
    uid_other, _tok_other = signup(client, f"gj_malformed_other_{uuid.uuid4().hex[:8]}")
    devo_id = str(uuid.uuid4())
    try:
        # Directly insert a devotion with a syntactically-invalid (non-uuid)
        # group_id -- the column is free-form text with no format
        # constraint, so this is reachable from real client-supplied data,
        # not just a contrived test value.
        db = DBManager()
        try:
            db.cur.execute(
                "INSERT INTO devotions (_id, title, creator_id, participants, group_id, verses, prompts) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s)",
                (devo_id, "Malformed group_id session", uid, [], "not-a-valid-uuid", [], []),
            )
            db.conn.commit()
        finally:
            db.close()

        app_logger = logging.getLogger("backend.interactions.devotion")
        handler = _CapturingHandler()
        app_logger.addHandler(handler)
        prior_level = app_logger.level
        app_logger.setLevel(logging.DEBUG)
        prior_propagate = app_logger.propagate
        try:
            # A different user (not creator/participant) hits the group
            # lookup branch and triggers the uuid-cast error.
            r = join_call(client, _tok_other, devo_id, uid_other)
            check("malformed group_id join-call -> 403 (fail-closed, Q14 preserved)",
                  r.status_code == 403, str(r.status_code) + " " + r.text)

            check("at least one log record was captured at ERROR level or higher",
                  any(rec.levelno >= logging.ERROR for rec in handler.records),
                  f"levels seen: {[rec.levelname for rec in handler.records]}")
            error_records = [rec for rec in handler.records if rec.levelno >= logging.ERROR]
            has_traceback = any(rec.exc_info for rec in error_records)
            check("the ERROR record carries exception/traceback info (logger.exception, not logger.warning)",
                  has_traceback, f"exc_info present per record: {[bool(rec.exc_info) for rec in error_records]}")

            joined = handler.formatted()
            check("log message distinguishes an unresolved error from a confirmed non-membership result",
                  "could not be resolved" in joined.lower() or "not a confirmed" in joined.lower()
                  or "errored" in joined.lower(),
                  joined[:500])
        finally:
            app_logger.removeHandler(handler)
            app_logger.setLevel(prior_level)
            app_logger.propagate = prior_propagate
    finally:
        cleanup(uid, uid_other, devotion_ids=[devo_id])


def main():
    with TestClient(main_module.app) as client:
        original_chime = devotion_module.chime
        devotion_module.chime = FakeChimeClient()
        try:
            test_non_creator_group_member_can_join_session(client, devotion_module.chime)
            test_genuine_outsider_still_denied(client, devotion_module.chime)
            test_malformed_group_id_fails_closed_and_logs_error(client, devotion_module.chime)
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
