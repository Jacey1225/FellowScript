"""Tests for `delete_object()` in `api/backend/interactions/attachments.py`
(task 20260923-s3-delete-object-permission, testing step -- the final gate
of this Lightweight pipeline).

Context: `delete_object()` is deliberately fail-soft (never raises -- see its
own docstring), so when the app's production IAM identity was missing
`s3:DeleteObject` on the attachments bucket, every cleanup call swallowed an
`AccessDenied` `ClientError`, logged it, and returned normally -- old
profile photos (on replacement) and a departing user's attachments (on
account deletion) silently never left the bucket, with no user-visible
symptom at all. The backend gate for this task confirmed the missing IAM
grant, had the user attach a minimal least-privilege policy
(`s3:DeleteObject` on `attachments/*` and `profile-photos/*` of the
production bucket), and re-verified live against production that the same
call now succeeds. No code change was made or needed -- `delete_object()`
itself was already correct.

This file exists because that verification was infra-side (a live prod
probe, not a repeatable automated test), and `delete_object()` had zero
direct unit coverage of its own before this task (confirmed via codegraph:
"no covering tests found" for `delete_object`) -- every existing caller-side
test (`test_profile_photo.py`) swaps in a fake recorder instead of exercising
`delete_object()`'s own S3-call/error-handling contract. Covers:

  1. Blank/None object_key: no-op, never calls S3 at all.
  2. Success path: calls the S3 client's delete_object with exactly the
     configured bucket and the given key, and does not raise.
  3. Regression -- the exact incident this task fixed: an AccessDenied
     ClientError on `s3:DeleteObject` (what production actually threw before
     the IAM grant) is caught and logged, never raised -- so a caller
     replacing/removing an object is never broken by a permission gap, this
     time or in the future if the grant is ever lost again.
  4. A different (non-AccessDenied) ClientError is handled the same
     fail-soft way -- the catch isn't accidentally narrowed to one error
     code.
  5. AttachmentConfigError (S3 unconfigured) is caught the same fail-soft
     way, never raised.
  6. Regression: the success path is a plain, unremarkable case that must
     keep working exactly as before -- proves this task's fix didn't need
     to (and didn't) touch the function's happy path.

Run with: cd api && ../.venv/bin/python tests/test_attachment_delete_object.py
"""
import _pathfix  # noqa: F401,E402

import os

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")

from dotenv import load_dotenv  # noqa: E402
load_dotenv()  # real .env values (if present) win over the placeholders above

from botocore.exceptions import ClientError  # noqa: E402

import backend.interactions.attachments as attachments  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


class _FakeS3Client:
    """Stands in for attachments._client() so no real S3 call is ever made.
    Records every delete_object call and can be configured to raise on it,
    mirroring exactly what boto3 would raise for an AccessDenied response."""

    def __init__(self, error: Exception | None = None):
        self.error = error
        self.calls = []

    def delete_object(self, Bucket, Key):  # noqa: N803 -- matches boto3's own kwarg casing
        self.calls.append({"Bucket": Bucket, "Key": Key})
        if self.error is not None:
            raise self.error
        return {"ResponseMetadata": {"HTTPStatusCode": 204}}


def make_access_denied_error() -> ClientError:
    """The exact error class/code this task's incident produced: the app's
    production IAM identity lacked s3:DeleteObject on the bucket."""
    return ClientError(
        {"Error": {"Code": "AccessDenied", "Message": "Access Denied"}},
        "DeleteObject",
    )


def make_other_client_error() -> ClientError:
    return ClientError(
        {"Error": {"Code": "InternalError", "Message": "We encountered an internal error"}},
        "DeleteObject",
    )


def with_fake_client(fake_client):
    """Context-manager-free swap of attachments._client -- delete_object()
    calls _client() internally, so patching the module-level function is
    enough; no real boto3 client is ever constructed in this file."""
    orig = attachments._client
    attachments._client = lambda: fake_client
    return orig


def restore_client(orig):
    attachments._client = orig


# ── 1. Blank/None key: no-op, never touches S3 ──────────────────────────────

def test_delete_object_blank_key_is_noop():
    print("\n=== 1. delete_object(): blank/None object_key is a no-op, never calls S3 ===")
    fake = _FakeS3Client()
    orig = with_fake_client(fake)
    try:
        result = attachments.delete_object(None)
        check("delete_object(None) returns None (no exception)", result is None)
        check("delete_object(None) never calls S3", fake.calls == [], fake.calls)

        result = attachments.delete_object("")
        check("delete_object('') returns None (no exception)", result is None)
        check("delete_object('') never calls S3", fake.calls == [], fake.calls)
    finally:
        restore_client(orig)


# ── 2. Success path: correct Bucket/Key, no exception ───────────────────────

def test_delete_object_success_path():
    print("\n=== 2. delete_object(): success calls S3 with the configured bucket and the "
          "given key, does not raise ===")
    fake = _FakeS3Client()
    orig = with_fake_client(fake)
    try:
        key = "attachments/some-user/some-object.jpg"
        result = attachments.delete_object(key)
        check("delete_object() returns None on success (no return value contract)", result is None)
        check("exactly one S3 delete_object call was made", len(fake.calls) == 1, fake.calls)
        check("the call used the configured S3_BUCKET_NAME",
              fake.calls[0]["Bucket"] == attachments.S3_BUCKET_NAME, fake.calls)
        check("the call used exactly the given object key",
              fake.calls[0]["Key"] == key, fake.calls)
    finally:
        restore_client(orig)


# ── 3. Regression: the exact incident -- AccessDenied on s3:DeleteObject ────

def test_delete_object_access_denied_is_fail_soft():
    print("\n=== 3. REGRESSION (task 20260923-s3-delete-object-permission): an AccessDenied "
          "ClientError on s3:DeleteObject -- what production actually threw before the IAM "
          "grant was applied -- is caught and logged, never raised ===")
    fake = _FakeS3Client(error=make_access_denied_error())
    orig = with_fake_client(fake)
    try:
        raised = False
        try:
            result = attachments.delete_object("profile-photos/some-user/old-photo.jpg")
        except Exception as e:  # noqa: BLE001 -- exactly what must NOT happen
            raised = True
            check("delete_object() does not raise on AccessDenied "
                  "(caller must never be broken by a missing S3 permission)", False, repr(e))
        if not raised:
            check("delete_object() does not raise on AccessDenied "
                  "(caller must never be broken by a missing S3 permission)", True)
            check("delete_object() still returns None (fail-soft, not fail-loud)", result is None)
        check("the S3 call was actually attempted (this is a caught failure, not a skip)",
              len(fake.calls) == 1, fake.calls)
    finally:
        restore_client(orig)


# ── 4. A different ClientError gets the same fail-soft treatment ───────────

def test_delete_object_other_client_error_is_fail_soft():
    print("\n=== 4. A non-AccessDenied ClientError (e.g. a transient S3 InternalError) is "
          "handled the same fail-soft way -- the catch isn't narrowed to one error code ===")
    fake = _FakeS3Client(error=make_other_client_error())
    orig = with_fake_client(fake)
    try:
        raised = False
        try:
            attachments.delete_object("attachments/some-user/some-object.jpg")
        except Exception as e:  # noqa: BLE001
            raised = True
            check("delete_object() does not raise on a non-AccessDenied ClientError", False, repr(e))
        if not raised:
            check("delete_object() does not raise on a non-AccessDenied ClientError", True)
    finally:
        restore_client(orig)


# ── 5. AttachmentConfigError (unconfigured S3) is also fail-soft ───────────

def test_delete_object_unconfigured_is_fail_soft():
    print("\n=== 5. delete_object(): S3 unconfigured (AttachmentConfigError) is caught, "
          "never raised -- same fail-soft posture as the ClientError cases ===")
    saved = {k: os.environ.get(k) for k in ("S3_BUCKET_NAME", "S3_REGION")}
    fake = _FakeS3Client()
    orig = with_fake_client(fake)
    try:
        os.environ["S3_BUCKET_NAME"] = ""
        os.environ["S3_REGION"] = ""
        import importlib
        importlib.reload(attachments)
        # Reloading attachments replaces its module-level _client -- re-patch
        # the fresh module object so this test still never touches real S3.
        orig_after_reload = with_fake_client(fake)
        try:
            raised = False
            try:
                result = attachments.delete_object("attachments/some-user/some-object.jpg")
            except Exception as e:  # noqa: BLE001
                raised = True
                check("delete_object() does not raise when S3 is unconfigured", False, repr(e))
            if not raised:
                check("delete_object() does not raise when S3 is unconfigured", True)
                check("delete_object() still returns None", result is None)
            check("validate_attachment_config() failing means S3 is never actually called",
                  fake.calls == [], fake.calls)
        finally:
            restore_client(orig_after_reload)
    finally:
        for k, v in saved.items():
            if v is not None:
                os.environ[k] = v
            else:
                os.environ.pop(k, None)
        import importlib
        importlib.reload(attachments)


def main():
    test_delete_object_blank_key_is_noop()
    test_delete_object_success_path()
    test_delete_object_access_denied_is_fail_soft()
    test_delete_object_other_client_error_is_fail_soft()
    test_delete_object_unconfigured_is_fail_soft()

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        import sys
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
