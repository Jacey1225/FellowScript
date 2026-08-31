"""Apple StoreKit / App Store Server integration (iOS).

StoreKit 2 verifies transactions cryptographically ON DEVICE and hands the app a
signed JWS. The app forwards that JWS here; we verify Apple's signature chain
(x5c, rooted at the pinned Apple Root CA - G3) before trusting any claim in the
payload, then read the product, original transaction id, and expiry to record
the subscription. This same verified decode also gates App Store Server
Notifications (POST /subscriptions/apple/notifications), which is otherwise
unauthenticated by design (Apple's servers can't carry a user session — same
posture as the Stripe webhook, which trusts a signature instead of a session).

Without this verification, both call sites would accept a client-fabricated
JWS payload: an authenticated user could forge their own /apple/sync body to
grant themselves a paid plan for free, and anyone could forge an unauthenticated
/apple/notifications body to activate, cancel, or refund an arbitrary account's
subscription (keyed only by a guessable originalTransactionId).
"""

import base64
import json
import logging
import os
from datetime import datetime, timezone

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

logger = logging.getLogger(__name__)

# Apple Root CA - G3, pinned in source rather than fetched at verify-time so a
# compromised/MITM'd network path can't substitute a different trust root.
# Fetched directly from https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
# over TLS; SHA-256 fingerprint matches Apple's published value
# 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79.
_APPLE_ROOT_CA_G3_PEM = b"""-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----"""
_APPLE_ROOT_CA_G3 = x509.load_pem_x509_certificate(_APPLE_ROOT_CA_G3_PEM, default_backend())

# App Store Connect product id → member_count. Must match the products created
# in App Store Connect and StoreKitManager on iOS. One fixed-price product per
# member count (1-8), since StoreKit can't compute an arbitrary price.
APPLE_PRODUCTS: dict[str, int] = {
    "com.fellowscript.access.one":   1,
    "com.fellowscript.access.two":   2,
    "com.fellowscript.access.three": 3,
    "com.fellowscript.access.four":  4,
    "com.fellowscript.access.five":  5,
    "com.fellowscript.access.six":   6,
    "com.fellowscript.access.seven": 7,
    "com.fellowscript.access.eight": 8,
}

# StoreKit 2 stamps every signed transaction with an `environment`:
#   "Xcode"      — local .storekit-file testing in Xcode; the transaction is
#                  fabricated on-device (ids like "0"), never a real purchase.
#   "Sandbox"    — App Store sandbox: TestFlight builds AND App Review testing.
#   "Production" — a real paid App Store purchase.
# The live server must NEVER treat an "Xcode" transaction as a real plan — that
# is exactly how a dev/test device leaks a paid plan onto every account it signs
# into. "Sandbox" is intentionally allowed because App Review exercises IAP in
# sandbox; set APPLE_ALLOW_SANDBOX=false to also refuse sandbox on a pure-prod box.
#
# No implicit default: this gates whether a real-money-adjacent grant (a paid
# plan) can be created from a non-production transaction, so an operator must
# say explicitly which way a deployment should behave rather than the process
# silently inheriting a permissive fallback if the var is ever left unset.
_ALLOW_SANDBOX_RAW = os.getenv("APPLE_ALLOW_SANDBOX")
if _ALLOW_SANDBOX_RAW is None:
    raise RuntimeError(
        "APPLE_ALLOW_SANDBOX is not set. Set it explicitly to \"true\" (non-production "
        "deployments serving TestFlight/App Review, the current behavior) or \"false\" "
        "(a pure-production deployment) — there is no implicit default."
    )
_ALLOW_SANDBOX = _ALLOW_SANDBOX_RAW.strip().lower() != "false"


def is_accepted_environment(environment: str | None) -> bool:
    """True if a transaction from this StoreKit environment may create a plan."""
    env = (environment or "").strip().lower()
    # A real transaction always carries an environment. Treat an absent/unknown
    # value as untrusted rather than silently accepting it.
    if env == "production":
        return True
    if env == "sandbox":
        return _ALLOW_SANDBOX
    return False


def member_count_for(product_id: str) -> int | None:
    return APPLE_PRODUCTS.get(product_id or "")


def _b64url_decode(segment: str) -> bytes:
    segment += "=" * (-len(segment) % 4)   # restore padding
    return base64.urlsafe_b64decode(segment)


def _cert_signed_by(cert: "x509.Certificate", issuer_public_key) -> bool:
    """True if ``cert``'s signature verifies against ``issuer_public_key``."""
    try:
        if isinstance(issuer_public_key, ec.EllipticCurvePublicKey):
            issuer_public_key.verify(
                cert.signature,
                cert.tbs_certificate_bytes,
                ec.ECDSA(cert.signature_hash_algorithm),
            )
        else:
            issuer_public_key.verify(
                cert.signature,
                cert.tbs_certificate_bytes,
                padding.PKCS1v15(),
                cert.signature_hash_algorithm,
            )
        return True
    except InvalidSignature:
        return False


def _verify_x5c_chain(x5c: list[str]) -> "x509.Certificate":
    """Verify a JWS header's ``x5c`` certificate chain roots at the pinned
    Apple Root CA - G3, and return the leaf certificate (whose public key
    signs the JWS itself) on success.

    ``x5c`` is ordered leaf-first; Apple's chains omit the root, so the last
    entry is normally the intermediate (Apple Worldwide Developer Relations /
    App Store Server) cert, not the root itself.

    Raises ValueError if the chain is empty, expired, or does not chain to
    the pinned root.
    """
    if not x5c:
        raise ValueError("JWS header missing x5c certificate chain")

    try:
        chain = [x509.load_der_x509_certificate(base64.b64decode(c), default_backend()) for c in x5c]
    except Exception as e:
        raise ValueError("Malformed x5c certificate in JWS header") from e

    now = datetime.now(timezone.utc)
    for cert in chain:
        if not (cert.not_valid_before_utc <= now <= cert.not_valid_after_utc):
            raise ValueError("Certificate in Apple JWS chain is expired or not yet valid")

    # Each cert must be signed by the next one up the chain.
    for child, issuer in zip(chain, chain[1:]):
        if not _cert_signed_by(child, issuer.public_key()):
            raise ValueError("Apple JWS certificate chain is not internally consistent")

    # The top of the supplied chain must itself be the pinned root, or be
    # directly signed by it — never trust a self-declared/unpinned root.
    top = chain[-1]
    if top.fingerprint(hashes.SHA256()) != _APPLE_ROOT_CA_G3.fingerprint(hashes.SHA256()):
        if not _cert_signed_by(top, _APPLE_ROOT_CA_G3.public_key()):
            raise ValueError("Apple JWS certificate chain does not root at Apple Root CA - G3")

    return chain[0]


def decode_jws(jws: str) -> dict:
    """Verify a StoreKit / App Store Server JWS (``header.payload.signature``)
    against Apple's x5c certificate chain, rooted at the pinned Apple Root CA -
    G3, and return the decoded payload only if the signature is valid.

    Raises ValueError if the token is malformed, the certificate chain does
    not verify, or the signature itself is invalid.
    """
    parts = (jws or "").split(".")
    if len(parts) != 3:
        raise ValueError("Malformed JWS")
    header_b64, payload_b64, sig_b64 = parts

    header = json.loads(_b64url_decode(header_b64))
    if header.get("alg") != "ES256":
        raise ValueError(f"Unsupported/unexpected JWS algorithm: {header.get('alg')!r}")

    leaf = _verify_x5c_chain(header.get("x5c") or [])

    signature = _b64url_decode(sig_b64)
    if len(signature) != 64:
        raise ValueError("Malformed ES256 JWS signature")
    r = int.from_bytes(signature[:32], "big")
    s = int.from_bytes(signature[32:], "big")
    der_signature = encode_dss_signature(r, s)

    signing_input = f"{header_b64}.{payload_b64}".encode("ascii")
    try:
        leaf.public_key().verify(der_signature, signing_input, ec.ECDSA(hashes.SHA256()))
    except InvalidSignature as e:
        raise ValueError("Apple JWS signature verification failed") from e

    return json.loads(_b64url_decode(payload_b64))
