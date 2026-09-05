"""Tests for task 20260904-session-push-notifications:

backend step 1 added two new push sends around the existing devotion/session
feature -- (1) `_notify_session_created` (api/routes/devotion.py), fired
synchronously at the end of `POST /devotions/` (`create_devotion`), and (2)
`_fire_due_session_reminders` (api/backend/interactions/scheduler.py), a new
polling job that fires once a session's `time_start` arrives -- plus a new
`devotions.reminder_sent_at` column used as an atomic once-only dedup claim.

frontend step 2 added iOS-side tap navigation for these two push types
(FellowScriptApp.AppDelegate's `didReceive response:` + AppState.openSession);
that side is covered separately in FellowScriptTests/
SessionPushNotificationsAppStateTests.swift.

This file proves, against the REAL route/job functions and a REAL Postgres DB
(never a mocked manager), the specific behaviors named in this task's
acceptance criteria:

  1. Creating a session notifies every other current member of its group
     (via `DevotionManager.resolve_members`, the same membership concept
     `is_authorized` already encodes) -- but never the creator.
  2. A DM session (`group_id = "uidA|uidB"`) notifies the one other
     participant -- the degenerate small-DM case the intake spec flagged as
     "near-certainly yes."
  3. A session with no notifiable member holding a registered device token
     fails to notify gracefully (create still succeeds, no push sent, no
     crash).
  4. A per-recipient push failure (a bad/expired token, a transient APNs
     error) is isolated -- one recipient's failure never blocks another
     recipient's push, and never aborts the create call itself.
  5. Once a session's `time_start` arrives, every member (INCLUDING the
     creator -- unlike the creation push, which deliberately excludes them)
     gets exactly one "Session Starting" reminder push, and
     `reminder_sent_at` is set (the atomic claim).
  6. A session whose `time_start` hasn't arrived yet is left alone --
     `reminder_sent_at` stays NULL, no push sent.
  7. THE regression this task explicitly calls out (mirroring
     .claude/pipeline/20260825-scheduled-event-duplicate-fire's discipline):
     running the reminder job across multiple sequential poll cycles for the
     same due session never double-fires -- exactly one push per member,
     network-wide, no matter how many times the job polls afterward.
  8. The same double-fire guard holds under REAL concurrency -- two threads,
     each running their own event loop/DB connections, racing the same due
     session's claim -- not just sequential re-invocation (same technique as
     test_heartbeat_backend_scheduling.py's concurrent-poll-cycles test).
  9. A session with no notifiable member holding a device token (e.g. its
     group/DM has since been emptied) still gets claimed (reminder_sent_at
     set) without crashing -- "claimed but nobody to push" is a real no-op,
     not a job failure.
  10. A per-recipient reminder-push failure is isolated the same way the
      creation push's is.
  11. Pre-deployment smoke test: the real app (main.app) boots with
      `session_reminder_fire` registered on the scheduler.
  12. Existing `/devotions/*` behavior (the IDOR/authorization fixes this new
      code sits next to) is unchanged -- re-run as part of the full suite,
      not duplicated here; see test_idor_agent_notification_devotion.py.

Uses a capturing fake `send_push` (same technique as
test_heartbeat_backend_scheduling.py / test_activity_notifications.py) so no
real APNs call is made.

Run:  cd api && ../.venv/bin/python tests/test_session_push_notifications.py
"""
import _pathfix  # noqa: F401,E402

import asyncio
import importlib
import os
import sys
import threading
import uuid
from datetime import datetime, timedelta, timezone as tzmod

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
import backend.interactions.scheduler as scheduler_module  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── Fixtures ─────────────────────────────────────────────────────────────────

def cookie_header(token: str):
    return {"cookie": f"session={token}"} if token else {}


_signup_counter = 0


def signup(client, username):
    """Same fake-per-caller-IP technique as test_friend_activity_push_triggers.py
    -- /signup is rate-limited at 5/minute per client IP (backend/
    rate_limiting.py), and this file's creation-push tests need more than 5
    signups in one run. TestClient requests otherwise all share one apparent
    IP, so a distinct `cf-connecting-ip` per signup gives each its own
    rate-limit bucket, matching how production resolves the real visitor IP
    behind Cloudflare anyway."""
    global _signup_counter
    _signup_counter += 1
    fake_ip = f"203.0.113.{_signup_counter % 250 + 1}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def make_user(prefix: str) -> str:
    """A bare user row -- used for direct-DB-insert devotion fixtures that
    don't need a real authenticated session (only creation-push tests, which
    go through the real route, need signup())."""
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


def make_group(member_ids: list[str], title: str = "test-group") -> str:
    gid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("groups", {"_id": gid, "title": title, "users": member_ids})
    finally:
        db.close()
    return gid


def set_device_token(user_id: str, token: str) -> None:
    db = DBManager()
    try:
        db.insertion(
            "device_tokens", {"user_id": user_id, "token": token},
            conflict="(user_id) DO UPDATE SET token = EXCLUDED.token",
        )
    finally:
        db.close()


def make_session_direct(
    creator_id: str, group_id: str = "", participants: list[str] | None = None,
    title: str = "Session", time_start: datetime | None = None,
) -> str:
    """Insert a devotions row directly (bypassing the route/schema layer) so
    reminder-job tests can control `time_start` precisely -- the real
    `POST /devotions/` route always needs a real authenticated session
    (fine for the creation-push tests below, which use it), but the reminder
    job only cares about DB state, not the route."""
    session_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO devotions (_id, title, time_start, group_id, creator_id, participants, verses, prompts) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
            (session_id, title, time_start, group_id or None, creator_id,
             participants or [], [], []),
        )
        db.conn.commit()
    finally:
        db.close()
    return session_id


def get_reminder_sent_at(session_id: str):
    db = DBManager()
    try:
        db.cur.execute("SELECT reminder_sent_at FROM devotions WHERE _id = %s", (session_id,))
        row = db.cur.fetchone()
        return row[0] if row else None
    finally:
        db.close()


def cleanup(user_ids: list[str] | None = None, group_ids: list[str] | None = None,
            session_ids: list[str] | None = None) -> None:
    db = DBManager()
    try:
        # FK order: devotions.creator_id -> users has no ON DELETE clause
        # (RESTRICT), so sessions must go before their creator's user row.
        for sid in (session_ids or []):
            db.cur.execute("DELETE FROM devotions WHERE _id = %s", (sid,))
        if user_ids:
            db.cur.execute("DELETE FROM devotions WHERE creator_id = ANY(%s::uuid[])", (user_ids,))
        for gid in (group_ids or []):
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in (user_ids or []):
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


class _CapturingPush:
    """Same technique as test_heartbeat_backend_scheduling.py's _CapturingPush,
    extended with `fail_tokens` so a specific recipient's send can be made to
    raise -- proving per-recipient failure isolation (acceptance criterion:
    'no crash, isolated per-recipient error handling')."""

    def __init__(self, fail_tokens: set[str] | None = None):
        self.calls: list[tuple[str, str, str, dict | None]] = []
        self.fail_tokens = fail_tokens or set()

    async def __call__(self, token: str, title: str, body: str, data: dict | None = None) -> bool:
        if token in self.fail_tokens:
            raise RuntimeError("simulated APNs failure")
        self.calls.append((token, title, body, data))
        return True


def install_push(fail_tokens: set[str] | None = None) -> _CapturingPush:
    push = _CapturingPush(fail_tokens=fail_tokens)
    push_module.send_push = push
    return push


def restore_push() -> None:
    importlib.reload(push_module)


async def run_reminder_job() -> None:
    await scheduler_module._fire_due_session_reminders()


# ── 1/2/3/4: Creation push (POST /devotions/ -> _notify_session_created) ───
#
# All four share ONE TestClient/app-lifespan context (passed in from main()),
# rather than each opening/closing its own -- the scheduler module is a
# process-wide singleton (see start_scheduler/scheduler in scheduler.py), and
# repeatedly entering/exiting the real ASGI lifespan across several separate
# `with TestClient(...)` blocks in the same process races that singleton's
# background event loop (observed directly: "RuntimeError: Event loop is
# closed" from apscheduler's wakeup() when a second lifespan tried to
# register jobs after the first's loop had already been torn down). One
# shared lifespan for this whole file's route-driven tests avoids that.

def test_creation_push_notifies_other_group_members_not_creator(client):
    print("=== 1. Creating a group session pushes every OTHER member, never the creator ===")
    uid_creator, token_creator = signup(client, f"crpush_creator_{uuid.uuid4().hex[:8]}")
    uid_m1, _ = signup(client, f"crpush_m1_{uuid.uuid4().hex[:8]}")
    uid_m2, _ = signup(client, f"crpush_m2_{uuid.uuid4().hex[:8]}")
    gid = make_group([uid_creator, uid_m1, uid_m2])
    set_device_token(uid_creator, f"tok-{uid_creator}")
    set_device_token(uid_m1, f"tok-{uid_m1}")
    set_device_token(uid_m2, f"tok-{uid_m2}")

    push = install_push()
    devo_id = str(uuid.uuid4())
    payload = {
        "devotion_id": devo_id, "user_id": uid_creator,
        "devotion": {"id": devo_id, "title": "Morning Prayer", "creator_id": uid_creator,
                     "group_id": gid, "prompts": [], "verses": []},
    }
    try:
        r = client.post("/devotions/", json=payload, headers=cookie_header(token_creator))
        check("create session -> 201", r.status_code == 201, str(r.status_code) + " " + r.text)

        tokens_pushed = {c[0] for c in push.calls}
        check("m1 (other group member) was pushed", f"tok-{uid_m1}" in tokens_pushed, str(push.calls))
        check("m2 (other group member) was pushed", f"tok-{uid_m2}" in tokens_pushed, str(push.calls))
        check("creator was NOT pushed their own session-created notification",
              f"tok-{uid_creator}" not in tokens_pushed, str(push.calls))

        m1_call = next(c for c in push.calls if c[0] == f"tok-{uid_m1}")
        _, title, body, data = m1_call
        check("push title is 'New Session'", title == "New Session", title)
        check("push body names the session title", "Morning Prayer" in body, body)
        check("push data carries devotion_id + group_id",
              data == {"devotion_id": devo_id, "group_id": gid}, str(data))
    finally:
        restore_push()
        cleanup(user_ids=[uid_creator, uid_m1, uid_m2], group_ids=[gid])


def test_creation_push_dm_session_notifies_the_other_participant(client):
    print("\n=== 2. A DM session (group_id='uidA|uidB') notifies the one other participant ===")
    uid_a, token_a = signup(client, f"crpushdm_a_{uuid.uuid4().hex[:8]}")
    uid_b, _ = signup(client, f"crpushdm_b_{uuid.uuid4().hex[:8]}")
    dm_key = f"{uid_a}|{uid_b}"
    set_device_token(uid_a, f"tok-{uid_a}")
    set_device_token(uid_b, f"tok-{uid_b}")

    push = install_push()
    devo_id = str(uuid.uuid4())
    payload = {
        "devotion_id": devo_id, "user_id": uid_a,
        "devotion": {"id": devo_id, "title": "Quick Check-in", "creator_id": uid_a,
                     "group_id": dm_key, "prompts": [], "verses": []},
    }
    try:
        r = client.post("/devotions/", json=payload, headers=cookie_header(token_a))
        check("create DM session -> 201", r.status_code == 201, str(r.status_code) + " " + r.text)

        tokens_pushed = {c[0] for c in push.calls}
        check("the other DM participant (b) was pushed", f"tok-{uid_b}" in tokens_pushed, str(push.calls))
        check("the creator (a) was NOT pushed", f"tok-{uid_a}" not in tokens_pushed, str(push.calls))
        check("exactly one push sent for a 2-person DM", len(push.calls) == 1, str(push.calls))
    finally:
        restore_push()
        cleanup(user_ids=[uid_a, uid_b])


def test_creation_push_no_tokens_fails_gracefully(client):
    print("\n=== 3. No notifiable member has a registered device token -- graceful no-op, no crash ===")
    uid_creator, token_creator = signup(client, f"crpushnotok_creator_{uuid.uuid4().hex[:8]}")
    uid_m1, _ = signup(client, f"crpushnotok_m1_{uuid.uuid4().hex[:8]}")
    gid = make_group([uid_creator, uid_m1])
    # Deliberately no set_device_token calls at all.

    push = install_push()
    devo_id = str(uuid.uuid4())
    payload = {
        "devotion_id": devo_id, "user_id": uid_creator,
        "devotion": {"id": devo_id, "title": "No Token Session", "creator_id": uid_creator,
                     "group_id": gid, "prompts": [], "verses": []},
    }
    try:
        r = client.post("/devotions/", json=payload, headers=cookie_header(token_creator))
        check("create still succeeds -> 201 even with zero registered device tokens",
              r.status_code == 201, str(r.status_code) + " " + r.text)
        check("no push was attempted (nobody had a token)", push.calls == [], str(push.calls))
    finally:
        restore_push()
        cleanup(user_ids=[uid_creator, uid_m1], group_ids=[gid])


def test_creation_push_recipient_failure_does_not_abort_batch_or_create_call(client):
    print("\n=== 4. One recipient's push failure is isolated -- doesn't block another recipient's "
          "push or fail the create call ===")
    uid_creator, token_creator = signup(client, f"crpushfail_creator_{uuid.uuid4().hex[:8]}")
    uid_m1, _ = signup(client, f"crpushfail_m1_{uuid.uuid4().hex[:8]}")
    uid_m2, _ = signup(client, f"crpushfail_m2_{uuid.uuid4().hex[:8]}")
    gid = make_group([uid_creator, uid_m1, uid_m2])
    set_device_token(uid_m1, f"tok-{uid_m1}")
    set_device_token(uid_m2, f"tok-{uid_m2}")

    push = install_push(fail_tokens={f"tok-{uid_m2}"})
    devo_id = str(uuid.uuid4())
    payload = {
        "devotion_id": devo_id, "user_id": uid_creator,
        "devotion": {"id": devo_id, "title": "Partial Failure Session", "creator_id": uid_creator,
                     "group_id": gid, "prompts": [], "verses": []},
    }
    try:
        r = client.post("/devotions/", json=payload, headers=cookie_header(token_creator))
        check("create call still succeeds -> 201 despite one recipient's push raising",
              r.status_code == 201, str(r.status_code) + " " + r.text)
        tokens_pushed = {c[0] for c in push.calls}
        check("m1 (whose push didn't fail) still got pushed", f"tok-{uid_m1}" in tokens_pushed, str(push.calls))
        check("m2's failing push is not in the successful-calls log (it raised)",
              f"tok-{uid_m2}" not in tokens_pushed, str(push.calls))
    finally:
        restore_push()
        cleanup(user_ids=[uid_creator, uid_m1, uid_m2], group_ids=[gid])


# ── 5/6: Reminder job basic due/not-due behavior ────────────────────────────

def test_reminder_job_fires_for_due_session_including_creator():
    print("\n=== 5. A session whose time_start has passed gets exactly one reminder push per "
          "member -- INCLUDING the creator (unlike the creation push) -- and reminder_sent_at is claimed ===")
    uid_creator = make_user("remdue_creator")
    uid_m1 = make_user("remdue_m1")
    gid = make_group([uid_creator, uid_m1])
    set_device_token(uid_creator, f"tok-{uid_creator}")
    set_device_token(uid_m1, f"tok-{uid_m1}")
    past = datetime.now(tzmod.utc) - timedelta(minutes=1)
    session_id = make_session_direct(uid_creator, group_id=gid, title="Due Session", time_start=past)

    push = install_push()
    try:
        asyncio.run(run_reminder_job())
        check("reminder_sent_at is set after the job fires the due session",
              get_reminder_sent_at(session_id) is not None, str(get_reminder_sent_at(session_id)))
        tokens_pushed = {c[0] for c in push.calls}
        check("creator WAS pushed the reminder (reminder audience includes the creator)",
              f"tok-{uid_creator}" in tokens_pushed, str(push.calls))
        check("other member was pushed the reminder", f"tok-{uid_m1}" in tokens_pushed, str(push.calls))
        check("exactly one push per member", len(push.calls) == 2, str(push.calls))
        title, body, data = next((c[1], c[2], c[3]) for c in push.calls if c[0] == f"tok-{uid_creator}")
        check("reminder push title is 'Session Starting'", title == "Session Starting", title)
        check("reminder push body names the session title", "Due Session" in body, body)
        check("reminder push data carries devotion_id + group_id",
              data == {"devotion_id": session_id, "group_id": gid}, str(data))
    finally:
        restore_push()
        cleanup(user_ids=[uid_creator, uid_m1], group_ids=[gid], session_ids=[session_id])


def test_reminder_job_leaves_not_yet_due_session_alone():
    print("\n=== 6. A session whose time_start hasn't arrived yet is left completely alone ===")
    uid_creator = make_user("remfuture_creator")
    set_device_token(uid_creator, f"tok-{uid_creator}")
    future = datetime.now(tzmod.utc) + timedelta(hours=1)
    session_id = make_session_direct(uid_creator, title="Future Session", time_start=future)

    push = install_push()
    try:
        asyncio.run(run_reminder_job())
        check("reminder_sent_at stays NULL for a not-yet-due session",
              get_reminder_sent_at(session_id) is None, str(get_reminder_sent_at(session_id)))
        check("no push was sent for a not-yet-due session",
              not any(c[0] == f"tok-{uid_creator}" for c in push.calls), str(push.calls))
    finally:
        restore_push()
        cleanup(user_ids=[uid_creator], session_ids=[session_id])


# ── 7/8: THE regression -- no double-fire, sequential and concurrent ───────

def test_reminder_job_does_not_double_fire_across_repeated_poll_cycles():
    print("\n=== 7. Regression (20260825-scheduled-event-duplicate-fire precedent): running the "
          "reminder job across MULTIPLE SEQUENTIAL poll cycles for the same due session fires "
          "exactly once, not once per cycle ===")
    uid_creator = make_user("remrepeat_creator")
    set_device_token(uid_creator, f"tok-{uid_creator}")
    past = datetime.now(tzmod.utc) - timedelta(minutes=5)
    session_id = make_session_direct(uid_creator, title="Repeat-Poll Session", time_start=past)

    push = install_push()
    try:
        asyncio.run(run_reminder_job())
        first_sent_at = get_reminder_sent_at(session_id)
        check("first poll cycle fires and claims the session", first_sent_at is not None, str(first_sent_at))

        # Three more poll cycles for the SAME still-past time_start -- a naive
        # rolling time-window re-check (the exact bug this project already
        # root-caused once) would re-fire on every one of these; the atomic
        # `WHERE reminder_sent_at IS NULL` claim must not.
        for _ in range(3):
            asyncio.run(run_reminder_job())

        check("reminder_sent_at is unchanged across later poll cycles (claimed once, not re-claimed)",
              get_reminder_sent_at(session_id) == first_sent_at, str(get_reminder_sent_at(session_id)))
        pushes_for_creator = [c for c in push.calls if c[0] == f"tok-{uid_creator}"]
        check("exactly one push exists after 4 total poll cycles, not 4",
              len(pushes_for_creator) == 1, str(pushes_for_creator))
    finally:
        restore_push()
        cleanup(user_ids=[uid_creator], session_ids=[session_id])


def test_reminder_job_does_not_double_fire_under_concurrent_polls():
    print("\n=== 8. Two REAL concurrent poll cycles (separate threads/event loops/DB connections) "
          "racing the same due session's claim still fire exactly once, network-wide ===")
    uid_creator = make_user("remrace_creator")
    uid_m1 = make_user("remrace_m1")
    gid = make_group([uid_creator, uid_m1])
    set_device_token(uid_creator, f"tok-{uid_creator}")
    set_device_token(uid_m1, f"tok-{uid_m1}")
    past = datetime.now(tzmod.utc) - timedelta(minutes=1)
    session_id = make_session_direct(uid_creator, group_id=gid, title="Race Session", time_start=past)

    push = install_push()
    try:
        barrier = threading.Barrier(2)
        errors: list[Exception] = []

        def run_one():
            try:
                barrier.wait(timeout=5)
                asyncio.run(run_reminder_job())
            except Exception as e:
                errors.append(e)

        t1 = threading.Thread(target=run_one)
        t2 = threading.Thread(target=run_one)
        t1.start()
        t2.start()
        t1.join(timeout=30)
        t2.join(timeout=30)

        check("both concurrent poll-cycle threads completed without raising", not errors, str(errors))
        check("reminder_sent_at is set exactly once", get_reminder_sent_at(session_id) is not None,
              str(get_reminder_sent_at(session_id)))
        pushes_for_creator = [c for c in push.calls if c[0] == f"tok-{uid_creator}"]
        pushes_for_m1 = [c for c in push.calls if c[0] == f"tok-{uid_m1}"]
        check("creator got exactly one push despite two concurrent poll cycles",
              len(pushes_for_creator) == 1, str(pushes_for_creator))
        check("other member got exactly one push despite two concurrent poll cycles",
              len(pushes_for_m1) == 1, str(pushes_for_m1))
    finally:
        restore_push()
        cleanup(user_ids=[uid_creator, uid_m1], group_ids=[gid], session_ids=[session_id])


# ── 9/10: Graceful no-member / per-recipient-failure handling ──────────────

def test_reminder_job_no_notifiable_members_still_claims_gracefully():
    print("\n=== 9. A due session whose group has since been deleted (no notifiable member has "
          "a token) still gets claimed -- no crash, graceful no-op push-wise ===")
    uid_creator = make_user("remnomembers_creator")
    # Deliberately no device token for the creator. A real group is created
    # and referenced, then deleted before the job runs -- devotions.group_id
    # carries an ON DELETE SET NULL foreign key in this DB (confirmed via
    # pg_constraint), so this reproduces "the group has since been deleted"
    # exactly as it happens for real, not via an unreferenced fake id (which
    # the FK constraint itself would reject at insert time).
    gid = make_group([uid_creator])
    past = datetime.now(tzmod.utc) - timedelta(minutes=1)
    session_id = make_session_direct(uid_creator, group_id=gid, title="Orphaned Session", time_start=past)
    db = DBManager()
    try:
        db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        db.conn.commit()
    finally:
        db.close()

    push = install_push()
    try:
        asyncio.run(run_reminder_job())
        check("session is still claimed (reminder_sent_at set) even with nobody to notify",
              get_reminder_sent_at(session_id) is not None, str(get_reminder_sent_at(session_id)))
        check("no push was sent (creator had no token, and the group is gone)",
              push.calls == [], str(push.calls))
    finally:
        restore_push()
        cleanup(user_ids=[uid_creator], session_ids=[session_id])


def test_reminder_job_recipient_failure_is_isolated():
    print("\n=== 10. One member's reminder-push failure doesn't block another member's push, "
          "and the session is still correctly claimed ===")
    uid_creator = make_user("remfail_creator")
    uid_m1 = make_user("remfail_m1")
    gid = make_group([uid_creator, uid_m1])
    set_device_token(uid_creator, f"tok-{uid_creator}")
    set_device_token(uid_m1, f"tok-{uid_m1}")
    past = datetime.now(tzmod.utc) - timedelta(minutes=1)
    session_id = make_session_direct(uid_creator, group_id=gid, title="Partial Failure Reminder", time_start=past)

    push = install_push(fail_tokens={f"tok-{uid_creator}"})
    try:
        asyncio.run(run_reminder_job())
        check("session claimed despite one recipient's push failing",
              get_reminder_sent_at(session_id) is not None, str(get_reminder_sent_at(session_id)))
        tokens_pushed = {c[0] for c in push.calls}
        check("the OTHER member (whose push didn't fail) still got pushed",
              f"tok-{uid_m1}" in tokens_pushed, str(push.calls))
        check("the failing recipient's push is not in the successful-calls log",
              f"tok-{uid_creator}" not in tokens_pushed, str(push.calls))
    finally:
        restore_push()
        cleanup(user_ids=[uid_creator, uid_m1], group_ids=[gid], session_ids=[session_id])


# ── 11: Pre-deployment smoke test ───────────────────────────────────────────

def test_real_app_boots_with_session_reminder_job_registered(client):
    print("\n=== 11. Real app (main.app) boots, and session_reminder_fire is registered on the scheduler ===")
    check("main.app is importable and non-null", main_module.app is not None)
    # Reuses the already-entered lifespan (see the note above test 1) instead
    # of opening a second `with TestClient(...)` block.
    job_ids = {job.id for job in scheduler_module.scheduler.get_jobs()}
    check("session_reminder_fire job is registered on the scheduler",
          "session_reminder_fire" in job_ids, str(job_ids))


def main():
    try:
        # Reminder-job tests call the job function directly (no app boot
        # needed) and run first/standalone; the four creation-push tests plus
        # the smoke test share one real app lifespan (see note above test 1).
        test_reminder_job_fires_for_due_session_including_creator()
        test_reminder_job_leaves_not_yet_due_session_alone()
        test_reminder_job_does_not_double_fire_across_repeated_poll_cycles()
        test_reminder_job_does_not_double_fire_under_concurrent_polls()
        test_reminder_job_no_notifiable_members_still_claims_gracefully()
        test_reminder_job_recipient_failure_is_isolated()

        with TestClient(main_module.app) as client:
            test_creation_push_notifies_other_group_members_not_creator(client)
            test_creation_push_dm_session_notifies_the_other_participant(client)
            test_creation_push_no_tokens_fails_gracefully(client)
            test_creation_push_recipient_failure_does_not_abort_batch_or_create_call(client)
            test_real_app_boots_with_session_reminder_job_registered(client)
    finally:
        importlib.reload(push_module)  # restore the real send_push implementation

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
