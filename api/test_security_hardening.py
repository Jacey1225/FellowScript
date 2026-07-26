"""Tests for infra-security hardening applied via the security-compliance skill:
CORS origin restriction and rate limiting on /signup and /login.

Run with: cd api && ../.venv/bin/python test_security_hardening.py
"""
import os
import time
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
import main as main_module  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def main():
    with TestClient(main_module.app) as client:
        print("=== 1. CORS: unlisted origin gets no Access-Control-Allow-Origin ===")
        r = client.options("/login", headers={
            "Origin": "https://evil.example.com",
            "Access-Control-Request-Method": "POST",
        })
        check("evil origin has no ACAO header", r.headers.get("access-control-allow-origin") is None,
              str(r.headers.get("access-control-allow-origin")))

        print("\n=== 2. CORS: real frontend origin is allowed ===")
        r2 = client.options("/login", headers={
            "Origin": "https://fellowscript.com",
            "Access-Control-Request-Method": "POST",
        })
        check("fellowscript.com origin echoed back in ACAO",
              r2.headers.get("access-control-allow-origin") == "https://fellowscript.com",
              str(r2.headers.get("access-control-allow-origin")))

        print("\n=== 3. Rate limiting: signup/login happy paths still work ===")
        uname = f"rl_{uuid.uuid4().hex[:8]}"
        r3 = client.post("/signup", json={
            "username": uname, "email": f"{uname}@example.com", "plain_pass": "TestPass123!",
        })
        check("signup happy path still returns 201", r3.status_code == 201, str(r3.status_code))
        uid = r3.json().get("user_id")
        token = r3.cookies.get("session")

        r4 = client.post("/login", json={"username": uname, "plain_pass": "TestPass123!"})
        check("login happy path still returns 200", r4.status_code == 200, str(r4.status_code))

        print("\n=== 4. Rate limiting: brute-forcing /login eventually returns 429 ===")
        codes = [client.post("/login", json={"username": uname, "plain_pass": "wrong"}).status_code
                 for _ in range(13)]
        check("some attempts succeed as 401 before the limit trips",
              codes.count(401) > 0, str(codes))
        check("brute-force attempts eventually hit 429", 429 in codes, str(codes))

        print("\n=== 5. Rate limiting keys off CF-Connecting-IP, not the rotating "
              "Cloudflare edge IP nginx forwards as request.client ===")
        # Simulate two distinct real visitors both routed through the same
        # (spoofed-as-different) Cloudflare edge IP on request.client, to prove
        # the limiter distinguishes them via CF-Connecting-IP rather than
        # bucketing every Cloudflare-fronted request together (or, worse,
        # treating every request as a different client and never limiting).
        from main import get_client_ip
        from starlette.requests import Request as StarletteRequest

        def fake_request(cf_ip: str | None):
            scope = {
                "type": "http", "headers": [(b"cf-connecting-ip", cf_ip.encode())] if cf_ip else [],
                "client": ("198.51.100.9", 0),  # a stand-in "Cloudflare edge IP"
            }
            return StarletteRequest(scope)

        check("CF-Connecting-IP header is used when present",
              get_client_ip(fake_request("203.0.113.5")) == "203.0.113.5")
        check("falls back to request.client.host when header absent (local/dev)",
              get_client_ip(fake_request(None)) == "198.51.100.9")
        check("two different real visitors behind the same edge IP are distinguished",
              get_client_ip(fake_request("203.0.113.5")) != get_client_ip(fake_request("203.0.113.6")))

        print("\n=== 6. Rate limiting: brute-forcing /signup eventually returns 429 ===")
        codes2 = []
        spam_uids, spam_tokens = [], []
        for _ in range(7):
            u = f"rl_spam_{uuid.uuid4().hex[:8]}"
            r5 = client.post("/signup", json={"username": u, "email": f"{u}@example.com", "plain_pass": "x"})
            codes2.append(r5.status_code)
            if r5.status_code == 201:
                spam_uids.append(r5.json()["user_id"])
                spam_tokens.append(r5.cookies.get("session"))
        check("mass signup attempts eventually hit 429", 429 in codes2, str(codes2))

        if uid:
            client.delete(f"/user/{uid}", cookies={"session": token})
        for su, st in zip(spam_uids, spam_tokens):
            client.delete(f"/user/{su}", cookies={"session": st})

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
