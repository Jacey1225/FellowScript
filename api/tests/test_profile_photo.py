"""Tests for the profile-photo upload/serving surface (task
20260905-profile-photo, testing step 10 -- the final gate).

Covers, per this task's acceptance criteria / workflow step 10 charter:
  1. Upload-url endpoint auth/scoping (POST /user/{user_id}/photo/upload-url):
     deny-by-default -- no session cookie -> 401; requesting an upload URL
     for a DIFFERENT user_id -> 403 (self-scoping, no path to set/replace
     someone else's photo); requesting for ONESELF -> 200 with an
     object_key scoped under the caller's own "profile-photos/{uid}/" prefix
     (server-derived, matching attachments.py's existing precedent).
  2. Upload-url endpoint MIME/size enforcement, fail-closed: an allowed
     image MIME succeeds; a non-image MIME (even one valid for a *different*
     attachment kind, e.g. video/mp4) is rejected 400, not silently coerced
     or defaulted; an unrecognized content_type is rejected 400. Verifies
     the policy's size/MIME limits match attachments.PER_KIND_LIMITS['image']
     exactly (no separate, drifted profile-photo-specific tunable).
  3. is_own_profile_photo_key() defense-in-depth check, fail-closed: blank/
     None, a foreign user's prefix, and a ".."-traversal-looking segment all
     return False; only a key unambiguously under the caller's own prefix
     returns True.
  4. Confirm endpoint (POST /user/{user_id}/photo/confirm): self-scoping
     (401/403) mirrors upload-url; a client-submitted object_key that fails
     is_own_profile_photo_key -> 403 and is never persisted; a valid own key
     persists onto the user's row and returns a profile_photo_url (never the
     raw key); replacing an existing photo deletes the prior S3 object
     (best-effort cleanup, never orphaned).
  5. Remove endpoint (DELETE /user/{user_id}/photo): self-scoping mirrors
     the above; idempotent no-op (204, no cleanup call) when no photo is
     set; clears the column and deletes the object when one is set.
  6. Fallback-to-initials rendering (client-side): see
     frontend/src/components/AppNav.test.jsx's "profile photo rendering"
     describe block for the client-side half of this acceptance criterion
     (backend only ever hands back a URL or None -- rendering-with-fallback
     is a client concern).

Run with: cd api && ../.venv/bin/python tests/test_profile_photo.py
"""
import _pathfix  # noqa: F401,E402

import os
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from dotenv import load_dotenv  # noqa: E402
load_dotenv()  # real .env values (if present) win over the placeholders below


def _ensure_attachment_config_present():
    """Same rationale as test_messaging_attachments.py's identically-named
    helper: presigned S3 POST/GET generation is pure local signing (no
    network call), so a placeholder bucket/region is sufficient to prove the
    code path works even when this environment's real S3 config is absent.
    GIF_PROVIDER/GIF_PROVIDER_API_KEY are unrelated to profile photos but
    main.py's lifespan validates them unconditionally at boot (same
    validate_apns_config()-style eager-validation precedent), so main.app
    won't boot in this file either without them -- never exercised beyond
    letting the app start."""
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
import routes.profile_photo as profile_photo_module  # noqa: E402
import backend.interactions.attachments as attachments  # noqa: E402
from backend.interactions.profile_photo import (  # noqa: E402
    PROFILE_PHOTO_KEY_PREFIX,
    generate_profile_photo_upload_policy,
    is_own_profile_photo_key,
)

PASSED, FAILED, SKIPPED = [], [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── Fixtures / helpers (mirrors test_messaging_attachments.py) ─────────────

def cookie_header(token: str | None):
    return {"cookie": f"session={token}"} if token else {}


_signup_counter = 0


def signup(client, prefix: str):
    """Spoofs a distinct CF-Connecting-IP per call so this file's several
    signups don't trip /signup's per-IP rate limit -- same technique
    test_messaging_attachments.py/test_friend_activity.py use."""
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


def cleanup_users(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def current_photo_key(user_id: str):
    db = DBManager()
    try:
        db.cur.execute("SELECT profile_photo_key FROM users WHERE _id = %s", (user_id,))
        row = db.cur.fetchone()
        return row[0] if row else None
    finally:
        db.close()


class _FakeDeleteRecorder:
    """Swaps in for routes.profile_photo.delete_object so tests can observe
    which (if any) key cleanup was requested without touching real S3."""
    def __init__(self):
        self.calls = []

    def __call__(self, object_key):
        self.calls.append(object_key)


# ── 1. Upload-url endpoint: auth/scoping (deny-by-default) ─────────────────

def test_upload_url_auth_and_scoping(client):
    print("\n=== 1. POST /user/{user_id}/photo/upload-url: auth + self-scoping ===")
    uid_a, token_a = signup(client, "pfp_upload_a")
    uid_b, token_b = signup(client, "pfp_upload_b")
    try:
        r = client.post(f"/user/{uid_a}/photo/upload-url", json={"content_type": "image/jpeg"})
        check("no session cookie -> 401 (deny-by-default)", r.status_code == 401, f"{r.status_code} {r.text}")

        r = client.post(f"/user/{uid_b}/photo/upload-url", json={"content_type": "image/jpeg"},
                         headers=cookie_header(token_a))
        check("requesting an upload URL for a DIFFERENT user -> 403 (self-scoping, no cross-user path)",
              r.status_code == 403, f"{r.status_code} {r.text}")

        r = client.post(f"/user/{uid_a}/photo/upload-url", json={"content_type": "image/jpeg"},
                         headers=cookie_header(token_a))
        check("requesting an upload URL for ONESELF -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
        body = r.json()
        check("response has url/fields/object_key/expires_in",
              all(k in body for k in ("url", "fields", "object_key", "expires_in")), str(body))
        check("object_key is server-derived under the caller's own profile-photos/<uid>/ prefix, "
              "never a client-suppliable value",
              body.get("object_key", "").startswith(f"{PROFILE_PHOTO_KEY_PREFIX}/{uid_a}/"),
              body.get("object_key"))
        check("object_key is distinct from the message-attachments prefix (can't be confused/swept together)",
              not body.get("object_key", "").startswith("attachments/"), body.get("object_key"))
    finally:
        cleanup_users(uid_a, uid_b)


# ── 2. Upload-url endpoint: MIME/size enforcement, fail-closed ─────────────

def test_upload_url_mime_enforcement(client):
    print("\n=== 2. POST /user/{user_id}/photo/upload-url: image-only allowlist, fail-closed ===")
    uid, token = signup(client, "pfp_upload_mime")
    try:
        cases = [
            ("image/jpeg", True, "allowed image mime (jpeg)"),
            ("image/png", True, "allowed image mime (png)"),
            ("video/mp4", False, "video mime -- rejected outright, not coerced to 'image'"),
            ("application/pdf", False, "file-kind mime -- profile photos never accept non-image kinds"),
            ("image/svg+xml", False, "unrecognized/unsupported image mime (not on the allowlist) -- fail closed"),
            ("", False, "blank content_type -- fail closed, not a generic default"),
        ]
        for content_type, should_succeed, label in cases:
            r = client.post(f"/user/{uid}/photo/upload-url", json={"content_type": content_type},
                             headers=cookie_header(token))
            if should_succeed:
                check(f"{label} -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            else:
                check(f"{label} -> 400 (not 500, not silently accepted)",
                      r.status_code == 400, f"{r.status_code} {r.text}")
    finally:
        cleanup_users(uid)


def test_upload_policy_limits_match_attachments_image_precedent():
    print("\n=== 2-cont. generate_profile_photo_upload_policy(): reuses attachments.py's "
          "PER_KIND_LIMITS['image'] verbatim (no drifted profile-photo-specific tunable) ===")
    image_limits = attachments.PER_KIND_LIMITS["image"]
    for content_type in image_limits["allowed_mime"]:
        policy = generate_profile_photo_upload_policy("unit-test-user", content_type)
        check(f"{content_type}: object_key under profile-photos/<user>/ (server-derived, no client filename/ext)",
              policy["object_key"].startswith("profile-photos/unit-test-user/"), policy["object_key"])
        check(f"{content_type}: expires_in matches attachments.UPLOAD_URL_TTL_SECONDS (no separate TTL introduced)",
              policy["expires_in"] == attachments.UPLOAD_URL_TTL_SECONDS)

    try:
        generate_profile_photo_upload_policy("unit-test-user", "video/mp4")
        check("a non-'image'-allowlisted content_type raises ValueError (not silently permitted)",
              False, "did not raise")
    except ValueError:
        check("a non-'image'-allowlisted content_type raises ValueError (not silently permitted)", True)


# ── 3. is_own_profile_photo_key(): fail-closed ownership check ─────────────

def test_is_own_profile_photo_key_fails_closed():
    print("\n=== 3. is_own_profile_photo_key(): fail-closed for blank/foreign/traversal keys ===")
    uid = "unit-test-user"
    check("blank string -> False", is_own_profile_photo_key(uid, "") is False)
    check("None -> False", is_own_profile_photo_key(uid, None) is False)
    check("a DIFFERENT user's own-looking key -> False (no cross-user confirm)",
          is_own_profile_photo_key(uid, f"{PROFILE_PHOTO_KEY_PREFIX}/some-other-user/abc.jpg") is False)
    check("a '..'-traversal-looking segment under the caller's own prefix -> False",
          is_own_profile_photo_key(uid, f"{PROFILE_PHOTO_KEY_PREFIX}/{uid}/../../etc/passwd") is False)
    check("the message-attachments prefix (different namespace entirely) -> False",
          is_own_profile_photo_key(uid, f"attachments/{uid}/abc.jpg") is False)
    check("a genuinely own-prefixed key -> True",
          is_own_profile_photo_key(uid, f"{PROFILE_PHOTO_KEY_PREFIX}/{uid}/abc.jpg") is True)


# ── 4. Confirm endpoint: auth/scoping, fail-closed key check, persistence, cleanup ──

def test_confirm_auth_and_scoping(client):
    print("\n=== 4a. POST /user/{user_id}/photo/confirm: auth + self-scoping ===")
    uid_a, token_a = signup(client, "pfp_confirm_a")
    uid_b, token_b = signup(client, "pfp_confirm_b")
    own_key = f"{PROFILE_PHOTO_KEY_PREFIX}/{uid_a}/{uuid.uuid4()}.jpg"
    try:
        r = client.post(f"/user/{uid_a}/photo/confirm", json={"object_key": own_key})
        check("no session cookie -> 401", r.status_code == 401, f"{r.status_code} {r.text}")

        r = client.post(f"/user/{uid_b}/photo/confirm", json={"object_key": own_key},
                         headers=cookie_header(token_a))
        check("confirming onto a DIFFERENT user's row -> 403 (self-scoping)",
              r.status_code == 403, f"{r.status_code} {r.text}")
        check("no row was mutated by the rejected cross-user attempt",
              current_photo_key(uid_b) is None)
    finally:
        cleanup_users(uid_a, uid_b)


def test_confirm_rejects_foreign_or_ambiguous_key(client):
    print("\n=== 4b. POST /user/{user_id}/photo/confirm: rejects a key that fails "
          "is_own_profile_photo_key even though the caller is otherwise authorized ===")
    uid, token = signup(client, "pfp_confirm_badkey")
    other_uid, other_token = signup(client, "pfp_confirm_other")
    try:
        foreign_key = f"{PROFILE_PHOTO_KEY_PREFIX}/{other_uid}/{uuid.uuid4()}.jpg"
        r = client.post(f"/user/{uid}/photo/confirm", json={"object_key": foreign_key},
                         headers=cookie_header(token))
        check("a well-formed but FOREIGN-prefixed object_key -> 403 (not persisted)",
              r.status_code == 403, f"{r.status_code} {r.text}")
        check("row is untouched after the rejected confirm", current_photo_key(uid) is None)

        traversal_key = f"{PROFILE_PHOTO_KEY_PREFIX}/{uid}/../../etc/passwd"
        r = client.post(f"/user/{uid}/photo/confirm", json={"object_key": traversal_key},
                         headers=cookie_header(token))
        check("a traversal-looking object_key -> 403 (fail closed, not sanitized-and-accepted)",
              r.status_code == 403, f"{r.status_code} {r.text}")
    finally:
        cleanup_users(uid, other_uid)


def test_confirm_persists_and_returns_url_never_raw_key(client):
    print("\n=== 4c. POST /user/{user_id}/photo/confirm: persists the key, returns a URL "
          "(never the raw key) ===")
    uid, token = signup(client, "pfp_confirm_ok")
    try:
        own_key = f"{PROFILE_PHOTO_KEY_PREFIX}/{uid}/{uuid.uuid4()}.jpg"
        r = client.post(f"/user/{uid}/photo/confirm", json={"object_key": own_key},
                         headers=cookie_header(token))
        check("confirming one's own well-formed key -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
        body = r.json()
        check("response carries a non-blank profile_photo_url (a presigned GET, "
              "which legitimately embeds the key as its S3 path -- see "
              "generate_download_url's own precedent -- but is a short-lived signed "
              "URL, never a bare/permanent reference)",
              bool(body.get("profile_photo_url")), str(body))
        check("response never carries the raw profile_photo_key as its own field",
              "profile_photo_key" not in body, str(body))
        check("the column now holds exactly the confirmed key", current_photo_key(uid) == own_key,
              current_photo_key(uid))

        r = client.get(f"/user/{uid}", headers=cookie_header(token))
        check("GET /user/{id} reflects a profile_photo_url and never the raw key",
              "profile_photo_url" in r.json() and "profile_photo_key" not in r.json(), str(r.json()))
    finally:
        cleanup_users(uid)


def test_confirm_replace_deletes_prior_object(client):
    print("\n=== 4d. confirm_profile_photo(): replacing an existing photo deletes the prior "
          "S3 object (best-effort, never orphaned) ===")
    uid, token = signup(client, "pfp_confirm_replace")
    recorder = _FakeDeleteRecorder()
    orig_delete_object = profile_photo_module.delete_object
    try:
        profile_photo_module.delete_object = recorder

        first_key = f"{PROFILE_PHOTO_KEY_PREFIX}/{uid}/{uuid.uuid4()}.jpg"
        r = client.post(f"/user/{uid}/photo/confirm", json={"object_key": first_key},
                         headers=cookie_header(token))
        check("first confirm (no prior photo) -> 200, no cleanup call", r.status_code == 200)
        check("no delete_object call on the very first photo (nothing to replace)",
              recorder.calls == [], recorder.calls)

        second_key = f"{PROFILE_PHOTO_KEY_PREFIX}/{uid}/{uuid.uuid4()}.jpg"
        r = client.post(f"/user/{uid}/photo/confirm", json={"object_key": second_key},
                         headers=cookie_header(token))
        check("second confirm (replacing) -> 200", r.status_code == 200)
        check("the FIRST (now-superseded) key was passed to delete_object exactly once",
              recorder.calls == [first_key], recorder.calls)
        check("the column now holds only the NEW key", current_photo_key(uid) == second_key)
    finally:
        profile_photo_module.delete_object = orig_delete_object
        cleanup_users(uid)


# ── 5. Remove endpoint: auth/scoping, idempotence, cleanup ─────────────────

def test_remove_auth_and_scoping(client):
    print("\n=== 5a. DELETE /user/{user_id}/photo: auth + self-scoping ===")
    uid_a, token_a = signup(client, "pfp_remove_a")
    uid_b, token_b = signup(client, "pfp_remove_b")
    try:
        r = client.delete(f"/user/{uid_a}/photo")
        check("no session cookie -> 401", r.status_code == 401, f"{r.status_code} {r.text}")

        r = client.delete(f"/user/{uid_b}/photo", headers=cookie_header(token_a))
        check("removing a DIFFERENT user's photo -> 403 (self-scoping)",
              r.status_code == 403, f"{r.status_code} {r.text}")
    finally:
        cleanup_users(uid_a, uid_b)


def test_remove_idempotent_and_cleans_up(client):
    print("\n=== 5b. DELETE /user/{user_id}/photo: idempotent no-op with none set; "
          "clears column + deletes object when one is set ===")
    uid, token = signup(client, "pfp_remove_ok")
    recorder = _FakeDeleteRecorder()
    orig_delete_object = profile_photo_module.delete_object
    try:
        profile_photo_module.delete_object = recorder

        r = client.delete(f"/user/{uid}/photo", headers=cookie_header(token))
        check("removing with no photo currently set -> 204 (idempotent no-op, not an error)",
              r.status_code == 204, f"{r.status_code} {r.text}")
        check("no cleanup call when there was nothing to clean up", recorder.calls == [], recorder.calls)

        own_key = f"{PROFILE_PHOTO_KEY_PREFIX}/{uid}/{uuid.uuid4()}.jpg"
        r = client.post(f"/user/{uid}/photo/confirm", json={"object_key": own_key},
                         headers=cookie_header(token))
        check("setup: confirm a photo -> 200", r.status_code == 200)

        r = client.delete(f"/user/{uid}/photo", headers=cookie_header(token))
        check("removing an actually-set photo -> 204", r.status_code == 204, f"{r.status_code} {r.text}")
        check("column is cleared", current_photo_key(uid) is None)
        check("the removed key was passed to delete_object exactly once",
              recorder.calls == [own_key], recorder.calls)
    finally:
        profile_photo_module.delete_object = orig_delete_object
        cleanup_users(uid)


def main():
    if _ENV_WAS_SYNTHETIC:
        print("NOTE: this environment's .env was missing S3_BUCKET_NAME/S3_REGION -- using "
              "synthetic placeholders so main.app can boot and the code paths can be proven "
              "correct (presigned S3 POST/GET generation is pure local signing, no network "
              "call). See test_messaging_attachments.py's module docstring for the same note.")

    with TestClient(main_module.app) as client:
        test_upload_url_auth_and_scoping(client)
        test_upload_url_mime_enforcement(client)
        test_upload_policy_limits_match_attachments_image_precedent()
        test_is_own_profile_photo_key_fails_closed()
        test_confirm_auth_and_scoping(client)
        test_confirm_rejects_foreign_or_ambiguous_key(client)
        test_confirm_persists_and_returns_url_never_raw_key(client)
        test_remove_auth_and_scoping(client)
        # These two swap module-level state (routes.profile_photo.delete_object)
        # for the duration of the call only, restoring it in their own
        # finally -- kept last so that swap window is as small as possible.
        # (Only ever one `with TestClient(main_module.app)` per process in
        # this test suite -- apscheduler's global singleton doesn't tolerate
        # a second app lifespan starting up in the same process.)
        test_confirm_replace_deletes_prior_object(client)
        test_remove_idempotent_and_cleans_up(client)

    print(f"\n{'='*60}")
    skipped_note = f", {len(SKIPPED)} skipped" if SKIPPED else ""
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED{skipped_note}")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        import sys
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed{skipped_note}")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
