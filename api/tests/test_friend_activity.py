"""Tests for GET /friends/{user_id}/activity (FriendsManager.get_friend_activity),
the new friend-activity read surface backing the Editorial Hero dashboard's
Friend Activity card + check-in nudge (task
20260826-friend-activity-dashboard-implementation, backend step 2 / security
step 4).

Covers:
  1. Authorization -- require_match scoping: a caller can only read their own
     friend list (403 on mismatch, 401 unauthenticated).
  2. Empty states -- no friends at all, and a friend with zero tracked
     activity, both render a defined shape rather than an error or crash.
  3. Privacy scoping of note previews -- a friend's PUBLIC personal note
     surfaces; a PRIVATE note never leaks into the preview, matching the
     privacy decision documented in FriendsManager.get_friend_activity's
     docstring, even though it still bumps last_active_at.
  4. Group-shared and reply notes -- excluded from the preview even when
     public, since "friend" visibility isn't the same grant as group
     membership or reply-thread visibility.
  5. Highlight-only activity -- counts toward last_active_at but never
     surfaces content (highlights have no privacy flag today).
  6. Block scoping, both directions -- a blocked-in-either-direction "friend"
     (stale/bypassed user_friends row) is excluded from both friends_active
     and check_in_candidates, mirroring ActivityManager.friend_device_tokens'
     defense-in-depth re-check.
  7. Ordering -- friends_active is ordered by last_active_at desc, with
     never-active friends sorting last.
  8. check_in_candidates selection -- ordered longest-since-contact first; a
     never-messaged friend is a valid (null-days) candidate.
  9. Cross-user leakage -- a non-friend's public note never surfaces for a
     user who isn't their friend.
  10. check_in_candidates pool is bounded to FriendsManager.CHECK_IN_POOL_SIZE
      (task 20260902-dashboard-friend-randomization) even when the caller has
      more eligible friends than that, and still ordered longest-since-contact
      first within the bounded pool.

Run:  cd api && ../.venv/bin/python tests/test_friend_activity.py
"""
import _pathfix  # noqa: F401,E402

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
from backend.interactions.activity import ActivityManager  # noqa: E402
from backend.interactions.friends import FriendsManager  # noqa: E402
from backend.interactions.websockets import ConnectionManager  # noqa: E402
from schemas.message import Message  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── Fixtures / helpers ──────────────────────────────────────────────────────

def cookie_header(token: str | None):
    return {"cookie": f"session={token}"} if token else {}


_signup_counter = 0


def signup(client, prefix: str):
    """Each call spoofs a distinct CF-Connecting-IP so this file's ~20
    signups (well over the 5/minute per-IP limit) don't trip /signup's rate
    limiter -- mirrors the technique test_security_hardening.py uses to prove
    the limiter keys off that header rather than the shared TestClient
    connection. This is purely a test-harness workaround for a single-IP
    test run, not a claim about the limiter's real-world behavior."""
    global _signup_counter
    _signup_counter += 1
    fake_ip = f"203.0.113.{_signup_counter % 250 + 1}"
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


def create_note(client, token, user_id, title, text, public, is_reply=False,
                 group_id="", timestamp=None):
    body = {"title": title, "text": text, "public": public, "is_reply": is_reply,
            "group_id": group_id}
    if timestamp is not None:
        body["timestamp"] = timestamp
    r = client.post(f"/notes/{user_id}", json=body, headers=cookie_header(token))
    assert r.status_code == 201, f"create_note failed: {r.status_code} {r.text}"
    return r.json()["id"]


def create_group(client, token, owner_id, member_ids):
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


def send_direct_message(from_user, to_user, text, when):
    cm = ConnectionManager()
    try:
        cm.save_message(Message(
            from_user=from_user, to_users=[to_user], group_id=None,
            text=text, timestamp=str(when),
        ))
    finally:
        cm.close()


def record_activity(user_id: str, when=None) -> None:
    am = ActivityManager()
    try:
        if when is not None:
            am.record_activity(user_id, now=when)
        else:
            am.record_activity(user_id)
    finally:
        am.close()


def cleanup(*user_ids: str) -> None:
    db = DBManager()
    try:
        for uid in user_ids:
            # notes.user_id has no ON DELETE CASCADE -- clear owned rows first
            # so the user delete doesn't hit an FK violation (same pattern as
            # test_activity_notifications.py's cleanup).
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM highlights WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM messages WHERE from_user = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def get_activity(client, user_id, token):
    return client.get(f"/friends/{user_id}/activity", headers=cookie_header(token))


# ── 1. Authorization ─────────────────────────────────────────────────────────

def test_authorization(client):
    print("=== 1. Authorization scoping (require_match) ===")
    uid_a, token_a = signup(client, "auth_a")
    uid_b, token_b = signup(client, "auth_b")
    try:
        r = get_activity(client, uid_b, token_a)
        check("caller cannot read another user's friend-activity feed (403)",
              r.status_code == 403, f"{r.status_code} {r.text}")

        r2 = client.get(f"/friends/{uid_a}/activity")  # no session cookie
        check("unauthenticated request is rejected (401)",
              r2.status_code == 401, f"{r2.status_code} {r2.text}")

        r3 = get_activity(client, uid_a, token_a)
        check("caller can read their own feed (200)",
              r3.status_code == 200, f"{r3.status_code} {r3.text}")
    finally:
        cleanup(uid_a, uid_b)


# ── 2. Empty states ──────────────────────────────────────────────────────────

def test_empty_states(client):
    print("\n=== 2. Empty states ===")
    uid_lonely, token_lonely = signup(client, "empty_lonely")
    uid_a, token_a = signup(client, "empty_a")
    uid_b, token_b = signup(client, "empty_b")
    try:
        make_friends(uid_a, uid_b)  # B has zero tracked activity, zero messages

        r = get_activity(client, uid_lonely, token_lonely)
        check("no friends -> 200", r.status_code == 200, r.text)
        body = r.json()
        check("no friends -> friends_active is an empty list", body["friends_active"] == [], body)
        check("no friends -> check_in_candidates is an empty list",
              body["check_in_candidates"] == [], body)

        r2 = get_activity(client, uid_a, token_a)
        body2 = r2.json()
        check("friend with zero activity still appears in friends_active",
              len(body2["friends_active"]) == 1 and body2["friends_active"][0]["friend_id"] == uid_b,
              body2)
        check("friend with zero activity has last_active_at None",
              body2["friends_active"][0]["last_active_at"] is None, body2)
        check("friend with zero activity has note_preview None",
              body2["friends_active"][0]["note_preview"] is None, body2)
        check("never-messaged friend is still a valid check_in candidate",
              len(body2["check_in_candidates"]) == 1
              and body2["check_in_candidates"][0]["friend_id"] == uid_b, body2)
        check("never-messaged check_in candidate has days_since_contact None",
              body2["check_in_candidates"][0]["days_since_contact"] is None, body2)
    finally:
        cleanup(uid_lonely, uid_a, uid_b)


# ── 3. Note preview privacy scoping ─────────────────────────────────────────

def test_note_privacy_scoping(client):
    print("\n=== 3. Note preview privacy scoping (public vs private) ===")
    uid_a, token_a = signup(client, "priv_a")
    uid_b, token_b = signup(client, "priv_b")
    try:
        make_friends(uid_a, uid_b)

        create_note(client, token_b, uid_b, "Private thoughts", "should never leak",
                    public=False, timestamp="2026-08-20 08:00:00")

        r = get_activity(client, uid_a, token_a)
        entry = r.json()["friends_active"][0]
        check("private note does not leak into note_preview",
              entry["note_preview"] is None, entry)
        check("private note still counts toward last_active_at",
              entry["last_active_at"] is not None, entry)

        note_id = create_note(client, token_b, uid_b, "Sunday reflections",
                              "a public note", public=True, timestamp="2026-08-21 08:00:00")

        r2 = get_activity(client, uid_a, token_a)
        entry2 = r2.json()["friends_active"][0]
        check("public personal note surfaces in note_preview",
              entry2["note_preview"] is not None and entry2["note_preview"]["note_id"] == note_id,
              entry2)
        check("note_preview text matches the public note's text",
              entry2["note_preview"]["text"] == "a public note", entry2)
    finally:
        cleanup(uid_a, uid_b)


# ── 4. Group-shared and reply notes excluded ────────────────────────────────

def test_group_and_reply_notes_excluded(client):
    print("\n=== 4. Group-shared and reply notes excluded from preview ===")
    uid_a, token_a = signup(client, "grp_a")
    uid_b, token_b = signup(client, "grp_b")
    gid = None
    try:
        make_friends(uid_a, uid_b)
        gid = create_group(client, token_b, uid_b, [uid_a])

        create_note(client, token_b, uid_b, "Group note", "shared with the group",
                    public=True, group_id=gid, timestamp="2026-08-20 08:00:00")

        r = get_activity(client, uid_a, token_a)
        entry = r.json()["friends_active"][0]
        check("public group note is excluded from a mere friend's note_preview "
              "(group membership is not the same grant as friendship)",
              entry["note_preview"] is None, entry)

        create_note(client, token_b, uid_b, "A reply", "reply body",
                    public=True, is_reply=True, timestamp="2026-08-21 08:00:00")

        r2 = get_activity(client, uid_a, token_a)
        entry2 = r2.json()["friends_active"][0]
        check("public reply note is excluded from note_preview (personal notes only)",
              entry2["note_preview"] is None, entry2)
    finally:
        if gid:
            delete_group(gid)
        cleanup(uid_a, uid_b)


# ── 5. Highlight-only activity ──────────────────────────────────────────────

def test_highlight_only_activity_no_content_leak(client):
    print("\n=== 5. Highlight activity counts but never shows content ===")
    uid_a, token_a = signup(client, "hl_a")
    uid_b, token_b = signup(client, "hl_b")
    try:
        make_friends(uid_a, uid_b)
        r = client.post(f"/notes/highlight/{uid_b}", json={
            "book": "Genesis", "chapter": 1, "verse": 1, "color": "#ff0000",
        }, headers=cookie_header(token_b))
        check("highlight_verse succeeds", r.status_code == 200, r.text)

        r2 = get_activity(client, uid_a, token_a)
        entry = r2.json()["friends_active"][0]
        check("highlight-only activity sets last_active_at",
              entry["last_active_at"] is not None, entry)
        check("highlight-only activity never surfaces note_preview content "
              "(highlights have no privacy flag today)",
              entry["note_preview"] is None, entry)
    finally:
        cleanup(uid_a, uid_b)


# ── 6. Block scoping, both directions ───────────────────────────────────────

def test_block_scoping_both_directions(client):
    print("\n=== 6. Block scoping, both directions ===")
    uid_a, token_a = signup(client, "blk_a")
    uid_b, token_b = signup(client, "blk_b")   # A blocks B
    uid_c, token_c = signup(client, "blk_c")   # C blocks A
    uid_d, token_d = signup(client, "blk_d")   # real, unblocked friend
    try:
        make_friends(uid_a, uid_b)
        make_friends(uid_a, uid_c)
        make_friends(uid_a, uid_d)
        block(uid_a, uid_b)   # A blocked B
        block(uid_c, uid_a)   # C blocked A

        # Give B and C public notes -- if the block re-check ever regressed,
        # this is exactly the leak this test would catch.
        create_note(client, token_b, uid_b, "B note", "should never surface to A",
                    public=True, timestamp="2026-08-22 08:00:00")
        create_note(client, token_c, uid_c, "C note", "should never surface to A",
                    public=True, timestamp="2026-08-22 08:00:00")

        r = get_activity(client, uid_a, token_a)
        body = r.json()
        ids = {e["friend_id"] for e in body["friends_active"]}
        check("A blocked B: B excluded from friends_active despite the stale user_friends row",
              uid_b not in ids, body)
        check("C blocked A: C excluded from friends_active despite the stale user_friends row",
              uid_c not in ids, body)
        check("real unblocked friend D still present", uid_d in ids, body)
        candidate_ids = {c["friend_id"] for c in body["check_in_candidates"]}
        check("check_in_candidates never includes a blocked-in-either-direction contact",
              uid_b not in candidate_ids and uid_c not in candidate_ids,
              body)
        check("real unblocked friend D still eligible as a check_in candidate",
              uid_d in candidate_ids, body)
    finally:
        cleanup(uid_a, uid_b, uid_c, uid_d)


# ── 7. Ordering ──────────────────────────────────────────────────────────────

def test_ordering_most_recently_active_first(client):
    print("\n=== 7. Ordering: most-recently-active friend first, never-active last ===")
    uid_a, token_a = signup(client, "ord_a")
    uid_old, _ = signup(client, "ord_old")
    uid_new, _ = signup(client, "ord_new")
    uid_never, _ = signup(client, "ord_never")
    try:
        make_friends(uid_a, uid_old)
        make_friends(uid_a, uid_new)
        make_friends(uid_a, uid_never)

        record_activity(uid_old, when=datetime(2026, 1, 1, tzinfo=tzmod.utc))
        record_activity(uid_new, when=datetime(2026, 8, 20, tzinfo=tzmod.utc))
        # uid_never: no user_activity row at all.

        r = get_activity(client, uid_a, token_a)
        order = [e["friend_id"] for e in r.json()["friends_active"]]
        check("most-recently-active friend sorts first",
              order.index(uid_new) < order.index(uid_old), order)
        check("never-active friend sorts last",
              order.index(uid_never) > order.index(uid_old), order)
    finally:
        cleanup(uid_a, uid_old, uid_new, uid_never)


# ── 8. check_in_candidates selection ────────────────────────────────────────

def test_check_in_selects_longest_since_contact(client):
    print("\n=== 8. check_in_candidates: longest-since-contact ordered first ===")
    uid_a, token_a = signup(client, "ci_a")
    uid_recent, _ = signup(client, "ci_recent")
    uid_stale, _ = signup(client, "ci_stale")
    try:
        make_friends(uid_a, uid_recent)
        make_friends(uid_a, uid_stale)

        send_direct_message(uid_a, uid_recent, "hey!", datetime(2026, 8, 25, tzinfo=tzmod.utc))
        send_direct_message(uid_stale, uid_a, "hi there", datetime(2026, 1, 1, tzinfo=tzmod.utc))

        r = get_activity(client, uid_a, token_a)
        body = r.json()
        candidates = body["check_in_candidates"]
        check("check_in_candidates includes both friends",
              len(candidates) == 2, body)
        check("check_in_candidates orders the friend gone longest without contact first",
              candidates[0]["friend_id"] == uid_stale, body)
        check("the more-recently-contacted friend still appears, just second",
              candidates[1]["friend_id"] == uid_recent, body)
        check("days_since_contact is a positive int for a real past message",
              isinstance(candidates[0]["days_since_contact"], int)
              and candidates[0]["days_since_contact"] > 0,
              body)
    finally:
        cleanup(uid_a, uid_recent, uid_stale)


# ── 10. check_in_candidates pool is bounded (CHECK_IN_POOL_SIZE) ───────────

def test_check_in_pool_bounded_to_pool_size(client):
    print("\n=== 10. check_in_candidates is bounded to CHECK_IN_POOL_SIZE, still ordered ===")
    pool_size = FriendsManager.CHECK_IN_POOL_SIZE
    uid_a, token_a = signup(client, "pool_a")
    # One more friend than the pool size, each with a distinct, strictly
    # increasing last-contact date -- oldest-contact friend must still make
    # the bounded pool and sort first; a friend contacted even later than all
    # the others must be excluded once the pool is full.
    friend_ids = []
    try:
        for i in range(pool_size + 1):
            uid_f, _ = signup(client, f"pool_f{i}")
            friend_ids.append(uid_f)
            make_friends(uid_a, uid_f)
            # i=0 is contacted longest ago (2026-01-01), each subsequent
            # friend more recently, so friend_ids[-1] (the (pool_size+1)th)
            # is the MOST recently contacted -- expected to be excluded from
            # the bounded pool.
            send_direct_message(uid_a, uid_f, "hi", datetime(2026, 1, 1 + i, tzinfo=tzmod.utc))

        r = get_activity(client, uid_a, token_a)
        body = r.json()
        candidates = body["check_in_candidates"]
        check(f"check_in_candidates is capped at CHECK_IN_POOL_SIZE ({pool_size}) "
              f"even though the caller has {pool_size + 1} eligible friends",
              len(candidates) == pool_size, body)

        candidate_ids = [c["friend_id"] for c in candidates]
        check("the longest-since-contact friend (contacted first, i.e. longest ago) is in the bounded pool",
              friend_ids[0] in candidate_ids, body)
        check("the most-recently-contacted friend is excluded once the pool is full",
              friend_ids[-1] not in candidate_ids, body)
        check("bounded pool is still ordered longest-since-contact first",
              candidates[0]["friend_id"] == friend_ids[0], body)
        days = [c["days_since_contact"] for c in candidates]
        check("days_since_contact is non-increasing across the ordered bounded pool",
              days == sorted(days, reverse=True), body)
    finally:
        cleanup(uid_a, *friend_ids)


# ── 9. Cross-user leakage ────────────────────────────────────────────────────

def test_cross_user_leakage_non_friend_never_surfaces(client):
    print("\n=== 9. Cross-user leakage: a non-friend never surfaces ===")
    uid_a, token_a = signup(client, "leak_a")
    uid_stranger, token_stranger = signup(client, "leak_stranger")
    try:
        # No friendship at all -- stranger has a public note.
        create_note(client, token_stranger, uid_stranger, "Stranger note",
                    "not a friend", public=True, timestamp="2026-08-22 08:00:00")

        r = get_activity(client, uid_a, token_a)
        body = r.json()
        check("a non-friend's public note never appears for a user who isn't their friend",
              body["friends_active"] == [] and body["check_in_candidates"] == [], body)
    finally:
        cleanup(uid_a, uid_stranger)


def main():
    # Single shared TestClient/app lifespan for every test -- the scheduler
    # is a module-level singleton, so a second independent
    # TestClient(main_module.app) lifespan in the same process fails trying
    # to re-register jobs against a closed event loop (same rationale as
    # test_activity_notifications.py).
    with TestClient(main_module.app) as client:
        test_authorization(client)
        test_empty_states(client)
        test_note_privacy_scoping(client)
        test_group_and_reply_notes_excluded(client)
        test_highlight_only_activity_no_content_leak(client)
        test_block_scoping_both_directions(client)
        test_ordering_most_recently_active_first(client)
        test_check_in_selects_longest_since_contact(client)
        test_cross_user_leakage_non_friend_never_surfaces(client)
        test_check_in_pool_bounded_to_pool_size(client)

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
