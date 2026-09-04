"""Validation tests for the Discord-Dev-channel question: "do users get
notified when a friend creates/edits a note, highlights a verse, or messages
them?"

Originally this file only documented two gaps (see git history for the
pre-fix version). Both gaps have since been closed
(.claude/pipeline/20260901-friend-activity-notification-gaps); this file now
asserts the corrected behavior end-to-end (real Postgres, real routes via
TestClient, real ActivityManager/ConnectionManager/scheduler code). See
backend/interactions/activity.py, backend/interactions/scheduler.py
(_friend_went_active_notify), routes/notes.py, and
backend/interactions/websockets.py.

Behavior this file proves:

  1. Note CREATE: create_note calls ActivityManager.record_activity for the
     path user (routes/notes.py::_record_activity), persisting
     `last_activity_type=note_created`. The _friend_went_active_notify
     scheduled job (every 5 min in production) queues a content-aware
     "<username> created a new note." push -- but only on an inactive->active
     TRANSITION (first-ever activity, or a gap > INACTIVITY_THRESHOLD=24h). A
     second note created shortly after the first does NOT queue a second
     notification (dedup/transition semantics are unchanged by this fix).

  2. Note EDIT (PUT /notes/{user_id}?note_id=...): update_note now calls
     _record_activity(user_id, NOTE_EDITED) exactly like create_note/
     post_reply/highlight_verse -- closing the previous gap where edits never
     bumped user_activity or could notify at all. An edit shortly after
     other activity (same active window, not a fresh transition) still
     bumps last_activity_at/last_activity_type without re-queuing a
     notification, matching create's own dedup semantics; an edit that IS a
     genuine inactive->active transition queues a content-aware
     "<username> edited a note." push.

  3. Verse highlight: highlight_verse also calls _record_activity with
     VERSE_HIGHLIGHTED, so a qualifying transition now queues a
     content-aware "<username> highlighted a verse." push instead of the
     old generic text.

     None of the three notification bodies above ever include the note's
     title/text or the highlighted book/chapter/verse -- action-naming only.

  4. Direct message: ConnectionManager.send_msg (backend/interactions/
     websockets.py) is a real, immediate, per-message notification path --
     WebSocket delivery if the recipient is connected, else an APNs push
     carrying the actual message text/sender name. This one matches what
     the question assumes and is untouched by this fix.

Run:  cd api && ../.venv/bin/python tests/test_friend_activity_notification_paths.py
"""
import _pathfix  # noqa: F401,E402

import asyncio
import os
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone as tzmod

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
import backend.interactions.websockets as ws_module  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── Fixtures / helpers (mirrors test_activity_notifications.py /
#    test_friend_activity.py conventions) ───────────────────────────────────

def cookie_header(token: str | None):
    return {"cookie": f"session={token}"} if token else {}


_signup_counter = 0


def signup(client, prefix: str):
    """Distinct CF-Connecting-IP per signup so this file's handful of
    signups don't trip /signup's 5/minute per-IP rate limiter -- same
    technique as test_friend_activity.py."""
    global _signup_counter
    _signup_counter += 1
    fake_ip = f"203.0.114.{_signup_counter % 250 + 1}"
    username = f"{prefix}_{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com",
        "plain_pass": "TestPass123!", "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def make_friends(uid_a: str, uid_b: str) -> None:
    db = DBManager()
    try:
        db.insertion("user_friends", {"user_id": uid_a, "friend_id": uid_b})
        db.insertion("user_friends", {"user_id": uid_b, "friend_id": uid_a})
    finally:
        db.close()


def set_device_token(user_id: str, token: str) -> None:
    db = DBManager()
    try:
        db.insertion(
            "device_tokens", {"user_id": user_id, "token": token},
            conflict="(user_id) DO UPDATE SET token = EXCLUDED.token",
        )
    finally:
        db.close()


def get_activity_row(user_id: str):
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT last_activity_at, became_active_at, friend_notified_at, "
            "last_activity_type FROM user_activity WHERE user_id = %s",
            (user_id,),
        )
        return db.cur.fetchone()
    finally:
        db.close()


def push_activity_into_past(user_id: str, when) -> None:
    """Directly back-date user_activity's timestamps (and mark it
    already-notified) so the *next* real activity call is forced through a
    genuine inactive->active transition, without the test needing to sleep
    for INACTIVITY_THRESHOLD (24h). Mirrors test_friend_activity.py's
    approach of manipulating `user_activity` directly to control transition
    timing rather than relying on wall-clock time."""
    db = DBManager()
    try:
        db.cur.execute(
            "UPDATE user_activity SET last_activity_at = %s, became_active_at = %s, "
            "friend_notified_at = %s WHERE user_id = %s",
            (when, when, when, user_id),
        )
        db.conn.commit()
    finally:
        db.close()


def cleanup(*user_ids: str) -> None:
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM highlights WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM messages WHERE from_user = %s", (uid,))
            db.cur.execute("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM user_activity WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


class _CapturingPush:
    """Replaces backend.interactions.push.send_push / backend.interactions.
    websockets.send_push. Records every call. Same shape as
    test_activity_notifications.py's _CapturingPush."""

    def __init__(self):
        self.calls: list[tuple[str, str, str]] = []

    async def __call__(self, token: str, title: str, body: str, data: dict | None = None) -> bool:
        self.calls.append((token, title, body))
        return True


async def _run_friend_went_active():
    await scheduler_module._friend_went_active_notify()


# ── 1. Note CREATE: generic, transition-only, batched -- not per-note ──────

def test_note_create_triggers_content_aware_transition_notification(client):
    print("=== 1. Friend CREATES a note ===")
    uid_owner, token_owner = signup(client, "notecreate_owner")
    uid_friend, _ = signup(client, "notecreate_friend")
    try:
        make_friends(uid_owner, uid_friend)
        set_device_token(uid_friend, f"tok-{uid_friend}")

        # Owner is fresh (no user_activity row) -- first note is a real
        # inactive->active transition.
        r = client.post(f"/notes/{uid_owner}", json={
            "title": "Morning reflection", "text": "grateful today", "public": True,
        }, headers=cookie_header(token_owner))
        check("create_note succeeds", r.status_code == 201, f"{r.status_code} {r.text}")

        row = get_activity_row(uid_owner)
        check("create_note recorded activity + a transition (became_active_at set)",
              row is not None and row[1] is not None, str(row))
        check("transition queued (friend_notified_at is NULL, pending the scheduled job)",
              row is not None and row[2] is None, str(row))
        check("activity row records the note_created activity type",
              row is not None and row[3] == "note_created", str(row))

        push = _CapturingPush()
        push_module.send_push = push
        asyncio.run(_run_friend_went_active())

        check("friend receives a push after the scheduled job runs",
              len(push.calls) == 1 and push.calls[0][0] == f"tok-{uid_friend}", str(push.calls))
        check("the push names the action (created a new note) instead of the old "
              "generic 'came back' text, and does NOT leak the note's title/text",
              "Morning reflection" not in push.calls[0][2] and "grateful today" not in push.calls[0][2]
              and "created a new note" in push.calls[0][2]
              and "came back to FellowScript" not in push.calls[0][2],
              str(push.calls))

        # Creating a SECOND note right after does NOT queue a second
        # notification -- proves this is not a per-note-creation notification,
        # only a once-per-inactive->active-transition one.
        push.calls.clear()
        r2 = client.post(f"/notes/{uid_owner}", json={
            "title": "Second note", "text": "same day", "public": True,
        }, headers=cookie_header(token_owner))
        check("second create_note succeeds", r2.status_code == 201, f"{r2.status_code} {r2.text}")
        asyncio.run(_run_friend_went_active())
        check("a second note created within the same activity window does NOT "
              "queue/send another friend notification", push.calls == [], str(push.calls))
    finally:
        cleanup(uid_owner, uid_friend)


# ── 2. Note EDIT: now records activity, notifies content-aware on a real
#    transition, and still respects existing dedup semantics ──────────────

def test_note_edit_records_activity_and_notifies_content_aware(client):
    print("\n=== 2. Friend EDITS an existing note ===")
    uid_owner, token_owner = signup(client, "noteedit_owner")
    uid_friend, _ = signup(client, "noteedit_friend")
    try:
        make_friends(uid_owner, uid_friend)
        set_device_token(uid_friend, f"tok-{uid_friend}")

        r = client.post(f"/notes/{uid_owner}", json={
            "title": "Original title", "text": "original text", "public": True,
        }, headers=cookie_header(token_owner))
        check("initial create_note succeeds", r.status_code == 201, f"{r.status_code} {r.text}")
        note_id = r.json()["id"]

        # Drain/settle the create's own transition first so it can't be
        # mistaken for the edit's effect.
        push = _CapturingPush()
        push_module.send_push = push
        asyncio.run(_run_friend_went_active())
        push.calls.clear()

        row_before = get_activity_row(uid_owner)
        check("baseline: activity row exists after create, with the transition "
              "now marked notified", row_before is not None and row_before[2] is not None,
              str(row_before))

        # -- 2a. Edit shortly after create: same active window, NOT a fresh
        #    inactive->active transition. GAP FIX proof #1: update_note now
        #    calls _record_activity at all (previously it never did), so
        #    last_activity_at/last_activity_type move -- but since this isn't
        #    a real transition, became_active_at/friend_notified_at must stay
        #    exactly as the already-notified baseline (no regression to the
        #    existing dedup/transition semantics that test 1 also checks).
        r2 = client.put(
            f"/notes/{uid_owner}?note_id={note_id}",
            json={"title": "Edited title", "text": "edited text", "public": True},
            headers=cookie_header(token_owner),
        )
        check("update_note (edit) succeeds", r2.status_code == 200, f"{r2.status_code} {r2.text}")

        row_after_edit = get_activity_row(uid_owner)
        check("FIX: editing a note now bumps last_activity_at and records "
              "last_activity_type=note_edited -- update_note calls "
              "ActivityManager.record_activity same as create_note/post_reply/"
              "highlight_verse", row_after_edit is not None
              and row_after_edit[0] != row_before[0]
              and row_after_edit[3] == "note_edited",
              f"before={row_before} after={row_after_edit}")
        check("no regression: this edit is within the same already-notified "
              "active window, so became_active_at/friend_notified_at are "
              "unchanged (not treated as a fresh transition)",
              row_after_edit[1] == row_before[1] and row_after_edit[2] == row_before[2],
              f"before={row_before} after={row_after_edit}")

        asyncio.run(_run_friend_went_active())
        check("no friend notification fires for a same-window edit (matches "
              "test 1's same-window second-create dedup assertion)",
              push.calls == [], str(push.calls))

        # -- 2b. Force a genuine inactive->active transition via an edit (no
        #    note create involved) by back-dating the activity row past
        #    INACTIVITY_THRESHOLD, then editing again.
        push.calls.clear()
        push_activity_into_past(
            uid_owner, datetime.now(tzmod.utc) - (INACTIVITY_THRESHOLD + timedelta(hours=1)),
        )
        r3 = client.put(
            f"/notes/{uid_owner}?note_id={note_id}",
            json={"title": "Edited again", "text": "edited text v2", "public": True},
            headers=cookie_header(token_owner),
        )
        check("second update_note (edit) succeeds", r3.status_code == 200, f"{r3.status_code} {r3.text}")

        row_transition = get_activity_row(uid_owner)
        check("this edit IS a real inactive->active transition (became_active_at "
              "advanced, friend_notified_at reset to NULL, type=note_edited)",
              row_transition is not None and row_transition[1] != row_before[1]
              and row_transition[2] is None and row_transition[3] == "note_edited",
              str(row_transition))

        asyncio.run(_run_friend_went_active())
        check("FIX CONFIRMED: friend receives a content-aware 'edited a note' "
              "push for a note-edit transition, with no note title/text leaked",
              len(push.calls) == 1 and push.calls[0][0] == f"tok-{uid_friend}"
              and "edited a note" in push.calls[0][2]
              and "Edited again" not in push.calls[0][2] and "edited text v2" not in push.calls[0][2]
              and "came back to FellowScript" not in push.calls[0][2],
              str(push.calls))
    finally:
        cleanup(uid_owner, uid_friend)


# ── 3. Verse highlight: content-aware transition notification ──────────────

def test_highlight_verse_triggers_content_aware_transition_notification(client):
    print("\n=== 3. Friend HIGHLIGHTS a verse ===")
    uid_owner, token_owner = signup(client, "highlight_owner")
    uid_friend, _ = signup(client, "highlight_friend")
    try:
        make_friends(uid_owner, uid_friend)
        set_device_token(uid_friend, f"tok-{uid_friend}")

        r = client.post(f"/notes/highlight/{uid_owner}", json={
            "book": "John", "chapter": 3, "verse": 16, "color": "#00ff00",
        }, headers=cookie_header(token_owner))
        check("highlight_verse succeeds", r.status_code == 200, f"{r.status_code} {r.text}")

        row = get_activity_row(uid_owner)
        check("highlight_verse recorded activity + a transition",
              row is not None and row[1] is not None, str(row))
        check("activity row records the verse_highlighted activity type",
              row is not None and row[3] == "verse_highlighted", str(row))

        push = _CapturingPush()
        push_module.send_push = push
        asyncio.run(_run_friend_went_active())

        check("friend receives a push after the scheduled job runs",
              len(push.calls) == 1 and push.calls[0][0] == f"tok-{uid_friend}", str(push.calls))
        # Round 2 of task 20260904-friend-activity-push-triggers deliberately
        # reversed the prior "never mention the verse" contract asserted here:
        # a highlight notification now carries the real verse reference (and,
        # when bible_text can resolve it, the actual verse text) in the push
        # body -- see test_friend_activity_push_triggers.py for the fallback
        # cases (a text-lookup miss, and the highlight row itself being
        # unresolvable) this file doesn't cover.
        check("the push names the action and now includes the real verse "
              "reference (John 3:16) per the Round 2 content-aware decision, "
              "instead of the old fully-generic 'came back'/'highlighted a "
              "verse' text",
              "John" in push.calls[0][2] and "3:16" in push.calls[0][2]
              and "highlighted" in push.calls[0][2]
              and "came back to FellowScript" not in push.calls[0][2],
              str(push.calls))
    finally:
        cleanup(uid_owner, uid_friend)


# ── 4. Direct message: real, immediate, content-bearing notification ───────

def test_friend_message_delivers_live_and_offline(client):
    print("\n=== 4. Friend MESSAGES the user (online + offline) ===")
    uid_a, token_a = signup(client, "dm_a")
    uid_b, token_b = signup(client, "dm_b")
    try:
        make_friends(uid_a, uid_b)

        # -- 4a. B is online (live WebSocket) -- A's message must arrive on
        #    B's socket in real time, no push needed.
        marker_live = f"live-{uuid.uuid4().hex[:8]}"
        with client.websocket_connect(f"/message/ws/{uid_b}", headers=cookie_header(token_b)) as ws_b:
            with client.websocket_connect(f"/message/ws/{uid_a}", headers=cookie_header(token_a)) as ws_a:
                ws_a.send_json({
                    "from_user": uid_a, "to_users": [uid_b], "text": marker_live,
                    "group_id": None, "timestamp": datetime.now(tzmod.utc).isoformat(),
                })
                frame = ws_b.receive_json()
            check("B (online) receives A's message live over their own WebSocket, "
                  "with the real message text", frame.get("text") == marker_live, str(frame))
            check("delivered frame identifies the real sender", frame.get("from_user") == uid_a, str(frame))

        # -- 4b. B is offline -- A's message must fall through to a real APNs
        #    push carrying the actual message text (not a generic notice).
        set_device_token(uid_b, f"tok-{uid_b}")
        push = _CapturingPush()
        orig_send_push = ws_module.send_push
        ws_module.send_push = push
        try:
            marker_offline = f"offline-{uuid.uuid4().hex[:8]}"
            with client.websocket_connect(f"/message/ws/{uid_a}", headers=cookie_header(token_a)) as ws_a:
                ws_a.send_json({
                    "from_user": uid_a, "to_users": [uid_b], "text": marker_offline,
                    "group_id": None, "timestamp": datetime.now(tzmod.utc).isoformat(),
                })
                time.sleep(0.3)  # let the server-side coroutine dispatch + push

            check("B (offline) receives a real push containing the actual message text",
                  any(c[0] == f"tok-{uid_b}" and marker_offline in c[2] for c in push.calls),
                  str(push.calls))
        finally:
            ws_module.send_push = orig_send_push
    finally:
        cleanup(uid_a, uid_b)


def main():
    try:
        with TestClient(main_module.app) as client:
            test_note_create_triggers_content_aware_transition_notification(client)
            test_note_edit_records_activity_and_notifies_content_aware(client)
            test_highlight_verse_triggers_content_aware_transition_notification(client)
            test_friend_message_delivers_live_and_offline(client)
    finally:
        import importlib
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
