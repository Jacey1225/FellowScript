"""Tests for task 20260901-heartbeat-backend-scheduling, backend step 1:
`_fire_due_heartbeats` (api/backend/interactions/scheduler.py), the new
server-side cron job that fires heartbeats on a fixed schedule regardless of
whether any client ever foregrounds the app -- replacing the removed iOS
`HeartbeatScheduler.checkAndFire` client-side trigger.

This proves, against the REAL job function and a REAL Postgres DB (never a
mocked manager), the specific behaviors this task's acceptance criteria call
out:

  1. A heartbeat whose scheduled UTC HH:mm slot has already passed today
     fires (creates a note) even with zero client interaction -- the core
     "no device ever foregrounds the app" acceptance criterion.
  2. A heartbeat whose slot hasn't arrived yet today is left alone.
  3. Two overlapping/concurrent poll cycles for the same due heartbeat still
     produce exactly one fired note, network-wide -- the job's own
     candidate-selection query is only a pre-filter; commit_hb_response's
     atomic per-calendar-day `last_fired` claim is what actually prevents the
     double fire, and this must hold under real concurrency, not just
     sequential re-invocation.
  4. The same weekly notes-cap gate commit_heartbeat's route applies is also
     applied here, so firing server-side (with no client/route in the loop
     at all) can't let an at-cap free user mint unlimited notes.
  5. A malformed/unparseable time slot on one heartbeat is caught, logged,
     and skipped without aborting the rest of the poll cycle -- a due
     heartbeat for a different user in the same cycle must still fire.
  6. The fired-event push payload never carries prompt/note text in the
     alert title/body (per the push_content_policy decision) -- title is the
     agent's name (or a generic fallback when unnamed), body is a fixed
     generic string, and heartbeat_id/agent_id ride in `data` only.
  7. The real app (main.app) boots with `heartbeat_fire` registered as a
     scheduler job -- the pre-deployment smoke-test mandate for any change
     touching `start_scheduler`.

Extended for testing step 4's re-verification pass against the reworked
per-user-local-timezone due-detection (architecture.json's timezone_handling
revision, superseding the prior UTC-only implementation this suite
originally targeted):

  8. Two users in different timezones (Asia/Tokyo, UTC+9; America/Los_Angeles,
     UTC-7 under 2026 DST), at the SAME frozen instant, with stored HH:mm
     slots deliberately chosen so a naive fixed-UTC interpretation of "is it
     due" would get BOTH users wrong in opposite directions (one fired too
     early, one not fired when it should already have been) -- proving
     due-ness is resolved per-user-local, not against a shared UTC clock, and
     that each still fires exactly once.
  9. Day-boundary-crossing: a user whose local calendar day has already
     rolled over relative to UTC's calendar date (frozen instant chosen so
     the user's local `day` differs from the frozen UTC date's `day`) is
     scanned/indexed into the 31-slot `timestamps` array by their OWN local
     day-of-month, not UTC's -- and fires against that local day's slot.

Extended again for testing step 4's RE-VERIFY/EXTEND pass against the
async-blocking-fix rework (architecture.json's revision block,
2026-09-01): the shipped-then-corrected implementation had every sync
psycopg2 call in `_fire_due_heartbeats` -- and `commit_hb_response`'s own
internal blocking `requests.post(..., timeout=60)` LLM call -- running
unoffloaded on the process's single shared asyncio event loop, which would
have stalled every other coroutine (every other in-flight request, every
other scheduler job) for up to 60s per fire. The fix wraps each of those
calls in `loop.run_in_executor`. This suite's original tests above already
prove the fire still produces correct end results; they do NOT prove the
event loop stayed free *while* a fire was in progress -- a regression back
to an unoffloaded synchronous call would still pass every test above
(the final DB state is identical either way) while silently reintroducing
the production stall. Test 10 below closes that gap directly:

 10. Event-loop-responsiveness regression test: `AgentManager._call_api` is
     monkeypatched to synchronously `time.sleep()` for a fixed duration
     (standing in for a slow real LLM call), a due heartbeat fire is run,
     and a separate lightweight coroutine on the SAME event loop is polled
     throughout via `asyncio.sleep(0.05)` to record the wall-clock gap
     between its own consecutive wake-ups. If `commit_hb_response`'s
     internal `_call_api` call were ever run unoffloaded on the event loop
     (the exact bug this revision fixes), that probe coroutine could not be
     scheduled again until the blocking sleep finished, producing a single
     gap of roughly the full sleep duration. With the fix in place, the
     probe keeps waking up on schedule throughout, because the blocking
     call runs on a separate thread-pool worker thread instead.

Uses a monkeypatched `AgentManager._call_api` (same technique as
test_commit_heartbeat_idempotency.py / test_commit_heartbeat_notes_cap.py) so
no real LLM call is made, and a capturing fake `send_push` (same technique as
test_activity_notifications.py) so no real APNs call is made. Scheduler time
is frozen (same `_FrozenDateTime` monkeypatch technique as
test_activity_notifications.py) so due/not-due slots are deterministic
regardless of wall-clock time.

Run:  cd api && ../.venv/bin/python tests/test_heartbeat_backend_scheduling.py
"""
import _pathfix  # noqa: F401,E402

import asyncio
import importlib
import os
import sys
import uuid
from datetime import datetime, timezone as tzmod

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
from backend.interactions.agent import AgentManager  # noqa: E402
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


def make_user_with_timezone(prefix: str, tzname: str) -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {
            "_id": uid, "username": f"{prefix}_{uid[:8]}",
            "email": f"{prefix}_{uid[:8]}@example.com", "hash_pass": "x",
            "timezone": tzname,
        })
    finally:
        db.close()
    return uid


def make_agent(user_id: str, name: str = "") -> str:
    agent_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("agents", {
            "_id": agent_id, "user_id": user_id, "role": "", "chats": [], "name": name,
        })
    finally:
        db.close()
    return agent_id


def make_heartbeat(agent_id: str, user_id: str, timestamps: list) -> str:
    import json
    hb_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt) "
            "VALUES (%s, %s, %s, %s::jsonb, %s)",
            (hb_id, agent_id, user_id, json.dumps(timestamps), "Write a reflection on today."),
        )
        db.conn.commit()
    finally:
        db.close()
    return hb_id


def due_timestamps_for(now: datetime, hhmm: str) -> list:
    """A 31-slot timestamps array with only today's (now.day) slot set."""
    slots = [None] * 31
    slots[now.day - 1] = hhmm
    return slots


def due_timestamps_for_day(day: int, hhmm: str) -> list:
    """A 31-slot timestamps array with only the given day-of-month's slot
    set — used when the slot must be indexed by a LOCAL day-of-month that
    differs from the frozen UTC instant's own day-of-month."""
    slots = [None] * 31
    slots[day - 1] = hhmm
    return slots


def set_device_token(user_id: str, token: str) -> None:
    db = DBManager()
    try:
        db.insertion(
            "device_tokens", {"user_id": user_id, "token": token},
            conflict="(user_id) DO UPDATE SET token = EXCLUDED.token",
        )
    finally:
        db.close()


def insert_notes(user_id: str, count: int) -> None:
    db = DBManager()
    try:
        for i in range(count):
            db.insertion("notes", {
                "_id": str(uuid.uuid4()), "user_id": user_id,
                "title": f"n{i}", "text": "body", "public": False, "is_reply": False,
            })
    finally:
        db.close()


def get_last_fired(hb_id: str):
    db = DBManager()
    try:
        db.cur.execute("SELECT last_fired FROM agent_heartbeats WHERE _id = %s", (hb_id,))
        row = db.cur.fetchone()
        return row[0] if row else None
    finally:
        db.close()


def note_count_for_heartbeat(hb_id: str) -> int:
    db = DBManager()
    try:
        db.cur.execute("SELECT count(*) FROM agentic_context WHERE heartbeat_id = %s", (hb_id,))
        return db.cur.fetchone()[0]
    finally:
        db.close()


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))  # no cascade from users
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))      # cascades agents/hb/context/device_tokens
        db.conn.commit()
    finally:
        db.close()


# ── Fake / capturing send_push and frozen time (same techniques as
#    test_activity_notifications.py) ─────────────────────────────────────────

class _CapturingPush:
    def __init__(self):
        self.calls: list[tuple[str, str, str, dict | None]] = []

    async def __call__(self, token: str, title: str, body: str, data: dict | None = None) -> bool:
        self.calls.append((token, title, body, data))
        return True


class _FrozenDateTime(datetime):
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


def stub_call_api(self, agent_role, messages):
    return (
        '{"__action": "create_note", "title": "Reflection", '
        '"text": "Generated content.", "verses": []}'
    )


async def run_job():
    await scheduler_module._fire_due_heartbeats()


# ── 1. Due heartbeat fires with zero client interaction ─────────────────────

def test_due_heartbeat_fires_with_no_client_interaction():
    print("=== 1. Due heartbeat fires server-side with no client ever calling commit_heartbeat ===")
    now = datetime(2026, 3, 15, 14, 30, tzinfo=tzmod.utc)
    uid = make_user("hbdue")
    agent_id = make_agent(uid, name="Faith Tracker")
    hb_id = make_heartbeat(agent_id, uid, due_timestamps_for(now, "14:00"))  # slot already passed
    set_device_token(uid, f"tok-{uid}")
    push = _CapturingPush()
    push_module.send_push = push
    freeze_scheduler_time(now)
    try:
        asyncio.run(run_job())
        check("last_fired is set after the job fires the due heartbeat",
              get_last_fired(hb_id) is not None, str(get_last_fired(hb_id)))
        check("exactly one note was created with zero client interaction",
              note_count_for_heartbeat(hb_id) == 1, str(note_count_for_heartbeat(hb_id)))
        check("a push was sent to the owning user's device",
              any(c[0] == f"tok-{uid}" for c in push.calls), str(push.calls))
    finally:
        cleanup(uid)


# ── 2. Not-yet-due heartbeat is left alone ──────────────────────────────────

def test_not_yet_due_heartbeat_is_not_fired():
    print("\n=== 2. Heartbeat whose slot hasn't arrived yet today is left alone ===")
    now = datetime(2026, 3, 15, 14, 30, tzinfo=tzmod.utc)
    uid = make_user("hbfuture")
    agent_id = make_agent(uid, name="Evening Reflection")
    hb_id = make_heartbeat(agent_id, uid, due_timestamps_for(now, "23:59"))  # slot not reached yet
    set_device_token(uid, f"tok-{uid}")
    push = _CapturingPush()
    push_module.send_push = push
    freeze_scheduler_time(now)
    try:
        asyncio.run(run_job())
        check("last_fired stays NULL for a not-yet-due slot",
              get_last_fired(hb_id) is None, str(get_last_fired(hb_id)))
        check("no note was created for a not-yet-due slot",
              note_count_for_heartbeat(hb_id) == 0, str(note_count_for_heartbeat(hb_id)))
        check("no push was sent for a not-yet-due slot",
              not any(c[0] == f"tok-{uid}" for c in push.calls), str(push.calls))
    finally:
        cleanup(uid)


# ── 3. Concurrent poll cycles never double-fire the same heartbeat ─────────

def test_concurrent_poll_cycles_do_not_double_fire():
    print("\n=== 3. Two overlapping poll cycles for the same due heartbeat fire exactly once ===")
    now = datetime(2026, 3, 15, 14, 30, tzinfo=tzmod.utc)
    uid = make_user("hbrace")
    agent_id = make_agent(uid, name="Race Agent")
    hb_id = make_heartbeat(agent_id, uid, due_timestamps_for(now, "14:00"))
    set_device_token(uid, f"tok-{uid}")
    push = _CapturingPush()
    push_module.send_push = push
    freeze_scheduler_time(now)
    try:
        # A single asyncio event loop can't produce a genuine race here:
        # _fire_due_heartbeats' DB calls are synchronous (psycopg2) and only
        # yield to another coroutine at its `await send_push(...)` point,
        # which is already AFTER the claim has committed -- so
        # asyncio.gather(run_job(), run_job()) on one loop would just run
        # the two calls back-to-back, and the second's own candidate scan
        # would already exclude the now-claimed row by construction, never
        # actually exercising Postgres's row-lock arbitration on
        # commit_hb_response's UPDATE...WHERE...RETURNING claim. Two real OS
        # threads, each running its own event loop and its own DB
        # connections, are needed to genuinely overlap two poll cycles'
        # candidate scans before either has claimed -- the actual scenario
        # this acceptance criterion (a server poller racing a stale client,
        # or two overlapping poll cycles) describes.
        import threading

        barrier = threading.Barrier(2)
        errors: list[Exception] = []

        def run_one():
            try:
                barrier.wait(timeout=5)  # line both threads up to start together
                asyncio.run(run_job())
            except Exception as e:
                errors.append(e)

        t1 = threading.Thread(target=run_one)
        t2 = threading.Thread(target=run_one)
        t1.start()
        t2.start()
        t1.join(timeout=30)
        t2.join(timeout=30)
        check("both concurrent poll-cycle threads completed without raising",
              not errors, str(errors))
        check("exactly one note exists network-wide after two concurrent poll cycles",
              note_count_for_heartbeat(hb_id) == 1, str(note_count_for_heartbeat(hb_id)))
        pushes_for_user = [c for c in push.calls if c[0] == f"tok-{uid}"]
        check("exactly one push was sent despite two concurrent poll cycles",
              len(pushes_for_user) == 1, str(pushes_for_user))
    finally:
        cleanup(uid)


# ── 4. Notes-cap gate blocks server-side firing too ─────────────────────────

def test_notes_cap_blocks_server_side_firing():
    print("\n=== 4. A free user already at their notes cap is not fired for by the server job ===")
    now = datetime(2026, 3, 15, 14, 30, tzinfo=tzmod.utc)
    uid = make_user("hbcap")
    agent_id = make_agent(uid, name="Cap Agent")
    hb_id = make_heartbeat(agent_id, uid, due_timestamps_for(now, "14:00"))
    insert_notes(uid, 10)  # exactly at the free-plan cap
    set_device_token(uid, f"tok-{uid}")
    push = _CapturingPush()
    push_module.send_push = push
    freeze_scheduler_time(now)
    try:
        asyncio.run(run_job())
        check("last_fired stays NULL -- the cap gate runs before the claim",
              get_last_fired(hb_id) is None, str(get_last_fired(hb_id)))
        check("no note was created for an at-cap user",
              note_count_for_heartbeat(hb_id) == 0, str(note_count_for_heartbeat(hb_id)))
        check("no push was sent for a gated (non-)fire",
              not any(c[0] == f"tok-{uid}" for c in push.calls), str(push.calls))
    finally:
        cleanup(uid)


# ── 5. One user's malformed slot can't abort another user's due fire ───────

def test_malformed_slot_does_not_abort_the_whole_cycle():
    print("\n=== 5. A malformed time slot for one heartbeat doesn't stop a genuinely due "
          "heartbeat for another user in the same poll cycle ===")
    now = datetime(2026, 3, 15, 14, 30, tzinfo=tzmod.utc)
    uid_bad = make_user("hbbad")
    agent_bad = make_agent(uid_bad, name="Bad Agent")
    hb_bad = make_heartbeat(agent_bad, uid_bad, due_timestamps_for(now, "not-a-time"))

    uid_good = make_user("hbgood")
    agent_good = make_agent(uid_good, name="Good Agent")
    hb_good = make_heartbeat(agent_good, uid_good, due_timestamps_for(now, "14:00"))

    push = _CapturingPush()
    push_module.send_push = push
    freeze_scheduler_time(now)
    try:
        asyncio.run(run_job())
        check("the malformed-slot heartbeat is skipped, not fired",
              get_last_fired(hb_bad) is None, str(get_last_fired(hb_bad)))
        check("the malformed-slot heartbeat did not crash the cycle for other users -- "
              "the genuinely due heartbeat in the SAME cycle still fired",
              get_last_fired(hb_good) is not None, str(get_last_fired(hb_good)))
        check("exactly one note was created (for the good heartbeat only)",
              note_count_for_heartbeat(hb_good) == 1, str(note_count_for_heartbeat(hb_good)))
    finally:
        cleanup(uid_bad, uid_good)


# ── 6. Push payload never carries prompt/note content ──────────────────────

def test_push_payload_is_generic_and_carries_ids_in_data():
    print("\n=== 6. Fired-event push: alert has no prompt/note text; ids ride in `data` only ===")
    now = datetime(2026, 3, 15, 14, 30, tzinfo=tzmod.utc)

    uid_named = make_user("hbpushname")
    agent_named = make_agent(uid_named, name="Morning Devotion")
    hb_named = make_heartbeat(agent_named, uid_named, due_timestamps_for(now, "14:00"))
    set_device_token(uid_named, f"tok-{uid_named}")

    uid_unnamed = make_user("hbpushnoname")
    agent_unnamed = make_agent(uid_unnamed, name="")
    hb_unnamed = make_heartbeat(agent_unnamed, uid_unnamed, due_timestamps_for(now, "14:00"))
    set_device_token(uid_unnamed, f"tok-{uid_unnamed}")

    push = _CapturingPush()
    push_module.send_push = push
    freeze_scheduler_time(now)
    try:
        asyncio.run(run_job())

        named_call = next((c for c in push.calls if c[0] == f"tok-{uid_named}"), None)
        check("named agent's push exists", named_call is not None, str(push.calls))
        if named_call:
            _, title, body, data = named_call
            check("title is the agent's name, not a truncated prompt",
                  title == "Morning Devotion", title)
            check("body is the fixed generic string, not prompt/note content",
                  "reflection" not in body.lower() and "today" not in body.lower(), body)
            check("data carries the correct heartbeat_id", data is not None and data.get("heartbeat_id") == hb_named, str(data))
            check("data carries the correct agent_id", data is not None and data.get("agent_id") == agent_named, str(data))

        unnamed_call = next((c for c in push.calls if c[0] == f"tok-{uid_unnamed}"), None)
        check("unnamed agent's push exists", unnamed_call is not None, str(push.calls))
        if unnamed_call:
            _, title, body, data = unnamed_call
            check("unnamed agent falls back to a generic title, never blank",
                  title == "Scheduled Event", title)
            check("data still carries the correct ids for the unnamed-agent case",
                  data is not None and data.get("heartbeat_id") == hb_unnamed and data.get("agent_id") == agent_unnamed,
                  str(data))
    finally:
        cleanup(uid_named, uid_unnamed)


# ── 8. Cross-timezone divergence from naive UTC, both fire correctly ───────

def test_cross_timezone_users_diverge_from_naive_utc_but_fire_correctly():
    print("\n=== 8. Two users in different timezones, same frozen instant: due-ness "
          "diverges from a naive fixed-UTC read in OPPOSITE directions for each, "
          "but both resolve correctly under their own local calendar ===")
    now = datetime(2026, 3, 15, 14, 30, tzinfo=tzmod.utc)

    # Tokyo (UTC+9, no DST): local time is 23:30. A slot of "23:00" has
    # already passed locally and must fire -- but compared naively against
    # the frozen UTC instant (14:30), "23:00" hasn't arrived yet, so a
    # UTC-only implementation would WRONGLY leave this un-fired.
    uid_tokyo = make_user_with_timezone("hbtztokyo", "Asia/Tokyo")
    agent_tokyo = make_agent(uid_tokyo, name="Tokyo Agent")
    hb_tokyo = make_heartbeat(agent_tokyo, uid_tokyo, due_timestamps_for(now, "23:00"))
    set_device_token(uid_tokyo, f"tok-{uid_tokyo}")

    # Los Angeles (UTC-7 under 2026 DST): local time is 07:30. A slot of
    # "08:00" has NOT arrived yet locally and must NOT fire -- but compared
    # naively against the frozen UTC instant (14:30), "08:00" already
    # passed, so a UTC-only implementation would WRONGLY fire this early.
    uid_la = make_user_with_timezone("hbtzla", "America/Los_Angeles")
    agent_la = make_agent(uid_la, name="LA Agent")
    hb_la = make_heartbeat(agent_la, uid_la, due_timestamps_for(now, "08:00"))
    set_device_token(uid_la, f"tok-{uid_la}")

    push = _CapturingPush()
    push_module.send_push = push
    freeze_scheduler_time(now)
    try:
        asyncio.run(run_job())
        check("Tokyo user's past-local-time slot fires (naive UTC would have left it un-fired)",
              get_last_fired(hb_tokyo) is not None, str(get_last_fired(hb_tokyo)))
        check("exactly one note for the Tokyo heartbeat",
              note_count_for_heartbeat(hb_tokyo) == 1, str(note_count_for_heartbeat(hb_tokyo)))
        check("LA user's not-yet-local-time slot does NOT fire (naive UTC would have fired it early)",
              get_last_fired(hb_la) is None, str(get_last_fired(hb_la)))
        check("no note for the LA heartbeat yet",
              note_count_for_heartbeat(hb_la) == 0, str(note_count_for_heartbeat(hb_la)))
    finally:
        cleanup(uid_tokyo, uid_la)


# ── 9. Day-boundary crossing: indexed by local day-of-month, not UTC's ─────

def test_day_boundary_crossing_indexes_by_local_day_not_utc_day():
    print("\n=== 9. Day-boundary crossing: heartbeat is indexed/due-checked by the "
          "user's LOCAL day-of-month, not the frozen UTC instant's day-of-month ===")
    # Frozen UTC instant late enough (16:00 UTC) that Tokyo (UTC+9) has
    # already rolled over into the next calendar day (01:00 local, day 16)
    # while the UTC calendar date itself is still day 15.
    now = datetime(2026, 3, 15, 16, 0, tzinfo=tzmod.utc)
    uid = make_user_with_timezone("hbtzcross", "Asia/Tokyo")
    agent_id = make_agent(uid, name="Cross-Day Agent")
    # Slot set on LOCAL day 16 (not UTC day 15) — due since local time is 01:00.
    hb_id = make_heartbeat(agent_id, uid, due_timestamps_for_day(16, "00:30"))
    set_device_token(uid, f"tok-{uid}")
    push = _CapturingPush()
    push_module.send_push = push
    freeze_scheduler_time(now)
    try:
        asyncio.run(run_job())
        check("heartbeat indexed by the user's local day (16) fires even though "
              "the frozen UTC date is still day 15",
              get_last_fired(hb_id) is not None, str(get_last_fired(hb_id)))
        check("exactly one note created", note_count_for_heartbeat(hb_id) == 1,
              str(note_count_for_heartbeat(hb_id)))
    finally:
        cleanup(uid)


# ── 10. Event loop stays responsive during a slow/blocking LLM call ────────

def test_event_loop_stays_responsive_during_slow_llm_call():
    print("\n=== 10. Event loop stays responsive during a slow/blocking LLM call -- proving "
          "commit_hb_response's internal _call_api is actually offloaded via run_in_executor, "
          "not run synchronously on the shared event loop (async-blocking-fix revision) ===")
    import time as _time

    SLOW_SECONDS = 1.5
    PROBE_INTERVAL = 0.05

    def slow_call_api(self, agent_role, messages):
        _time.sleep(SLOW_SECONDS)  # stands in for a slow real requests.post(..., timeout=60)
        return (
            '{"__action": "create_note", "title": "Reflection", '
            '"text": "Generated content.", "verses": []}'
        )

    now = datetime(2026, 3, 15, 14, 30, tzinfo=tzmod.utc)
    uid = make_user("hbresponsive")
    agent_id = make_agent(uid, name="Responsive Agent")
    hb_id = make_heartbeat(agent_id, uid, due_timestamps_for(now, "14:00"))
    set_device_token(uid, f"tok-{uid}")
    push = _CapturingPush()
    push_module.send_push = push
    freeze_scheduler_time(now)

    original_call_api = AgentManager._call_api
    AgentManager._call_api = slow_call_api
    try:
        async def probe(stop_event, gaps):
            last = _time.monotonic()
            while not stop_event.is_set():
                await asyncio.sleep(PROBE_INTERVAL)
                now_mono = _time.monotonic()
                gaps.append(now_mono - last)
                last = now_mono

        async def run_with_probe():
            stop_event = asyncio.Event()
            gaps: list = []
            probe_task = asyncio.create_task(probe(stop_event, gaps))
            start = _time.monotonic()
            await scheduler_module._fire_due_heartbeats()
            elapsed = _time.monotonic() - start
            stop_event.set()
            await probe_task
            return gaps, elapsed

        gaps, elapsed = asyncio.run(run_with_probe())

        check(
            "sanity: the fire actually took roughly SLOW_SECONDS (the slow call really ran)",
            elapsed >= SLOW_SECONDS * 0.8, f"elapsed={elapsed:.3f}",
        )
        check(
            "the responsiveness probe kept waking up throughout the slow call -- "
            "several probe iterations completed during the fire, not just before/after it",
            len(gaps) >= 5, f"gaps={gaps}",
        )
        max_gap = max(gaps) if gaps else float("inf")
        check(
            f"no single gap between probe wake-ups approaches SLOW_SECONDS "
            f"(max_gap={max_gap:.3f}s, SLOW_SECONDS={SLOW_SECONDS}s) -- proves the event loop "
            "was never blocked solid for the LLM call's duration; a regression back to an "
            "unoffloaded synchronous commit_hb_response call would show a single ~SLOW_SECONDS "
            "gap here instead",
            max_gap < SLOW_SECONDS * 0.5,
            f"max_gap={max_gap} gaps={gaps}",
        )
        check("the heartbeat still fired correctly despite the slow (offloaded) call",
              get_last_fired(hb_id) is not None, str(get_last_fired(hb_id)))
        check("exactly one note created", note_count_for_heartbeat(hb_id) == 1,
              str(note_count_for_heartbeat(hb_id)))
    finally:
        AgentManager._call_api = original_call_api
        cleanup(uid)


# ── 7. Pre-deployment smoke test: real app boots with the job registered ───

def test_real_app_boots_with_heartbeat_job_registered():
    print("\n=== 7. Real app (main.app) boots (lifespan startup runs start_scheduler), "
          "and heartbeat_fire is registered on the scheduler ===")
    check("main.app is importable and non-null", main_module.app is not None)
    # TestClient's context manager drives the real ASGI lifespan (startup +
    # shutdown), which is what actually calls start_scheduler() -- importing
    # main_module alone does not, so job registration must be checked inside
    # this context, not against a bare import.
    with TestClient(main_module.app):
        job_ids = {job.id for job in scheduler_module.scheduler.get_jobs()}
        check("heartbeat_fire job is registered on the scheduler",
              "heartbeat_fire" in job_ids, str(job_ids))


def main():
    original_call_api = AgentManager._call_api
    AgentManager._call_api = stub_call_api
    try:
        test_due_heartbeat_fires_with_no_client_interaction()
        test_not_yet_due_heartbeat_is_not_fired()
        test_concurrent_poll_cycles_do_not_double_fire()
        test_notes_cap_blocks_server_side_firing()
        test_malformed_slot_does_not_abort_the_whole_cycle()
        test_push_payload_is_generic_and_carries_ids_in_data()
        test_cross_timezone_users_diverge_from_naive_utc_but_fire_correctly()
        test_day_boundary_crossing_indexes_by_local_day_not_utc_day()
        test_event_loop_stays_responsive_during_slow_llm_call()
        test_real_app_boots_with_heartbeat_job_registered()
    finally:
        AgentManager._call_api = original_call_api
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
