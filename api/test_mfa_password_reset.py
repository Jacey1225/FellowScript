"""Tests for email-based 2FA and the "forgot password" email flow.

Stubs the actual SES send (an external third-party API, not the database —
matches this project's convention of never mocking Postgres but not needing
live AWS credentials to test the request/response/DB logic around it) and
captures the code/token so tests can drive the full flow end to end against
a real Postgres test DB, exactly like the existing test files.

Run with: cd api && ../.venv/bin/python test_mfa_password_reset.py
"""
import os
import re
import uuid
from datetime import datetime, timedelta, timezone as tzmod

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402

PASSED, FAILED = [], []
SENT_EMAILS = []  # each entry: {"to": str, "subject": str, "html": str, "text": str}


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def _fake_send_email(to_email, subject, html_body, text_body):
    SENT_EMAILS.append({"to": to_email, "subject": subject, "html": html_body, "text": text_body})


def _last_code() -> str:
    """Pull the 6-digit code out of the most recently "sent" email."""
    m = re.search(r"\b(\d{6})\b", SENT_EMAILS[-1]["subject"])
    assert m, f"no 6-digit code found in subject: {SENT_EMAILS[-1]['subject']}"
    return m.group(1)


def _last_reset_token() -> str:
    m = re.search(r"token=([\w-]+)", SENT_EMAILS[-1]["html"])
    assert m, "no reset token found in emailed link"
    return m.group(1)


def _expire_reset_token(token_or_user_email: str) -> None:
    """Force the most recently issued reset token for this email to look expired."""
    db = DBManager()
    try:
        db.cur.execute(
            "UPDATE password_reset_tokens SET expires_at = %s "
            "WHERE user_id = (SELECT _id FROM users WHERE email = %s) "
            "AND used = false",
            (datetime.now(tzmod.utc) - timedelta(minutes=1), token_or_user_email),
        )
        db.conn.commit()
    finally:
        db.close()


def main():
    main_module.send_email = _fake_send_email  # patch the name main.py actually calls

    with TestClient(main_module.app) as client:
        uname = f"mfa_{uuid.uuid4().hex[:8]}"
        email = f"{uname}@example.com"
        password = "TestPass123!"
        r = client.post("/signup", json={"username": uname, "email": email, "plain_pass": password})
        check("setup: signup succeeds", r.status_code == 201, str(r.status_code))
        uid = r.json()["user_id"]
        token = r.cookies.get("session")
        cookies = {"session": token}

        print("\n=== Password reset ===")
        SENT_EMAILS.clear()
        r = client.post("/auth/password-reset/request", json={"email": email})
        check("reset request (real email) returns generic 202", r.status_code == 202, str(r.status_code))
        check("reset request actually sent an email", len(SENT_EMAILS) == 1, str(SENT_EMAILS))

        SENT_EMAILS.clear()
        r2 = client.post("/auth/password-reset/request", json={"email": "no_such_user_at_all@example.com"})
        check("reset request (unknown email) returns the SAME generic response",
              r2.status_code == 202 and r2.json() == r.json(), f"{r2.status_code} {r2.json()}")
        check("reset request (unknown email) sends no email (no enumeration oracle)",
              len(SENT_EMAILS) == 0, str(SENT_EMAILS))

        SENT_EMAILS.clear()
        client.post("/auth/password-reset/request", json={"email": email})
        reset_token = _last_reset_token()

        r3 = client.post("/auth/password-reset/confirm", json={"token": "not-a-real-token", "new_password": "x"})
        check("reset confirm with garbage token -> 400", r3.status_code == 400, str(r3.status_code))

        new_password = "NewPass456!"
        r4 = client.post("/auth/password-reset/confirm", json={"token": reset_token, "new_password": new_password})
        check("reset confirm with valid token -> 200", r4.status_code == 200, str(r4.status_code))

        r5 = client.post("/login", json={"username": uname, "plain_pass": password})
        check("old password no longer works after reset", r5.status_code == 401, str(r5.status_code))
        r6 = client.post("/login", json={"username": uname, "plain_pass": new_password})
        check("new password works after reset", r6.status_code == 200, str(r6.status_code))
        token = r6.cookies.get("session")
        cookies = {"session": token}

        r7 = client.post("/auth/password-reset/confirm", json={"token": reset_token, "new_password": "yet_another"})
        check("reset token cannot be reused (single-use) -> 400", r7.status_code == 400, str(r7.status_code))

        SENT_EMAILS.clear()
        client.post("/auth/password-reset/request", json={"email": email})
        expired_token = _last_reset_token()
        _expire_reset_token(email)
        r8 = client.post("/auth/password-reset/confirm", json={"token": expired_token, "new_password": "x"})
        check("expired reset token -> 400", r8.status_code == 400, str(r8.status_code))

        print("\n=== Enabling 2FA ===")
        r9 = client.post("/auth/mfa/enable")
        check("mfa/enable without a session -> 401 (security boundary)", r9.status_code == 401, str(r9.status_code))

        SENT_EMAILS.clear()
        r10 = client.post("/auth/mfa/enable", cookies=cookies)
        check("mfa/enable (authenticated) sends a setup code", r10.status_code == 200 and len(SENT_EMAILS) == 1,
              f"{r10.status_code} {SENT_EMAILS}")
        setup_code = _last_code()

        r11 = client.post("/auth/mfa/confirm", json={"code": "000000"}, cookies=cookies)
        check("mfa/confirm with wrong code -> 400", r11.status_code == 400, str(r11.status_code))

        r12 = client.post("/auth/mfa/confirm", json={"code": setup_code}, cookies=cookies)
        check("mfa/confirm with correct code -> enabled", r12.status_code == 200 and r12.json().get("mfa_enabled") is True,
              f"{r12.status_code} {r12.json()}")

        print("\n=== Logging in with 2FA enabled ===")
        SENT_EMAILS.clear()
        r13 = client.post("/login", json={"username": uname, "plain_pass": new_password})
        check("login with 2FA enabled pauses instead of issuing a session",
              r13.status_code == 200 and r13.json().get("mfa_required") is True, f"{r13.status_code} {r13.json()}")
        check("login with 2FA enabled sets NO session cookie yet",
              r13.cookies.get("session") is None, str(dict(r13.cookies)))
        check("login with 2FA enabled emailed a login code", len(SENT_EMAILS) == 1, str(SENT_EMAILS))
        login_code = _last_code()
        mfa_user_id = r13.json()["user_id"]

        r14 = client.post("/auth/mfa/verify-login", json={"user_id": mfa_user_id, "code": "000000"})
        check("verify-login with wrong code -> 401", r14.status_code == 401, str(r14.status_code))

        r15 = client.post("/auth/mfa/verify-login", json={"user_id": mfa_user_id, "code": login_code})
        check("verify-login with correct code -> session issued",
              r15.status_code == 200 and r15.cookies.get("session") is not None, str(r15.status_code))

        r16 = client.post("/auth/mfa/verify-login", json={"user_id": mfa_user_id, "code": login_code})
        check("login code cannot be reused (single-use) -> 401", r16.status_code == 401, str(r16.status_code))

        print("\n=== Disabling 2FA ===")
        r17 = client.post("/auth/mfa/disable", json={"plain_pass": "wrong password"}, cookies=cookies)
        check("mfa/disable with wrong password -> 401", r17.status_code == 401, str(r17.status_code))

        r18 = client.post("/auth/mfa/disable", json={"plain_pass": new_password}, cookies=cookies)
        check("mfa/disable with correct password -> disabled",
              r18.status_code == 200 and r18.json().get("mfa_enabled") is False, f"{r18.status_code} {r18.json()}")

        r19 = client.post("/login", json={"username": uname, "plain_pass": new_password})
        check("login after disabling 2FA issues a normal session again",
              r19.status_code == 200 and "mfa_required" not in r19.json(), f"{r19.status_code} {r19.json()}")

        client.delete(f"/user/{uid}", cookies={"session": r19.cookies.get("session")})

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
