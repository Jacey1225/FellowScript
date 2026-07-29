"""Guideline 4.8 regression test: Sign in with Apple/Google must never block
account creation on terms_accepted. Apple supplies full_name/email exactly
once, ever, per Apple ID + app — rejecting that first call with a 422 loses
the name permanently (no retry can recover it). Google is stricter-adjacent
(it resupplies name/email every time, but the same 422-on-first-try friction
is still the wrong UX). Both must always succeed on first auth; if terms
weren't accepted, the account is created anyway and terms_reaccept_required
signals the client to prompt for consent immediately after.

Run with: cd api && ../.venv/bin/python tests/test_sso_terms_gate.py
"""
import _pathfix  # noqa: F401

import os
import uuid
from unittest.mock import AsyncMock, MagicMock

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


def main():
    with TestClient(main_module.app) as client:
        print("=== Apple: first authorization, terms NOT accepted ===")
        fake_sub = f"apple-sub-{uuid.uuid4().hex[:8]}"
        fake_email = f"appletest_{uuid.uuid4().hex[:8]}@example.com"

        main_module.jwt.decode = MagicMock(return_value={"sub": fake_sub, "email": fake_email})
        main_module._apple_jwk_client.get_signing_key_from_jwt = MagicMock(return_value=MagicMock(key="fake"))

        r1 = client.post("/auth/apple", json={
            "identity_token": "fake-token", "full_name": "Jordan Reviewer",
            "email": fake_email, "terms_accepted": False,
        })
        check("first Apple auth without terms_accepted still creates the account (200, not 422)",
              r1.status_code == 200, str((r1.status_code, r1.text)))
        body1 = r1.json()
        uid = body1.get("user_id")
        check("account username derived from Apple's supplied full_name",
              body1.get("username", "").startswith("jordan_reviewer"), str(body1.get("username")))
        check("terms_reaccept_required is signaled so the client can prompt after the fact",
              body1.get("terms_reaccept_required") is True, str(body1))
        check("session cookie issued despite unaccepted terms", r1.cookies.get("session") is not None)

        db = DBManager()
        db.cur.execute("SELECT terms_accepted_at, terms_version FROM users WHERE _id = %s", (uid,))
        row = db.cur.fetchone()
        db.close()
        check("terms_accepted_at/terms_version stay NULL until the user actually agrees",
              row == (None, None), str(row))

        print("\n=== Apple: returning user (second auth, no full_name this time) ===")
        r2 = client.post("/auth/apple", json={"identity_token": "fake-token", "terms_accepted": False})
        check("returning Apple user matched by sub, not re-created", r2.status_code == 200, str(r2.status_code))
        check("same user_id on return visit", r2.json().get("user_id") == uid, str(r2.json()))

        r3 = client.post(f"/user/{uid}/accept-terms", cookies={"session": r2.cookies.get("session")})
        check("accept-terms endpoint works post-creation", r3.status_code == 200, str(r3.status_code))
        db = DBManager()
        db.cur.execute("SELECT terms_version FROM users WHERE _id = %s", (uid,))
        check("terms_version now stamped after explicit acceptance", db.cur.fetchone()[0] is not None)
        db.close()

        cleanup(uid)

        print("\n=== Apple: first authorization WITH terms already accepted ===")
        fake_sub2 = f"apple-sub-{uuid.uuid4().hex[:8]}"
        main_module.jwt.decode = MagicMock(return_value={"sub": fake_sub2, "email": f"a2_{uuid.uuid4().hex[:6]}@example.com"})
        r4 = client.post("/auth/apple", json={
            "identity_token": "fake-token", "full_name": "Already Agreed", "terms_accepted": True,
        })
        check("Apple auth with terms_accepted=true creates account normally", r4.status_code == 200, str(r4.status_code))
        check("no reaccept prompt when terms were actually accepted",
              "terms_reaccept_required" not in r4.json(), str(r4.json()))
        cleanup(r4.json()["user_id"])

        print("\n=== Google: first authorization, terms NOT accepted ===")
        fake_google_sub = f"google-sub-{uuid.uuid4().hex[:8]}"
        fake_google_email = f"googletest_{uuid.uuid4().hex[:8]}@example.com"

        fake_response = MagicMock()
        fake_response.status_code = 200
        fake_response.json = MagicMock(return_value={
            "sub": fake_google_sub, "email": fake_google_email, "given_name": "Taylor",
            "aud": os.getenv("CLIENT_ID", ""),
        })
        mock_client = MagicMock()
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=False)
        mock_client.get = AsyncMock(return_value=fake_response)
        main_module.httpx.AsyncClient = MagicMock(return_value=mock_client)

        r5 = client.post("/auth/google", json={"credential": "fake-credential", "terms_accepted": False})
        check("first Google auth without terms_accepted still creates the account (200, not 422)",
              r5.status_code == 200, str((r5.status_code, r5.text)))
        check("terms_reaccept_required signaled for Google too",
              r5.json().get("terms_reaccept_required") is True, str(r5.json()))
        cleanup(r5.json()["user_id"])

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
