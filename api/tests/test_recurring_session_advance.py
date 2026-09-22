"""Tests for task 20260921-recurring-session-next-occurrence:

backend step 1 added a new apscheduler job `_advance_recurring_sessions`
(api/backend/interactions/scheduler.py) -- the natural counterpart to the
sibling `_auto_delete_expired_sessions` job (20260921-session-auto-delete-
window): once a `recurring = TRUE` session's `time_end` is more than
`SESSION_RECURRING_ADVANCE_GRACE_SECONDS` (1 hour) in the past, and a
fail-closed Chime-presence gate (`_session_auto_delete_confirmed_call_empty`,
reused as-is) confirms the call is not still occupied, the row's
`time_start`/`time_end` are advanced in place by exactly one *local calendar*
week (zoneinfo-aware, not a raw UTC `timedelta(days=7)`), and its
per-occurrence state (`reminder_sent_at`, `chime_meeting_id`, `chime_meeting`)
is reset. security step 2 added a `chime_meeting_id` re-check to the atomic
advance UPDATE (`_advance_recurring_session_if_still_candidate`) so the
presence gate can't be defeated by a call that (re)starts in the window
between the check and the write.

This proves, against the REAL job functions and a REAL Postgres DB (never a
mocked manager), the specific behaviors this task's acceptance criteria call
out:

  1. A recurring session past its grace period is advanced by exactly one
     week, with its original duration preserved exactly.
  2. `reminder_sent_at`/`chime_meeting_id`/`chime_meeting` are reset on
     advance so the next occurrence re-arms its own reminder and never
     inherits a finished call's meeting state.
  3. A non-recurring session is never touched by this job, regardless of how
     far past `time_end` it is (mirrors the sibling job's own exclusion of
     `recurring = TRUE` rows, in the opposite direction).
  4. A recurring session still within its 1-hour grace period is never
     advanced (grace-period boundary, "not yet" side).
  5. Weekly math correctly crosses a DST spring-forward transition (wall-clock
     time preserved, NOT a raw 7*24h UTC shift -- which would land one hour
     off local wall-clock time across the transition).
  6. Weekly math correctly crosses a DST fall-back transition (same
     wall-clock-preserving requirement, opposite direction).
  7. A session with a missing/NULL `time_end` is never a candidate at all --
     not silently advanced, not silently guessed at.
  8. A session whose `creator_id` doesn't resolve to any real user (the
     `users` LEFT JOIN comes back empty) is never advanced -- explicit
     fail-closed skip, not a silent UTC default.
  9. A session whose creator has an unresolvable/garbage `users.timezone`
     value is never advanced -- explicit fail-closed skip via
     `logger.exception`, not a silent UTC default.
  10. A session whose call is still live (Chime confirms the meeting still
      exists) is NOT advanced -- deferred, re-checked next cycle.
  11. A session whose call is confirmed torn down (Chime raises
      `NotFoundException`) IS advanced, and its stale `chime_meeting_id`/
      `chime_meeting` are cleared in the same statement.
  12. Race-safety: the atomic advance re-check (`time_end` AND
      `chime_meeting_id`) prevents a double-advance if two poll cycles race
      on the same row -- the second, stale attempt is a no-op, not a second
      week added on top of the first.
  13. Every actual advance is logged with old/new `time_start`.
  14. Every deferral (call still live) and skip (unresolved timezone) is
      logged with its cause.
  15. Pre-deployment smoke test: the real app (main.app) boots with
      `session_recurring_advance` registered on the scheduler.

The fake Chime client defaults to "meeting still exists" for ANY MeetingId it
wasn't explicitly told about (same technique as
test_session_auto_delete_window.py) -- this job does a full-table scan of
`devotions`, so this default keeps the fake from ever causing an unrelated
real session (in a shared dev DB) to be advanced/have its meeting state
cleared just because it happened to also be a candidate on the same cycle.

Run:  cd api && ../.venv/bin/python tests/test_recurring_session_advance.py
"""
import _pathfix  # noqa: F401,E402

import asyncio
import json
import logging
import uuid
from datetime import datetime, timedelta, timezone as tzmod
from zoneinfo import ZoneInfo

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

GRACE = scheduler_module.SESSION_RECURRING_ADVANCE_GRACE_SECONDS


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── Fixtures ─────────────────────────────────────────────────────────────────

def make_user(prefix: str, timezone: str | None = None) -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        values = {
            "_id": uid, "username": f"{prefix}_{uid[:8]}",
            "email": f"{prefix}_{uid[:8]}@example.com", "hash_pass": "x",
        }
        if timezone is not None:
            values["timezone"] = timezone
        db.insertion("users", values)
    finally:
        db.close()
    return uid


def force_user_timezone(uid: str, tzname: str) -> None:
    """Bypass the `timezone` column's own semantics entirely -- sets a
    genuinely unresolvable IANA name directly, to exercise the fail-closed
    ZoneInfo-resolution-failure path (distinct from the "no matching user at
    all" path `make_session_direct(creator_id=<dangling uuid>)` exercises)."""
    db = DBManager()
    try:
        db.cur.execute("UPDATE users SET timezone = %s WHERE _id = %s", (tzname, uid))
        db.conn.commit()
    finally:
        db.close()


def make_session_direct(
    creator_id: str, *, time_start: datetime | None, time_end: datetime | None,
    recurring: bool = True, chime_meeting_id: str = "", chime_meeting: dict | None = None,
    reminder_sent_at: datetime | None = None, title: str = "Recurring-advance session",
) -> str:
    """Insert a devotions row directly (bypassing the route/schema layer),
    same technique as test_session_auto_delete_window.py's
    `make_session_direct` -- this job only cares about DB state."""
    session_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO devotions (_id, title, time_start, time_end, recurring, "
            "group_id, creator_id, participants, verses, prompts, chime_meeting_id, "
            "chime_meeting, reminder_sent_at) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
            (session_id, title, time_start, time_end, recurring,
             None, creator_id, [], [], [], chime_meeting_id,
             json.dumps(chime_meeting or {}), reminder_sent_at),
        )
        db.conn.commit()
    finally:
        db.close()
    return session_id


def get_session_row(session_id: str) -> dict | None:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT time_start, time_end, recurring, chime_meeting_id, "
            "chime_meeting, reminder_sent_at FROM devotions WHERE _id = %s",
            (session_id,),
        )
        row = db.cur.fetchone()
        if not row:
            return None
        return {
            "time_start": row[0], "time_end": row[1], "recurring": row[2],
            "chime_meeting_id": row[3], "chime_meeting": row[4],
            "reminder_sent_at": row[5],
        }
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
    message = (
        f"An error occurred (NotFoundException) when calling the {operation_name} "
        "operation: One or more of the resources in the request does not exist "
        "in the system."
    )
    return ClientError({"Error": {"Code": "NotFoundException", "Message": message}}, operation_name)


class FakeChimeClient:
    """Same shape/safe-default as test_session_auto_delete_window.py's fake:
    an unrecognized MeetingId defaults to "still exists" (the non-destructive
    outcome for this job too -- deferred, not advanced/cleared)."""

    def __init__(self):
        self._responses: dict[str, Exception | None] = {}
        self.get_meeting_calls: list[str] = []

    def set_response(self, meeting_id: str, error: Exception | None) -> None:
        self._responses[meeting_id] = error

    def get_meeting(self, MeetingId=None, **kwargs):
        self.get_meeting_calls.append(MeetingId)
        if MeetingId in self._responses:
            error = self._responses[MeetingId]
            if error is not None:
                raise error
            return {"Meeting": {"MeetingId": MeetingId}}
        return {"Meeting": {"MeetingId": MeetingId}}  # safe default: "still exists"


class _CapturingLogHandler(logging.Handler):
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
    await scheduler_module._advance_recurring_sessions()


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


# ── 1. Successful advance: exactly one week, duration preserved, state reset ──

def test_successful_advance_preserves_duration_and_resets_state():
    print("=== 1. Recurring session past grace, no call -> advanced exactly one week, "
          "duration preserved, per-occurrence state reset ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("radadvance", timezone="UTC")
    old_start = now - timedelta(days=7, hours=2)
    old_end = old_start + timedelta(hours=1)  # 1-hour session, well past grace
    sid = make_session_direct(
        uid, time_start=old_start, time_end=old_end, recurring=True,
        chime_meeting_id="", reminder_sent_at=now - timedelta(days=6),
    )
    handler, slog, prior = capture_scheduler_logs()
    try:
        asyncio.run(run_job())
        row = get_session_row(sid)
        check("session row still exists after advance", row is not None, f"sid={sid}")
        if row:
            expected_start = old_start + timedelta(days=7)
            expected_end = old_end + timedelta(days=7)
            check("new time_start is exactly one week after the old one",
                  abs((row["time_start"] - expected_start).total_seconds()) < 1,
                  f"got={row['time_start']} expected={expected_start}")
            check("duration (time_end - time_start) preserved exactly",
                  row["time_end"] - row["time_start"] == old_end - old_start,
                  f"new duration={row['time_end'] - row['time_start']}")
            check("reminder_sent_at reset to NULL so the next reminder can fire",
                  row["reminder_sent_at"] is None, str(row["reminder_sent_at"]))
            check("chime_meeting_id reset to its default ('')",
                  row["chime_meeting_id"] == "", repr(row["chime_meeting_id"]))
            check("chime_meeting reset to its default ('{}')",
                  row["chime_meeting"] == {}, repr(row["chime_meeting"]))
        fired = [r for r in handler.records if "recurring-advanced" in r and sid in r]
        check("a 'Session recurring-advanced' log line was emitted naming this session",
              len(fired) == 1, str(handler.records))
    finally:
        release_scheduler_logs(handler, slog, prior)
        cleanup(uid, session_ids=[sid])


# ── 2. Non-recurring session is never touched ───────────────────────────────

def test_non_recurring_session_never_advanced():
    print("\n=== 2. Non-recurring session, way past time_end -> never a candidate, never advanced ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("radnonrecurring", timezone="UTC")
    old_start = now - timedelta(days=30)
    old_end = old_start + timedelta(hours=1)
    sid = make_session_direct(uid, time_start=old_start, time_end=old_end, recurring=False)
    try:
        asyncio.run(run_job())
        row = get_session_row(sid)
        check("non-recurring session's time_start is untouched",
              row is not None and row["time_start"] == old_start, str(row))
        check("non-recurring session's time_end is untouched",
              row is not None and row["time_end"] == old_end, str(row))
    finally:
        cleanup(uid, session_ids=[sid])


# ── 3. Still within the grace period -> not advanced ────────────────────────

def test_within_grace_period_is_not_advanced():
    print("\n=== 3. Recurring session whose time_end is within the grace period -> never advanced ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("radwithingrace", timezone="UTC")
    old_start = now - timedelta(seconds=GRACE - 300 + 3600)
    old_end = now - timedelta(seconds=GRACE - 300)
    sid = make_session_direct(uid, time_start=old_start, time_end=old_end, recurring=True)
    try:
        asyncio.run(run_job())
        row = get_session_row(sid)
        check("session still within its grace period is not advanced",
              row is not None and row["time_start"] == old_start, str(row))
    finally:
        cleanup(uid, session_ids=[sid])


# ── 4. DST spring-forward: wall-clock preserved, not a raw UTC shift ───────

def test_dst_spring_forward_preserves_local_wall_clock():
    print("\n=== 4. DST spring-forward (America/New_York, Mar 8 2026) -> local wall-clock time preserved ===")
    uid = make_user("radspring", timezone="America/New_York")
    zone = ZoneInfo("America/New_York")
    # 2026-03-01 09:00 local (EST, UTC-05:00) -- one week before the
    # 2026-03-08 02:00 local spring-forward transition, at a time of day
    # nowhere near the 2-3am transition gap itself.
    old_start_local = datetime(2026, 3, 1, 9, 0, tzinfo=zone)
    old_start = old_start_local.astimezone(tzmod.utc)
    old_end = old_start + timedelta(hours=1)
    sid = make_session_direct(uid, time_start=old_start, time_end=old_end, recurring=True)
    try:
        asyncio.run(run_job())
        row = get_session_row(sid)
        check("session was advanced", row is not None and row["time_start"] != old_start, str(row))
        if row:
            new_local = row["time_start"].astimezone(zone)
            # Correct: wall clock stays 09:00 local on 2026-03-08 (now EDT,
            # UTC-04:00) -- a full calendar week later, same time of day.
            expected_local = datetime(2026, 3, 8, 9, 0, tzinfo=zone)
            check("new local wall-clock time is still 09:00 (not shifted by the DST offset delta)",
                  new_local.hour == 9 and new_local.date() == expected_local.date(),
                  f"got local={new_local}")
            # A naive UTC timedelta(days=7) add would have produced 10:00
            # local instead (one hour off) -- explicitly assert we did NOT
            # get that wrong answer.
            wrong_naive_utc = old_start + timedelta(days=7)
            check("result differs from the naive raw-UTC-add answer (which would be off by 1h)",
                  row["time_start"] != wrong_naive_utc,
                  f"new_utc={row['time_start']} naive_wrong_utc={wrong_naive_utc}")
    finally:
        cleanup(uid, session_ids=[sid])


# ── 5. DST fall-back: wall-clock preserved, not a raw UTC shift ────────────

def test_dst_fall_back_preserves_local_wall_clock():
    print("\n=== 5. DST fall-back (America/New_York, Nov 2 2025) -> local wall-clock time preserved ===")
    uid = make_user("radfallback", timezone="America/New_York")
    zone = ZoneInfo("America/New_York")
    # 2025-10-26 09:00 local (EDT, UTC-04:00) -- one week before the
    # 2025-11-02 02:00 local fall-back transition. Must be in the actual
    # past (this environment's "today" is 2026-09-21) so it's genuinely
    # past its grace period and picked up as a candidate.
    old_start_local = datetime(2025, 10, 26, 9, 0, tzinfo=zone)
    old_start = old_start_local.astimezone(tzmod.utc)
    old_end = old_start + timedelta(hours=1)
    sid = make_session_direct(uid, time_start=old_start, time_end=old_end, recurring=True)
    try:
        asyncio.run(run_job())
        row = get_session_row(sid)
        check("session was advanced", row is not None and row["time_start"] != old_start, str(row))
        if row:
            new_local = row["time_start"].astimezone(zone)
            check("new local wall-clock time is still 09:00 on 2025-11-02 (not shifted by the DST offset delta)",
                  new_local.hour == 9 and new_local.date() == datetime(2025, 11, 2).date(),
                  f"got local={new_local}")
            wrong_naive_utc = old_start + timedelta(days=7)
            check("result differs from the naive raw-UTC-add answer (which would be off by 1h)",
                  row["time_start"] != wrong_naive_utc,
                  f"new_utc={row['time_start']} naive_wrong_utc={wrong_naive_utc}")
    finally:
        cleanup(uid, session_ids=[sid])


# ── 6. NULL time_end never a candidate ──────────────────────────────────────

def test_missing_time_end_never_a_candidate():
    print("\n=== 6. Recurring session with NULL time_end -> never a candidate, never advanced ===")
    uid = make_user("radnotime", timezone="UTC")
    now = datetime.now(tzmod.utc)
    sid = make_session_direct(uid, time_start=now - timedelta(days=30), time_end=None, recurring=True)
    try:
        asyncio.run(run_job())
        row = get_session_row(sid)
        check("session with NULL time_end survives the job untouched",
              row is not None and row["time_end"] is None, str(row))
    finally:
        cleanup(uid, session_ids=[sid])


# ── 7. creator_id doesn't resolve to any user -> skip ───────────────────────

def test_dangling_creator_id_skips_advance():
    print("\n=== 7. Recurring session whose creator_id matches no real user -> skipped, not advanced ===")
    now = datetime.now(tzmod.utc)
    dangling_creator = str(uuid.uuid4())  # never inserted into users
    old_start = now - timedelta(days=7, hours=2)
    old_end = old_start + timedelta(hours=1)
    db = DBManager()
    try:
        sid = str(uuid.uuid4())
        db.cur.execute(
            "INSERT INTO devotions (_id, title, time_start, time_end, recurring, "
            "group_id, creator_id, participants, verses, prompts, chime_meeting_id) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
            (sid, "Dangling creator session", old_start, old_end, True,
             None, None, [], [], [], ""),
        )
        db.conn.commit()
    finally:
        db.close()
    handler, slog, prior = capture_scheduler_logs()
    try:
        asyncio.run(run_job())
        row = get_session_row(sid)
        check("session with no resolvable creator is not advanced",
              row is not None and row["time_start"] == old_start, str(row))
        skipped = [r for r in handler.records if "no resolvable creator timezone" in r and sid in r]
        check("a 'no resolvable creator timezone' skip was logged",
              len(skipped) == 1, str(handler.records))
    finally:
        release_scheduler_logs(handler, slog, prior)
        cleanup(session_ids=[sid])


# ── 8. Invalid/unresolvable timezone string -> skip ─────────────────────────

def test_invalid_timezone_string_skips_advance():
    print("\n=== 8. Recurring session whose creator has an unresolvable timezone string -> skipped ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("radbadtz", timezone="UTC")
    force_user_timezone(uid, "Not/ARealZone")
    old_start = now - timedelta(days=7, hours=2)
    old_end = old_start + timedelta(hours=1)
    sid = make_session_direct(uid, time_start=old_start, time_end=old_end, recurring=True)
    handler, slog, prior = capture_scheduler_logs()
    try:
        asyncio.run(run_job())
        row = get_session_row(sid)
        check("session with an unresolvable creator timezone is not advanced",
              row is not None and row["time_start"] == old_start, str(row))
        failed = [r for r in handler.records if "failed to resolve next weekly occurrence" in r and sid in r]
        check("a 'failed to resolve next weekly occurrence' log was emitted (logger.exception)",
              len(failed) == 1, str(handler.records))
    finally:
        release_scheduler_logs(handler, slog, prior)
        cleanup(uid, session_ids=[sid])


# ── 9. Call still live -> deferred, not advanced ────────────────────────────

def test_call_still_present_defers_advance():
    print("\n=== 9. Chime confirms the meeting still exists -> advance deferred, not advanced ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("radstilllive", timezone="UTC")
    meeting_id = f"meeting-{uuid.uuid4()}"
    old_start = now - timedelta(days=7, hours=2)
    old_end = old_start + timedelta(hours=1)
    sid = make_session_direct(
        uid, time_start=old_start, time_end=old_end, recurring=True,
        chime_meeting_id=meeting_id, chime_meeting={"MeetingId": meeting_id},
    )
    _fake_chime.set_response(meeting_id, None)  # "still exists"
    handler, slog, prior = capture_scheduler_logs()
    install_fake_chime()
    try:
        asyncio.run(run_job())
        row = get_session_row(sid)
        check("session whose call is still live is NOT advanced",
              row is not None and row["time_start"] == old_start, str(row))
        check("chime_meeting_id is untouched while the call is still live",
              row is not None and row["chime_meeting_id"] == meeting_id, str(row))
        check("Chime's get_meeting was actually called for this session's meeting",
              meeting_id in _fake_chime.get_meeting_calls, str(_fake_chime.get_meeting_calls))
        deferred = [r for r in handler.records if "deferred" in r and sid in r]
        check("a deferred log line was emitted naming this session",
              len(deferred) == 1, str(handler.records))
    finally:
        restore_boto3_client()
        release_scheduler_logs(handler, slog, prior)
        cleanup(uid, session_ids=[sid])


# ── 10. Call confirmed torn down -> advanced, meeting state cleared ────────

def test_call_confirmed_empty_advances_and_clears_meeting_state():
    print("\n=== 10. Chime raises NotFoundException (meeting already reaped) -> advanced, meeting state cleared ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("radconfirmedempty", timezone="UTC")
    meeting_id = f"meeting-{uuid.uuid4()}"
    old_start = now - timedelta(days=7, hours=2)
    old_end = old_start + timedelta(hours=1)
    sid = make_session_direct(
        uid, time_start=old_start, time_end=old_end, recurring=True,
        chime_meeting_id=meeting_id, chime_meeting={"MeetingId": meeting_id},
    )
    _fake_chime.set_response(meeting_id, make_not_found_error())
    handler, slog, prior = capture_scheduler_logs()
    install_fake_chime()
    try:
        asyncio.run(run_job())
        row = get_session_row(sid)
        check("session whose call is confirmed empty IS advanced",
              row is not None and row["time_start"] != old_start, str(row))
        check("chime_meeting_id was cleared back to its default",
              row is not None and row["chime_meeting_id"] == "", str(row))
        check("chime_meeting was cleared back to its default",
              row is not None and row["chime_meeting"] == {}, str(row))
        fired = [r for r in handler.records if "recurring-advanced" in r and sid in r]
        check("a 'Session recurring-advanced' log line was emitted naming this session",
              len(fired) == 1, str(handler.records))
    finally:
        restore_boto3_client()
        release_scheduler_logs(handler, slog, prior)
        cleanup(uid, session_ids=[sid])


# ── 11. Atomic re-check prevents a double-advance across racing cycles ─────

def test_atomic_recheck_prevents_double_advance():
    print("\n=== 11. Two racing poll cycles reading the same stale state -> only the first actually advances ===")
    now = datetime.now(tzmod.utc)
    uid = make_user("radrace", timezone="UTC")
    old_start = now - timedelta(days=7, hours=2)
    old_end = old_start + timedelta(hours=1)
    sid = make_session_direct(uid, time_start=old_start, time_end=old_end, recurring=True, chime_meeting_id="")
    try:
        new_start = old_start + timedelta(days=7)
        new_end = old_end + timedelta(days=7)
        # Both "cycles" read the same original time_end/chime_meeting_id
        # snapshot (as they would if they scanned concurrently) and race to
        # write it via the same atomic function.
        first = scheduler_module._advance_recurring_session_if_still_candidate(
            DBManager(), sid, old_end, "", new_start, new_end,
        )
        second = scheduler_module._advance_recurring_session_if_still_candidate(
            DBManager(), sid, old_end, "", new_start + timedelta(days=7), new_end + timedelta(days=7),
        )
        check("the first (fresh-state) racing attempt succeeds", first is True, str(first))
        check("the second (stale-state) racing attempt is rejected, not a double-advance",
              second is False, str(second))
        row = get_session_row(sid)
        check("the row reflects exactly ONE week of advance, not two",
              row is not None and row["time_start"] == new_start,
              f"got={row['time_start'] if row else None} expected_single_advance={new_start}")
    finally:
        cleanup(uid, session_ids=[sid])


# ── 12. Smoke test ───────────────────────────────────────────────────────

def test_real_app_boots_with_recurring_advance_job_registered():
    print("\n=== 12. Real app (main.app) boots with session_recurring_advance registered on the scheduler ===")
    check("main.app is importable and non-null", main_module.app is not None)
    with TestClient(main_module.app):
        job_ids = {job.id for job in scheduler_module.scheduler.get_jobs()}
        check("session_recurring_advance job is registered on the scheduler",
              "session_recurring_advance" in job_ids, str(job_ids))


def main():
    try:
        test_successful_advance_preserves_duration_and_resets_state()
        test_non_recurring_session_never_advanced()
        test_within_grace_period_is_not_advanced()
        test_dst_spring_forward_preserves_local_wall_clock()
        test_dst_fall_back_preserves_local_wall_clock()
        test_missing_time_end_never_a_candidate()
        test_dangling_creator_id_skips_advance()
        test_invalid_timezone_string_skips_advance()
        test_call_still_present_defers_advance()
        test_call_confirmed_empty_advances_and_clears_meeting_state()
        test_atomic_recheck_prevents_double_advance()
        test_real_app_boots_with_recurring_advance_job_registered()
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
