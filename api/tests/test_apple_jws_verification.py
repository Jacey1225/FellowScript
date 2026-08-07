"""Tests for the Apple StoreKit JWS signature-verification fix (security audit
finding 1, CRITICAL): api/backend/subscription/apple_service.py::decode_jws()
used to decode a StoreKit/App Store Server JWS payload WITHOUT verifying its
signature, so:
  - POST /subscriptions/apple/sync (authenticated) let any user forge their
    own transaction payload and grant themselves a paid plan for free.
  - POST /subscriptions/apple/notifications (unauthenticated by design, like
    the Stripe webhook) let anyone forge an App Store Server Notification to
    activate/cancel/refund an arbitrary account's subscription, keyed only by
    a guessable apple_original_transaction_id.

decode_jws() now verifies the JWS header's x5c certificate chain against a
pinned copy of Apple's Root CA - G3 before trusting any claim in the payload.
This file proves, at both the crypto layer (unit) and the API layer
(integration), that:
  1. A syntactically valid JWS whose chain roots at a trusted CA and whose
     signature is valid is accepted (using a synthetic root swapped in for
     the pinned Apple root, since we don't have Apple's private key).
  2. A tampered payload (valid chain/signature over different bytes) is
     rejected.
  3. A chain that does not root at the pinned Apple Root CA - G3 (i.e. any
     self-signed/attacker-controlled chain) is rejected, using the REAL
     pinned root — this is the actual forgery scenario in the finding.
  4. Malformed JWS strings are rejected.
  5. The forged-payload rejection actually prevents plan creation via
     POST /subscriptions/apple/sync, and prevents a forged App Store Server
     Notification from touching a real subscription via
     POST /subscriptions/apple/notifications.

Run with: cd api && ../.venv/bin/python tests/test_apple_jws_verification.py
"""
import _pathfix  # noqa: F401

import base64
import json
import os
import uuid
from datetime import datetime, timedelta, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from cryptography import x509  # noqa: E402
from cryptography.hazmat.backends import default_backend  # noqa: E402
from cryptography.hazmat.primitives import hashes  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature  # noqa: E402
from cryptography.hazmat.primitives.serialization import Encoding  # noqa: E402
from cryptography.x509.oid import NameOID  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from backend.subscription import apple_service  # noqa: E402
from db import DBManager  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── Synthetic Apple-shaped cert chain (root + leaf, EC P-256, same shape as
#    Apple's real x5c chain) so we can construct fully valid JWS payloads
#    without Apple's private key. ────────────────────────────────────────────

def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _make_root():
    key = ec.generate_private_key(ec.SECP256R1(), default_backend())
    subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Root CA")])
    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject).issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256(), default_backend())
    )
    return key, cert


def _make_leaf(root_key, root_cert):
    key = ec.generate_private_key(ec.SECP256R1(), default_backend())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Leaf (App Store Server)")])
    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject).issuer_name(root_cert.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=365))
        .sign(root_key, hashes.SHA256(), default_backend())
    )
    return key, cert


def _der_b64(cert) -> str:
    return base64.b64encode(cert.public_bytes(Encoding.DER)).decode()


def _build_jws(leaf_key, x5c_certs: list, payload: dict, header_extra: dict | None = None) -> str:
    header = {"alg": "ES256", "x5c": [_der_b64(c) for c in x5c_certs]}
    if header_extra:
        header.update(header_extra)
    header_b64 = _b64url(json.dumps(header).encode())
    payload_b64 = _b64url(json.dumps(payload).encode())
    signing_input = f"{header_b64}.{payload_b64}".encode("ascii")
    der_sig = leaf_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der_sig)
    raw_sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    sig_b64 = _b64url(raw_sig)
    return f"{header_b64}.{payload_b64}.{sig_b64}"


def main():
    root_key, root_cert = _make_root()
    leaf_key, leaf_cert = _make_leaf(root_key, root_cert)

    real_payload = {
        "productId": "com.fellowscript.access.two",
        "originalTransactionId": "1000000000000001",
        "transactionId": "1000000000000001",
        "expiresDate": int((datetime.now(timezone.utc) + timedelta(days=30)).timestamp() * 1000),
        "environment": "Production",
    }

    print("=== 1. Valid chain + valid signature is ACCEPTED (synthetic root pinned in place of Apple's) ===")
    valid_jws = _build_jws(leaf_key, [leaf_cert], real_payload)
    orig_root = apple_service._APPLE_ROOT_CA_G3
    apple_service._APPLE_ROOT_CA_G3 = root_cert
    try:
        decoded = apple_service.decode_jws(valid_jws)
        check("valid JWS decodes to the original payload",
              decoded.get("originalTransactionId") == real_payload["originalTransactionId"], str(decoded))

        print("\n=== 2. Tampered payload (valid chain/signature, different bytes) is REJECTED ===")
        header_b64, _, sig_b64 = valid_jws.split(".")
        tampered_payload = dict(real_payload)
        tampered_payload["productId"] = "com.fellowscript.access.eight"  # attacker tries to upgrade the product
        tampered_b64 = _b64url(json.dumps(tampered_payload).encode())
        tampered_jws = f"{header_b64}.{tampered_b64}.{sig_b64}"
        try:
            apple_service.decode_jws(tampered_jws)
            check("tampered-payload JWS is rejected", False, "decode_jws did not raise")
        except ValueError as e:
            check("tampered-payload JWS is rejected", "signature" in str(e).lower(), str(e))
    finally:
        apple_service._APPLE_ROOT_CA_G3 = orig_root

    print("\n=== 3. Chain rooted at an attacker-controlled CA (NOT the real pinned Apple root) is REJECTED ===")
    # This is the actual forgery scenario in the finding: an attacker with no
    # access to Apple's private key builds their own self-signed chain.
    forged_jws = _build_jws(leaf_key, [leaf_cert], real_payload)
    try:
        apple_service.decode_jws(forged_jws)  # verified against the REAL pinned Apple root this time
        check("forged chain (unrelated to real Apple root) is rejected", False, "decode_jws did not raise")
    except ValueError as e:
        check("forged chain (unrelated to real Apple root) is rejected",
              "root" in str(e).lower() or "chain" in str(e).lower(), str(e))

    print("\n=== 4. Malformed JWS strings are rejected ===")
    for bad, label in [
        ("not-a-jws", "wrong segment count"),
        ("", "empty string"),
        ("a.b", "two segments"),
        ("a.b.c.d", "four segments"),
    ]:
        try:
            apple_service.decode_jws(bad)
            check(f"malformed JWS rejected ({label})", False, "did not raise")
        except ValueError:
            check(f"malformed JWS rejected ({label})", True)

    print("\n=== 5. Empty x5c header is rejected ===")
    header_b64 = _b64url(json.dumps({"alg": "ES256", "x5c": []}).encode())
    payload_b64 = _b64url(json.dumps(real_payload).encode())
    no_chain_jws = f"{header_b64}.{payload_b64}.{_b64url(b'x' * 64)}"
    try:
        apple_service.decode_jws(no_chain_jws)
        check("missing x5c chain rejected", False, "did not raise")
    except ValueError as e:
        check("missing x5c chain rejected", "x5c" in str(e).lower(), str(e))

    # ── Route-level: forged JWS must never grant a plan or touch a real one ──
    print("\n=== 6. POST /subscriptions/apple/sync rejects a forged JWS (400), grants no plan ===")
    with TestClient(main_module.app) as client:
        uname = f"applejws_{uuid.uuid4().hex[:8]}"
        r = client.post("/signup", json={
            "username": uname, "email": f"{uname}@example.com",
            "plain_pass": "TestPass123!", "terms_accepted": True,
        })
        check("test user signup succeeds", r.status_code == 201, str(r.status_code))
        uid = r.json().get("user_id")
        token = r.cookies.get("session")
        cookies = {"session": token}

        forged_sync_jws = _build_jws(leaf_key, [leaf_cert], real_payload)
        rs = client.post("/subscriptions/apple/sync", json={"user_id": uid, "jws": forged_sync_jws}, cookies=cookies)
        check("forged apple/sync JWS is rejected with 400", rs.status_code == 400, str(rs.status_code) + " " + rs.text)

        rp = client.get(f"/subscriptions/user/{uid}", cookies=cookies)
        # No plan should have been created from the forged transaction —
        # either a 404 (no plan) or a plan whose provider isn't apple/txn isn't ours.
        if rp.status_code == 200:
            body = rp.json()
            check("no plan was created from the forged transaction",
                  body.get("apple_original_transaction_id") != real_payload["originalTransactionId"], str(body))
        else:
            check("no plan was created from the forged transaction", rp.status_code in (404, 200), str(rp.status_code))

        print("\n=== 7. POST /subscriptions/apple/notifications rejects a forged signedPayload (400) ===")
        outer_note_payload = {
            "notificationType": "DID_RENEW",
            "data": {"signedTransactionInfo": forged_sync_jws},
        }
        forged_notification_jws = _build_jws(leaf_key, [leaf_cert], outer_note_payload)
        rn = client.post("/subscriptions/apple/notifications", json={"signedPayload": forged_notification_jws})
        check("forged apple/notifications payload is rejected with 400",
              rn.status_code == 400, str(rn.status_code) + " " + rn.text)

        client.delete(f"/user/{uid}", cookies=cookies)

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
