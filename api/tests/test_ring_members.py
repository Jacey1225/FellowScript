"""Tests for the "ring group members from an active call" feature (task
20260916-call-ring-members, testing step 5 -- the final backend-facing
workflow step, after the 2nd security-bounce rework).

Covers, per architecture.json step 5's charter and the intake spec's
acceptance criteria, `POST /devotions/ring`
(`routes.devotion.ring_members`) and the backend it's built on
(`backend.interactions.devotion.DevotionManager.real_group_roster`,
`claim_ring_slot`/`release_ring_claim`, `validate_ring_config`,
`DevotionManager.save_devotion`'s chime_meeting_id hardening):

  1. Caller authorization requires BOTH `is_authorized` AND independent
     `real_group_roster` membership: a session whose `creator_id`/
     `participants` are self-declared (client-supplied, unvalidated at
     creation) to claim membership in a group the caller was never actually
     added to must still be denied -- `is_authorized` alone would pass this,
     proving `real_group_roster` is genuinely doing separate, real work.
  2. Target eligibility: a real group member can ring another real member of
     the *same* real group, but not a signed-up user who isn't in that
     group's real roster (`not_a_member`), even if nothing else about the
     request looks wrong.
  3. DM-encoded `group_id` ("uidA|uidB"): a self-minted pair with no real
     mutual friendship yields an empty roster and denies BOTH the caller and
     the "target" -- proves the exploit security's 2nd bounce fixed
     (`group_id="<attacker>|<victim>"` no longer just string-splits into a
     trusted roster). A genuine mutual-friend, non-blocked pair still rings
     normally. A friendship undone by a block in either direction is denied
     the same way (merged, enumeration-safe).
  4. `chime_meeting_id` live-call gate: a session with no live call attached
     denies every target with `no_active_call` (not a generic failure, not a
     403) without ever touching per-target membership/cooldown state. Also
     proves the 3rd security pass's fix directly: a client-supplied
     `chime_meeting_id` on `POST /devotions/` create is silently discarded
     server-side, so a caller cannot self-mint a "live call" and bypass this
     gate.
  5. Cross-session `ring_cooldowns` enforcement and its boundary: a second
     ring to the same recipient within the cooldown window is denied
     (`rate_limited`) without a second push; critically, a *fresh*
     `session_id` between the same real (sender, recipient) pair does NOT
     reset the cooldown (the exact gap the 2nd security bounce closed by
     dropping `session_id` from the claim key) -- proven by ringing again
     from a brand-new session and still getting `rate_limited`. Backdating
     `ring_cooldowns.last_rung_at` past the window (same direct-DB technique
     `test_friend_nudges.py` uses) then allows a fresh ring through.
  6. Fail-fast config validation: `validate_ring_config()` raises
     `RingConfigError` (never silently defaults) for every one of
     RING_FEATURE_ENABLED/RING_COOLDOWN_MINUTES being unset, non-boolean, or
     a non-positive/non-integer cooldown.
  7. Feature flag: `RING_FEATURE_ENABLED = False` makes the route 404 exactly
     as if it didn't exist.

NOT covered here: iOS `RingMembersSheet`'s per-row UI states (success/error/
rate-limited/no-active-call/not-a-member) -- see this task's testing.json for
why that iOS coverage could not be added in this pass (FellowScriptTests
currently fails to compile for an unrelated reason: `ThrowingTestDataService`
in AppStateAuthAccountTests.swift does not implement the new
`DataServiceProtocol.ringMembers` requirement frontend step 4 added, so the
entire iOS test target is red, not just this feature's coverage).

Run with: cd api && ../.venv/bin/python tests/test_ring_members.py
"""
import _pathfix  # noqa: F401,E402

import os
import sys
import uuid
from datetime import datetime, timedelta, timezone as tzmod

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from dotenv import load_dotenv  # noqa: E402
load_dotenv()  # real .env values (if present) win over the placeholders below

# Same rationale as test_friend_nudges.py's placeholders: main.py's lifespan
# validates these unconditionally at boot regardless of what this file is
# actually testing.
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

# Force the ring feature ON for this file regardless of the real .env's
# off-by-default rollout value ("false" -- a deploy-time choice per the
# proactive-flagging stance, not something this test file should match).
# Both vars are read at `backend.interactions.devotion` *import time*
# (module-level `os.getenv` calls), so this must happen before that module
# -- or `main`, which imports it transitively -- is first imported.
os.environ["RING_FEATURE_ENABLED"] = "true"
os.environ["RING_COOLDOWN_MINUTES"] = "5"

from fastapi.testclient import TestClient  # noqa: E402

from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
import routes.devotion as devotion_module  # noqa: E402
import backend.interactions.devotion as devotion_backend_module  # noqa: E402
from backend.interactions.devotion import DevotionManager, RingConfigError  # noqa: E402

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
    global _signup_counter
    _signup_counter += 1
    fake_ip = f"203.0.117.{_signup_counter % 250 + 1}"
    username = f"{prefix}_{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com",
        "plain_pass": "TestPass123!", "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def create_group(client, token, owner_uid, member_uids):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner_uid}", json={
        "group_id": gid, "title": "Ring test group", "users": [owner_uid, *member_uids],
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def create_session(client, token, user_id, creator_id, group_id, participants=None, chime_meeting_id=""):
    """Direct pass-through of every client-controllable devotion field --
    including a caller-supplied `chime_meeting_id`, which security's 3rd
    pass confirmed must be silently discarded server-side (test 4b below)."""
    devo_id = str(uuid.uuid4())
    payload = {
        "devotion_id": devo_id, "user_id": user_id,
        "devotion": {
            "id": devo_id, "title": "Ring test session", "creator_id": creator_id,
            "participants": participants or [], "group_id": group_id,
            "prompts": ["p1"], "verses": [], "chime_meeting_id": chime_meeting_id,
        },
    }
    r = client.post("/devotions/", json=payload, headers=cookie_header(token))
    assert r.status_code == 201, f"create_devotion failed: {r.status_code} {r.text}"
    return devo_id


def set_device_token(user_id: str, token: str) -> None:
    db = DBManager()
    try:
        db.insertion(
            "device_tokens", {"user_id": user_id, "token": token},
            conflict="(user_id) DO UPDATE SET token = EXCLUDED.token",
        )
    finally:
        db.close()


def set_live_call(session_id: str) -> None:
    db = DevotionManager()
    try:
        db.save_chime_meeting(session_id, f"meeting-{uuid.uuid4()}", {"MeetingId": "fake"})
    finally:
        db.close()


def get_session_row(session_id: str) -> dict:
    db = DevotionManager()
    try:
        return db.get_session(session_id)
    finally:
        db.close()


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


def get_ring_cooldown_row(sender_id: str, recipient_id: str):
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT last_rung_at FROM ring_cooldowns WHERE sender_id = %s AND recipient_id = %s",
            (sender_id, recipient_id),
        )
        return db.cur.fetchone()
    finally:
        db.close()


def backdate_ring_cooldown(sender_id: str, recipient_id: str, when) -> None:
    db = DBManager()
    try:
        db.cur.execute(
            "UPDATE ring_cooldowns SET last_rung_at = %s WHERE sender_id = %s AND recipient_id = %s",
            (when, sender_id, recipient_id),
        )
        db.conn.commit()
    finally:
        db.close()


def cleanup(*user_ids: str, group_ids=(), devotion_ids=()) -> None:
    db = DBManager()
    try:
        for did in devotion_ids:
            db.cur.execute("DELETE FROM devotions WHERE _id = %s", (did,))
        for gid in group_ids:
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM ring_cooldowns WHERE sender_id = %s OR recipient_id = %s", (uid, uid))
            db.cur.execute("DELETE FROM devotions WHERE creator_id = %s", (uid,))
            db.cur.execute("DELETE FROM groups WHERE %s = ANY(users)", (uid,))
            db.cur.execute("DELETE FROM blocked_users WHERE blocker_id = %s OR blocked_id = %s", (uid, uid))
            db.cur.execute("DELETE FROM user_friends WHERE user_id = %s OR friend_id = %s", (uid, uid))
            db.cur.execute("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


class _CapturingPush:
    """Replaces backend.interactions.push.send_push at the MODULE level --
    routes.devotion.ring_members does `from backend.interactions.push import
    send_push` as a local import *inside* the route function, so patching
    routes.devotion.send_push (module-level) would have no effect; the local
    import re-resolves the name from backend.interactions.push's current
    attribute on every call, so patching it there is what actually takes
    effect."""

    def __init__(self, result: bool = True):
        self.calls: list[tuple[str, str, str, dict]] = []
        self._result = result

    async def __call__(self, token: str, title: str, body: str, data: dict | None = None) -> bool:
        self.calls.append((token, title, body, data or {}))
        return self._result


def ring(client, token, user_id, devotion_id, target_ids):
    return client.post("/devotions/ring", json={
        "devotion_id": devotion_id, "user_id": user_id, "target_ids": target_ids,
    }, headers=cookie_header(token))


def ring_pushes(push: "_CapturingPush"):
    """Filter a _CapturingPush's captured calls down to genuine ring pushes
    (data.action == "ring") -- excludes the separately-scoped, out-of-bounds
    `_notify_session_created` "New Session" push that `POST /devotions/`
    create also fires whenever a target already has a device token
    registered at session-creation time. That push is unrelated to this
    feature's own send-count guarantees (see intake-spec.md's "Explicitly
    out of scope" -- `_notify_session_created` is untouched by this task),
    so counting ring-specific pushes is the correct signal here, not raw
    call count."""
    return [c for c in push.calls if c[3].get("action") == "ring"]


# ── 1. Forged creator_id/participants alone can't pass ring's caller check ──

def test_forged_session_membership_denied_without_real_group_roster(client):
    print("=== 1. is_authorized alone (via self-declared creator_id) is not enough -- "
          "real_group_roster must independently confirm membership ===")
    uid_owner, tok_owner = signup(client, "ring_forge_owner")
    uid_real_member, _ = signup(client, "ring_forge_member")
    uid_attacker, tok_attacker = signup(client, "ring_forge_attacker")
    gid = None
    devo_id = None
    try:
        # Real group: owner + real_member only. Attacker is NOT a member.
        gid = create_group(client, tok_owner, uid_owner, [uid_real_member])

        # Attacker creates their OWN session (they are genuinely its
        # creator_id/participant per the client-supplied DevotionPlan) but
        # points group_id at a real group they were never added to.
        devo_id = create_session(
            client, tok_attacker, uid_attacker,
            creator_id=uid_attacker, group_id=gid, participants=[uid_attacker],
        )
        set_live_call(devo_id)

        r = ring(client, tok_attacker, uid_attacker, devo_id, [uid_real_member])
        check("attacker whose creator_id/participants claim membership, but who "
              "is NOT in the group's real roster, is denied 403 (not 200 with a "
              "per-target reason) -- is_authorized alone would have passed this",
              r.status_code == 403, f"{r.status_code} {r.text}")
    finally:
        cleanup(uid_owner, uid_real_member, uid_attacker,
                group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


# ── 2. Real group membership: happy path + target-not-a-member denial ──────

def test_real_group_member_can_ring_member_but_not_outsider(client):
    print("\n=== 2. Real group ring: member -> member succeeds; member -> outsider is not_a_member ===")
    uid_a, tok_a = signup(client, "ring_real_a")
    uid_b, _ = signup(client, "ring_real_b")
    uid_outsider, _ = signup(client, "ring_real_outsider")
    orig_send_push = devotion_backend_module.__dict__.get("send_push")
    gid = None
    devo_id = None
    try:
        gid = create_group(client, tok_a, uid_a, [uid_b])
        devo_id = create_session(client, tok_a, uid_a, creator_id=uid_a, group_id=gid, participants=[])
        set_device_token(uid_b, f"tok-{uid_b}")

        # 2a. No live call yet -- denied with no_active_call, not a 403, and
        # no push attempted at all.
        import backend.interactions.push as push_module
        push = _CapturingPush(result=True)
        push_module.send_push = push
        r0 = ring(client, tok_a, uid_a, devo_id, [uid_b])
        check("ring before any live call attached -> 200 with per-target no_active_call",
              r0.status_code == 200 and r0.json()["results"][uid_b] == {"sent": False, "reason": "no_active_call"},
              f"{r0.status_code} {r0.text}")
        check("no push attempted while gated by no_active_call", len(push.calls) == 0, str(push.calls))

        # 2b. Attach a real live call -- member -> member now succeeds.
        set_live_call(devo_id)
        r1 = ring(client, tok_a, uid_a, devo_id, [uid_b])
        check("real group member ringing another real member with a live call -> sent",
              r1.status_code == 200 and r1.json()["results"][uid_b]["sent"] is True,
              f"{r1.status_code} {r1.text}")
        check("exactly one push sent, to the target's real device token",
              len(push.calls) == 1 and push.calls[0][0] == f"tok-{uid_b}", str(push.calls))
        check("push data payload carries action=ring and the live devotion_id for deep-linking",
              push.calls[0][3].get("action") == "ring" and push.calls[0][3].get("devotion_id") == devo_id,
              str(push.calls))

        # 2c. Ringing a real, signed-up user who is genuinely NOT in this
        # group's roster -> not_a_member, even though nothing else is wrong.
        r2 = ring(client, tok_a, uid_a, devo_id, [uid_outsider])
        check("ringing a real user outside the session's own group -> not_a_member",
              r2.status_code == 200 and r2.json()["results"][uid_outsider] == {"sent": False, "reason": "not_a_member"},
              f"{r2.status_code} {r2.text}")
    finally:
        import backend.interactions.push as push_module
        if orig_send_push is not None:
            push_module.send_push = orig_send_push
        cleanup(uid_a, uid_b, uid_outsider, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


# ── 3. DM-encoded group_id: unverified pair denied, verified pair allowed ──

def test_dm_group_id_requires_verified_mutual_friendship(client):
    print("\n=== 3. DM-encoded group_id: self-minted pair denied; verified friend pair allowed; "
          "block undoes it ===")
    uid_x, tok_x = signup(client, "ring_dm_x")
    uid_y, _ = signup(client, "ring_dm_y")
    uid_z, _ = signup(client, "ring_dm_z")
    import backend.interactions.push as push_module
    orig_send_push = push_module.send_push
    devo_ids = []
    try:
        # 3a. X and Y are strangers -- X self-mints a DM group_id "X|Y" with
        # no real friendship behind it.
        gid_xy = f"{uid_x}|{uid_y}"
        devo_xy = create_session(client, tok_x, uid_x, creator_id=uid_x, group_id=gid_xy, participants=[uid_x, uid_y])
        devo_ids.append(devo_xy)
        set_live_call(devo_xy)
        r1 = ring(client, tok_x, uid_x, devo_xy, [uid_y])
        check("self-minted DM group_id with NO real friendship -> 403 "
              "(caller X is not even in their own empty real_group_roster)",
              r1.status_code == 403, f"{r1.status_code} {r1.text}")

        # 3b. Make X and Z genuine, non-blocked mutual friends -- the exact
        # legitimate case this session model supports (ringing a real DM
        # call partner).
        make_friends(uid_x, uid_z)
        set_device_token(uid_z, f"tok-{uid_z}")
        push = _CapturingPush(result=True)
        push_module.send_push = push

        gid_xz = f"{uid_x}|{uid_z}"
        devo_xz = create_session(client, tok_x, uid_x, creator_id=uid_x, group_id=gid_xz, participants=[uid_x, uid_z])
        devo_ids.append(devo_xz)
        set_live_call(devo_xz)
        r2 = ring(client, tok_x, uid_x, devo_xz, [uid_z])
        check("verified mutual-friend, non-blocked DM pair -> sent",
              r2.status_code == 200 and r2.json()["results"][uid_z]["sent"] is True,
              f"{r2.status_code} {r2.text}")
        check("exactly one ring push sent for the legitimate DM ring",
              len(ring_pushes(push)) == 1, str(push.calls))

        # 3c. Same friend pair, but Z has since blocked X -- must now be
        # denied the same fail-closed way (merged reason, not distinguished
        # from "not friends").
        make_blocked(uid_z, uid_x)
        gid_xz_2 = f"{uid_x}|{uid_z}"
        devo_xz_2 = create_session(client, tok_x, uid_x, creator_id=uid_x, group_id=gid_xz_2, participants=[uid_x, uid_z])
        devo_ids.append(devo_xz_2)
        set_live_call(devo_xz_2)
        r3 = ring(client, tok_x, uid_x, devo_xz_2, [uid_z])
        check("a friendship undone by a block (either direction) -> still denied 403, "
              "despite a real user_friends row existing",
              r3.status_code == 403, f"{r3.status_code} {r3.text}")

        # 3d. Malformed split (not the well-formed 2-distinct-id shape) --
        # e.g. an id paired with itself -- fails closed too.
        gid_malformed = f"{uid_x}|{uid_x}"
        devo_malformed = create_session(client, tok_x, uid_x, creator_id=uid_x, group_id=gid_malformed, participants=[uid_x])
        devo_ids.append(devo_malformed)
        set_live_call(devo_malformed)
        r4 = ring(client, tok_x, uid_x, devo_malformed, [uid_x])
        check("degenerate DM split (same id twice) -> fails closed (403), never trusted as a roster",
              r4.status_code == 403, f"{r4.status_code} {r4.text}")
    finally:
        push_module.send_push = orig_send_push
        cleanup(uid_x, uid_y, uid_z, devotion_ids=devo_ids)


# ── 4. chime_meeting_id live-call gate + create-time hardening ─────────────

def test_live_call_gate_and_chime_meeting_id_cannot_be_client_forged(client):
    print("\n=== 4. chime_meeting_id gate: no_active_call up front; cannot be self-minted at create ===")
    uid_a, tok_a = signup(client, "ring_live_a")
    uid_b, _ = signup(client, "ring_live_b")
    uid_c, _ = signup(client, "ring_live_c")
    gid = None
    devo_id = None
    devo_id_forged = None
    try:
        gid = create_group(client, tok_a, uid_a, [uid_b, uid_c])
        devo_id = create_session(client, tok_a, uid_a, creator_id=uid_a, group_id=gid, participants=[])
        set_device_token(uid_b, f"tok-{uid_b}")
        set_device_token(uid_c, f"tok-{uid_c}")

        # 4a. No live call yet -- EVERY target denied up front with
        # no_active_call, before any per-target membership/cooldown check.
        r1 = ring(client, tok_a, uid_a, devo_id, [uid_b, uid_c])
        results = r1.json().get("results", {})
        check("no_active_call applies to every requested target at once",
              r1.status_code == 200
              and results.get(uid_b) == {"sent": False, "reason": "no_active_call"}
              and results.get(uid_c) == {"sent": False, "reason": "no_active_call"},
              f"{r1.status_code} {r1.text}")

        # 4b. A caller who POSTs a self-chosen non-empty chime_meeting_id at
        # session-creation time must NOT get a "live call" for free --
        # security's 3rd pass fix (DevotionManager.save_devotion hardcodes
        # chime_meeting_id/chime_meeting to empty on create regardless of
        # request body content).
        devo_id_forged = create_session(
            client, tok_a, uid_a, creator_id=uid_a, group_id=gid, participants=[],
            chime_meeting_id="forged-meeting-id-not-real",
        )
        row = get_session_row(devo_id_forged)
        check("a client-supplied chime_meeting_id on create is discarded server-side "
              "(the persisted session's chime_meeting_id is empty)",
              not row.get("chime_meeting_id"), str(row.get("chime_meeting_id")))

        r2 = ring(client, tok_a, uid_a, devo_id_forged, [uid_b])
        check("ring against a session with a client-forged (never persisted) "
              "chime_meeting_id still sees no_active_call -- the gate is genuinely "
              "server-only, not bypassable via the create payload",
              r2.status_code == 200 and r2.json()["results"][uid_b] == {"sent": False, "reason": "no_active_call"},
              f"{r2.status_code} {r2.text}")
    finally:
        cleanup(uid_a, uid_b, uid_c, group_ids=[gid] if gid else (),
                devotion_ids=[d for d in (devo_id, devo_id_forged) if d])


# ── 5. Cross-session cooldown enforcement + fresh-session-id boundary ──────

def test_cross_session_cooldown_and_fresh_session_does_not_reset_it(client):
    print("\n=== 5. Cross-session ring_cooldowns: rate-limited within window; a FRESH session_id "
          "does NOT reset it; backdating past the window allows a retry ===")
    uid_a, tok_a = signup(client, "ring_cd_a")
    uid_b, _ = signup(client, "ring_cd_b")
    import backend.interactions.push as push_module
    orig_send_push = push_module.send_push
    gid = None
    devo_id_1 = None
    devo_id_2 = None
    try:
        gid = create_group(client, tok_a, uid_a, [uid_b])
        set_device_token(uid_b, f"tok-{uid_b}")
        push = _CapturingPush(result=True)
        push_module.send_push = push

        devo_id_1 = create_session(client, tok_a, uid_a, creator_id=uid_a, group_id=gid, participants=[])
        set_live_call(devo_id_1)

        r1 = ring(client, tok_a, uid_a, devo_id_1, [uid_b])
        check("first ring in session 1 succeeds -> sent",
              r1.status_code == 200 and r1.json()["results"][uid_b]["sent"] is True, f"{r1.status_code} {r1.text}")

        r2 = ring(client, tok_a, uid_a, devo_id_1, [uid_b])
        check("second ring to the same recipient inside the cooldown (same session) -> rate_limited",
              r2.status_code == 200 and r2.json()["results"][uid_b] == {"sent": False, "reason": "rate_limited"},
              f"{r2.status_code} {r2.text}")
        check("still exactly one real ring push sent so far", len(ring_pushes(push)) == 1, str(push.calls))

        # Boundary: a brand-new session_id between the SAME real (sender,
        # recipient) pair must NOT reset the cooldown -- this is exactly the
        # gap the 2nd security bounce closed (dropping session_id from the
        # claim_ring_slot key).
        devo_id_2 = create_session(client, tok_a, uid_a, creator_id=uid_a, group_id=gid, participants=[])
        set_live_call(devo_id_2)
        r3 = ring(client, tok_a, uid_a, devo_id_2, [uid_b])
        check("ringing the same recipient from a FRESH session_id still -> rate_limited "
              "(a new session_id must never reset the cross-session cooldown)",
              r3.status_code == 200 and r3.json()["results"][uid_b] == {"sent": False, "reason": "rate_limited"},
              f"{r3.status_code} {r3.text}")
        check("still exactly one real ring push sent (the fresh-session ring did not go through)",
              len(ring_pushes(push)) == 1, str(push.calls))

        # Backdate past the window -- a subsequent ring (from either session)
        # now succeeds again, proving the cooldown does genuinely expire.
        backdate_ring_cooldown(uid_a, uid_b, datetime.now(tzmod.utc) - timedelta(minutes=6))
        r4 = ring(client, tok_a, uid_a, devo_id_2, [uid_b])
        check("a ring attempted just past the cooldown window succeeds again",
              r4.status_code == 200 and r4.json()["results"][uid_b]["sent"] is True, f"{r4.status_code} {r4.text}")
        check("the reset ring sends a genuine second ring push", len(ring_pushes(push)) == 2, str(push.calls))
    finally:
        push_module.send_push = orig_send_push
        cleanup(uid_a, uid_b, group_ids=[gid] if gid else (),
                devotion_ids=[d for d in (devo_id_1, devo_id_2) if d])


# ── 6. Fail-fast config validation ──────────────────────────────────────────

def test_validate_ring_config_fails_fast_on_every_bad_shape(client):
    print("\n=== 6. validate_ring_config() fails loudly for every unset/invalid shape ===")
    mod = devotion_backend_module
    orig_flag_raw = mod._RING_FEATURE_ENABLED_RAW
    orig_cooldown_raw = mod._RING_COOLDOWN_MINUTES_RAW
    orig_flag = mod.RING_FEATURE_ENABLED
    orig_cooldown = mod.RING_COOLDOWN_MINUTES
    try:
        cases = [
            ("RING_FEATURE_ENABLED unset", None, "5"),
            ("RING_FEATURE_ENABLED not a bool string", "maybe", "5"),
            ("RING_COOLDOWN_MINUTES unset", "true", None),
            ("RING_COOLDOWN_MINUTES not an integer", "true", "soon"),
            ("RING_COOLDOWN_MINUTES zero", "true", "0"),
            ("RING_COOLDOWN_MINUTES negative", "true", "-5"),
        ]
        for label, flag_raw, cooldown_raw in cases:
            mod._RING_FEATURE_ENABLED_RAW = flag_raw
            mod._RING_COOLDOWN_MINUTES_RAW = cooldown_raw
            raised = False
            try:
                mod.validate_ring_config()
            except RingConfigError:
                raised = True
            check(f"validate_ring_config() raises RingConfigError for: {label}", raised, label)

        # A genuinely valid shape must NOT raise, and must actually populate
        # the typed globals other code reads via is_ring_enabled()/
        # RING_COOLDOWN_MINUTES.
        mod._RING_FEATURE_ENABLED_RAW = "TRUE"
        mod._RING_COOLDOWN_MINUTES_RAW = "7"
        mod.validate_ring_config()
        check("a valid config (case-insensitive 'TRUE', positive int) parses without raising "
              "and sets RING_FEATURE_ENABLED/RING_COOLDOWN_MINUTES correctly",
              mod.RING_FEATURE_ENABLED is True and mod.RING_COOLDOWN_MINUTES == 7,
              f"enabled={mod.RING_FEATURE_ENABLED} cooldown={mod.RING_COOLDOWN_MINUTES}")
    finally:
        mod._RING_FEATURE_ENABLED_RAW = orig_flag_raw
        mod._RING_COOLDOWN_MINUTES_RAW = orig_cooldown_raw
        mod.RING_FEATURE_ENABLED = orig_flag
        mod.RING_COOLDOWN_MINUTES = orig_cooldown
        # Restore the real validated state for every subsequent test in this
        # file/process (this file sets RING_FEATURE_ENABLED=true,
        # RING_COOLDOWN_MINUTES=5 at import time).
        mod.validate_ring_config()


# ── 7. Feature flag disabled -> 404 exactly as if the route didn't exist ───

def test_ring_feature_disabled_returns_404(client):
    print("\n=== 7. RING_FEATURE_ENABLED=False -> 404, no 'disabled' leak ===")
    uid_a, tok_a = signup(client, "ring_flag_a")
    uid_b, _ = signup(client, "ring_flag_b")
    gid = None
    devo_id = None
    orig = devotion_backend_module.RING_FEATURE_ENABLED
    try:
        gid = create_group(client, tok_a, uid_a, [uid_b])
        devo_id = create_session(client, tok_a, uid_a, creator_id=uid_a, group_id=gid, participants=[])
        set_live_call(devo_id)
        set_device_token(uid_b, f"tok-{uid_b}")

        devotion_backend_module.RING_FEATURE_ENABLED = False
        r = ring(client, tok_a, uid_a, devo_id, [uid_b])
        check("disabled feature flag -> 404 (indistinguishable from a nonexistent route)",
              r.status_code == 404, f"{r.status_code} {r.text}")
    finally:
        devotion_backend_module.RING_FEATURE_ENABLED = orig
        cleanup(uid_a, uid_b, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def main():
    with TestClient(main_module.app) as client:
        test_forged_session_membership_denied_without_real_group_roster(client)
        test_real_group_member_can_ring_member_but_not_outsider(client)
        test_dm_group_id_requires_verified_mutual_friendship(client)
        test_live_call_gate_and_chime_meeting_id_cannot_be_client_forged(client)
        test_cross_session_cooldown_and_fresh_session_does_not_reset_it(client)
        test_validate_ring_config_fails_fast_on_every_bad_shape(client)
        test_ring_feature_disabled_returns_404(client)

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
