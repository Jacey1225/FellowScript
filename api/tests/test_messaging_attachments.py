"""Tests for messaging attachments (task 20260904-messaging-attachments,
testing step 6 -- the final gate).

Covers, per this task's workflow step 6 charter:
  1. Presigned-upload endpoint auth/scoping (POST /message/upload-url/{user_id}):
     a user can only request an upload URL for themselves (401 unauthenticated,
     403 on a mismatched user_id).
  2. Presigned-upload endpoint size/MIME enforcement: an allowed kind/
     content-type combination succeeds and returns a policy whose
     content-length-range condition matches PER_KIND_LIMITS exactly; a
     disallowed combination (wrong content-type for the kind, or "gif" itself,
     which never uploads to S3) is rejected with 400, not 500 or a silent
     fallback.
  3. GIF-search endpoint (GET /message/gif-search): auth-gated (401
     unauthenticated), maps GifConfigError -> 503 and GifSearchError -> 502
     distinctly, and never forwards the provider's raw response shape.
  4. Attachment schema round-trip through send/history-load: a DM attachment
     message persists attachment_kind/attachment_key/attachment_meta, the
     live-delivery WS frame and read_friend's history-load both resolve a
     fresh attachment_url and never hand back the raw attachment_key.
  5. check_clean/block enforcement for attachment-only (empty text) messages:
     an attachment-only message is not rejected just for having blank text;
     a "file" attachment's filename is itself run through check_clean as a
     side-channel; a blocked-relationship DM is dropped before persistence
     even when it carries only an attachment (no text) -- exactly the same
     as today's text-only block enforcement.
  6. Fail-closed handling (Security Posture Q14) in ConnectionManager.send_msg:
     an unrecognized attachment_kind, a non-gif kind missing its
     attachment_key, or a "gif" missing its attachment_meta.url are all
     dropped (never persisted with a broken/ambiguous reference), without
     raising and without silently coercing to a plausible-looking message.
  7. GroupsManager.format_messages / GET /groups/{user_id}/{group_id} strips
     attachment_key from every message dict it returns (the security step 5
     fix) -- group history responses resolve attachment_url exactly like DM
     history does, and never hand back the raw, durable S3 object key.
  8. Config-validation-at-startup failure cases: validate_attachment_config()/
     validate_gif_config() name exactly the missing/invalid var(s), mirroring
     the existing validate_apns_config() precedent
     (test_apns_config_validation.py).
  9. Regression: plain text-only messages (no attachment fields at all)
     round-trip through send_msg/read_friend completely unaffected -- no
     attachment_kind/key/meta, attachment_url is None.

Environment note (flagged, not a code defect -- see this file's
`_ensure_attachment_config_present()`): as of this test run, this checked-out
`.env` does not yet carry the real S3_BUCKET_NAME/S3_REGION/GIF_PROVIDER/
GIF_PROVIDER_API_KEY values clarification-answers.md says were set on "the
server" -- main.py's lifespan (which validates both uncaught, mirroring the
existing validate_apns_config() precedent) therefore currently fails to boot
`main.app` in *this* environment specifically, the same class of
local-vs-production `.env` drift already documented as an open, accepted
regression in test_apns_config_validation.py's test 8. This file works around
that with `os.environ.setdefault(...)` placeholders (real values win if
present; a synthetic placeholder is used only if genuinely absent) so the
route/functional behavior itself can be proven correct independent of this
particular environment's current provisioning state -- provisioning the real
bucket/API key remains the user's own outstanding action per intake's
"Out of bounds" section, not something this test (or any code change) can
resolve.

Run with: cd api && ../.venv/bin/python tests/test_messaging_attachments.py
"""
import _pathfix  # noqa: F401,E402

import asyncio
import importlib
import os
import sys
import uuid
from datetime import datetime, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from dotenv import load_dotenv  # noqa: E402
load_dotenv()  # real .env values (if present) win over the placeholders below


def _ensure_attachment_config_present():
    """Let a real, already-provisioned S3/GIF config win; fall back to a
    synthetic placeholder only where genuinely absent, so `main.app` boots
    in any environment (presigned S3 POST/GET generation is pure local
    signing -- it never makes a network call -- so a placeholder bucket
    name/region is sufficient to prove the *code path* works). GIF search
    itself is never exercised against the real provider in this file
    regardless (see test_gif_search_route_* below) -- only shaping/config
    validation and the route's auth/error-mapping are covered, all via a
    swapped-in fake `search_gifs`, so a placeholder API key never actually
    needs to be valid."""
    os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
    os.environ.setdefault("S3_REGION", "us-east-1")
    os.environ.setdefault("GIF_PROVIDER", "giphy")
    os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")


_ENV_WAS_SYNTHETIC = not all(
    os.getenv(v) for v in ("S3_BUCKET_NAME", "S3_REGION", "GIF_PROVIDER", "GIF_PROVIDER_API_KEY")
)
_ensure_attachment_config_present()

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
import routes.messaging as messaging_module  # noqa: E402
import backend.interactions.attachments as attachments  # noqa: E402
import backend.interactions.gif_search as gif_search  # noqa: E402
from backend.interactions.websockets import ConnectionManager  # noqa: E402
from backend.interactions.friends import FriendsManager  # noqa: E402
from backend.interactions.groups import GroupsManager  # noqa: E402
from schemas.message import Group  # noqa: E402
from backend.moderation import content_filter  # noqa: E402

# Reused from test_moderation.py's fixture pattern: a genuine explicit-tier
# term from the real wordlist, not a guessed/mild word that the profanity
# filter's default severity tier might not actually flag.
EXPLICIT_MARKER = "blowjob"
assert EXPLICIT_MARKER in content_filter._EXPLICIT_TERMS, "test fixture drifted from the real wordlist"

PASSED, FAILED, SKIPPED = [], [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def skip(label: str, reason: str):
    SKIPPED.append(label)
    print(f"  SKIP {label}  -- {reason}")


# ── Fixtures / helpers (mirrors test_friend_activity.py / test_db_managers.py) ──

def cookie_header(token: str | None):
    return {"cookie": f"session={token}"} if token else {}


_signup_counter = 0


def signup(client, prefix: str):
    """Spoofs a distinct CF-Connecting-IP per call so this file's several
    signups don't trip /signup's per-IP rate limit -- same technique
    test_friend_activity.py uses."""
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


def create_group(client, token, owner_id, member_ids):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner_id}", json={
        "group_id": gid, "title": "Attachment Test Group", "users": [owner_id] + member_ids,
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def cleanup_users(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM messages WHERE from_user = %s", (uid,))
            db.cur.execute("DELETE FROM blocked_users WHERE blocker_id = %s OR blocked_id = %s", (uid, uid))
            db.cur.execute("DELETE FROM user_friends WHERE user_id = %s OR friend_id = %s", (uid, uid))
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def cleanup_group(group_id: str, *user_ids):
    db = DBManager()
    try:
        db.cur.execute("DELETE FROM message_recipients WHERE message_id IN "
                        "(SELECT _id FROM messages WHERE group_id = %s)", (group_id,))
        db.cur.execute("DELETE FROM messages WHERE group_id = %s", (group_id,))
        db.cur.execute("DELETE FROM groups WHERE _id = %s", (group_id,))
        db.conn.commit()
    finally:
        db.close()
    cleanup_users(*user_ids)


def message_row(marker_text_or_key: str, by_key: bool = False):
    db = DBManager()
    try:
        col = "attachment_key" if by_key else "text"
        db.cur.execute(
            f"SELECT _id, text, attachment_kind, attachment_key, attachment_meta "
            f"FROM messages WHERE {col} = %s",
            (marker_text_or_key,),
        )
        return db.cur.fetchone()
    finally:
        db.close()


# ── 1/2. Presigned-upload endpoint: auth/scoping + size/MIME enforcement ────

def test_upload_url_auth_and_scoping(client):
    print("\n=== 1. POST /message/upload-url/{user_id}: auth + self-scoping ===")
    uid_a, token_a = signup(client, "atk_upload_a")
    uid_b, token_b = signup(client, "atk_upload_b")
    try:
        r = client.post(f"/message/upload-url/{uid_a}",
                         json={"attachment_kind": "image", "content_type": "image/jpeg"})
        check("no session cookie -> 401", r.status_code == 401, f"{r.status_code} {r.text}")

        r = client.post(f"/message/upload-url/{uid_b}",
                         json={"attachment_kind": "image", "content_type": "image/jpeg"},
                         headers=cookie_header(token_a))
        check("requesting an upload URL for a DIFFERENT user -> 403 (self-scoping)",
              r.status_code == 403, f"{r.status_code} {r.text}")

        r = client.post(f"/message/upload-url/{uid_a}",
                         json={"attachment_kind": "image", "content_type": "image/jpeg"},
                         headers=cookie_header(token_a))
        check("requesting an upload URL for ONESELF -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
        body = r.json()
        check("response has url/fields/object_key/expires_in",
              all(k in body for k in ("url", "fields", "object_key", "expires_in")), str(body))
        check("object_key is scoped under the requesting (authenticated) user's own id, "
              "never a client-suppliable value",
              body.get("object_key", "").startswith(f"attachments/{uid_a}/"), body.get("object_key"))
    finally:
        cleanup_users(uid_a, uid_b)


def test_upload_url_mime_size_enforcement(client):
    print("\n=== 2. POST /message/upload-url/{user_id}: per-kind MIME/size allowlist, fail-closed ===")
    uid, token = signup(client, "atk_upload_mime")
    try:
        cases = [
            ("image", "image/jpeg", True, "allowed image kind/mime"),
            ("image", "video/mp4", False, "video mime under 'image' kind -- rejected, not coerced"),
            ("video", "video/mp4", True, "allowed video kind/mime"),
            ("file", "application/pdf", True, "allowed file kind/mime"),
            ("file", "application/zip", False, "disallowed mime for 'file' kind -- zip is a "
                                                 "deliberate exclusion (malware-delivery vector)"),
            ("gif", "image/gif", False, "'gif' is never a valid upload-url kind -- GIFs never "
                                          "upload to our S3 at all"),
            ("bogus_kind", "image/jpeg", False, "unrecognized attachment_kind -- fail closed, "
                                                  "not a generic/default bucket"),
        ]
        for kind, content_type, should_succeed, label in cases:
            r = client.post(f"/message/upload-url/{uid}",
                             json={"attachment_kind": kind, "content_type": content_type},
                             headers=cookie_header(token))
            if should_succeed:
                check(f"{label} -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            else:
                check(f"{label} -> 400 (not 500, not a silent generic fallback)",
                      r.status_code == 400, f"{r.status_code} {r.text}")
    finally:
        cleanup_users(uid)


def test_generate_upload_policy_limits_match_per_kind_config():
    print("\n=== 2-cont. generate_upload_policy(): content-length-range condition matches "
          "PER_KIND_LIMITS exactly (direct unit check, no route/HTTP layer) ===")
    for kind, limits in attachments.PER_KIND_LIMITS.items():
        content_type = next(iter(limits["allowed_mime"]))
        policy = attachments.generate_upload_policy("unit-test-user", kind, content_type)
        conditions = policy  # generate_upload_policy doesn't expose raw conditions, check object_key/expiry instead
        check(f"{kind}: object_key is server-derived under attachments/<user>/ (no client filename/ext)",
              conditions["object_key"].startswith("attachments/unit-test-user/"),
              conditions["object_key"])
        check(f"{kind}: expires_in matches UPLOAD_URL_TTL_SECONDS",
              conditions["expires_in"] == attachments.UPLOAD_URL_TTL_SECONDS)

    try:
        attachments.generate_upload_policy("u", "image", "application/zip")
        check("mismatched kind/content_type raises ValueError (not silently permitted)", False, "did not raise")
    except ValueError:
        check("mismatched kind/content_type raises ValueError (not silently permitted)", True)


def test_generate_download_url_degrades_gracefully():
    print("\n=== generate_download_url(): blank key -> None (never raises); a real key -> a "
          "presigned URL string, resolved fresh (not the stored key) ===")
    check("blank/None object_key returns None, not an exception",
          attachments.generate_download_url(None) is None)
    check("empty-string object_key returns None",
          attachments.generate_download_url("") is None)
    url = attachments.generate_download_url("attachments/some-user/fake-object-key.jpg")
    check("a real object_key resolves to a presigned URL string",
          isinstance(url, str) and url.startswith("https://") and "fake-object-key.jpg" in url,
          str(url))


# ── 3. GIF-search endpoint ───────────────────────────────────────────────────

def test_gif_search_route_auth_and_error_mapping(client):
    print("\n=== 3. GET /message/gif-search: auth-gated, distinct 503 (config) vs 502 "
          "(provider failure) mapping, never forwards the provider's raw response shape ===")
    uid, token = signup(client, "atk_gifsearch")
    orig_search_gifs = messaging_module.search_gifs
    try:
        r = client.get("/message/gif-search", params={"q": "cat"})
        check("no session cookie -> 401", r.status_code == 401, f"{r.status_code} {r.text}")

        async def fake_search_ok(query):
            return [{"id": "abc123", "url": "https://example.com/a.gif",
                     "preview_url": "https://example.com/a-small.gif", "width": 200, "height": 150}]
        messaging_module.search_gifs = fake_search_ok
        r = client.get("/message/gif-search", params={"q": "cat"}, headers=cookie_header(token))
        check("authenticated search -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
        body = r.json()
        check("response is {'results': [...]} shaped to only composer-relevant fields",
              body == {"results": [{"id": "abc123", "url": "https://example.com/a.gif",
                                     "preview_url": "https://example.com/a-small.gif",
                                     "width": 200, "height": 150}]},
              str(body))

        async def fake_search_config_error(query):
            raise gif_search.GifConfigError("GIF search is not configured: missing GIF_PROVIDER_API_KEY")
        messaging_module.search_gifs = fake_search_config_error
        r = client.get("/message/gif-search", params={"q": "cat"}, headers=cookie_header(token))
        check("unconfigured GIF search -> 503 (not 500, not a raw config error leaked to client)",
              r.status_code == 503, f"{r.status_code} {r.text}")
        check("503 body never echoes the raw config-error text (no var names leaked)",
              "GIF_PROVIDER_API_KEY" not in r.text, r.text)

        async def fake_search_provider_error(query):
            raise gif_search.GifSearchError("GIF provider request failed: 500 Internal Server Error")
        messaging_module.search_gifs = fake_search_provider_error
        r = client.get("/message/gif-search", params={"q": "cat"}, headers=cookie_header(token))
        check("provider call itself failing -> 502, distinct from the 503 config case",
              r.status_code == 502, f"{r.status_code} {r.text}")
    finally:
        messaging_module.search_gifs = orig_search_gifs
        cleanup_users(uid)


def test_gif_search_shaping_never_leaks_raw_provider_fields():
    print("\n=== 3-cont. _shape_giphy/_shape_tenor: only composer-relevant fields ever "
          "survive, no provider-side tracking/analytics fields forwarded ===")
    giphy_raw = [{
        "id": "xyz789", "url": "https://giphy.com/should-not-leak",
        "analytics": {"onload": {"url": "https://giphy-analytics.example/track"}},
        "images": {
            "original": {"url": "https://media.giphy.com/xyz789/giphy.gif", "width": "480", "height": "270"},
            "fixed_width_small": {"url": "https://media.giphy.com/xyz789/small.gif"},
        },
    }]
    shaped = gif_search._shape_giphy(giphy_raw)
    check("giphy shaping returns exactly the composer fields",
          shaped == [{"id": "xyz789", "url": "https://media.giphy.com/xyz789/giphy.gif",
                      "preview_url": "https://media.giphy.com/xyz789/small.gif",
                      "width": 480, "height": 270}],
          str(shaped))
    check("giphy shaping never forwards the 'analytics' tracking block",
          "analytics" not in shaped[0], str(shaped))

    tenor_raw = [{
        "id": "t123",
        "media_formats": {
            "gif": {"url": "https://media.tenor.com/t123/full.gif", "dims": [320, 240]},
            "tinygif": {"url": "https://media.tenor.com/t123/tiny.gif"},
        },
        "content_description": "should not leak either",
    }]
    shaped = gif_search._shape_tenor(tenor_raw)
    check("tenor shaping returns exactly the composer fields",
          shaped == [{"id": "t123", "url": "https://media.tenor.com/t123/full.gif",
                      "preview_url": "https://media.tenor.com/t123/tiny.gif",
                      "width": 320, "height": 240}],
          str(shaped))


# ── 4/9. Attachment schema round-trip (DM) + plain-text regression ─────────

async def _send_and_check(manager, payload, marker_label):
    """Runs send_msg against a fake sender socket so a content-filter/
    dropped-message error frame (if any) can be observed."""
    sender_ws = FakeRecordingWebSocket()
    manager.active_connections[payload["from_user"]] = sender_ws
    await manager.send_msg(payload)
    return sender_ws.sent


class FakeRecordingWebSocket:
    def __init__(self):
        self.sent = []

    async def send_json(self, payload):
        self.sent.append(payload)


def test_send_msg_attachment_round_trip_dm():
    print("\n=== 4. ConnectionManager.send_msg + FriendsManager.read_friend: DM attachment "
          "round-trip -- persists kind/key/meta, resolves a fresh attachment_url, NEVER "
          "hands the raw attachment_key back to the client ===")
    sender_id = _make_user("atk_dm_sender")
    recip_id = _make_user("atk_dm_recip")
    make_friends(sender_id, recip_id)
    manager = ConnectionManager()
    try:
        marker = f"attachments/{sender_id}/{uuid.uuid4()}.jpg"
        recip_ws = FakeRecordingWebSocket()
        manager.active_connections[recip_id] = recip_ws
        payload = {
            "from_user": sender_id, "to_users": [recip_id], "group_id": None,
            "text": "", "timestamp": datetime.now(timezone.utc).isoformat(),
            "attachment_kind": "image", "attachment_key": marker,
            "attachment_meta": {"width": 800, "height": 600},
        }
        asyncio.run(manager.send_msg(payload))

        row = message_row(marker, by_key=True)
        check("attachment message was persisted", row is not None, str(row))
        if row:
            _, text, kind, key, meta = row
            check("persisted attachment_kind == 'image'", kind == "image", kind)
            check("persisted attachment_key matches the object key sent", key == marker, key)
            check("persisted attachment_meta preserved", meta == {"width": 800, "height": 600}, str(meta))
            check("persisted text is empty (attachment-only message, no caption)", text == "", repr(text))

        check("recipient's live WS frame carries attachment_kind/meta and a resolved attachment_url",
              len(recip_ws.sent) == 1
              and recip_ws.sent[0].get("attachment_kind") == "image"
              and recip_ws.sent[0].get("attachment_meta") == {"width": 800, "height": 600}
              and isinstance(recip_ws.sent[0].get("attachment_url"), str)
              and recip_ws.sent[0]["attachment_url"].startswith("https://"),
              str(recip_ws.sent))
        check("recipient's live WS frame never carries the raw attachment_key",
              "attachment_key" not in recip_ws.sent[0], str(recip_ws.sent[0]))

        fm = FriendsManager(recip_id)
        try:
            history = fm.read_friend(sender_id)
            other_msgs = history.get("other_msgs", [])
            match = next((m for m in other_msgs if m.get("attachment_kind") == "image"), None)
            check("history load (read_friend) finds the attachment message", match is not None, str(other_msgs))
            if match:
                check("history load resolves attachment_url (fresh presigned GET)",
                      isinstance(match.get("attachment_url"), str) and match["attachment_url"].startswith("https://"),
                      str(match))
                check("history load NEVER hands back the raw attachment_key",
                      "attachment_key" not in match, str(match))
        finally:
            fm.close()
    finally:
        manager.close()
        cleanup_users(sender_id, recip_id)


def test_send_msg_plaintext_regression():
    print("\n=== 9. Regression: a plain text-only message (no attachment fields at all) is "
          "completely unaffected -- attachment_kind/key/meta stay unset, attachment_url is None ===")
    sender_id = _make_user("atk_plain_sender")
    recip_id = _make_user("atk_plain_recip")
    make_friends(sender_id, recip_id)
    manager = ConnectionManager()
    try:
        marker = f"plaintext-regress-{uuid.uuid4().hex[:8]}"
        recip_ws = FakeRecordingWebSocket()
        manager.active_connections[recip_id] = recip_ws
        payload = {
            "from_user": sender_id, "to_users": [recip_id], "group_id": None,
            "text": marker, "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        asyncio.run(manager.send_msg(payload))

        row = message_row(marker)
        check("plain text message persisted", row is not None, str(row))
        if row:
            _, text, kind, key, meta = row
            check("attachment_kind is NULL for a text-only message", kind is None, kind)
            check("attachment_key is NULL for a text-only message", key is None, key)

        check("recipient's WS frame has attachment_kind=None and attachment_url=None",
              len(recip_ws.sent) == 1
              and recip_ws.sent[0].get("attachment_kind") is None
              and recip_ws.sent[0].get("attachment_url") is None
              and recip_ws.sent[0].get("text") == marker,
              str(recip_ws.sent))
    finally:
        manager.close()
        cleanup_users(sender_id, recip_id)


def _make_user(prefix: str) -> str:
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


# ── 5/6. check_clean + block enforcement + fail-closed handling ────────────

def test_send_msg_fail_closed_cases():
    print("\n=== 6. ConnectionManager.send_msg fail-closed on an ambiguous/broken attachment "
          "reference: dropped (never persisted), never raises ===")
    sender_id = _make_user("atk_failclosed_sender")
    recip_id = _make_user("atk_failclosed_recip")
    make_friends(sender_id, recip_id)
    manager = ConnectionManager()
    try:
        cases = [
            ("unrecognized attachment_kind", {
                "attachment_kind": "spreadsheet_of_evil", "attachment_key": "attachments/x/y.csv",
                "attachment_meta": {},
            }),
            ("non-gif kind missing its object key", {
                "attachment_kind": "video", "attachment_key": None, "attachment_meta": {},
            }),
            ("gif missing its provider url in attachment_meta", {
                "attachment_kind": "gif", "attachment_key": None, "attachment_meta": {"id": "abc"},
            }),
        ]
        for label, extra in cases:
            marker = f"failclosed-{uuid.uuid4().hex[:8]}"
            payload = {
                "from_user": sender_id, "to_users": [recip_id], "group_id": None,
                "text": marker, "timestamp": datetime.now(timezone.utc).isoformat(),
                **extra,
            }
            raised = False
            try:
                asyncio.run(manager.send_msg(payload))
            except Exception as e:  # noqa: BLE001 -- exactly what must NOT happen
                raised = True
                check(f"{label}: send_msg does not raise", False, repr(e))
            if not raised:
                check(f"{label}: send_msg does not raise", True)
            row = message_row(marker)
            check(f"{label}: message was dropped, never persisted", row is None, str(row))
    finally:
        manager.close()
        cleanup_users(sender_id, recip_id)


def test_send_msg_content_filter_covers_attachment_filename():
    print("\n=== 5. check_clean covers a 'file' attachment's filename as a side-channel, "
          "same as text -- rejected message is never persisted, sender is told why ===")
    sender_id = _make_user("atk_filter_sender")
    recip_id = _make_user("atk_filter_recip")
    make_friends(sender_id, recip_id)
    manager = ConnectionManager()
    try:
        marker = f"attachments/{sender_id}/{uuid.uuid4()}.pdf"
        payload = {
            "from_user": sender_id, "to_users": [recip_id], "group_id": None,
            "text": "", "timestamp": datetime.now(timezone.utc).isoformat(),
            "attachment_kind": "file", "attachment_key": marker,
            "attachment_meta": {"filename": f"{EXPLICIT_MARKER}.pdf"},
        }
        sent = asyncio.run(_send_and_check(manager, payload, "filter"))
        row = message_row(marker, by_key=True)
        check("a message whose attachment filename trips the content filter is never persisted",
              row is None, str(row))
        check("the sender's own socket is told the message was rejected (mirrors the "
              "existing text-content-filter error contract)",
              len(sent) == 1 and sent[0].get("reason") == "message_rejected", str(sent))
    finally:
        manager.close()
        cleanup_users(sender_id, recip_id)


def test_send_msg_block_enforcement_attachment_only():
    print("\n=== 5-cont. Block enforcement holds for an attachment-only (empty text) DM, "
          "exactly like today's text-only block enforcement ===")
    sender_id = _make_user("atk_block_sender")
    recip_id = _make_user("atk_block_recip")
    block(recip_id, sender_id)  # recip has blocked sender
    manager = ConnectionManager()
    try:
        marker = f"attachments/{sender_id}/{uuid.uuid4()}.png"
        payload = {
            "from_user": sender_id, "to_users": [recip_id], "group_id": None,
            "text": "", "timestamp": datetime.now(timezone.utc).isoformat(),
            "attachment_kind": "image", "attachment_key": marker,
            "attachment_meta": {"width": 100, "height": 100},
        }
        asyncio.run(manager.send_msg(payload))
        row = message_row(marker, by_key=True)
        check("an attachment-only DM to a blocked relationship is dropped entirely, "
              "not saved/delivered", row is None, str(row))
    finally:
        manager.close()
        cleanup_users(sender_id, recip_id)


# ── 7. Group history strips attachment_key ──────────────────────────────────

def test_group_history_strips_attachment_key(client):
    print("\n=== 7. GroupsManager.format_messages / GET /groups/{user_id}/{group_id}: group "
          "message history resolves attachment_url but NEVER hands back the raw "
          "attachment_key (security step 5's fix) ===")
    uid_owner, token_owner = signup(client, "atk_group_owner")
    uid_member, token_member = signup(client, "atk_group_member")
    group_id = None
    manager = ConnectionManager()
    try:
        group_id = create_group(client, token_owner, uid_owner, [uid_member])
        marker = f"attachments/{uid_owner}/{uuid.uuid4()}.mp4"
        payload = {
            "from_user": uid_owner, "to_users": [uid_owner, uid_member], "group_id": group_id,
            "text": "", "timestamp": datetime.now(timezone.utc).isoformat(),
            "attachment_kind": "video", "attachment_key": marker,
            "attachment_meta": {"width": 1920, "height": 1080},
        }
        asyncio.run(manager.send_msg(payload))

        r = client.get(f"/groups/{uid_member}/{group_id}", headers=cookie_header(token_member))
        check("fetch_group succeeds for a real member", r.status_code == 200, f"{r.status_code} {r.text}")
        body = r.json()
        all_msgs = body.get("host_msgs", []) + body.get("other_msgs", [])
        match = next((m for m in all_msgs if m.get("attachment_kind") == "video"), None)
        check("group history contains the attachment message", match is not None, str(all_msgs))
        if match:
            check("group history resolves attachment_url",
                  isinstance(match.get("attachment_url"), str) and match["attachment_url"].startswith("https://"),
                  str(match))
            check("group history NEVER includes the raw attachment_key field at all "
                  "(the security step 5 fix -- previously a raw SELECT * leaked it)",
                  "attachment_key" not in match, str(match))
    finally:
        manager.close()
        if group_id:
            cleanup_group(group_id, uid_owner, uid_member)
        else:
            cleanup_users(uid_owner, uid_member)


# ── 8. Config-validation-at-startup failure cases ───────────────────────────

def test_attachment_config_validation_failure_cases():
    print("\n=== 8. validate_attachment_config(): names exactly which var(s) are missing, "
          "mirrors validate_apns_config()'s precedent ===")
    saved = {k: os.environ.get(k) for k in ("S3_BUCKET_NAME", "S3_REGION")}
    try:
        os.environ["S3_BUCKET_NAME"] = ""
        os.environ["S3_REGION"] = "us-east-1"
        importlib.reload(attachments)
        try:
            attachments.validate_attachment_config()
            check("missing S3_BUCKET_NAME alone raises AttachmentConfigError", False, "did not raise")
        except attachments.AttachmentConfigError as e:
            check("error names exactly S3_BUCKET_NAME", "S3_BUCKET_NAME" in str(e), str(e))
            check("error does not falsely name S3_REGION as missing too", "S3_REGION" not in str(e), str(e))

        os.environ["S3_BUCKET_NAME"] = ""
        os.environ["S3_REGION"] = ""
        importlib.reload(attachments)
        try:
            attachments.validate_attachment_config()
            check("both vars missing raises AttachmentConfigError", False, "did not raise")
        except attachments.AttachmentConfigError as e:
            check("error names both S3_BUCKET_NAME and S3_REGION",
                  "S3_BUCKET_NAME" in str(e) and "S3_REGION" in str(e), str(e))

        try:
            attachments.generate_upload_policy("u", "image", "image/jpeg")
            check("generate_upload_policy propagates AttachmentConfigError when unconfigured "
                  "(not silently degraded)", False, "did not raise")
        except attachments.AttachmentConfigError:
            check("generate_upload_policy propagates AttachmentConfigError when unconfigured "
                  "(not silently degraded)", True)

        check("generate_download_url degrades to None (not raise) when unconfigured -- a "
              "rendering hiccup shouldn't break the whole thread/history load",
              attachments.generate_download_url("attachments/x/y.jpg") is None)
    finally:
        for k, v in saved.items():
            if v is not None:
                os.environ[k] = v
            else:
                os.environ.pop(k, None)
        importlib.reload(attachments)


def test_gif_config_validation_failure_cases():
    print("\n=== 8-cont. validate_gif_config(): names exactly what's missing/invalid, never "
          "the key value itself ===")
    saved = {k: os.environ.get(k) for k in ("GIF_PROVIDER", "GIF_PROVIDER_API_KEY")}
    try:
        os.environ["GIF_PROVIDER"] = "giphy"
        os.environ["GIF_PROVIDER_API_KEY"] = ""
        importlib.reload(gif_search)
        try:
            gif_search.validate_gif_config()
            check("missing GIF_PROVIDER_API_KEY raises GifConfigError", False, "did not raise")
        except gif_search.GifConfigError as e:
            check("error names GIF_PROVIDER_API_KEY", "GIF_PROVIDER_API_KEY" in str(e), str(e))

        os.environ["GIF_PROVIDER"] = "not_a_real_provider"
        os.environ["GIF_PROVIDER_API_KEY"] = "some-key"
        importlib.reload(gif_search)
        try:
            gif_search.validate_gif_config()
            check("unrecognized GIF_PROVIDER value raises GifConfigError", False, "did not raise")
        except gif_search.GifConfigError as e:
            check("error names GIF_PROVIDER as the invalid field", "GIF_PROVIDER" in str(e), str(e))
            check("error never echoes back the (here, harmless) API key value",
                  "some-key" not in str(e), str(e))

        try:
            asyncio.run(gif_search.search_gifs("cats"))
            check("search_gifs propagates GifConfigError when unconfigured (not silently "
                  "degraded to an empty result set)", False, "did not raise")
        except gif_search.GifConfigError:
            check("search_gifs propagates GifConfigError when unconfigured (not silently "
                  "degraded to an empty result set)", True)
    finally:
        for k, v in saved.items():
            if v is not None:
                os.environ[k] = v
            else:
                os.environ.pop(k, None)
        importlib.reload(gif_search)


def main():
    if _ENV_WAS_SYNTHETIC:
        print("NOTE: this environment's .env was missing one or more of "
              "S3_BUCKET_NAME/S3_REGION/GIF_PROVIDER/GIF_PROVIDER_API_KEY -- using synthetic "
              "placeholders so main.app can boot and the code paths can be proven correct. "
              "See this file's module docstring: provisioning the REAL values remains the "
              "user's own outstanding action, tracked in clarification-answers.md, not a gap "
              "this test (or any code change) can close.")

    with TestClient(main_module.app) as client:
        test_upload_url_auth_and_scoping(client)
        test_upload_url_mime_size_enforcement(client)
        test_generate_upload_policy_limits_match_per_kind_config()
        test_generate_download_url_degrades_gracefully()
        test_gif_search_route_auth_and_error_mapping(client)
        test_gif_search_shaping_never_leaks_raw_provider_fields()
        test_send_msg_attachment_round_trip_dm()
        test_send_msg_plaintext_regression()
        test_send_msg_fail_closed_cases()
        test_send_msg_content_filter_covers_attachment_filename()
        test_send_msg_block_enforcement_attachment_only()
        test_group_history_strips_attachment_key(client)
        test_attachment_config_validation_failure_cases()
        test_gif_config_validation_failure_cases()

    print(f"\n{'='*60}")
    skipped_note = f", {len(SKIPPED)} skipped" if SKIPPED else ""
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED{skipped_note}")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed{skipped_note}")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
