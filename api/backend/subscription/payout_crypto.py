"""Field-level encryption for affiliate payout details
(task 20261008-affiliate-payout-details).

AES-256-GCM via ``cryptography`` (already a dependency). Wire format, per field:

    base64url( key_id (1 byte) || nonce (12 bytes) || ciphertext || tag )

A fresh random 96-bit nonce is drawn for every encryption. The AAD binds the
ciphertext to ``<row_id>|<field name>`` so it cannot be replayed into another
row or field.

Keys come from the env var ``PAYOUT_ENCRYPTION_KEYS``: a comma-separated list of
``<id>:<base64 of exactly 32 bytes>`` entries, id 1..255. The FIRST entry is the
current key (used for every new write); the rest are older keys kept for
decryption until ``scripts/rotate_payout_keys.py`` reports zero rows on them.
Missing or malformed config refuses to boot (``validate_payout_keys`` runs from
``startup_checks``). Key material is never logged and never appears in an
exception message.

Rotation: prepend ``<new id>:<new key>`` to the list, restart, run the rotation
script, then drop retired entries.
"""
from __future__ import annotations

import base64
import binascii
import hmac
import os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ENV_VAR = "PAYOUT_ENCRYPTION_KEYS"
NONCE_LEN = 12
KEY_LEN = 32


class PayoutKeyConfigError(RuntimeError):
    """PAYOUT_ENCRYPTION_KEYS is unset or malformed. Never contains key material."""


class PayoutDecryptError(RuntimeError):
    """A stored value could not be decrypted (wrong key, tampering, wrong binding)."""


def _parse(raw: str | None) -> tuple[int, dict[int, bytes]]:
    if raw is None or not raw.strip():
        raise PayoutKeyConfigError(
            f"{ENV_VAR} is not set. There is no implicit default; set it to "
            "'<id>:<base64 of 32 random bytes>' (first entry is the current key)."
        )
    keys: dict[int, bytes] = {}
    current: int | None = None
    for i, entry in enumerate(raw.split(",")):
        kid_s, sep, b64 = entry.strip().partition(":")
        if not sep or not kid_s.isdigit() or not b64:
            raise PayoutKeyConfigError(f"{ENV_VAR} entry {i} must look like '<id>:<base64 key>'")
        kid = int(kid_s)
        if not 1 <= kid <= 255 or kid in keys:
            raise PayoutKeyConfigError(f"{ENV_VAR} entry {i} has an out-of-range or duplicate key id")
        try:
            key = base64.b64decode(b64.strip(), validate=True)
        except (binascii.Error, ValueError):
            raise PayoutKeyConfigError(f"{ENV_VAR} entry {i} is not valid base64") from None
        if len(key) != KEY_LEN:
            raise PayoutKeyConfigError(f"{ENV_VAR} entry {i} must decode to exactly {KEY_LEN} bytes")
        keys[kid] = key
        if current is None:
            current = kid
    return current, keys  # type: ignore[return-value]


def _keys() -> tuple[int, dict[int, bytes]]:
    # Read per call (cheap) so tests and rotation never see a stale cache.
    return _parse(os.environ.get(ENV_VAR))


def _aad(row_id: str, field: str) -> bytes:
    return f"{row_id}|{field}".encode()


def encrypt(plaintext: str, row_id: str, field: str) -> str:
    kid, keys = _keys()
    nonce = os.urandom(NONCE_LEN)
    ct = AESGCM(keys[kid]).encrypt(nonce, plaintext.encode("utf-8"), _aad(row_id, field))
    return base64.urlsafe_b64encode(bytes([kid]) + nonce + ct).decode("ascii")


def key_id_of(token: str) -> int:
    """The key id a stored value was written under (no decryption)."""
    try:
        return base64.urlsafe_b64decode(token.encode("ascii"))[0]
    except (binascii.Error, ValueError, IndexError):
        raise PayoutDecryptError("malformed ciphertext") from None


def decrypt(token: str, row_id: str, field: str) -> str:
    _, keys = _keys()
    try:
        blob = base64.urlsafe_b64decode(token.encode("ascii"))
        kid, nonce, ct = blob[0], blob[1:1 + NONCE_LEN], blob[1 + NONCE_LEN:]
        key = keys.get(kid)
        if key is None or len(nonce) != NONCE_LEN or len(ct) < 16:
            raise PayoutDecryptError("cannot decrypt stored value")
        return AESGCM(key).decrypt(nonce, ct, _aad(row_id, field)).decode("utf-8")
    except (InvalidTag, binascii.Error, ValueError, IndexError):
        # Deliberately generic: never echo token, key id guesses or AAD.
        raise PayoutDecryptError("cannot decrypt stored value") from None


def current_key_id() -> int:
    return _keys()[0]


def validate_payout_keys() -> None:
    """Startup check: parse the key list and round-trip a self-test with every key."""
    _, keys = _keys()
    for kid, key in keys.items():
        nonce = os.urandom(NONCE_LEN)
        probe = AESGCM(key)
        if not hmac.compare_digest(probe.decrypt(nonce, probe.encrypt(nonce, b"selftest", b"aad"), b"aad"), b"selftest"):
            raise PayoutKeyConfigError(f"{ENV_VAR} self-test failed for key id {kid}")
    row = "00000000-0000-0000-0000-000000000000"
    if decrypt(encrypt("selftest", row, "selftest"), row, "selftest") != "selftest":
        raise PayoutKeyConfigError(f"{ENV_VAR} self-test failed")
