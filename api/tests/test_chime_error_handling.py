"""Tests for the Chime CreateMeeting/CreateAttendee ClientError leak fix
(20260827-chime-create-meeting-iam-fix, backend step 1).

Prior to the fix, a `ClientError` raised by `chime.create_meeting`/
`chime.create_attendee` (e.g. the production `AccessDeniedException` this
task was filed for) was surfaced verbatim to the iOS client via
`HTTPException(status_code=500, detail=str(e))` -- leaking the assumed-role
ARN, AWS account id, region, and IAM policy detail straight into the app's
error screen. The fix wraps every Chime call site in a `try/except
ClientError` that logs the real exception server-side and raises a shared,
generic `_CHIME_ERROR_DETAIL` ("Could not start the call. Please try again.")
instead.

Covers all four call sites named in the intake spec's acceptance criteria:
  - api/routes/messaging.py::_get_or_create_meeting (POST /chime/{session_id})
  - api/routes/messaging.py::_create_attendee (POST /chime/{session_id}/{user_id}/attend)
  - api/routes/devotion.py::join_call's create_meeting branch (POST /devotions/join-call)
  - api/routes/devotion.py::join_call's create_attendee branch (POST /devotions/join-call)

For each: simulates the real production `ClientError` (AccessDeniedException,
carrying the actual ARN/account id/region from the bug report) via a fake
Chime client swapped onto the module-level `chime` object routes.messaging
and routes.devotion each construct at import time, then asserts:
  1. The HTTP response is 500 with the generic, non-leaking detail string
     exactly -- and the raw exception text (ARN, account id, action name,
     "AccessDeniedException", "identity-based policy") is NOT present
     anywhere in the response body.
  2. The real ClientError text (session_id/user_id context + the original
     AccessDeniedException message) WAS written to the server-side log via
     `logger.error(...)`, so the failure is still diagnosable operationally
     even though the client never sees it.

Also covers the happy path (fake Chime client succeeds) for each call site as
a regression check that the try/except wrapping didn't break the normal flow.

Run with: cd api && ../.venv/bin/python tests/test_chime_error_handling.py
"""
import _pathfix  # noqa: F401

import logging
import os
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from botocore.exceptions import ClientError  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import routes.messaging as messaging_module  # noqa: E402
import routes.devotion as devotion_module  # noqa: E402
from db import DBManager  # noqa: E402

PASSED, FAILED = [], []

# The real production error text from the bug report -- if any of this leaks
# into a client-facing response, the fix has regressed.
_LEAKED_FRAGMENTS = [
    "AccessDeniedException",
    "arn:aws:sts::335651423109",
    "arn:aws:chime:us-east-1:335651423109",
    "FellowScriptCloudWatchRole",
    "not authorized to perform",
    "identity-based policy",
]


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
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    })
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            # Devotion sessions created by this test reference creator_id
            # with no ON DELETE CASCADE, so they must go before the user row.
            db.cur.execute("DELETE FROM devotions WHERE creator_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def make_access_denied_error(operation_name: str) -> ClientError:
    """Reproduces the exact production AccessDeniedException from the bug report."""
    message = (
        f"An error occurred (AccessDeniedException) when calling the {operation_name} "
        "operation: User: arn:aws:sts::335651423109:assumed-role/FellowScriptCloudWatchRole/"
        "i-055f29109661cd2d6 is not authorized to perform: chime:{op} on resource: "
        "arn:aws:chime:us-east-1:335651423109:meeting/* because no identity-based policy "
        "allows the chime:{op} action"
    ).format(op=operation_name)
    return ClientError(
        {"Error": {"Code": "AccessDeniedException", "Message": message}},
        operation_name,
    )


class FakeChimeClient:
    """Stand-in for the boto3 chime-sdk-meetings client. Each method either
    raises the configured ClientError or returns a minimal valid response
    shape, so both the error path and the (unbroken) happy path are covered
    with the same fake."""

    def __init__(self):
        self.create_meeting_error: ClientError | None = None
        self.create_attendee_error: ClientError | None = None

    def create_meeting(self, **kwargs):
        if self.create_meeting_error:
            raise self.create_meeting_error
        return {"Meeting": {
            "MeetingId": str(uuid.uuid4()),
            "ExternalMeetingId": kwargs.get("ExternalMeetingId", ""),
            "MediaRegion": "us-east-1",
            "MediaPlacement": {},
        }}

    def create_attendee(self, **kwargs):
        if self.create_attendee_error:
            raise self.create_attendee_error
        return {"Attendee": {
            "AttendeeId": str(uuid.uuid4()),
            "ExternalUserId": kwargs.get("ExternalUserId", ""),
            "JoinToken": "fake-join-token",
        }}


class _CapturingHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records: list[str] = []

    def emit(self, record):
        self.records.append(self.format(record))


def create_devotion_session(client, token, uid, participants=None):
    devo_id = str(uuid.uuid4())
    payload = {
        "devotion_id": devo_id, "user_id": uid,
        "devotion": {
            "id": devo_id, "title": "Session test", "creator_id": uid,
            "participants": participants or [], "prompts": ["p1"], "verses": [],
        },
    }
    r = client.post("/devotions/", json=payload, headers=cookie_header(token))
    assert r.status_code == 201, f"create_devotion failed: {r.status_code} {r.text}"
    return devo_id


def assert_no_leak(label: str, body: str):
    for fragment in _LEAKED_FRAGMENTS:
        check(f"{label}: response body does not leak {fragment!r}",
              fragment not in body, body[:300])


def test_messaging_start_meeting_create_meeting_error(client, token, uid, logger_name):
    print("\n== POST /chime/{session_id} (start_meeting -> _get_or_create_meeting): create_meeting ClientError ==")
    session_id = create_devotion_session(client, token, uid)

    fake = FakeChimeClient()
    fake.create_meeting_error = make_access_denied_error("CreateMeeting")
    original = messaging_module.chime
    messaging_module.chime = fake

    app_logger = logging.getLogger(logger_name)
    handler = _CapturingHandler()
    app_logger.addHandler(handler)
    prior_level = app_logger.level
    app_logger.setLevel(logging.DEBUG)
    try:
        r = client.post(f"/chime/{session_id}", headers=cookie_header(token))
        check("start_meeting with failing create_meeting -> 500 (not 200/leak-shaped 4xx)",
              r.status_code == 500, str(r.status_code) + " " + r.text)
        body = r.text
        check("response detail is exactly the generic client-safe message",
              r.json().get("detail") == "Could not start the call. Please try again.",
              str(r.json()))
        assert_no_leak("start_meeting error", body)

        joined = "\n".join(handler.records)
        check("real ClientError was logged server-side (session_id present)",
              session_id in joined, joined[:500])
        check("real ClientError's AccessDeniedException text reached the server log",
              "AccessDeniedException" in joined, joined[:500])
    finally:
        app_logger.removeHandler(handler)
        app_logger.setLevel(prior_level)
        messaging_module.chime = original


def test_messaging_start_meeting_happy_path(client, token, uid):
    print("\n== POST /chime/{session_id}: happy path regression check ==")
    session_id = create_devotion_session(client, token, uid)
    fake = FakeChimeClient()
    original = messaging_module.chime
    messaging_module.chime = fake
    try:
        r = client.post(f"/chime/{session_id}", headers=cookie_header(token))
        check("start_meeting with succeeding create_meeting -> 200",
              r.status_code == 200, str(r.status_code) + " " + r.text)
        check("response contains a real MeetingId",
              bool(r.json().get("Meeting", {}).get("MeetingId")), str(r.json()))
    finally:
        messaging_module.chime = original


def test_messaging_join_meeting_create_attendee_error(client, token, uid, logger_name):
    print("\n== POST /chime/{session_id}/{user_id}/attend (_create_attendee): create_attendee ClientError ==")
    session_id = create_devotion_session(client, token, uid)

    # First, succeed at creating the meeting so chime_meeting_id is set
    # (join_meeting 400s with "No active meeting" otherwise, unrelated to
    # this fix).
    fake = FakeChimeClient()
    original = messaging_module.chime
    messaging_module.chime = fake
    try:
        r = client.post(f"/chime/{session_id}", headers=cookie_header(token))
        assert r.status_code == 200, f"setup create_meeting failed: {r.status_code} {r.text}"

        fake.create_attendee_error = make_access_denied_error("CreateAttendee")
        app_logger = logging.getLogger("routes.messaging")
        handler = _CapturingHandler()
        app_logger.addHandler(handler)
        prior_level = app_logger.level
        app_logger.setLevel(logging.DEBUG)
        try:
            r = client.post(f"/chime/{session_id}/{uid}/attend", headers=cookie_header(token))
            check("join_meeting with failing create_attendee -> 500",
                  r.status_code == 500, str(r.status_code) + " " + r.text)
            check("response detail is exactly the generic client-safe message",
                  r.json().get("detail") == "Could not start the call. Please try again.",
                  str(r.json()))
            assert_no_leak("join_meeting error", r.text)

            joined = "\n".join(handler.records)
            check("real ClientError was logged server-side (uid present)",
                  uid in joined, joined[:500])
            check("real ClientError's AccessDeniedException text reached the server log",
                  "AccessDeniedException" in joined, joined[:500])
        finally:
            app_logger.removeHandler(handler)
            app_logger.setLevel(prior_level)
    finally:
        messaging_module.chime = original


def test_devotion_join_call_create_meeting_error(client, token, uid):
    print("\n== POST /devotions/join-call: create_meeting branch ClientError ==")
    session_id = create_devotion_session(client, token, uid, participants=[uid])

    fake = FakeChimeClient()
    fake.create_meeting_error = make_access_denied_error("CreateMeeting")
    original = devotion_module.chime
    devotion_module.chime = fake

    app_logger = logging.getLogger("routes.devotion")
    handler = _CapturingHandler()
    app_logger.addHandler(handler)
    prior_level = app_logger.level
    app_logger.setLevel(logging.DEBUG)
    try:
        r = client.post("/devotions/join-call",
                         params={"session_id": session_id, "user_id": uid},
                         headers=cookie_header(token))
        check("join_call with failing create_meeting -> 500",
              r.status_code == 500, str(r.status_code) + " " + r.text)
        check("response detail is exactly the generic client-safe message",
              r.json().get("detail") == "Could not start the call. Please try again.",
              str(r.json()))
        assert_no_leak("devotion join_call create_meeting error", r.text)

        joined = "\n".join(handler.records)
        check("real ClientError was logged server-side (session_id present)",
              session_id in joined, joined[:500])
        check("real ClientError's AccessDeniedException text reached the server log",
              "AccessDeniedException" in joined, joined[:500])
    finally:
        app_logger.removeHandler(handler)
        app_logger.setLevel(prior_level)
        devotion_module.chime = original


def test_devotion_join_call_create_attendee_error(client, token, uid):
    print("\n== POST /devotions/join-call: create_attendee branch ClientError (meeting already exists) ==")
    session_id = create_devotion_session(client, token, uid, participants=[uid])

    fake = FakeChimeClient()
    original = devotion_module.chime
    devotion_module.chime = fake
    try:
        # First call succeeds fully, creating the meeting + attendee so a
        # second join-call takes the "meeting already exists" branch and
        # only exercises create_attendee.
        r = client.post("/devotions/join-call",
                         params={"session_id": session_id, "user_id": uid},
                         headers=cookie_header(token))
        assert r.status_code == 200, f"setup join_call failed: {r.status_code} {r.text}"

        fake.create_attendee_error = make_access_denied_error("CreateAttendee")
        app_logger = logging.getLogger("routes.devotion")
        handler = _CapturingHandler()
        app_logger.addHandler(handler)
        prior_level = app_logger.level
        app_logger.setLevel(logging.DEBUG)
        try:
            r = client.post("/devotions/join-call",
                             params={"session_id": session_id, "user_id": uid},
                             headers=cookie_header(token))
            check("join_call with failing create_attendee -> 500",
                  r.status_code == 500, str(r.status_code) + " " + r.text)
            check("response detail is exactly the generic client-safe message",
                  r.json().get("detail") == "Could not start the call. Please try again.",
                  str(r.json()))
            assert_no_leak("devotion join_call create_attendee error", r.text)

            joined = "\n".join(handler.records)
            check("real ClientError was logged server-side (session_id and user present)",
                  session_id in joined and uid in joined, joined[:500])
            check("real ClientError's AccessDeniedException text reached the server log",
                  "AccessDeniedException" in joined, joined[:500])
        finally:
            app_logger.removeHandler(handler)
            app_logger.setLevel(prior_level)
    finally:
        devotion_module.chime = original


def test_devotion_join_call_happy_path(client, token, uid):
    print("\n== POST /devotions/join-call: happy path regression check ==")
    session_id = create_devotion_session(client, token, uid, participants=[uid])
    fake = FakeChimeClient()
    original = devotion_module.chime
    devotion_module.chime = fake
    try:
        r = client.post("/devotions/join-call",
                         params={"session_id": session_id, "user_id": uid},
                         headers=cookie_header(token))
        check("join_call with succeeding chime calls -> 200",
              r.status_code == 200, str(r.status_code) + " " + r.text)
        body = r.json()
        check("response contains a real MeetingId and AttendeeId",
              bool(body.get("Meeting", {}).get("MeetingId")) and bool(body.get("Attendee", {}).get("AttendeeId")),
              str(body))
    finally:
        devotion_module.chime = original


def main():
    uid = None
    with TestClient(main_module.app) as client:
        try:
            uid, token = signup(client, f"chime_err_test_{uuid.uuid4().hex[:8]}")

            test_messaging_start_meeting_create_meeting_error(client, token, uid, "routes.messaging")
            test_messaging_start_meeting_happy_path(client, token, uid)
            test_messaging_join_meeting_create_attendee_error(client, token, uid, "routes.messaging")
            test_devotion_join_call_create_meeting_error(client, token, uid)
            test_devotion_join_call_create_attendee_error(client, token, uid)
            test_devotion_join_call_happy_path(client, token, uid)
        finally:
            if uid:
                cleanup(uid)

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        import sys
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
