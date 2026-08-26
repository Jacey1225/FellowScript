"""Tests for the activity-based notification system that replaced the
agentic/custom notification subsystem (see
.claude/pipeline/20260826-activity-based-notifications):

  1. Removal completeness — the old CRUD/trigger/next notification surface,
     its DB table, its module, and its subscription-limit resource are
     genuinely gone (not just unrouted), while the real app still boots and
     the retained device-token registration endpoint still works.
  2. Activity-tracking correctness — ActivityManager.record_activity's
     inactive->active transition detection and its dedup-marker reset/carry
     behavior.
  3. The IDOR fix in routes/notes.py — create_note/post_reply/highlight_verse
     record activity for the authenticated path user, never a client-supplied
     body field (this exact bug was fixed by this task's security gate).
  4. Each of the three fixed notifications' boundary/timing conditions and
     duplicate-fire prevention: midday no-activity reminder, >24h guilt
     reminder, friend-went-active.
  5. Cross-user authorization/privacy: friend-went-active only reaches real,
     unblocked friends (defense-in-depth block check independent of
     user_friends), given this exact subsystem's prior IDOR history.
  6. Push-delivery failure handling: a failed send_push must not mark a
     notification as sent (so it can retry), mirroring the old
     test_notification_write_failure.py's intent for the new system.

Run:  cd api && ../.venv/bin/python tests/test_activity_notifications.py
"""
import _pathfix  # noqa: F401,E402

import asyncio
import importlib
import os
import sys
import uuid
from datetime import date, datetime, timedelta, timezone as tzmod

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
from backend.interactions.activity import ActivityManager, INACTIVITY_THRESHOLD  # noqa: E402
import backend.interactions.scheduler as scheduler_module  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402
from schemas.subscription import FREE_LIMITS  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── Test fixtures ────────────────────────────────────────────────────────────

def make_user(prefix: str, tzname: str = "UTC") -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {
            "_id": uid, "username": f"{prefix}_{uid[:8]}",
            "email": f"{prefix}_{uid[:8]}@example.com",
            "hash_pass": "x", "timezone": tzname,
        })
    finally:
        db.close()
    return uid


def set_device_token(user_id: str, token: str) -> None:
    db = DBManager()
    try:
        db.insertion(
            "device_tokens", {"user_id": user_id, "token": token},
            conflict="(user_id) DO UPDATE SET token = EXCLUDED.token",
        )
    finally:
        db.close()


def make_friends(uid_a: str, uid_b: str) -> None:
    db = DBManager()
    try:
        db.insertion("user_friends", {"user_id": uid_a, "friend_id": uid_b})
        db.insertion("user_friends", {"user_id": uid_b, "friend_id": uid_a})
    finally:
        db.close()


def block(blocker_id: str, blocked_id: str) -> None:
    db = DBManager()
    try:
        db.insertion("blocked_users", {"blocker_id": blocker_id, "blocked_id": blocked_id})
    finally:
        db.close()


def get_activity_row(user_id: str):
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT last_activity_at, became_active_at, friend_notified_at, "
            "midday_reminder_sent_date, guilt_reminder_sent_at "
            "FROM user_activity WHERE user_id = %s",
            (user_id,),
        )
        return db.cur.fetchone()
    finally:
        db.close()


def set_activity_row(user_id: str, **cols) -> None:
    """Seed/overwrite user_activity columns directly, for boundary-condition
    setup that doesn't go through record_activity's transition logic."""
    db = DBManager()
    try:
        db.insertion("user_activity", {"user_id": user_id, **cols})
        if cols:
            set_clause = ", ".join(f"{c} = %s" for c in cols)
            db.cur.execute(
                f"UPDATE user_activity SET {set_clause} WHERE user_id = %s",
                list(cols.values()) + [user_id],
            )
            db.conn.commit()
    finally:
        db.close()


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            # notes.user_id has no ON DELETE CASCADE (bare REFERENCES,
            # pre-existing/unrelated to this task) -- clear owned notes
            # first so the user delete doesn't hit a FK violation.
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM highlights WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def cookie_header(token: str):
    return {"cookie": f"session={token}"} if token else {}


def signup(client, username):
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    })
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


# ── Fake / captured send_push ───────────────────────────────────────────────

class _CapturingPush:
    """Replaces backend.interactions.push.send_push. Records every call;
    per-token behavior configurable via `outcomes` (token -> "ok" | "fail" |
    "raise"), default "ok"."""

    def __init__(self):
        self.calls: list[tuple[str, str, str]] = []
        self.outcomes: dict[str, str] = {}

    async def __call__(self, token: str, title: str, body: str) -> bool:
        self.calls.append((token, title, body))
        outcome = self.outcomes.get(token, "ok")
        if outcome == "raise":
            raise RuntimeError("simulated APNs failure")
        return outcome == "ok"


class _FrozenDateTime(datetime):
    """Monkeypatch target for scheduler_module.datetime — only `.now()` is
    overridden; every other datetime behavior (astimezone, comparisons, etc.)
    is inherited unchanged since instances are real datetime objects."""
    _frozen: "datetime | None" = None

    @classmethod
    def now(cls, tz=None):
        assert cls._frozen is not None, "freeze() was not called"
        return cls._frozen.astimezone(tz) if tz is not None else cls._frozen


def freeze_scheduler_time(when: datetime) -> None:
    _FrozenDateTime._frozen = when
    scheduler_module.datetime = _FrozenDateTime


def unfreeze_scheduler_time() -> None:
    scheduler_module.datetime = datetime


# ── 1. Removal completeness ─────────────────────────────────────────────────

def test_removal_completeness(client: TestClient):
    print("=== 1. Removal completeness ===")

    check("real app (main.app) boots cleanly with the new routers wired in",
          main_module.app is not None)

    try:
        importlib.import_module("backend.interactions.notifications")
        check("backend.interactions.notifications module no longer exists", False,
              "import unexpectedly succeeded")
    except ModuleNotFoundError:
        check("backend.interactions.notifications module no longer exists", True)

    try:
        import schemas.notifications  # noqa: F401
        check("schemas.notifications module no longer exists", False, "import unexpectedly succeeded")
    except ModuleNotFoundError:
        check("schemas.notifications module no longer exists", True)

    db = DBManager()
    try:
        try:
            db.cur.execute("SELECT 1 FROM notifications LIMIT 1")
            db.cur.fetchall()
            check("`notifications` table no longer exists", False, "query unexpectedly succeeded")
        except Exception:
            db.conn.rollback()
            check("`notifications` table no longer exists", True)
    finally:
        db.close()

    check("`agent_notifications` resource removed from FREE_LIMITS",
          "agent_notifications" not in FREE_LIMITS, str(FREE_LIMITS))

    uid, token = signup(client, f"removal_{uuid.uuid4().hex[:8]}")
    try:
        # Old CRUD/trigger/next surface must be gone -- 404 (unrouted),
        # not 401/403/500 (which would imply the route still exists).
        for method, path in [
            ("GET", f"/notification/{uid}"),
            ("GET", f"/notification/{uid}/next"),
            ("POST", f"/notification/{uid}/{uuid.uuid4()}/trigger"),
            ("DELETE", f"/notification/{uid}/{uuid.uuid4()}"),
        ]:
            r = client.request(method, path, headers=cookie_header(token))
            check(f"old route gone: {method} {path} -> 404", r.status_code == 404,
                  f"{r.status_code} {r.text}")

        # The retained device-token registration endpoint must still work.
        r = client.post(f"/notification/{uid}/device-token", json={"token": "abc-token"},
                         headers=cookie_header(token))
        check("device-token registration endpoint still works -> 204", r.status_code == 204,
              f"{r.status_code} {r.text}")
    finally:
        cleanup(uid)


# ── 2. Activity-tracking correctness ────────────────────────────────────────

def test_activity_tracking():
    print("\n=== 2. Activity-tracking correctness (ActivityManager) ===")
    uid = make_user("activity")
    am = ActivityManager()
    try:
        t0 = datetime(2026, 1, 10, 12, 0, tzinfo=tzmod.utc)
        am.record_activity(uid, now=t0)
        row = get_activity_row(uid)
        check("first-ever activity is a transition (became_active_at set)",
              row is not None and row[1] == t0, str(row))
        check("fresh transition leaves friend_notified_at NULL (queues friend job)",
              row[2] is None, str(row))

        # Pretend the friend job already ran, and midday/guilt already fired,
        # for this transition.
        set_activity_row(uid, friend_notified_at=t0, midday_reminder_sent_date=t0.date(),
                          guilt_reminder_sent_at=t0)

        # A second activity shortly after (still inside the window) must NOT
        # be treated as a new transition, and must not disturb the
        # already-set dedup markers.
        t1 = t0 + timedelta(hours=1)
        am.record_activity(uid, now=t1)
        row2 = get_activity_row(uid)
        check("activity within the inactivity window is not a new transition",
              row2[1] == t0, str(row2))
        check("non-transition activity leaves friend_notified_at untouched (no re-notify)",
              row2[2] == t0, str(row2))
        check("non-transition activity leaves midday dedup marker untouched",
              row2[3] == t0.date(), str(row2))
        check("non-transition activity bumps last_activity_at",
              row2[0] == t1, str(row2))

        # A gap of longer than INACTIVITY_THRESHOLD is a real transition, and
        # must reset every dedup marker for the fresh activity window.
        t2 = t1 + INACTIVITY_THRESHOLD + timedelta(minutes=1)
        am.record_activity(uid, now=t2)
        row3 = get_activity_row(uid)
        check("activity after the inactivity threshold IS a new transition",
              row3[1] == t2, str(row3))
        check("real transition resets friend_notified_at to NULL", row3[2] is None, str(row3))
        check("real transition resets midday dedup marker to NULL", row3[3] is None, str(row3))
        check("real transition resets guilt dedup marker to NULL", row3[4] is None, str(row3))
    finally:
        am.close()
        cleanup(uid)


# ── 3. IDOR-fix regression: activity recorded for path user, not body field ─

def test_activity_idor_fix_regression(client: TestClient):
    print("\n=== 3. IDOR-fix regression: create_note/highlight/reply record activity "
          "for the authenticated user, never a client-forged body field ===")
    uid_a, token_a = signup(client, f"idor_a_{uuid.uuid4().hex[:8]}")
    uid_b, token_b = signup(client, f"idor_b_{uuid.uuid4().hex[:8]}")
    try:
        # Attacker (A) creates a note under their own path user_id, but
        # forges the body's "user" field to victim B -- the exact vector
        # the security gate fixed. Activity must land on A (the
        # authenticated path user), never on B.
        r = client.post(f"/notes/{uid_a}", json={
            "title": "t", "text": "body", "user": uid_b,
        }, headers=cookie_header(token_a))
        check("create_note with forged body.user succeeds (still A's own note)",
              r.status_code == 201, f"{r.status_code} {r.text}")

        row_a = get_activity_row(uid_a)
        row_b = get_activity_row(uid_b)
        check("activity recorded for the authenticated path user (A)", row_a is not None, str(row_a))
        check("victim B's activity untouched by A's forged body field", row_b is None, str(row_b))

        # highlight_verse: also keyed off the require_match-verified path
        # user_id, no body field to forge -- confirm it still records for
        # the right user.
        r = client.post(f"/notes/highlight/{uid_b}", json={
            "book": "Genesis", "chapter": 1, "verse": 1, "color": "#ff0000",
        }, headers=cookie_header(token_b))
        check("highlight_verse succeeds", r.status_code == 200, f"{r.status_code} {r.text}")
        row_b2 = get_activity_row(uid_b)
        check("highlight_verse records activity for its own path user (B)",
              row_b2 is not None, str(row_b2))
    finally:
        cleanup(uid_a, uid_b)


# ── 4a. Midday no-activity reminder ─────────────────────────────────────────

async def _run_midday():
    await scheduler_module._midday_no_activity_reminder()


def test_midday_reminder():
    print("\n=== 4a. Midday no-activity reminder ===")
    uid_none = make_user("midday_none")   # never active
    uid_today = make_user("midday_today")  # already active today
    uid_no_token = make_user("midday_notoken")

    set_device_token(uid_none, f"tok-{uid_none}")
    set_device_token(uid_today, f"tok-{uid_today}")
    # uid_no_token deliberately gets no device token.

    noon_utc = datetime(2026, 3, 10, 12, 0, tzinfo=tzmod.utc)
    set_activity_row(uid_today, last_activity_at=noon_utc - timedelta(hours=1))

    push = _CapturingPush()
    push_module.send_push = push
    freeze_scheduler_time(noon_utc)
    try:
        asyncio.run(_run_midday())

        tokens_pushed = {c[0] for c in push.calls}
        check("user with no activity yet today at local noon gets the midday push",
              f"tok-{uid_none}" in tokens_pushed, str(push.calls))
        check("user who already had activity today does NOT get the midday push",
              f"tok-{uid_today}" not in tokens_pushed, str(push.calls))
        check("user with no device token is skipped without error (no crash)",
              True)  # asyncio.run above would have raised if it crashed

        row = get_activity_row(uid_none)
        check("midday dedup marker recorded after a successful send",
              row is not None and row[3] == noon_utc.date(), str(row))

        # Re-run at the exact same frozen instant -- must not double-send.
        push.calls.clear()
        asyncio.run(_run_midday())
        check("re-running at the same local noon does not re-send (dedup)",
              f"tok-{uid_none}" not in {c[0] for c in push.calls}, str(push.calls))
    finally:
        unfreeze_scheduler_time()
        cleanup(uid_none, uid_today, uid_no_token)


# ── 4b. Guilt (>24h) reminder ───────────────────────────────────────────────

async def _run_guilt():
    await scheduler_module._guilt_no_activity_reminder()


def test_guilt_reminder():
    print("\n=== 4b. >24h guilt reminder ===")
    uid_stale = make_user("guilt_stale")     # inactive >24h
    uid_recent = make_user("guilt_recent")   # active within 24h
    uid_never = make_user("guilt_never")     # no user_activity row at all

    set_device_token(uid_stale, f"tok-{uid_stale}")
    set_device_token(uid_recent, f"tok-{uid_recent}")
    set_device_token(uid_never, f"tok-{uid_never}")

    now = datetime.now(tzmod.utc)
    set_activity_row(uid_stale, last_activity_at=now - INACTIVITY_THRESHOLD - timedelta(hours=1))
    set_activity_row(uid_recent, last_activity_at=now - timedelta(hours=1))
    # uid_never: no user_activity row inserted at all.

    push = _CapturingPush()
    push_module.send_push = push
    try:
        asyncio.run(_run_guilt())
        tokens_pushed = {c[0] for c in push.calls}
        check("user inactive >24h gets the guilt push", f"tok-{uid_stale}" in tokens_pushed, str(push.calls))
        check("user active within 24h does NOT get the guilt push",
              f"tok-{uid_recent}" not in tokens_pushed, str(push.calls))
        check("user with no activity ever recorded does NOT get the guilt push "
              "(no 'you stopped' moment yet)", f"tok-{uid_never}" not in tokens_pushed, str(push.calls))

        row = get_activity_row(uid_stale)
        check("guilt dedup marker recorded after a successful send", row is not None and row[4] is not None, str(row))

        # Re-run immediately -- must not double-send within the threshold window.
        push.calls.clear()
        asyncio.run(_run_guilt())
        check("re-running immediately after does not re-send (dedup)",
              f"tok-{uid_stale}" not in {c[0] for c in push.calls}, str(push.calls))
    finally:
        cleanup(uid_stale, uid_recent, uid_never)


# ── 4c. Friend-went-active + cross-user authorization ───────────────────────

async def _run_friend():
    await scheduler_module._friend_went_active_notify()


def test_friend_went_active():
    print("\n=== 4c. Friend-went-active + cross-user privacy scoping ===")
    uid_a = make_user("friend_a")
    uid_b = make_user("friend_b")   # A's real friend
    uid_c = make_user("friend_c")   # A's friend-list entry, but blocks A (defense-in-depth case)

    set_device_token(uid_b, f"tok-{uid_b}")
    set_device_token(uid_c, f"tok-{uid_c}")
    make_friends(uid_a, uid_b)
    # Simulate a stale/bypassed user_friends row alongside a real block --
    # BlockManager.block_user normally deletes both user_friends rows on
    # block, but the job's own re-check must exclude this recipient even if
    # that invariant were ever violated (the exact defense-in-depth the
    # security gate added).
    make_friends(uid_a, uid_c)
    block(uid_c, uid_a)

    am = ActivityManager()
    try:
        am.record_activity(uid_a)  # first-ever activity -> real transition
    finally:
        am.close()

    push = _CapturingPush()
    push_module.send_push = push
    try:
        asyncio.run(_run_friend())
        tokens_pushed = {c[0] for c in push.calls}
        check("A's real, unblocked friend (B) is notified of A going active",
              f"tok-{uid_b}" in tokens_pushed, str(push.calls))
        check("A's blocked-in-either-direction contact (C) is NOT notified "
              "even though a user_friends row exists", f"tok-{uid_c}" not in tokens_pushed, str(push.calls))

        row = get_activity_row(uid_a)
        check("transition marked as friend-notified after the job runs",
              row is not None and row[2] is not None, str(row))

        # Re-run with no new transition -- must not re-spam B.
        push.calls.clear()
        asyncio.run(_run_friend())
        check("re-running with no new transition does not re-notify friends",
              f"tok-{uid_b}" not in {c[0] for c in push.calls}, str(push.calls))
    finally:
        cleanup(uid_a, uid_b, uid_c)


def test_friend_went_active_partial_push_failure():
    print("\n=== 4c-cont. Friend-went-active tolerates one friend's push failing ===")
    uid_a = make_user("friend_fail_a")
    uid_b = make_user("friend_fail_b")  # push raises for this one
    uid_c = make_user("friend_fail_c")  # push succeeds

    tok_b, tok_c = f"tok-{uid_b}", f"tok-{uid_c}"
    set_device_token(uid_b, tok_b)
    set_device_token(uid_c, tok_c)
    make_friends(uid_a, uid_b)
    make_friends(uid_a, uid_c)

    am = ActivityManager()
    try:
        am.record_activity(uid_a)
    finally:
        am.close()

    push = _CapturingPush()
    push.outcomes[tok_b] = "raise"
    push_module.send_push = push
    try:
        asyncio.run(_run_friend())
        tokens_pushed = {c[0] for c in push.calls}
        check("push exception for one friend does not stop the other friend's push",
              tok_c in tokens_pushed, str(push.calls))
        row = get_activity_row(uid_a)
        check("transition still marked notified even after a per-friend push exception",
              row is not None and row[2] is not None, str(row))
    finally:
        cleanup(uid_a, uid_b, uid_c)


# ── 5. Push-delivery failure handling (midday/guilt) ────────────────────────

def test_push_failure_does_not_mark_sent():
    print("\n=== 5. A failed push must not mark the reminder as sent (retryable) ===")
    uid = make_user("pushfail_guilt")
    tok = f"tok-{uid}"
    set_device_token(uid, tok)
    now = datetime.now(tzmod.utc)
    set_activity_row(uid, last_activity_at=now - INACTIVITY_THRESHOLD - timedelta(hours=1))

    push = _CapturingPush()
    push.outcomes[tok] = "fail"
    push_module.send_push = push
    try:
        asyncio.run(_run_guilt())
        row = get_activity_row(uid)
        check("guilt dedup marker NOT set when send_push returns False (stays retryable)",
              row is not None and row[4] is None, str(row))
    finally:
        cleanup(uid)


def main():
    try:
        # Single shared TestClient/app lifespan for every HTTP-based test --
        # the scheduler is a module-level singleton, so a second independent
        # TestClient(main_module.app) lifespan in the same process fails
        # trying to re-register jobs against a closed event loop.
        with TestClient(main_module.app) as client:
            test_removal_completeness(client)
            test_activity_idor_fix_regression(client)
        test_activity_tracking()
        test_midday_reminder()
        test_guilt_reminder()
        test_friend_went_active()
        test_friend_went_active_partial_push_failure()
        test_push_failure_does_not_mark_sent()
    finally:
        importlib.reload(push_module)  # restore the real send_push implementation
        unfreeze_scheduler_time()

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
