"""Tests for task 20260921-session-auto-delete-window:

backend step 1 added a new apscheduler job `_auto_delete_expired_sessions`
(api/backend/interactions/scheduler.py) that deletes a non-recurring session
once its `time_end` is more than `SESSION_AUTO_DELETE_GRACE_SECONDS` (1 hour)
in the past, but only once a fail-closed Chime-presence gate
(`_session_auto_delete_confirmed_call_empty`) confirms the call is not still
occupied. security step 2 fixed a TOCTOU race between that presence check and
the delete by re-verifying every candidate condition -- including
`chime_meeting_id` -- atomically inside `_delete_session_if_still_candidate`.

This proves, against the REAL job functions and a REAL Postgres DB (never a
mocked manager), the specific behaviors this task's acceptance criteria call
out:

  1. A non-recurring session whose call never started (`chime_meeting_id`
     empty) is deleted once past the 1-hour grace period -- no AWS call
     needed since there's no call to still be in.
  2. A non-recurring session still within its 1-hour grace period is never
     deleted (grace-period boundary, "not yet" side).
  3. A recurring session past its grace period is never deleted by this job,
     regardless of `time_end`.
  4. A session with a missing/NULL `time_end` is never a candidate at all --
     not silently deleted, not silently guessed at from `time_start`.
  5. A session whose call is still live (Chime confirms the meeting still
     exists) is NOT deleted -- deletion is deferred, re-checked next cycle.
  6. A session whose call is confirmed torn down (Chime raises
     `NotFoundException` on `get_meeting`) IS deleted.
  7. The specific "in-call delay-then-eventual-delete" acceptance criterion:
     the SAME session is deferred on one poll cycle (call still live) and
     then actually deleted on a later cycle once the call is confirmed gone.
  8. Any Chime error OTHER than `NotFoundException` (e.g. an unrelated
     `AccessDeniedException`) fails closed -- treated as "might still be in
     call," deferred, not deleted.
  9. A Chime call that raises a generic/timeout-shaped exception also fails
     closed the same way -- the presence check has no path that proceeds to
     delete on an ambiguous outcome.
  10. Race-safety (Security Posture Q3 / the security gate's own TOCTOU fix):
      a user who (re)joins/recreates the call in the exact window between
      this job's presence check and its delete (giving the row a NEW,
      different `chime_meeting_id`) is never deleted out from under them --
      `_delete_session_if_still_candidate`'s atomic re-verification catches
      the changed `chime_meeting_id` and the session survives.
  11. Every actual deletion is logged with its cause (Security Posture Q11).
  12. Every deferral (call still live) is logged with its cause.
  13. Every race-prevented skip (state changed since check) is logged with
      its cause, distinct from an ordinary deferral.
  14. Root-cause regression (task 20260923-session-opening-window-auto-
      delete): a candidate whose `chime_meeting_id` column is a genuine SQL
      NULL (not `''`) -- e.g. a pre-existing/migrated row -- is deleted like
      any other never-started session, not perpetually re-scanned and
      "skipped: state changed" every cycle forever. Before this fix,
      `_delete_session_if_still_candidate`'s atomic re-check compared the
      real column value against the `_scan_candidates`-normalized `""` with
      a plain `=`, and SQL's `NULL = ''` is never TRUE.
  15. Pre-deployment smoke test: the real app (main.app) boots with
      `session_auto_delete` registered on the scheduler.

The fake Chime client used throughout defaults to "meeting still exists" for
ANY MeetingId it wasn't explicitly told about -- this job does a full-table
scan of `devotions` (not scoped to this file's own fixtures, same shape as
`_fire_due_heartbeats`/`_fire_due_session_reminders`'s own full-table scans
elsewhere in this suite), so an unrecognized id defaults to the SAFE outcome
(deferred, not deleted) rather than ever letting this fake cause an unrelated
real session in a shared dev DB to be destructively deleted.

Run:  cd api && ../.venv/bin/python tests/test_session_auto_delete_window.py
"""
import _pathfix  # noqa: F401,E402

import asyncio
import logging
import uuid
from datetime import datetime, timedelta, timezone as tzmod

import os

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

import boto3  # noqa: E402
from botocore.exceptions import ClientError  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
import backend.interactions.scheduler as scheduler_module  # noqa: E402

PASSED, FAILED = [], []

GRACE = scheduler_module.SESSION_AUTO_DELETE_GRACE_SECONDS


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── Fixtures ─────────────────────────────────────────────────────────────────

def make_user(prefix: str) -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {
            "_id": uid, "username": f"{prefix}_{uid[:8]}",
            "email": f"{prefix}_{uid[:8]}@example.com", "hash_pass": "x",
        })
    finally:
        db.close()
    return uid


def make_session_direct(
    creator_id: str, *, time_end: datetime | None, recurring: bool = False,
    chime_meeting_id: str = "", title: str = "Auto-delete session",
) -> str:
    """Insert a devotions row directly (bypassing the route/schema layer),
    same technique as test_session_push_notifications.py's
    `make_session_direct` -- this job only cares about DB state
    (recurring/time_end/chime_meeting_id), not the route."""
    session_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO devotions (_id, title, time_start, time_end, recurring, "
            "group_id, creator_id, participants, verses, prompts, chime_meeting_id) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
            (session_id, title, time_end, time_end, recurring,
             None, creator_id, [], [], [], chime_meeting_id),
        )
        db.conn.commit()
    finally:
        db.close()
    return session_id


def session_exists(session_id: str) -> bool:
    db = DBManager()
    try:
        db.cur.execute("SELECT 1 FROM devotions WHERE _id = %s", (session_id,))
        return db.cur.fetchone() is not None
    finally:
        db.close()


def get_chime_meeting_id(session_id: str) -> str:
    db = DBManager()
    try:
        db.cur.execute("SELECT chime_meeting_id FROM devotions WHERE _id = %s", (session_id,))
        row = db.cur.fetchone()
        return (row[0] if row else "") or ""
    finally:
        db.close()


def set_chime_meeting_id(session_id: str, chime_meeting_id: str) -> None:
    db = DBManager()
    try:
        db.cur.execute(
            "UPDATE devotions SET chime_meeting_id = %s WHERE _id = %s",
            (chime_meeting_id, session_id),
        )
        db.conn.commit()
    finally:
        db.close()


def cleanup(*user_ids, session_ids=()):
    db = DBManager()
    try:
        for sid in session_ids:
            db.cur.execute("DELETE FROM devotions WHERE _id = %s", (sid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM devotions WHERE creator_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def make_not_found_error(operation_name: str = "GetMeeting") -> ClientError:
    """Same shape as test_chime_error_handling.py's
    `make_meeting_not_found_error` -- the exact AWS error Chime's
    chime-sdk-meetings service model documents for a torn-down/nonexistent
    MeetingId."""
    message = (
        f"An error occurred (NotFoundException) when calling the {operation_name} "
        "operation: One or more of the resources in the request does not exist "
        "in the system."
    )
    return ClientError({"Error": {"Code": "NotFoundException", "Message": message}}, operation_name)


def make_access_denied_error(operation_name: str = "GetMeeting") -> ClientError:
    message = (
        f"An error occurred (AccessDeniedException) when calling the {operation_name} "
        "operation: User is not authorized to perform this action."
    )
    return ClientError({"Error": {"Code": "AccessDeniedException", "Message": message}}, operation_name)


class FakeChimeClient:
    """Stand-in for the boto3 chime-sdk-meetings client's `get_meeting`.
    Any MeetingId not explicitly registered via `set_response`/
    `set_side_effect` defaults to "meeting still exists" (success, no
    error) -- the safe, non-destructive default. `_auto_delete_expired_
    sessions` does a full-table scan, so this default matters: it keeps
    this fake from ever being able to cause an unrelated real devotions row
    (in a shared dev DB) to be destructively deleted just because it
    happened to also be a candidate on the same poll cycle this test drives.
    """

    def __init__(self):
        self._responses: dict[str, Exception | None] = {}
        self._side_effects: dict[str, callable] = {}
        self.get_meeting_calls: list[str] = []

    def set_response(self, meeting_id: str, error: Exception | None) -> None:
        self._responses[meeting_id] = error

    def set_side_effect(self, meeting_id: str, fn) -> None:
        self._side_effects[meeting_id] = fn

    def get_meeting(self, MeetingId=None, **kwargs):
        self.get_meeting_calls.append(MeetingId)
        if MeetingId in self._side_effects:
            self._side_effects[MeetingId](MeetingId)
        if MeetingId in self._responses:
            error = self._responses[MeetingId]
            if error is not None:
                raise error
            return {"Meeting": {"MeetingId": MeetingId}}
        return {"Meeting": {"MeetingId": MeetingId}}  # safe default: "still exists"


class _CapturingLogHandler(logging.Handler):
    """Same technique as test_heartbeat_backend_scheduling.py /
    test_session_push_notifications.py -- a real logging.Handler attached to
    the module logger, not a mock."""

    def __init__(self):
        super().__init__()
        self.records: list[str] = []

    def emit(self, record):
        self.records.append(self.format(record))


_real_boto3_client = boto3.client
_fake_chime = FakeChimeClient()


def _fake_boto3_client(service_name, *args, **kwargs):
    if service_name == "chime-sdk-meetings":
        return _fake_chime
    return _real_boto3_client(service_name, *args, **kwargs)


def install_fake_chime() -> None:
    boto3.client = _fake_boto3_client


def restore_boto3_client() -> None:
    boto3.client = _real_boto3_client


async def run_job() -> None:
    await scheduler_module._auto_delete_expired_sessions()


def capture_scheduler_logs():
    handler = _CapturingLogHandler()
    scheduler_logger = logging.getLogger("backend.interactions.scheduler")
    scheduler_logger.addHandler(handler)
    prior_level = scheduler_logger.level
    scheduler_logger.setLevel(logging.DEBUG)
    return handler, scheduler_logger, prior_level


def release_scheduler_logs(handler, scheduler_logger, prior_level):
    scheduler_logger.removeHandler(handler)
    scheduler_logger.setLevel(prior_level)


# ── 1. No call ever started -> deleted once past grace period ──────────────

def test_no_call_ever_started_deletes_after_grace_period():
    print("=== 1. Non-recurring session, no call ever started, past the 1-hour grace period -> deleted ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("adnoctall")
    sid = make_session_direct(
        uid, time_end=now - timedelta(seconds=GRACE + 300), chime_meeting_id="",
    )
    handler, slog, prior = capture_scheduler_logs()
    try:
        asyncio.run(run_job())
        check("session with no chime_meeting_id, past grace, is deleted",
              not session_exists(sid), f"sid={sid}")
        fired = [r for r in handler.records if "Session auto-deleted" in r and sid in r]
        check("a 'Session auto-deleted' log line was emitted naming this session",
              len(fired) == 1, str(handler.records))
        check("the log line's reason reflects no call ever started",
              fired and "no_call_ever_started" in fired[0], str(fired))
    finally:
        release_scheduler_logs(handler, slog, prior)
        cleanup(uid, session_ids=[sid])


# ── 2. Still within the grace period -> not deleted ─────────────────────────

def test_within_grace_period_is_not_deleted():
    print("\n=== 2. Session whose time_end is within the 1-hour grace period -> never deleted ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("adwithingrace")
    sid = make_session_direct(
        uid, time_end=now - timedelta(seconds=GRACE - 300), chime_meeting_id="",
    )
    try:
        asyncio.run(run_job())
        check("session still within its grace period survives the job",
              session_exists(sid), f"sid={sid}")
    finally:
        cleanup(uid, session_ids=[sid])


# ── 3. Recurring session excluded regardless of time_end ───────────────────

def test_recurring_session_excluded_regardless_of_time_end():
    print("\n=== 3. Recurring session, way past time_end -> never a candidate, never deleted ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("adrecurring")
    sid = make_session_direct(
        uid, time_end=now - timedelta(seconds=GRACE * 24), recurring=True, chime_meeting_id="",
    )
    try:
        asyncio.run(run_job())
        check("recurring session survives the job even far past time_end",
              session_exists(sid), f"sid={sid}")
    finally:
        cleanup(uid, session_ids=[sid])


# ── 4. Missing/NULL time_end is never a candidate ───────────────────────────

def test_missing_time_end_never_a_candidate():
    print("\n=== 4. Session with NULL time_end -> never a candidate, never silently deleted ===")
    uid = make_user("adnotime")
    sid = make_session_direct(uid, time_end=None, chime_meeting_id="")
    try:
        asyncio.run(run_job())
        check("session with NULL time_end survives the job (not guessed at, not deleted)",
              session_exists(sid), f"sid={sid}")
    finally:
        cleanup(uid, session_ids=[sid])


# ── 5. Call still live -> deferred, not deleted ─────────────────────────────

def test_call_still_present_defers_deletion():
    print("\n=== 5. Chime confirms the meeting still exists -> deletion deferred, not deleted ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("adstilllive")
    meeting_id = f"meeting-{uuid.uuid4()}"
    sid = make_session_direct(
        uid, time_end=now - timedelta(seconds=GRACE + 300), chime_meeting_id=meeting_id,
    )
    _fake_chime.set_response(meeting_id, None)  # "still exists"
    handler, slog, prior = capture_scheduler_logs()
    install_fake_chime()
    try:
        asyncio.run(run_job())
        check("session whose call is still live is NOT deleted",
              session_exists(sid), f"sid={sid}")
        check("Chime's get_meeting was actually called for this session's meeting",
              meeting_id in _fake_chime.get_meeting_calls, str(_fake_chime.get_meeting_calls))
        deferred = [r for r in handler.records if "deferred" in r and sid in r]
        check("a deferred log line was emitted naming this session",
              len(deferred) == 1, str(handler.records))
    finally:
        restore_boto3_client()
        release_scheduler_logs(handler, slog, prior)
        cleanup(uid, session_ids=[sid])


# ── 6. Call confirmed torn down (NotFoundException) -> deleted ─────────────

def test_call_confirmed_empty_via_not_found_deletes():
    print("\n=== 6. Chime raises NotFoundException (meeting already reaped) -> deleted ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("adconfirmedempty")
    meeting_id = f"meeting-{uuid.uuid4()}"
    sid = make_session_direct(
        uid, time_end=now - timedelta(seconds=GRACE + 300), chime_meeting_id=meeting_id,
    )
    _fake_chime.set_response(meeting_id, make_not_found_error())
    handler, slog, prior = capture_scheduler_logs()
    install_fake_chime()
    try:
        asyncio.run(run_job())
        check("session whose call is confirmed empty (NotFoundException) IS deleted",
              not session_exists(sid), f"sid={sid}")
        fired = [r for r in handler.records if "Session auto-deleted" in r and sid in r]
        check("a 'Session auto-deleted' log line was emitted naming this session",
              len(fired) == 1, str(handler.records))
        check("the log line's reason reflects the call was confirmed empty",
              fired and "call_confirmed_empty" in fired[0], str(fired))
    finally:
        restore_boto3_client()
        release_scheduler_logs(handler, slog, prior)
        cleanup(uid, session_ids=[sid])


# ── 7. Deferred on one cycle, then actually deleted on a later cycle ───────

def test_deferred_then_eventually_deleted_across_poll_cycles():
    print("\n=== 7. Same session: deferred while call is live, then deleted once call ends ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("addelayed")
    meeting_id = f"meeting-{uuid.uuid4()}"
    sid = make_session_direct(
        uid, time_end=now - timedelta(seconds=GRACE + 300), chime_meeting_id=meeting_id,
    )
    _fake_chime.set_response(meeting_id, None)  # cycle 1: still live
    install_fake_chime()
    try:
        asyncio.run(run_job())
        check("cycle 1 (call still live): session NOT deleted",
              session_exists(sid), f"sid={sid}")

        _fake_chime.set_response(meeting_id, make_not_found_error())  # cycle 2: torn down
        asyncio.run(run_job())
        check("cycle 2 (call confirmed torn down): session IS deleted",
              not session_exists(sid), f"sid={sid}")
    finally:
        restore_boto3_client()
        cleanup(uid, session_ids=[sid])


# ── 8. Non-NotFound Chime error fails closed -> deferred ───────────────────

def test_ambiguous_chime_error_fails_closed_deferred():
    print("\n=== 8. A different Chime ClientError (e.g. AccessDeniedException) fails closed -> deferred ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("adambiguous")
    meeting_id = f"meeting-{uuid.uuid4()}"
    sid = make_session_direct(
        uid, time_end=now - timedelta(seconds=GRACE + 300), chime_meeting_id=meeting_id,
    )
    _fake_chime.set_response(meeting_id, make_access_denied_error())
    install_fake_chime()
    try:
        asyncio.run(run_job())
        check("a non-NotFound ClientError is NOT treated as confirmed-empty -- session survives",
              session_exists(sid), f"sid={sid}")
    finally:
        restore_boto3_client()
        cleanup(uid, session_ids=[sid])


# ── 9. Generic/timeout-shaped exception also fails closed -> deferred ──────

def test_chime_timeout_generic_exception_fails_closed_deferred():
    print("\n=== 9. A generic/timeout exception from Chime also fails closed -> deferred ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("adtimeout")
    meeting_id = f"meeting-{uuid.uuid4()}"
    sid = make_session_direct(
        uid, time_end=now - timedelta(seconds=GRACE + 300), chime_meeting_id=meeting_id,
    )
    _fake_chime.set_response(meeting_id, TimeoutError("simulated network timeout"))
    install_fake_chime()
    try:
        asyncio.run(run_job())
        check("a generic/timeout exception is NOT treated as confirmed-empty -- session survives",
              session_exists(sid), f"sid={sid}")
    finally:
        restore_boto3_client()
        cleanup(uid, session_ids=[sid])


# ── 10. Race safety: concurrent rejoin between check and delete ────────────

def test_concurrent_rejoin_race_prevents_deletion():
    print("\n=== 10. TOCTOU race: a concurrent rejoin between the presence check and the delete "
          "must NOT be deleted out from under the rejoining user ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("adrace")
    old_meeting_id = f"meeting-old-{uuid.uuid4()}"
    new_meeting_id = f"meeting-new-{uuid.uuid4()}"
    sid = make_session_direct(
        uid, time_end=now - timedelta(seconds=GRACE + 300), chime_meeting_id=old_meeting_id,
    )

    def simulate_concurrent_rejoin(_meeting_id):
        # Exactly the window Security step 2's TOCTOU fix protects: between
        # this job's presence check (about to confirm the OLD meeting is
        # torn down) and its delete, a concurrent join-call/attend request
        # recreates the meeting, giving the row a brand-new chime_meeting_id.
        set_chime_meeting_id(sid, new_meeting_id)

    _fake_chime.set_side_effect(old_meeting_id, simulate_concurrent_rejoin)
    _fake_chime.set_response(old_meeting_id, make_not_found_error())  # old meeting confirmed reaped
    handler, slog, prior = capture_scheduler_logs()
    install_fake_chime()
    try:
        asyncio.run(run_job())
        check("session is NOT deleted despite the old meeting being confirmed empty, "
              "because chime_meeting_id changed underneath the check",
              session_exists(sid), f"sid={sid}")
        check("the row still reflects the concurrently-recreated (new) meeting id",
              get_chime_meeting_id(sid) == new_meeting_id, get_chime_meeting_id(sid))
        skipped = [r for r in handler.records if "skipped" in r and sid in r]
        check("a distinct race-prevented-skip log line was emitted naming this session",
              len(skipped) == 1, str(handler.records))
    finally:
        restore_boto3_client()
        release_scheduler_logs(handler, slog, prior)
        cleanup(uid, session_ids=[sid])


# ── 14. Root-cause regression: NULL chime_meeting_id, not '' ────────────────

def test_null_chime_meeting_id_is_deleted_not_perpetually_skipped():
    print(
        "\n=== 14. Non-recurring session with a genuine SQL NULL chime_meeting_id "
        "(not ''), past grace -> deleted, not skipped forever ==="
    )
    now = datetime.now(tzmod.utc)
    uid = make_user("adnullchime")
    sid = make_session_direct(
        uid, time_end=now - timedelta(seconds=GRACE + 300), chime_meeting_id=None,
    )
    # Confirm the fixture actually landed a real SQL NULL, not '' -- this
    # test is worthless if it silently degrades to the already-covered
    # empty-string case.
    db = DBManager()
    try:
        db.cur.execute("SELECT chime_meeting_id FROM devotions WHERE _id = %s", (sid,))
        stored = db.cur.fetchone()[0]
    finally:
        db.close()
    handler, slog, prior = capture_scheduler_logs()
    try:
        check("fixture stored a real SQL NULL chime_meeting_id, not ''",
              stored is None, f"stored={stored!r}")
        asyncio.run(run_job())
        check("session with NULL chime_meeting_id, past grace, is deleted",
              not session_exists(sid), f"sid={sid}")
        deleted_lines = [r for r in handler.records if "Session auto-deleted" in r and sid in r]
        skipped_lines = [r for r in handler.records if "Session-auto-delete skipped" in r and sid in r]
        check("a 'Session auto-deleted' log line was emitted for this session",
              len(deleted_lines) == 1, str(handler.records))
        check("no 'skipped: state changed' log line was emitted for this session",
              len(skipped_lines) == 0, str(handler.records))
        # Second cycle: prove this isn't a one-off race win -- rerunning
        # against the (now-deleted) row must not resurrect the perpetual-
        # skip symptom either.
        asyncio.run(run_job())
        check("session stays deleted on a second poll cycle",
              not session_exists(sid), f"sid={sid}")
    finally:
        release_scheduler_logs(handler, slog, prior)
        cleanup(uid, session_ids=[sid])


# ── 15. Pre-deployment smoke test ───────────────────────────────────────────

def test_real_app_boots_with_session_auto_delete_job_registered():
    print("\n=== 15. Real app (main.app) boots with session_auto_delete registered on the scheduler ===")
    check("main.app is importable and non-null", main_module.app is not None)
    with TestClient(main_module.app):
        job_ids = {job.id for job in scheduler_module.scheduler.get_jobs()}
        check("session_auto_delete job is registered on the scheduler",
              "session_auto_delete" in job_ids, str(job_ids))


def main():
    try:
        test_no_call_ever_started_deletes_after_grace_period()
        test_within_grace_period_is_not_deleted()
        test_recurring_session_excluded_regardless_of_time_end()
        test_missing_time_end_never_a_candidate()
        test_call_still_present_defers_deletion()
        test_call_confirmed_empty_via_not_found_deletes()
        test_deferred_then_eventually_deleted_across_poll_cycles()
        test_ambiguous_chime_error_fails_closed_deferred()
        test_chime_timeout_generic_exception_fails_closed_deferred()
        test_concurrent_rejoin_race_prevents_deletion()
        test_null_chime_meeting_id_is_deleted_not_perpetually_skipped()
        test_real_app_boots_with_session_auto_delete_job_registered()
    finally:
        restore_boto3_client()

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
