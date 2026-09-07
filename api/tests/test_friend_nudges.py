"""Tests for the "friend nudge" push-notification feature (task
20260906-friend-nudges, testing step 4 -- the final workflow step).

Covers, per architecture.json step 4's charter and the intake spec's
acceptance criteria, the backend surface both iOS entry points call
(`POST /friends/{user_id}/{friend_id}/nudge`,
`backend.interactions.friends.FriendsManager.check_nudge_allowed` /
`claim_nudge_slot` / `release_nudge_claim`):

  1. Friend-only authorization: a stranger cannot nudge anyone (403,
     enumeration-safe "not_friends" reason).
  2. Block-respecting authorization (both directions): a `user_friends` row
     alone is not enough if either side has blocked the other -- proves the
     defense-in-depth re-check documented on `check_nudge_allowed`, and that
     a denied nudge never records a rate-limit claim.
  3. Happy path: a real friend with a registered device token receives
     exactly one push, with the sender's username in fixed template copy
     and no other PII (no email, no free text).
  4. Rate-limit enforcement: a second nudge to the same friend inside
     `NUDGE_RATE_LIMIT_HOURS` is denied 429 (specific, distinguishable from
     a generic 500) and does not send a second push.
  5. Rate-limit window-reset boundary: back-dating `friend_nudges.
     last_nudged_at` past the window (same direct-DB-manipulation technique
     `test_friend_activity_notification_paths.py` uses for
     `INACTIVITY_THRESHOLD`, rather than sleeping 24 real hours) allows a
     subsequent nudge through, which itself re-arms the window.
  6. Claim-before-send + release-on-failure (re-verifies backend's race-
     condition bounce fix at the route level, not just unit level): a send
     that returns `False` or raises `APNsConfigError` releases the claim so
     a failed nudge doesn't burn the sender's window, and the config error
     itself is never swallowed.
  7. Unreachable: a valid, unblocked friendship with no registered device
     token is denied (404, distinct from the 403 "not_friends" case) rather
     than silently no-op-ing.
  8. Feature flag: `NUDGE_FEATURE_ENABLED = False` makes the route 404
     exactly as if it didn't exist -- no "feature disabled" leak.
  9. Concurrency: two genuinely simultaneous `claim_nudge_slot` calls for
     the same (sender, recipient) pair -- exactly one wins. This is the
     precise race security's bounce (backend.json/security.json) fixed by
     replacing a two-step check-then-mark-sent with one atomic
     `INSERT ... ON CONFLICT ... WHERE ... RETURNING`.

NOT covered here (see this file's home task's testing.json summary for the
full reasoning): the avatar-tile nudge-trigger control's iOS UI states.
`DashboardComponents.swift`'s `onNudge` callback is forward-compatible
plumbing only (frontend.json) -- not invoked by any real control yet,
because the sibling `/design` task's spec for that exact control
(`.claude/design/20260906-friend-activity-avatar-row/design-spec.md`
Component #2) is itself still failing its own pipeline's critique
(critique.json step 5: bounce, citing a nested-Button/untappable
composition, an undefined rate-limited tap state, and a missing default
`onNudge` parameter -- exactly the facets a UI-state test would need to
exercise). There is no real control to test yet. `CheckInRow`'s nudge
wiring IS real and IS exercised by this file end-to-end through the shared
backend contract it calls.

Run with: cd api && ../.venv/bin/python tests/test_friend_nudges.py
"""
import _pathfix  # noqa: F401,E402

import os
import sys
import threading
import uuid
from datetime import datetime, timedelta, timezone as tzmod

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from dotenv import load_dotenv  # noqa: E402
load_dotenv()  # real .env values (if present) win over the placeholders below

# Same rationale as test_profile_photo.py's _ensure_attachment_config_present:
# main.py's lifespan validates these unconditionally at boot regardless of
# what this file is actually testing, and presigned-URL/GIF-search config
# validation is pure local signing/parsing (no network call), so a
# placeholder value is sufficient to let the real app boot.
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

# Force the nudge feature ON for this file regardless of the real .env's
# off-by-default rollout value ("false" -- a deploy-time choice per the
# proactive-flagging stance, not something this test file should have to
# match). Both vars are read at `backend.interactions.friends` *import
# time* (module-level `os.getenv` calls), so this must happen before that
# module -- or `main`, which imports it transitively -- is first imported.
os.environ["NUDGE_FEATURE_ENABLED"] = "true"
os.environ["NUDGE_RATE_LIMIT_HOURS"] = "24"

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
import routes.community as community_module  # noqa: E402
from backend.interactions.friends import FriendsManager  # noqa: E402
from backend.interactions.push import APNsConfigError  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def cookie_header(token: str | None):
    return {"cookie": f"session={token}"} if token else {}


_signup_counter = 0


def signup(client, prefix: str):
    """Distinct CF-Connecting-IP per signup so this file's signups don't
    trip /signup's own per-IP rate limiter -- same technique as
    test_friend_activity_notification_paths.py / test_friend_activity.py."""
    global _signup_counter
    _signup_counter += 1
    fake_ip = f"203.0.116.{_signup_counter % 250 + 1}"
    username = f"{prefix}_{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com",
        "plain_pass": "TestPass123!", "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session"), username


def make_friends(uid_a: str, uid_b: str) -> None:
    db = DBManager()
    try:
        db.insertion("user_friends", {"user_id": uid_a, "friend_id": uid_b})
        db.insertion("user_friends", {"user_id": uid_b, "friend_id": uid_a})
    finally:
        db.close()


def make_blocked(blocker_id: str, blocked_id: str) -> None:
    db = DBManager()
    try:
        db.insertion("blocked_users", {"blocker_id": blocker_id, "blocked_id": blocked_id})
    finally:
        db.close()


def remove_block(blocker_id: str, blocked_id: str) -> None:
    db = DBManager()
    try:
        db.cur.execute(
            "DELETE FROM blocked_users WHERE blocker_id = %s AND blocked_id = %s",
            (blocker_id, blocked_id),
        )
        db.conn.commit()
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


def get_nudge_row(sender_id: str, recipient_id: str):
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT last_nudged_at FROM friend_nudges WHERE sender_id = %s AND recipient_id = %s",
            (sender_id, recipient_id),
        )
        return db.cur.fetchone()
    finally:
        db.close()


def backdate_nudge(sender_id: str, recipient_id: str, when) -> None:
    db = DBManager()
    try:
        db.cur.execute(
            "UPDATE friend_nudges SET last_nudged_at = %s "
            "WHERE sender_id = %s AND recipient_id = %s",
            (when, sender_id, recipient_id),
        )
        db.conn.commit()
    finally:
        db.close()


def clear_nudge_row(sender_id: str, recipient_id: str) -> None:
    db = DBManager()
    try:
        db.cur.execute(
            "DELETE FROM friend_nudges WHERE sender_id = %s AND recipient_id = %s",
            (sender_id, recipient_id),
        )
        db.conn.commit()
    finally:
        db.close()


def cleanup(*user_ids: str) -> None:
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM friend_nudges WHERE sender_id = %s OR recipient_id = %s", (uid, uid))
            db.cur.execute("DELETE FROM blocked_users WHERE blocker_id = %s OR blocked_id = %s", (uid, uid))
            db.cur.execute("DELETE FROM user_friends WHERE user_id = %s OR friend_id = %s", (uid, uid))
            db.cur.execute("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


class _CapturingPush:
    """Replaces routes.community.send_push. Records every call and returns a
    fixed result -- same shape as test_friend_activity_notification_paths.py's
    _CapturingPush, minus the module it patches (community.py imports
    send_push by name, so the patch target is community_module.send_push,
    not backend.interactions.push.send_push)."""

    def __init__(self, result: bool = True):
        self.calls: list[tuple[str, str, str]] = []
        self._result = result

    async def __call__(self, token: str, title: str, body: str, data: dict | None = None) -> bool:
        self.calls.append((token, title, body))
        return self._result


class _RaisingPush:
    def __init__(self, exc: Exception):
        self.calls: list[tuple[str, str, str]] = []
        self._exc = exc

    async def __call__(self, token: str, title: str, body: str, data: dict | None = None) -> bool:
        self.calls.append((token, title, body))
        raise self._exc


def nudge(client, sender_token: str | None, sender_id: str, friend_id: str):
    return client.post(f"/friends/{sender_id}/{friend_id}/nudge", headers=cookie_header(sender_token))


# ── 1. Friend-only + block-respecting authorization ─────────────────────────

def test_nudge_requires_friendship_and_respects_blocks(client):
    print("=== 1. Friend-only + block-respecting authorization ===")
    uid_a, token_a, _ = signup(client, "nudge_authz_a")
    uid_b, token_b, _ = signup(client, "nudge_authz_b")
    uid_stranger, token_stranger, _ = signup(client, "nudge_authz_stranger")
    try:
        # 1a. Not friends at all.
        r = nudge(client, token_stranger, uid_stranger, uid_a)
        check("nudging a non-friend -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        check("the 403 reason is enumeration-safe (never mentions 'block')",
              "block" not in r.json().get("detail", "").lower(), r.text)

        # 1b. Friends, but the RECIPIENT has blocked the sender.
        make_friends(uid_a, uid_b)
        set_device_token(uid_b, f"tok-{uid_b}")
        make_blocked(uid_b, uid_a)
        r2 = nudge(client, token_a, uid_a, uid_b)
        check("recipient blocked sender -> still 403 despite an existing user_friends row",
              r2.status_code == 403, f"{r2.status_code} {r2.text}")
        row = get_nudge_row(uid_a, uid_b)
        check("no rate-limit claim was recorded for a denied (blocked) nudge", row is None, str(row))

        # 1c. Friends, SENDER has blocked the recipient (other direction).
        remove_block(uid_b, uid_a)
        make_blocked(uid_a, uid_b)
        r3 = nudge(client, token_a, uid_a, uid_b)
        check("sender blocked recipient (other direction) -> still 403",
              r3.status_code == 403, f"{r3.status_code} {r3.text}")
    finally:
        cleanup(uid_a, uid_b, uid_stranger)


# ── 2. Happy path: fixed copy, no PII beyond username ───────────────────────

def test_nudge_success_sends_fixed_copy_push(client):
    print("\n=== 2. Happy path: friend + token -> push sent with fixed template copy ===")
    uid_a, token_a, uname_a = signup(client, "nudge_ok_a")
    uid_b, token_b, uname_b = signup(client, "nudge_ok_b")
    orig_send_push = community_module.send_push
    try:
        make_friends(uid_a, uid_b)
        set_device_token(uid_b, f"tok-{uid_b}")

        push = _CapturingPush(result=True)
        community_module.send_push = push

        r = nudge(client, token_a, uid_a, uid_b)
        check("nudge succeeds -> 204", r.status_code == 204, f"{r.status_code} {r.text}")
        check("exactly one push sent, to the recipient's real device token",
              len(push.calls) == 1 and push.calls[0][0] == f"tok-{uid_b}", str(push.calls))
        check("push body names the sender by username (fixed template, not free text)",
              uname_a in push.calls[0][2], str(push.calls))
        check("push title/body carry no email or other PII beyond the sender's username",
              "@" not in push.calls[0][2] and "@" not in push.calls[0][1], str(push.calls))

        row = get_nudge_row(uid_a, uid_b)
        check("a rate-limit claim row now exists for this (sender, recipient) pair",
              row is not None, str(row))
    finally:
        community_module.send_push = orig_send_push
        cleanup(uid_a, uid_b)


# ── 3. Rate limit: second nudge denied, no double-send; window resets ──────

def test_nudge_rate_limit_enforced_and_resets_after_window(client):
    print("\n=== 3. Rate-limit enforcement + window-reset boundary ===")
    uid_a, token_a, _ = signup(client, "nudge_rl_a")
    uid_b, token_b, _ = signup(client, "nudge_rl_b")
    orig_send_push = community_module.send_push
    try:
        make_friends(uid_a, uid_b)
        set_device_token(uid_b, f"tok-{uid_b}")

        push = _CapturingPush(result=True)
        community_module.send_push = push

        r1 = nudge(client, token_a, uid_a, uid_b)
        check("first nudge succeeds -> 204", r1.status_code == 204, f"{r1.status_code} {r1.text}")

        r2 = nudge(client, token_a, uid_a, uid_b)
        check("second nudge to the same friend inside the window -> 429 "
              "(a specific, client-distinguishable reason -- not a generic 500)",
              r2.status_code == 429, f"{r2.status_code} {r2.text}")
        check("the rate-limited attempt does NOT trigger a second push",
              len(push.calls) == 1, str(push.calls))

        # Window-reset boundary: back-date last_nudged_at to just past
        # NUDGE_RATE_LIMIT_HOURS (24h) rather than sleeping 24 real hours --
        # same direct-DB-manipulation technique
        # test_friend_activity_notification_paths.py uses for
        # INACTIVITY_THRESHOLD.
        backdate_nudge(uid_a, uid_b, datetime.now(tzmod.utc) - timedelta(hours=25))
        r3 = nudge(client, token_a, uid_a, uid_b)
        check("a nudge attempted just past the window succeeds again -> 204",
              r3.status_code == 204, f"{r3.status_code} {r3.text}")
        check("the reset nudge sends a genuine second push", len(push.calls) == 2, str(push.calls))

        # Immediately re-nudging right after a fresh, successful send must
        # be denied again -- proves the reset itself re-arms the window
        # rather than leaving it permanently open.
        r4 = nudge(client, token_a, uid_a, uid_b)
        check("immediately re-nudging right after a successful reset send -> 429 again",
              r4.status_code == 429, f"{r4.status_code} {r4.text}")
        check("still exactly two real pushes sent in total", len(push.calls) == 2, str(push.calls))
    finally:
        community_module.send_push = orig_send_push
        cleanup(uid_a, uid_b)


# ── 4. Claim-before-send + release-on-failure (security bounce re-verify) ──

def test_nudge_failed_send_releases_claim(client):
    print("\n=== 4. A failed send releases the claim (doesn't burn the sender's window) ===")
    uid_a, token_a, _ = signup(client, "nudge_fail_a")
    uid_b, token_b, _ = signup(client, "nudge_fail_b")
    orig_send_push = community_module.send_push
    try:
        make_friends(uid_a, uid_b)
        set_device_token(uid_b, f"tok-{uid_b}")

        # 4a. send_push returns False ("APNs reported undeliverable") -> 502,
        # claim released.
        failing_push = _CapturingPush(result=False)
        community_module.send_push = failing_push
        r1 = nudge(client, token_a, uid_a, uid_b)
        check("send_push returning False -> 502 (an upstream failure, not a local one)",
              r1.status_code == 502, f"{r1.status_code} {r1.text}")
        row_after_fail = get_nudge_row(uid_a, uid_b)
        check("claim released after a failed (False) send -- no lingering rate-limit row",
              row_after_fail is None, str(row_after_fail))

        # A retry right after must be allowed to actually attempt again --
        # NOT rate-limited by the failed attempt.
        ok_push = _CapturingPush(result=True)
        community_module.send_push = ok_push
        r2 = nudge(client, token_a, uid_a, uid_b)
        check("retry after a released claim succeeds -> 204", r2.status_code == 204, f"{r2.status_code} {r2.text}")
        check("the successful retry leaves a fresh claim row",
              get_nudge_row(uid_a, uid_b) is not None, "")

        clear_nudge_row(uid_a, uid_b)  # reset for 4b

        # 4b. send_push raises APNsConfigError -> propagates loudly (never
        # swallowed to a silent success/no-op), claim released either way.
        # TestClient's exact propagation shape (raised in-process vs. turned
        # into a bare 500 response) isn't the point being proven here --
        # either is acceptable as long as the error is neither swallowed
        # nor treated as a successful send.
        raising_push = _RaisingPush(APNsConfigError("missing credential (test)"))
        community_module.send_push = raising_push
        propagated = False
        status_code = None
        try:
            r3 = nudge(client, token_a, uid_a, uid_b)
            status_code = r3.status_code
            propagated = status_code == 500
        except APNsConfigError:
            propagated = True
        check("send_push raising APNsConfigError propagates loudly (500, or a "
              "raised exception through TestClient) -- never swallowed into a "
              "quiet success", propagated, f"status={status_code}")
        row_after_raise = get_nudge_row(uid_a, uid_b)
        check("claim released after a raised send_push error too",
              row_after_raise is None, str(row_after_raise))
    finally:
        community_module.send_push = orig_send_push
        cleanup(uid_a, uid_b)


# ── 5. Unreachable: valid friendship, no device token ───────────────────────

def test_nudge_unreachable_without_device_token(client):
    print("\n=== 5. Valid, unblocked friendship but no device token -> denied, not silent ===")
    uid_a, token_a, _ = signup(client, "nudge_unreach_a")
    uid_b, token_b, _ = signup(client, "nudge_unreach_b")
    try:
        make_friends(uid_a, uid_b)  # deliberately no set_device_token(uid_b, ...)
        r = nudge(client, token_a, uid_a, uid_b)
        check("no device token for an otherwise-valid friend -> 404 (distinct from not_friends' 403)",
              r.status_code == 404, f"{r.status_code} {r.text}")
        row = get_nudge_row(uid_a, uid_b)
        check("no rate-limit claim recorded for an unreachable denial", row is None, str(row))
    finally:
        cleanup(uid_a, uid_b)


# ── 6. Feature flag: disabled -> 404 exactly as if the route didn't exist ──

def test_nudge_feature_disabled_returns_404(client):
    print("\n=== 6. NUDGE_FEATURE_ENABLED=False -> 404, no 'disabled' leak ===")
    uid_a, token_a, _ = signup(client, "nudge_flag_a")
    uid_b, token_b, _ = signup(client, "nudge_flag_b")
    import backend.interactions.friends as friends_module
    orig = friends_module.NUDGE_FEATURE_ENABLED
    try:
        make_friends(uid_a, uid_b)
        set_device_token(uid_b, f"tok-{uid_b}")
        friends_module.NUDGE_FEATURE_ENABLED = False
        r = nudge(client, token_a, uid_a, uid_b)
        check("disabled feature flag -> 404 (indistinguishable from a nonexistent route)",
              r.status_code == 404, f"{r.status_code} {r.text}")
    finally:
        friends_module.NUDGE_FEATURE_ENABLED = orig
        cleanup(uid_a, uid_b)


# ── 7. Concurrency: only one of two simultaneous claims wins ────────────────

def test_concurrent_claims_only_one_wins(client):
    print("\n=== 7. Concurrent claim_nudge_slot calls for the same pair -- only one wins ===")
    uid_a, _, _ = signup(client, "nudge_race_a")
    uid_b, _, _ = signup(client, "nudge_race_b")
    try:
        make_friends(uid_a, uid_b)

        results = [None, None]
        errors = []
        barrier = threading.Barrier(2)

        def attempt(i):
            manager = FriendsManager(uid_a)
            try:
                barrier.wait(timeout=5)
                results[i] = manager.claim_nudge_slot(uid_b)
            except Exception as e:  # pragma: no cover - surfaced via `errors`
                errors.append(e)
            finally:
                manager.close()

        threads = [threading.Thread(target=attempt, args=(i,)) for i in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)

        check("no unexpected errors from either concurrent claim attempt",
              not errors, str(errors))
        check("exactly one of two truly concurrent claims for the same "
              "(sender, recipient) pair wins the slot (the exact race "
              "security's bounce fixed by moving to one atomic "
              "INSERT ... ON CONFLICT ... WHERE ... RETURNING)",
              sorted(results, key=lambda v: (v is None, v)) == [False, True], str(results))
    finally:
        cleanup(uid_a, uid_b)


def main():
    with TestClient(main_module.app) as client:
        test_nudge_requires_friendship_and_respects_blocks(client)
        test_nudge_success_sends_fixed_copy_push(client)
        test_nudge_rate_limit_enforced_and_resets_after_window(client)
        test_nudge_failed_send_releases_claim(client)
        test_nudge_unreachable_without_device_token(client)
        test_nudge_feature_disabled_returns_404(client)
        test_concurrent_claims_only_one_wins(client)

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
