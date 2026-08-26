"""Regression coverage for task 20260825-scheduled-event-duplicate-fire,
backend step 1's fix to AgentManager.commit_hb_response's idempotency guard
(api/backend/interactions/agent.py).

Before the fix, the claim UPDATE's WHERE clause was a rolling 2-minute
window:

    WHERE _id = %s AND (last_fired IS NULL OR last_fired < NOW() - INTERVAL '2 minutes')

Heartbeats fire client-side only (iOS HeartbeatScheduler.checkAndFire calls
this on every app foreground — there is no server-side cron for heartbeats),
so a user backgrounding/reopening the app more than 2 minutes after the
event's first same-day fire would have their second commit_heartbeat call
re-claim the row, producing a second saved note and a second "Event Response
Saved" notification for the same calendar day — the exact bug reported in
this task's intake spec.

The fix replaced the rolling window with a calendar-day boundary check
(UTC date comparison on last_fired), so:
  1. The first commit of the day succeeds and creates exactly one note.
  2. ANY later same-day call — even one deliberately placed more than 2
     minutes after the first (the old window's exact blind spot) — is
     skipped and creates no second note.
  3. A call on a genuinely later calendar day (last_fired's UTC date is in
     the past relative to today) still succeeds normally — the legitimate
     once-per-day cadence is not regressed.

Uses a FakeManager subclass to stub _call_api (as test_agent_context.py
does), so no real LLM call is made and the test is deterministic.

Run:  cd api && ../.venv/bin/python tests/test_commit_heartbeat_idempotency.py
"""
import _pathfix  # noqa: F401

import uuid

from db import DBManager
from backend.interactions.agent import AgentManager

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


class FakeManager(AgentManager):
    """Stubs the LLM call so commit_hb_response is fully exercised (ownership
    check, idempotency claim, note creation, context save) without ever
    hitting the real OpenRouter API."""

    def _call_api(self, agent_role, messages):
        return (
            '{"__action": "create_note", "title": "Reflection", '
            '"text": "Generated content.", "verses": []}'
        )


def make_user() -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"hbidem_{uid[:8]}",
                               "email": f"hbidem_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()
    return uid


def make_agent(user_id: str) -> str:
    agent_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("agents", {"_id": agent_id, "user_id": user_id, "role": "", "chats": []})
    finally:
        db.close()
    return agent_id


def make_heartbeat(agent_id: str, user_id: str) -> str:
    hb_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt) "
            "VALUES (%s, %s, %s, %s::jsonb, %s)",
            (hb_id, agent_id, user_id, "[]", "Write a reflection."),
        )
        db.conn.commit()
    finally:
        db.close()
    return hb_id


def note_count_for_heartbeat(hb_id: str) -> int:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT count(*) FROM agentic_context WHERE heartbeat_id = %s", (hb_id,)
        )
        return db.cur.fetchone()[0]
    finally:
        db.close()


def set_last_fired(hb_id: str, sql_expr: str):
    """Directly back-date agent_heartbeats.last_fired using a raw SQL
    expression (e.g. "NOW() - INTERVAL '3 minutes'" or "NOW() - INTERVAL
    '1 day'") so tests can simulate "already fired N ago" without sleeping."""
    db = DBManager()
    try:
        db.cur.execute(
            f"UPDATE agent_heartbeats SET last_fired = {sql_expr} WHERE _id = %s", (hb_id,)
        )
        db.conn.commit()
    finally:
        db.close()


def cleanup(user_id: str):
    db = DBManager()
    try:
        db.delete("notes", {"user_id": user_id})
        db.delete("users", {"_id": user_id})  # cascades agents/heartbeats/context
    finally:
        db.close()


def main():
    uid = make_user()
    agent_id = make_agent(uid)

    try:
        print("=== 1. First commit of the day succeeds and creates exactly one note ===")
        hb_id = make_heartbeat(agent_id, uid)
        manager = FakeManager(uid)
        result1 = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        check("first call reports success", result1 == {"success": "saved note"}, str(result1))
        check("exactly one note/context row exists after first call",
              note_count_for_heartbeat(hb_id) == 1, str(note_count_for_heartbeat(hb_id)))

        print("\n=== 2. Immediate second call the same day is skipped, no second note ===")
        result2 = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        check("immediate retry is skipped", result2 == {"skipped": "already fired today"}, str(result2))
        check("still exactly one note/context row (no duplicate)",
              note_count_for_heartbeat(hb_id) == 1, str(note_count_for_heartbeat(hb_id)))

        print("\n=== 3. Reopen >2 minutes later, same calendar day — THE reported bug's exact "
              "gap in the old rolling-window guard — still skipped, no second note ===")
        hb_id2 = make_heartbeat(agent_id, uid)
        manager2 = FakeManager(uid)
        result3 = manager2.commit_hb_response(agent_id, hb_id2, "Reflect on today.")
        check("first fire of hb_id2 succeeds", result3 == {"success": "saved note"}, str(result3))
        check("exactly one note for hb_id2 after first fire",
              note_count_for_heartbeat(hb_id2) == 1, str(note_count_for_heartbeat(hb_id2)))

        # Back-date last_fired to 3 minutes ago (same UTC calendar day). Under
        # the OLD rolling 2-minute-window guard, this WOULD have re-claimed
        # the row (3 minutes > the 2-minute window) and created a second
        # note — this is the exact scenario the intake spec reports.
        set_last_fired(hb_id2, "NOW() - INTERVAL '3 minutes'")
        result4 = manager2.commit_hb_response(agent_id, hb_id2, "Reflect on today.")
        check(
            "reopen 3 minutes later (same day) is skipped — proves the fix; "
            "the old 2-minute rolling window would have let this re-fire",
            result4 == {"skipped": "already fired today"}, str(result4),
        )
        check("still exactly one note for hb_id2 (no duplicate from the >2-minute-later reopen)",
              note_count_for_heartbeat(hb_id2) == 1, str(note_count_for_heartbeat(hb_id2)))

        # Even further out same day — pin last_fired to the very start of
        # today's UTC calendar day (00:00:00 UTC) rather than a fixed
        # "N hours ago" offset. A fixed hour offset (e.g. "10 hours ago")
        # is flaky: it crosses into the *previous* UTC day whenever the test
        # happens to run within the first N hours after UTC midnight, which
        # would make this assertion fail for a reason that has nothing to do
        # with the guard being tested. Truncating must go via "AT TIME ZONE
        # 'UTC'" explicitly (not bare date_trunc('day', NOW())) because the
        # DB session's own timezone is not necessarily UTC (this environment's
        # session runs in America/Los_Angeles) — a bare date_trunc truncates
        # to midnight in the *session's* timezone, not UTC midnight, which
        # reintroduced the exact same flakiness one layer down. The
        # AT TIME ZONE 'UTC' ... AT TIME ZONE 'UTC' round-trip converts NOW()
        # to a naive UTC wall-clock value, truncates that to its day boundary,
        # then reinterprets it as UTC to get back a correct timestamptz — always
        # on today's UTC date regardless of wall-clock time or session
        # timezone, proving the guard is a calendar-day boundary, not merely a
        # slightly longer rolling window.
        set_last_fired(hb_id2, "date_trunc('day', NOW() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'")
        result5 = manager2.commit_hb_response(agent_id, hb_id2, "Reflect on today.")
        check("reopen at the start of today's UTC day is still skipped",
              result5 == {"skipped": "already fired today"}, str(result5))
        check("still exactly one note for hb_id2",
              note_count_for_heartbeat(hb_id2) == 1, str(note_count_for_heartbeat(hb_id2)))

        print("\n=== 4. Legitimate next-day fire still succeeds (no regression to once-per-day cadence) ===")
        # One second before the start of today's UTC day is guaranteed to be
        # on yesterday's UTC date regardless of wall-clock time (unlike a
        # fixed "NOW() - INTERVAL '1 day'" offset, which is always exactly 24
        # hours back and so isn't actually the source of the flakiness here,
        # but this keeps the anchor consistent with the fix above).
        set_last_fired(hb_id2, "date_trunc('day', NOW() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - INTERVAL '1 second'")
        result6 = manager2.commit_hb_response(agent_id, hb_id2, "Reflect on today.")
        check("a call on the next calendar day succeeds",
              result6 == {"success": "saved note"}, str(result6))
        check("a second note now exists for hb_id2 (one per legitimate day)",
              note_count_for_heartbeat(hb_id2) == 2, str(note_count_for_heartbeat(hb_id2)))

        print("\n=== 5. Unowned heartbeat is still rejected before any claim/LLM call ===")
        other_uid = make_user()
        try:
            other_manager = FakeManager(other_uid)
            result7 = other_manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
            check("cross-user commit is rejected", result7 == {"error": "heartbeat not found"}, str(result7))
            check("no extra note created for hb_id via cross-user attempt",
                  note_count_for_heartbeat(hb_id) == 1, str(note_count_for_heartbeat(hb_id)))
        finally:
            cleanup(other_uid)

    finally:
        cleanup(uid)

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
