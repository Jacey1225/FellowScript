"""Tests for the CallKit + PushKit VoIP ring-delivery feature (task
20260916-callkit-voip-ring, testing step 4 -- the final backend-facing
workflow step).

Covers, per architecture.json step 4's charter and the intake spec's
acceptance criteria, the backend half of this task:
`backend.interactions.push.send_voip_push`/`validate_voip_config`,
`backend.interactions.devotion.validate_ring_config`'s new
RING_VOIP_ENABLED/RING_TIMEOUT_SECONDS fields, `DevotionManager.
voip_device_tokens_bulk`, `routes.notifications.register_voip_device_token`,
and `routes.devotion.ring_members`'s new VoIP-delivery branch:

  1. `validate_voip_config()` fails fast (raises `APNsConfigError`) when
     VOIP_APNS_TOPIC is unset, and when it's set but doesn't match the exact
     `f"{BUNDLE_ID}.voip"` shape Apple mandates; passes for a correctly
     formed topic.
  2. `send_voip_push()` builds the exact payload/headers shape Apple's VoIP
     push contract requires (`apns-push-type: voip`, `apns-topic` is the
     dedicated VoIP topic -- never the plain BUNDLE_ID, `apns-priority: 10`,
     no `aps.alert`/`aps.sound`, caller `data` merged in) and raises
     `APNsConfigError` (not a silent `False`) when VOIP_APNS_TOPIC is unset,
     mirroring `send_push`'s fail-fast posture.
  3. `validate_ring_config()`'s two new fields (RING_VOIP_ENABLED,
     RING_TIMEOUT_SECONDS) fail fast for every unset/invalid shape, exactly
     like the two pre-existing fields already covered by
     `test_ring_members.py`, and a valid config populates
     `is_ring_voip_enabled()`/`ring_timeout_seconds()` correctly.
  4. VoIP device-token registration (`POST /notification/{user_id}/
     voip-device-token`) is a distinct token store from the pre-existing
     plain APNs `device_tokens` table: happy path (204, row persisted),
     missing-token error path (400), and the auth boundary (a caller cannot
     register a VoIP token on another user's behalf -- 403).
  5. `ring_members` end to end with `RING_VOIP_ENABLED=true`: a target with
     only a VoIP token (no plain APNs token) is rung via `send_voip_push`
     with the correct data shape (action/devotion_id/group_id/caller_id/
     caller_username/session_title/ring_timeout_seconds); a target with only
     a *plain* APNs token (no VoIP token) fails loud with `"no_voip_token"`,
     never silently falling back to the plain token/`send_push`; the
     cross-session cooldown claim/release semantics are unchanged (a failed
     VoIP send releases the claim, same as the plain-push path).
  6. `RING_VOIP_ENABLED=false` (the default/fallback): `ring_members`'s
     behavior for the exact same setup is byte-for-byte the pre-existing
     plain-APNs-push path (`test_ring_members.py`'s own coverage) -- this
     file adds one direct toggle test proving the flag actually switches
     delivery mechanism for the identical scenario, not just that each mode
     works in isolation.

Run with: cd api && ../.venv/bin/python tests/test_callkit_voip_ring.py
"""
import _pathfix  # noqa: F401,E402

import importlib
import os
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from dotenv import load_dotenv  # noqa: E402
load_dotenv()

os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

# Ring feature + VoIP delivery both forced ON for this file, regardless of
# the real .env's off-by-default rollout values -- both vars are read at
# `backend.interactions.devotion` *import time*, so this must happen before
# that module (or `main`, which imports it transitively) is first imported.
os.environ["RING_FEATURE_ENABLED"] = "true"
os.environ["RING_COOLDOWN_MINUTES"] = "5"
os.environ["RING_VOIP_ENABLED"] = "true"
os.environ["RING_TIMEOUT_SECONDS"] = "30"

from fastapi.testclient import TestClient  # noqa: E402

from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402
import backend.interactions.devotion as devotion_backend_module  # noqa: E402
from backend.interactions.devotion import DevotionManager, RingConfigError  # noqa: E402
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
    global _signup_counter
    _signup_counter += 1
    fake_ip = f"203.0.118.{_signup_counter % 250 + 1}"
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
        "group_id": gid, "title": "VoIP ring test group", "users": [owner_uid, *member_uids],
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def create_session(client, token, user_id, creator_id, group_id, participants=None):
    devo_id = str(uuid.uuid4())
    payload = {
        "devotion_id": devo_id, "user_id": user_id,
        "devotion": {
            "id": devo_id, "title": "VoIP ring test session", "creator_id": creator_id,
            "participants": participants or [], "group_id": group_id,
            "prompts": ["p1"], "verses": [], "chime_meeting_id": "",
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


def get_voip_token_row(user_id: str):
    db = DBManager()
    try:
        db.cur.execute("SELECT token FROM voip_device_tokens WHERE user_id = %s", (user_id,))
        return db.cur.fetchone()
    finally:
        db.close()


def set_live_call(session_id: str) -> None:
    db = DevotionManager()
    try:
        db.save_chime_meeting(session_id, f"meeting-{uuid.uuid4()}", {"MeetingId": "fake"})
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
            db.cur.execute("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM voip_device_tokens WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


class _CapturingVoipPush:
    """Same "patch the module attribute `routes.devotion.ring_members`'s own
    local import re-resolves from" technique `test_ring_members.py`'s
    `_CapturingPush` established -- `ring_members` does
    `from backend.interactions.push import send_push, send_voip_push` as a
    LOCAL import inside the route function, so this must patch
    `backend.interactions.push.send_voip_push`, not
    `routes.devotion.send_voip_push`."""

    def __init__(self, result: bool = True):
        self.calls: list[tuple[str, dict]] = []
        self._result = result

    async def __call__(self, device_token: str, data: dict) -> bool:
        self.calls.append((device_token, data))
        return self._result


class _CapturingPlainPush:
    """Matches `send_push`'s real signature (`device_token, title, body,
    data=None`) -- distinct from `_CapturingVoipPush` above, which matches
    `send_voip_push`'s (`device_token, data`). Using the wrong shape as a
    stand-in for the wrong function silently breaks argument binding (a
    `TypeError` raised before the fake's body even runs, which `ring_members`
    then swallows into a misleading `send_failed` -- exactly the class of
    test-fixture bug this distinction avoids)."""

    def __init__(self, result: bool = True):
        self.calls: list[tuple[str, str, str, dict]] = []
        self._result = result

    async def __call__(self, device_token: str, title: str, body: str, data: dict | None = None) -> bool:
        self.calls.append((device_token, title, body, data or {}))
        return self._result


def ring(client, token, user_id, devotion_id, target_ids):
    return client.post("/devotions/ring", json={
        "devotion_id": devotion_id, "user_id": user_id, "target_ids": target_ids,
    }, headers=cookie_header(token))


# ── 1. validate_voip_config() fail-fast shapes ──────────────────────────────

def test_validate_voip_config_fails_fast_on_every_bad_shape():
    print("=== 1. validate_voip_config() raises for unset/malformed VOIP_APNS_TOPIC, "
          "passes for the correct <bundle-id>.voip shape ===")
    orig_topic = push_module.VOIP_APNS_TOPIC
    try:
        push_module.VOIP_APNS_TOPIC = ""
        raised = False
        try:
            push_module.validate_voip_config()
        except APNsConfigError as e:
            raised = True
            check("unset VOIP_APNS_TOPIC error names it", "VOIP_APNS_TOPIC" in str(e), str(e))
        check("unset VOIP_APNS_TOPIC raises APNsConfigError", raised)

        push_module.VOIP_APNS_TOPIC = "com.wrong.topic"
        raised = False
        try:
            push_module.validate_voip_config()
        except APNsConfigError as e:
            raised = True
            check("malformed VOIP_APNS_TOPIC error names the expected shape",
                  "voip" in str(e).lower(), str(e))
        check("malformed (non <bundle-id>.voip) VOIP_APNS_TOPIC raises APNsConfigError", raised)

        push_module.VOIP_APNS_TOPIC = f"{push_module.BUNDLE_ID}.voip"
        try:
            push_module.validate_voip_config()
            check("correctly formed <bundle-id>.voip topic does not raise", True)
        except APNsConfigError as e:
            check("correctly formed <bundle-id>.voip topic does not raise", False, str(e))
    finally:
        push_module.VOIP_APNS_TOPIC = orig_topic


# ── 2. send_voip_push() payload/header shape + fail-fast ───────────────────

def test_send_voip_push_builds_correct_apple_voip_contract_shape():
    print("\n=== 2. send_voip_push() headers/payload match Apple's VoIP push contract; "
          "raises APNsConfigError (not silent False) when unconfigured ===")
    orig_topic = push_module.VOIP_APNS_TOPIC
    orig_post = push_module._post_to_apns
    captured = {}

    async def fake_post_to_apns(device_token, headers, payload):
        captured["device_token"] = device_token
        captured["headers"] = headers
        captured["payload"] = payload
        return True

    try:
        push_module.VOIP_APNS_TOPIC = f"{push_module.BUNDLE_ID}.voip"
        push_module._post_to_apns = fake_post_to_apns
        import asyncio
        result = asyncio.run(push_module.send_voip_push(
            "fake-voip-device-token",
            data={"action": "ring", "devotion_id": "d1", "group_id": "g1"},
        ))
        check("send_voip_push returns True on a successful post", result is True)
        check("apns-push-type is 'voip', not 'alert'",
              captured["headers"].get("apns-push-type") == "voip", captured.get("headers"))
        check("apns-topic is the dedicated VoIP topic, never the plain BUNDLE_ID",
              captured["headers"].get("apns-topic") == f"{push_module.BUNDLE_ID}.voip"
              and captured["headers"].get("apns-topic") != push_module.BUNDLE_ID,
              captured.get("headers"))
        check("apns-priority is '10' (immediate) -- Apple requires this for every VoIP push",
              captured["headers"].get("apns-priority") == "10", captured.get("headers"))
        check("payload carries no aps.alert (a VoIP push must never show a system notification)",
              "alert" not in captured["payload"].get("aps", {}), captured.get("payload"))
        check("payload carries no aps.sound", "sound" not in captured["payload"].get("aps", {}), captured.get("payload"))
        check("caller data is merged directly into the payload",
              captured["payload"].get("action") == "ring"
              and captured["payload"].get("devotion_id") == "d1"
              and captured["payload"].get("group_id") == "g1",
              captured.get("payload"))

        # Unconfigured VOIP_APNS_TOPIC -- must raise, not silently send/return False.
        push_module.VOIP_APNS_TOPIC = ""
        try:
            asyncio.run(push_module.send_voip_push("fake-voip-device-token", data={}))
            check("send_voip_push raises APNsConfigError when VOIP_APNS_TOPIC is unset", False,
                  "did not raise")
        except APNsConfigError:
            check("send_voip_push raises APNsConfigError when VOIP_APNS_TOPIC is unset", True)
    finally:
        push_module.VOIP_APNS_TOPIC = orig_topic
        push_module._post_to_apns = orig_post


# ── 3. validate_ring_config()'s new VoIP fields ─────────────────────────────

def test_validate_ring_config_voip_fields_fail_fast_on_every_bad_shape():
    print("\n=== 3. validate_ring_config()'s RING_VOIP_ENABLED/RING_TIMEOUT_SECONDS fail "
          "fast for every unset/invalid shape; a valid config populates the fresh-lookup "
          "getters correctly ===")
    mod = devotion_backend_module
    orig_voip_raw = mod._RING_VOIP_ENABLED_RAW
    orig_timeout_raw = mod._RING_TIMEOUT_SECONDS_RAW
    orig_flag_raw = mod._RING_FEATURE_ENABLED_RAW
    orig_cooldown_raw = mod._RING_COOLDOWN_MINUTES_RAW
    orig_voip = mod.RING_VOIP_ENABLED
    orig_timeout = mod.RING_TIMEOUT_SECONDS
    try:
        # Keep the two pre-existing fields valid throughout so only the new
        # fields' own validation is under test here.
        mod._RING_FEATURE_ENABLED_RAW = "true"
        mod._RING_COOLDOWN_MINUTES_RAW = "5"

        cases = [
            ("RING_VOIP_ENABLED unset", None, "30"),
            ("RING_VOIP_ENABLED not a bool string", "sometimes", "30"),
            ("RING_TIMEOUT_SECONDS unset", "true", None),
            ("RING_TIMEOUT_SECONDS not an integer", "true", "soon"),
            ("RING_TIMEOUT_SECONDS zero", "true", "0"),
            ("RING_TIMEOUT_SECONDS negative", "true", "-30"),
        ]
        for label, voip_raw, timeout_raw in cases:
            mod._RING_VOIP_ENABLED_RAW = voip_raw
            mod._RING_TIMEOUT_SECONDS_RAW = timeout_raw
            raised = False
            try:
                mod.validate_ring_config()
            except RingConfigError:
                raised = True
            check(f"validate_ring_config() raises RingConfigError for: {label}", raised, label)

        mod._RING_VOIP_ENABLED_RAW = "TRUE"
        mod._RING_TIMEOUT_SECONDS_RAW = "45"
        mod.validate_ring_config()
        check("a valid VoIP config (case-insensitive 'TRUE', positive int timeout) parses "
              "without raising and sets RING_VOIP_ENABLED/RING_TIMEOUT_SECONDS correctly",
              mod.RING_VOIP_ENABLED is True and mod.RING_TIMEOUT_SECONDS == 45,
              f"enabled={mod.RING_VOIP_ENABLED} timeout={mod.RING_TIMEOUT_SECONDS}")
        check("is_ring_voip_enabled() reflects the fresh-validated value (not import-time)",
              mod.is_ring_voip_enabled() is True)
        check("ring_timeout_seconds() reflects the fresh-validated value (not import-time)",
              mod.ring_timeout_seconds() == 45)
    finally:
        mod._RING_VOIP_ENABLED_RAW = orig_voip_raw
        mod._RING_TIMEOUT_SECONDS_RAW = orig_timeout_raw
        mod._RING_FEATURE_ENABLED_RAW = orig_flag_raw
        mod._RING_COOLDOWN_MINUTES_RAW = orig_cooldown_raw
        mod.RING_VOIP_ENABLED = orig_voip
        mod.RING_TIMEOUT_SECONDS = orig_timeout
        # Restore the real validated state (this file forces RING_VOIP_ENABLED=true,
        # RING_TIMEOUT_SECONDS=30 at import time) for every subsequent test/file.
        mod.validate_ring_config()


# ── 4. VoIP device-token registration: happy path, error path, auth boundary ─

def test_voip_device_token_registration_happy_error_and_auth_boundary(client):
    print("\n=== 4. POST /notification/{user_id}/voip-device-token: happy path persists to "
          "the DISTINCT voip_device_tokens table (not device_tokens); missing token -> 400; "
          "another user cannot register on someone else's behalf -> 403 ===")
    uid_a, tok_a = signup(client, "voip_reg_a")
    uid_b, tok_b = signup(client, "voip_reg_b")
    try:
        r1 = client.post(f"/notification/{uid_a}/voip-device-token", json={"token": "voip-tok-a"},
                          headers=cookie_header(tok_a))
        check("happy path registration returns 204", r1.status_code == 204, f"{r1.status_code} {r1.text}")
        row = get_voip_token_row(uid_a)
        check("token persisted to the distinct voip_device_tokens table",
              row is not None and row[0] == "voip-tok-a", row)

        r2 = client.post(f"/notification/{uid_a}/voip-device-token", json={"token": ""},
                          headers=cookie_header(tok_a))
        check("empty/missing token -> 400, not a 500 or silent success",
              r2.status_code == 400, f"{r2.status_code} {r2.text}")

        r3 = client.post(f"/notification/{uid_a}/voip-device-token", json={"token": "hijacked-token"},
                          headers=cookie_header(tok_b))
        check("user B cannot register a VoIP token on user A's behalf -> 403 (require_match)",
              r3.status_code == 403, f"{r3.status_code} {r3.text}")
        row_after = get_voip_token_row(uid_a)
        check("the attempted cross-user registration did not overwrite A's real token",
              row_after is not None and row_after[0] == "voip-tok-a", row_after)
    finally:
        cleanup(uid_a, uid_b)


# ── 5. ring_members end to end, RING_VOIP_ENABLED=true ──────────────────────

def test_ring_members_voip_enabled_sends_via_voip_push_and_fails_loud_on_missing_voip_token(client):
    print("\n=== 5. RING_VOIP_ENABLED=true: sends via send_voip_push with the correct data "
          "shape when a VoIP token exists; fails loud with no_voip_token (never falling back "
          "to a registered plain-APNs token) when it doesn't ===")
    orig_voip_send = push_module.send_voip_push
    orig_plain_send = push_module.send_push
    gid = None
    devo_id = None

    uid_a, tok_a = signup(client, "voip_ring_a")
    uid_b, tok_b = signup(client, "voip_ring_b")
    uid_c, tok_c = signup(client, "voip_ring_c")
    gid = None
    devo_id = None
    try:
        gid = create_group(client, tok_a, uid_a, [uid_b, uid_c])
        devo_id = create_session(client, tok_a, uid_a, creator_id=uid_a, group_id=gid, participants=[])
        set_live_call(devo_id)

        r_reg = client.post(f"/notification/{uid_b}/voip-device-token", json={"token": f"voip-tok-{uid_b}"},
                             headers=cookie_header(tok_b))
        assert r_reg.status_code == 204, f"voip token registration failed: {r_reg.status_code} {r_reg.text}"
        set_device_token(uid_c, f"plain-tok-{uid_c}")  # uid_c: plain APNs token only, no VoIP token

        voip_push = _CapturingVoipPush(result=True)
        push_module.send_voip_push = voip_push
        push_module.send_push = _CapturingPlainPush(result=True)  # must never be called for either target

        r = ring(client, tok_a, uid_a, devo_id, [uid_b, uid_c])
        check("ring response is 200", r.status_code == 200, f"{r.status_code} {r.text}")
        results = r.json().get("results", {})

        check("target with a registered VoIP token -> sent via send_voip_push",
              results.get(uid_b) == {"sent": True, "reason": None}, results)
        check("exactly one send_voip_push call, to the VoIP token (not any plain token)",
              len(voip_push.calls) == 1 and voip_push.calls[0][0] == f"voip-tok-{uid_b}",
              voip_push.calls)
        sent_data = voip_push.calls[0][1]
        check("VoIP push data carries action=ring, devotion_id, group_id, caller identity, "
              "session_title, and ring_timeout_seconds",
              sent_data.get("action") == "ring"
              and sent_data.get("devotion_id") == devo_id
              and sent_data.get("group_id") == gid
              and sent_data.get("caller_id") == uid_a
              and isinstance(sent_data.get("caller_username"), str) and sent_data.get("caller_username")
              and "session_title" in sent_data
              and sent_data.get("ring_timeout_seconds") == devotion_backend_module.ring_timeout_seconds(),
              sent_data)

        check("target with only a plain APNs token (no VoIP token) fails loud with "
              "'no_voip_token' -- never silently falls back to the plain token/send_push",
              results.get(uid_c) == {"sent": False, "reason": "no_voip_token"}, results)
        check("send_push (plain APNs) was never invoked for either target while VoIP delivery is enabled",
              len(push_module.send_push.calls) == 0, push_module.send_push.calls)
    finally:
        push_module.send_voip_push = orig_voip_send
        push_module.send_push = orig_plain_send
        cleanup(uid_a, uid_b, uid_c, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def test_ring_members_voip_send_failure_releases_cooldown_claim(client):
    print("\n=== 5b. A failed VoIP send releases the ring cooldown claim, same as the "
          "plain-push path -- a failed delivery must not burn the sender's cooldown ===")
    uid_a, tok_a = signup(client, "voip_ring_fail_a")
    uid_b, tok_b = signup(client, "voip_ring_fail_b")
    orig_voip_send = push_module.send_voip_push
    gid = None
    devo_id = None
    try:
        gid = create_group(client, tok_a, uid_a, [uid_b])
        devo_id = create_session(client, tok_a, uid_a, creator_id=uid_a, group_id=gid, participants=[])
        set_live_call(devo_id)
        r_reg = client.post(f"/notification/{uid_b}/voip-device-token", json={"token": f"voip-tok-{uid_b}"},
                             headers=cookie_header(tok_b))
        assert r_reg.status_code == 204

        failing_push = _CapturingVoipPush(result=False)  # simulates a non-2xx APNs response
        push_module.send_voip_push = failing_push

        r1 = ring(client, tok_a, uid_a, devo_id, [uid_b])
        check("a failed VoIP send reports send_failed, not sent=True",
              r1.status_code == 200 and r1.json()["results"][uid_b] == {"sent": False, "reason": "send_failed"},
              f"{r1.status_code} {r1.text}")

        # The claim must have been released -- a second attempt right away
        # (no cooldown wait) must be allowed to try again, not rate_limited.
        push_module.send_voip_push = _CapturingVoipPush(result=True)
        r2 = ring(client, tok_a, uid_a, devo_id, [uid_b])
        check("immediately retrying after a failed send is NOT rate_limited -- "
              "the failed send's claim was correctly released",
              r2.status_code == 200 and r2.json()["results"][uid_b]["sent"] is True,
              f"{r2.status_code} {r2.text}")
    finally:
        push_module.send_voip_push = orig_voip_send
        cleanup(uid_a, uid_b, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


# ── 6. RING_VOIP_ENABLED toggle: same scenario, different delivery mechanism ─

def test_ring_voip_enabled_flag_toggles_delivery_mechanism_for_the_identical_scenario(client):
    print("\n=== 6. Toggling RING_VOIP_ENABLED for the identical (sender, recipient) pair "
          "switches delivery mechanism: off -> plain send_push via device_tokens; on (after "
          "the cooldown elapses) -> send_voip_push via voip_device_tokens, never both at once ===")
    uid_a, tok_a = signup(client, "voip_toggle_a")
    uid_b, tok_b = signup(client, "voip_toggle_b")
    orig_voip_send = push_module.send_voip_push
    orig_plain_send = push_module.send_push
    gid = None
    devo_id = None
    try:
        gid = create_group(client, tok_a, uid_a, [uid_b])
        devo_id = create_session(client, tok_a, uid_a, creator_id=uid_a, group_id=gid, participants=[])
        set_live_call(devo_id)
        set_device_token(uid_b, f"plain-tok-{uid_b}")
        r_reg = client.post(f"/notification/{uid_b}/voip-device-token", json={"token": f"voip-tok-{uid_b}"},
                             headers=cookie_header(tok_b))
        assert r_reg.status_code == 204

        plain_push = _CapturingPlainPush(result=True)
        voip_push = _CapturingVoipPush(result=True)
        push_module.send_push = plain_push
        push_module.send_voip_push = voip_push

        devotion_backend_module.RING_VOIP_ENABLED = False
        r1 = ring(client, tok_a, uid_a, devo_id, [uid_b])
        check("RING_VOIP_ENABLED=false -> delivered via plain send_push to the plain token",
              r1.status_code == 200 and r1.json()["results"][uid_b]["sent"] is True
              and len(plain_push.calls) == 1 and plain_push.calls[0][0] == f"plain-tok-{uid_b}"
              and len(voip_push.calls) == 0,
              f"plain={plain_push.calls} voip={voip_push.calls}")

        # Elapse the cooldown (same technique as test_ring_members.py's own
        # cross-session cooldown test) so the second attempt is a genuine
        # fresh send under the new delivery mechanism, not a rate_limited
        # short-circuit that would never touch either push function.
        from datetime import datetime, timedelta, timezone as tzmod
        db = DBManager()
        try:
            db.cur.execute(
                "UPDATE ring_cooldowns SET last_rung_at = %s WHERE sender_id = %s AND recipient_id = %s",
                (datetime.now(tzmod.utc) - timedelta(minutes=6), uid_a, uid_b),
            )
            db.conn.commit()
        finally:
            db.close()

        devotion_backend_module.RING_VOIP_ENABLED = True
        r2 = ring(client, tok_a, uid_a, devo_id, [uid_b])
        check("RING_VOIP_ENABLED=true, cooldown elapsed -> the SAME (sender, recipient) pair "
              "now delivers via send_voip_push to the VoIP token, and NOT a second plain push",
              r2.status_code == 200 and r2.json()["results"][uid_b]["sent"] is True
              and len(voip_push.calls) == 1 and voip_push.calls[0][0] == f"voip-tok-{uid_b}"
              and len(plain_push.calls) == 1,  # unchanged from the first (off) call
              f"plain={plain_push.calls} voip={voip_push.calls}")
    finally:
        devotion_backend_module.RING_VOIP_ENABLED = True  # restore this file's forced default
        push_module.send_voip_push = orig_voip_send
        push_module.send_push = orig_plain_send
        cleanup(uid_a, uid_b, group_ids=[gid] if gid else (), devotion_ids=[devo_id] if devo_id else ())


def main():
    test_validate_voip_config_fails_fast_on_every_bad_shape()
    test_send_voip_push_builds_correct_apple_voip_contract_shape()
    test_validate_ring_config_voip_fields_fail_fast_on_every_bad_shape()
    with TestClient(main_module.app) as client:
        test_voip_device_token_registration_happy_error_and_auth_boundary(client)
        test_ring_members_voip_enabled_sends_via_voip_push_and_fails_loud_on_missing_voip_token(client)
        test_ring_members_voip_send_failure_releases_cooldown_claim(client)
        test_ring_voip_enabled_flag_toggles_delivery_mechanism_for_the_identical_scenario(client)

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
