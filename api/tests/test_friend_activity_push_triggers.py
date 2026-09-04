"""Tests for task 20260904-friend-activity-push-triggers (backend step 1 /
security step 2), covering the behavior the testing gate was flagged about
that wasn't covered by pre-existing test files:

  1. NOTE_REPLIED push wording -- names the replied-to note's owner, and its
     safe generic fallback when the parent note/owner can't be resolved
     (never raises, never aborts the batch).
  2. VERSE_HIGHLIGHTED push wording -- real verse text is composed via
     bible_text.verse_text; on a text-lookup miss it falls back to a
     reference-only body, and on the highlight row itself being unresolvable
     it falls back to the fully-generic "highlighted a verse." text. Neither
     fallback raises or aborts the batch.
  3. FriendsManager.get_friend_activity's new highlight_preview/activity_type
     fields respect block logic in both directions, mirroring
     test_friend_activity.py's existing note_preview/friend_device_tokens
     block-scoping coverage.
  4. No note/highlight/verse content leaks into any log line emitted by
     _friend_went_active_notify, even though the push body now intentionally
     carries real verse text (Security Posture Q13: redaction applies to
     logs, not to this now-intentionally-user-facing surface).
  5. is_valid_reference / highlight_verse's new 400 on a malformed or
     out-of-range book/chapter/verse reference (security gate's fix).

Run:  cd api && ../.venv/bin/python tests/test_friend_activity_push_triggers.py
"""
import _pathfix  # noqa: F401,E402

import asyncio
import logging
import os
import sys
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
import backend.interactions.bible_text as bible_text_module  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── Fixtures / helpers (mirrors test_friend_activity_notification_paths.py /
#    test_friend_activity.py conventions) ────────────────────────────────────

def cookie_header(token: str | None):
    return {"cookie": f"session={token}"} if token else {}


_signup_counter = 0


def signup(client, prefix: str):
    global _signup_counter
    _signup_counter += 1
    fake_ip = f"203.0.115.{_signup_counter % 250 + 1}"
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


def block(blocker_id: str, blocked_id: str) -> None:
    db = DBManager()
    try:
        db.insertion("blocked_users", {"blocker_id": blocker_id, "blocked_id": blocked_id})
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


def get_activity(client, user_id, token):
    return client.get(f"/friends/{user_id}/activity", headers=cookie_header(token))


def create_group(client, token, owner_id, member_ids):
    """A reply's author must satisfy _can_view_note (owner or shared-group
    member) on the parent -- a bare personal note the replier neither owns
    nor shares a group with returns the generic "cannot find note" 200 body,
    not a 201. Mirrors test_friend_activity.py's own create_group helper."""
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner_id}", json={
        "group_id": gid, "title": "Test Group", "users": [owner_id] + member_ids,
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def delete_group(gid: str) -> None:
    db = DBManager()
    try:
        db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        db.conn.commit()
    finally:
        db.close()


def delete_note(note_id: str) -> None:
    """Simulates a parent note going away between a reply being posted and
    the (async, batched) friend-went-active job later reading it -- e.g. the
    owner deleted it. FK on notes.parent_note_id has no cascade here (the
    reply row itself is untouched); this only removes the parent."""
    db = DBManager()
    try:
        db.cur.execute("DELETE FROM notes WHERE _id = %s", (note_id,))
        db.conn.commit()
    finally:
        db.close()


def delete_all_highlights(user_id: str) -> None:
    """Simulates the highlight row itself becoming unresolvable (e.g. removed)
    between highlight_verse recording the activity and the job later reading
    it back via most_recent_highlight."""
    db = DBManager()
    try:
        db.cur.execute("DELETE FROM highlights WHERE user_id = %s", (user_id,))
        db.conn.commit()
    finally:
        db.close()


def cleanup(*user_ids: str) -> None:
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM highlights WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM user_activity WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


class _CapturingPush:
    def __init__(self):
        self.calls: list[tuple[str, str, str]] = []

    async def __call__(self, token: str, title: str, body: str, data: dict | None = None) -> bool:
        self.calls.append((token, title, body))
        return True


class _CapturingLogHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records: list[str] = []

    def emit(self, record):
        self.records.append(self.format(record))


async def _run_friend_went_active():
    await scheduler_module._friend_went_active_notify()


# ── 1. NOTE_REPLIED: names the owner, safe fallback on unresolvable parent ──

def test_note_replied_push_names_owner(client):
    print("=== 1. NOTE_REPLIED push names the replied-to note's owner ===")
    uid_owner, token_owner = signup(client, "replywire_owner")
    uid_replier, token_replier = signup(client, "replywire_replier")
    uid_watcher, _ = signup(client, "replywire_watcher")
    gid = None
    try:
        make_friends(uid_replier, uid_watcher)
        set_device_token(uid_watcher, f"tok-{uid_watcher}")
        # _can_view_note requires ownership or shared group membership --
        # a bare personal note isn't reply-able by uid_replier, so post it
        # into a group both share.
        gid = create_group(client, token_owner, uid_owner, [uid_replier])

        r = client.post(f"/notes/{uid_owner}", json={
            "title": "Owner's note", "text": "owner content", "public": True, "group_id": gid,
        }, headers=cookie_header(token_owner))
        check("owner's note created", r.status_code == 201, f"{r.status_code} {r.text}")
        note_id = r.json()["id"]

        r2 = client.post(f"/notes/reply/{note_id}", json={
            "user": uid_replier, "title": "A reply", "text": "reply content",
            "public": True, "group_id": gid,
        }, headers=cookie_header(token_replier))
        check("reply posted", r2.status_code == 201, f"{r2.status_code} {r2.text}")

        push = _CapturingPush()
        push_module.send_push = push
        asyncio.run(_run_friend_went_active())

        check("watcher receives a push for the replier's transition",
              len(push.calls) == 1 and push.calls[0][0] == f"tok-{uid_watcher}", str(push.calls))
        body = push.calls[0][2] if push.calls else ""
        check("push names the parent note's owner by username, not a generic reply text",
              "replied to" in body and uid_owner not in body, body)
        check("push does not leak reply/note title or text content",
              "A reply" not in body and "reply content" not in body
              and "Owner's note" not in body and "owner content" not in body,
              body)
    finally:
        if gid:
            delete_group(gid)
        cleanup(uid_owner, uid_replier, uid_watcher)


def test_note_replied_falls_back_when_parent_note_unresolvable(client):
    print("\n=== 1b. NOTE_REPLIED falls back to generic text when the parent note is gone ===")
    uid_owner, token_owner = signup(client, "replyfb_owner")
    uid_replier, token_replier = signup(client, "replyfb_replier")
    uid_watcher, _ = signup(client, "replyfb_watcher")
    gid = None
    try:
        make_friends(uid_replier, uid_watcher)
        set_device_token(uid_watcher, f"tok-{uid_watcher}")
        gid = create_group(client, token_owner, uid_owner, [uid_replier])

        r = client.post(f"/notes/{uid_owner}", json={
            "title": "Soon deleted", "text": "will vanish", "public": True, "group_id": gid,
        }, headers=cookie_header(token_owner))
        note_id = r.json()["id"]

        r2 = client.post(f"/notes/reply/{note_id}", json={
            "user": uid_replier, "title": "A reply", "text": "reply content",
            "public": True, "group_id": gid,
        }, headers=cookie_header(token_replier))
        check("reply posted", r2.status_code == 201, f"{r2.status_code} {r2.text}")

        # Simulate the parent note disappearing before the batched job runs.
        delete_note(note_id)

        push = _CapturingPush()
        push_module.send_push = push
        asyncio.run(_run_friend_went_active())

        check("job does not crash/abort when the parent note can't be resolved -- "
              "watcher still receives a push", len(push.calls) == 1, str(push.calls))
        body = push.calls[0][2] if push.calls else ""
        check("falls back to the generic 'replied to a note.' text, no owner name/content leaked",
              body.endswith("replied to a note.") and "Soon deleted" not in body
              and "reply content" not in body,
              body)
    finally:
        if gid:
            delete_group(gid)
        cleanup(uid_owner, uid_replier, uid_watcher)


# ── 2. VERSE_HIGHLIGHTED: real verse text, and both fallback tiers ──────────

def test_verse_highlighted_falls_back_to_reference_only_on_text_lookup_miss(client):
    print("\n=== 2a. VERSE_HIGHLIGHTED falls back to reference-only text on a bible_text miss ===")
    uid_owner, token_owner = signup(client, "hlmiss_owner")
    uid_watcher, _ = signup(client, "hlmiss_watcher")
    try:
        make_friends(uid_owner, uid_watcher)
        set_device_token(uid_watcher, f"tok-{uid_watcher}")

        r = client.post(f"/notes/highlight/{uid_owner}", json={
            "book": "John", "chapter": 3, "verse": 16, "color": "#00ff00",
        }, headers=cookie_header(token_owner))
        check("highlight_verse succeeds", r.status_code == 200, f"{r.status_code} {r.text}")

        orig_verse_text = bible_text_module.verse_text
        bible_text_module.verse_text = lambda book, chapter, verse: None
        try:
            push = _CapturingPush()
            push_module.send_push = push
            asyncio.run(_run_friend_went_active())
        finally:
            bible_text_module.verse_text = orig_verse_text

        check("watcher still receives a push despite the text-lookup miss",
              len(push.calls) == 1, str(push.calls))
        body = push.calls[0][2] if push.calls else ""
        check("reference-only fallback names John 3:16 but carries no quoted verse text",
              "John" in body and "3:16" in body and '"' not in body,
              body)
    finally:
        cleanup(uid_owner, uid_watcher)


def test_verse_highlighted_falls_back_to_generic_when_highlight_row_unresolvable(client):
    print("\n=== 2b. VERSE_HIGHLIGHTED falls back to fully-generic text when the highlight row is gone ===")
    uid_owner, token_owner = signup(client, "hlgone_owner")
    uid_watcher, _ = signup(client, "hlgone_watcher")
    try:
        make_friends(uid_owner, uid_watcher)
        set_device_token(uid_watcher, f"tok-{uid_watcher}")

        r = client.post(f"/notes/highlight/{uid_owner}", json={
            "book": "Genesis", "chapter": 1, "verse": 1, "color": "#00ff00",
        }, headers=cookie_header(token_owner))
        check("highlight_verse succeeds", r.status_code == 200, f"{r.status_code} {r.text}")

        # Simulate the highlight row itself vanishing before the batched job
        # runs -- most_recent_highlight can't resolve any (book, chapter,
        # verse) reference at all, distinct from a resolved-reference-but-
        # no-text miss covered above.
        delete_all_highlights(uid_owner)

        push = _CapturingPush()
        push_module.send_push = push
        asyncio.run(_run_friend_went_active())

        check("job does not crash/abort when the highlight row can't be resolved -- "
              "watcher still receives a push", len(push.calls) == 1, str(push.calls))
        body = push.calls[0][2] if push.calls else ""
        check("falls back to the fully-generic 'highlighted a verse.' text, no reference leaked",
              body.endswith("highlighted a verse.") and "Genesis" not in body and "1:1" not in body,
              body)
    finally:
        cleanup(uid_owner, uid_watcher)


# ── 3. No log leak, even though the push body now carries real content ─────

def test_friend_went_active_job_never_logs_note_or_verse_content(client):
    print("\n=== 3. No note/verse content ever reaches a log line in the friend-went-active job ===")
    uid_highlighter, token_highlighter = signup(client, "nolog_hl")
    uid_owner, token_owner = signup(client, "nolog_owner")
    uid_replier, token_replier = signup(client, "nolog_replier")
    uid_watcher, _ = signup(client, "nolog_watcher")
    gid = None
    try:
        make_friends(uid_highlighter, uid_watcher)
        make_friends(uid_replier, uid_watcher)
        set_device_token(uid_watcher, f"tok-{uid_watcher}")
        gid = create_group(client, token_owner, uid_owner, [uid_replier])

        # uid_highlighter's ONLY activity this run is the highlight, so its
        # last_activity_type stays VERSE_HIGHLIGHTED at job-run time (a
        # second, later activity type would otherwise overwrite it before
        # the job composes real verse text for it).
        secret_verse_marker = "In the beginning, God created"  # Genesis 1:1's real text
        r = client.post(f"/notes/highlight/{uid_highlighter}", json={
            "book": "Genesis", "chapter": 1, "verse": 1, "color": "#00ff00",
        }, headers=cookie_header(token_highlighter))
        check("highlight_verse succeeds", r.status_code == 200, f"{r.status_code} {r.text}")

        r2 = client.post(f"/notes/{uid_owner}", json={
            "title": "SECRET_TITLE_MARKER", "text": "SECRET_TEXT_MARKER", "public": True, "group_id": gid,
        }, headers=cookie_header(token_owner))
        check("note create succeeds", r2.status_code == 201, f"{r2.status_code} {r2.text}")
        note_id = r2.json()["id"]
        # uid_replier's own transition composes NOTE_REPLIED text (names
        # uid_owner's username via a real query) -- distinct from
        # uid_owner's own NOTE_CREATED transition above.
        r3 = client.post(f"/notes/reply/{note_id}", json={
            "user": uid_replier, "title": "SECRET_REPLY_TITLE", "text": "SECRET_REPLY_TEXT",
            "public": True, "group_id": gid,
        }, headers=cookie_header(token_replier))
        check("reply succeeds", r3.status_code == 201, f"{r3.status_code} {r3.text}")

        handler = _CapturingLogHandler()
        scheduler_logger = logging.getLogger("backend.interactions.scheduler")
        scheduler_logger.addHandler(handler)
        push = _CapturingPush()
        push_module.send_push = push
        try:
            asyncio.run(_run_friend_went_active())
        finally:
            scheduler_logger.removeHandler(handler)

        check("sanity: the highlighter's push actually carried real verse text "
              "(otherwise this test wouldn't be exercising the leak-risk path)",
              any(secret_verse_marker in c[2] for c in push.calls), str(push.calls))

        forbidden = [secret_verse_marker, "Genesis", "1:1", "SECRET_TITLE_MARKER",
                     "SECRET_TEXT_MARKER", "SECRET_REPLY_TITLE", "SECRET_REPLY_TEXT"]
        leaked = [f for rec in handler.records for f in forbidden if f in rec]
        check("no note/verse/highlight content appears in any log line emitted by the job "
              "(the push body is the one deliberately user-facing surface for this content)",
              leaked == [], f"leaked={leaked} records={handler.records}")
    finally:
        if gid:
            delete_group(gid)
        cleanup(uid_highlighter, uid_owner, uid_replier, uid_watcher)


# ── 4. get_friend_activity's new highlight_preview/activity_type respect
#    block logic in both directions ──────────────────────────────────────────

def test_highlight_preview_respects_block_scoping_both_directions(client):
    print("\n=== 4. highlight_preview/activity_type respect block scoping, both directions ===")
    uid_a, token_a = signup(client, "hlblk_a")
    uid_b, token_b = signup(client, "hlblk_b")   # A blocks B
    uid_c, token_c = signup(client, "hlblk_c")   # C blocks A
    uid_d, token_d = signup(client, "hlblk_d")   # real, unblocked friend
    try:
        make_friends(uid_a, uid_b)
        make_friends(uid_a, uid_c)
        make_friends(uid_a, uid_d)
        block(uid_a, uid_b)
        block(uid_c, uid_a)

        for token, uid in ((token_b, uid_b), (token_c, uid_c), (token_d, uid_d)):
            r = client.post(f"/notes/highlight/{uid}", json={
                "book": "John", "chapter": 3, "verse": 16, "color": "#00ff00",
            }, headers=cookie_header(token))
            check(f"highlight_verse succeeds for {uid}", r.status_code == 200, f"{r.status_code} {r.text}")

        r = get_activity(client, uid_a, token_a)
        body = r.json()
        by_id = {e["friend_id"]: e for e in body["friends_active"]}
        check("A blocked B: B excluded from friends_active entirely (no highlight_preview leak)",
              uid_b not in by_id, body)
        check("C blocked A: C excluded from friends_active entirely (no highlight_preview leak)",
              uid_c not in by_id, body)
        check("real unblocked friend D is present with a highlight_preview and activity_type",
              uid_d in by_id and by_id[uid_d]["highlight_preview"] is not None
              and by_id[uid_d]["activity_type"] == "verse_highlighted",
              body)
        check("D's highlight_preview carries the real verse reference and resolved text",
              by_id[uid_d]["highlight_preview"]["book"] == "John"
              and by_id[uid_d]["highlight_preview"]["chapter"] == 3
              and by_id[uid_d]["highlight_preview"]["verse"] == 16
              and by_id[uid_d]["highlight_preview"]["verse_text"],
              body)
    finally:
        cleanup(uid_a, uid_b, uid_c, uid_d)


# ── 5. is_valid_reference / highlight_verse 400s on a bad reference ─────────

def test_highlight_verse_rejects_invalid_reference(client):
    print("\n=== 5. POST /notes/highlight rejects an unrecognized/out-of-range reference ===")
    uid, token = signup(client, "badref")
    try:
        r = client.post(f"/notes/highlight/{uid}", json={
            "book": "Frodo", "chapter": 1, "verse": 1, "color": "#00ff00",
        }, headers=cookie_header(token))
        check("unrecognized book -> 400", r.status_code == 400, f"{r.status_code} {r.text}")

        r2 = client.post(f"/notes/highlight/{uid}", json={
            "book": "Genesis", "chapter": 9999, "verse": 1, "color": "#00ff00",
        }, headers=cookie_header(token))
        check("out-of-range chapter -> 400", r2.status_code == 400, f"{r2.status_code} {r2.text}")

        r3 = client.post(f"/notes/highlight/{uid}", json={
            "book": "Genesis", "chapter": 1, "verse": 9999, "color": "#00ff00",
        }, headers=cookie_header(token))
        check("out-of-range verse -> 400", r3.status_code == 400, f"{r3.status_code} {r3.text}")

        r4 = client.post(f"/notes/highlight/{uid}", json={
            "book": "Genesis", "chapter": "not-a-number", "verse": 1, "color": "#00ff00",
        }, headers=cookie_header(token))
        check("non-integer chapter -> 400", r4.status_code == 400, f"{r4.status_code} {r4.text}")

        r5 = client.post(f"/notes/highlight/{uid}", json={
            "book": "John", "chapter": 3, "verse": 16, "color": "#00ff00",
        }, headers=cookie_header(token))
        check("a valid, real reference still succeeds (200)", r5.status_code == 200, f"{r5.status_code} {r5.text}")
    finally:
        cleanup(uid)


def main():
    with TestClient(main_module.app) as client:
        try:
            test_note_replied_push_names_owner(client)
            test_note_replied_falls_back_when_parent_note_unresolvable(client)
            test_verse_highlighted_falls_back_to_reference_only_on_text_lookup_miss(client)
            test_verse_highlighted_falls_back_to_generic_when_highlight_row_unresolvable(client)
            test_friend_went_active_job_never_logs_note_or_verse_content(client)
            test_highlight_preview_respects_block_scoping_both_directions(client)
            test_highlight_verse_rejects_invalid_reference(client)
        finally:
            import importlib
            importlib.reload(push_module)
            importlib.reload(bible_text_module)

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
