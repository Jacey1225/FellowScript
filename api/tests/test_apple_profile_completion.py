"""Apple can never resupply a lost name/email after the very first
authorization for a given Apple ID + app. This test verifies the server-side
half of the fallback: a first-ever Apple authorization missing full_name
and/or email flags the new account with needs_profile_completion=True, a
complete first authorization leaves it False, and setting username/email via
PUT /user/{id} clears the flag.

Run with: cd api && ../.venv/bin/python tests/test_apple_profile_completion.py
"""
import _pathfix  # noqa: F401

import os
import uuid
from unittest.mock import MagicMock

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def cleanup(uid: str):
    db = DBManager()
    try:
        db.delete("users", {"_id": uid})
    finally:
        db.close()


def cookie_header(session: str) -> dict:
    return {"Cookie": f"session={session}"}


def main():
    with TestClient(main_module.app) as client:
        print("=== First Apple authorization, missing BOTH full_name and email ===")
        fake_sub = f"apple-sub-{uuid.uuid4().hex[:8]}"
        main_module.jwt.decode = MagicMock(return_value={"sub": fake_sub})
        main_module._apple_jwk_client.get_signing_key_from_jwt = MagicMock(return_value=MagicMock(key="fake"))

        r1 = client.post("/auth/apple", json={"identity_token": "fake-token", "terms_accepted": True})
        check("first Apple auth with no name/email -> 200", r1.status_code == 200, str((r1.status_code, r1.text)))
        body1 = r1.json()
        uid1 = body1.get("user_id")
        check("needs_profile_completion is True when Apple supplied nothing",
              body1.get("needs_profile_completion") is True, str(body1))
        check("username fell back to a generated placeholder",
              body1.get("username", "").startswith("apple_user"), str(body1.get("username")))
        check("email is empty", body1.get("email", "") == "", str(body1.get("email")))

        print("\n=== Resolve via PUT /user/{id} with a real username + email ===")
        session1 = r1.cookies.get("session")
        r2 = client.put(f"/user/{uid1}", json={"username": "real_username", "email": "real@example.com"},
                        headers=cookie_header(session1))
        check("PUT /user/{id} with username+email -> 200", r2.status_code == 200, str(r2.status_code))
        check("needs_profile_completion cleared after resolving",
              r2.json().get("needs_profile_completion") is False, str(r2.json()))

        # A subsequent read should also reflect the cleared flag (not just the
        # PUT response) — confirms it was actually persisted, not just echoed.
        r3 = client.get(f"/user/{uid1}", headers=cookie_header(session1))
        check("needs_profile_completion stays cleared on re-read",
              r3.json().get("needs_profile_completion") is False, str(r3.json()))

        cleanup(uid1)

        print("\n=== First Apple authorization, full_name + email BOTH present ===")
        fake_sub2 = f"apple-sub-{uuid.uuid4().hex[:8]}"
        fake_email2 = f"appletest_{uuid.uuid4().hex[:8]}@example.com"
        main_module.jwt.decode = MagicMock(return_value={"sub": fake_sub2, "email": fake_email2})

        r4 = client.post("/auth/apple", json={
            "identity_token": "fake-token", "full_name": "Complete Person",
            "email": fake_email2, "terms_accepted": True,
        })
        check("first Apple auth with full name+email -> 200", r4.status_code == 200, str(r4.status_code))
        body4 = r4.json()
        check("needs_profile_completion is False when Apple supplied both",
              body4.get("needs_profile_completion") is False, str(body4))
        cleanup(body4["user_id"])

        print("\n=== First Apple authorization, email present but full_name missing ===")
        fake_sub3 = f"apple-sub-{uuid.uuid4().hex[:8]}"
        fake_email3 = f"appletest_{uuid.uuid4().hex[:8]}@example.com"
        main_module.jwt.decode = MagicMock(return_value={"sub": fake_sub3, "email": fake_email3})

        r5 = client.post("/auth/apple", json={
            "identity_token": "fake-token", "email": fake_email3, "terms_accepted": True,
        })
        body5 = r5.json()
        check("needs_profile_completion is True when only full_name is missing",
              body5.get("needs_profile_completion") is True, str(body5))
        cleanup(body5["user_id"])

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
