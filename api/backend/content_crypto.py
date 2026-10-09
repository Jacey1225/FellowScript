"""Field-level encryption at rest for user content (notes, chat messages, ...)
(task 20261008-content-encryption-at-rest).

AES-256-GCM via ``cryptography`` (already a dependency), same primitive and
key-ring shape as ``backend/subscription/payout_crypto.py`` but a SEPARATE key
ring (env var ``CONTENT_ENCRYPTION_KEYS``) so a content-key rotation or leak
never touches payout keys.

Stored form, in the existing column (no schema change beyond widening VARCHAR):

    ``enc:v1:`` + base64url( key_id (1 byte) || nonce (12 bytes) || ciphertext || tag )

A plaintext value that itself starts with ``enc:`` is stored with the escape
prefix ``enc:p:`` so plaintext and ciphertext are never ambiguous (no
heuristics). ``seal_plain`` / ``open_value`` below implement the three forms:

    ``enc:v1:...``  ciphertext   -> decrypt (fail CLOSED on any failure)
    ``enc:p:...``   escaped text -> strip the escape
    anything else   plaintext    -> returned unchanged (dual-read for rows not yet migrated)

The AAD is ``<table>.<column>|<row_id>`` so a ciphertext cannot be replayed into
another row, column or table. A fresh random 96-bit nonce is drawn per write.

Key ring: ``<id>:<base64 of 32 bytes>`` entries, comma separated, id 1..255; the
FIRST entry is the current key (all new writes); later entries are older keys
kept for decryption until ``scripts/rotate_content_keys.py`` reports zero rows on
them. Missing/malformed config refuses to boot (``validate_content_keys`` runs
from ``startup_checks``). Key material, plaintext and ciphertext never appear in
logs or exception messages: ``ContentDecryptError`` carries only the field, the
row id and the key id.

This module is pure crypto: it does not read feature flags or the database.
The flag-gated write decision lives in ``backend.content_store``.
"""
from __future__ import annotations

import base64
import binascii
import hmac
import os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ENV_VAR = "CONTENT_ENCRYPTION_KEYS"
NONCE_LEN = 12
KEY_LEN = 32
TAG_LEN = 16

CIPHER_PREFIX = "enc:v1:"
ESCAPE_PREFIX = "enc:p:"
_RESERVED = "enc:"


class ContentKeyConfigError(RuntimeError):
    """CONTENT_ENCRYPTION_KEYS is unset or malformed. Never contains key material."""


class ContentDecryptError(RuntimeError):
    """A stored value could not be decrypted. Carries ONLY field, row id and key id
    (never plaintext, ciphertext, key bytes or AAD)."""

    def __init__(self, field: str, row_id: str, key_id: int | None = None, reason: str = "cannot decrypt"):
        self.field = field
        self.row_id = str(row_id)
        self.key_id = key_id
        self.reason = reason
        super().__init__(f"{reason}: field={field} row={self.row_id} key_id={key_id}")


def _parse(raw: str | None) -> tuple[int, dict[int, bytes]]:
    if raw is None or not raw.strip():
        raise ContentKeyConfigError(
            f"{ENV_VAR} is not set. There is no implicit default; set it to "
            "'<id>:<base64 of 32 random bytes>' (first entry is the current key)."
        )
    keys: dict[int, bytes] = {}
    current: int | None = None
    for i, entry in enumerate(raw.split(",")):
        kid_s, sep, b64 = entry.strip().partition(":")
        if not sep or not kid_s.isdigit() or not b64:
            raise ContentKeyConfigError(f"{ENV_VAR} entry {i} must look like '<id>:<base64 key>'")
        kid = int(kid_s)
        if not 1 <= kid <= 255 or kid in keys:
            raise ContentKeyConfigError(f"{ENV_VAR} entry {i} has an out-of-range or duplicate key id")
        try:
            key = base64.b64decode(b64.strip(), validate=True)
        except (binascii.Error, ValueError):
            raise ContentKeyConfigError(f"{ENV_VAR} entry {i} is not valid base64") from None
        if len(key) != KEY_LEN:
            raise ContentKeyConfigError(f"{ENV_VAR} entry {i} must decode to exactly {KEY_LEN} bytes")
        keys[kid] = key
        if current is None:
            current = kid
    return current, keys  # type: ignore[return-value]


def _keys() -> tuple[int, dict[int, bytes]]:
    # Read per call (cheap) so tests and rotation never see a stale cache.
    return _parse(os.environ.get(ENV_VAR))


def _aad(field: str, row_id: str) -> bytes:
    # Lower-cased: a UUID has one canonical text form, but a client may send it
    # upper-case (e.g. a report's content_id) while the DB stores lower-case.
    return f"{field}|{str(row_id).lower()}".encode()


# -- classification -----------------------------------------------------------

def is_ciphertext(value: object) -> bool:
    return isinstance(value, str) and value.startswith(CIPHER_PREFIX)


def is_escaped_plaintext(value: object) -> bool:
    return isinstance(value, str) and value.startswith(ESCAPE_PREFIX)


def escape_plain(value: str) -> str:
    """Plaintext in its stored form: unchanged unless it starts with ``enc:``."""
    return ESCAPE_PREFIX + value if value.startswith(_RESERVED) else value


# -- primitives ---------------------------------------------------------------

def encrypt_field(row_id: str, field: str, plaintext: str) -> str:
    """Encrypt ``plaintext`` for ``field`` ('table.column') of ``row_id`` under the current key."""
    kid, keys = _keys()
    nonce = os.urandom(NONCE_LEN)
    ct = AESGCM(keys[kid]).encrypt(nonce, plaintext.encode("utf-8"), _aad(field, str(row_id)))
    return CIPHER_PREFIX + base64.urlsafe_b64encode(bytes([kid]) + nonce + ct).decode("ascii")


def key_id_of(stored: str) -> int:
    """The key id a stored ciphertext was written under (no decryption)."""
    if not is_ciphertext(stored):
        raise ContentDecryptError("?", "?", None, "not a ciphertext")
    try:
        return base64.urlsafe_b64decode(stored[len(CIPHER_PREFIX):].encode("ascii"))[0]
    except (binascii.Error, ValueError, IndexError):
        raise ContentDecryptError("?", "?", None, "malformed ciphertext") from None


def decrypt_field(row_id: str, field: str, stored: str) -> str:
    """Decrypt a ``enc:v1:`` value. Fails closed: never returns ciphertext or a guess."""
    kid: int | None = None
    try:
        _, keys = _keys()
        blob = base64.urlsafe_b64decode(stored[len(CIPHER_PREFIX):].encode("ascii"))
        kid, nonce, ct = blob[0], blob[1:1 + NONCE_LEN], blob[1 + NONCE_LEN:]
        key = keys.get(kid)
        if key is None:
            raise ContentDecryptError(field, row_id, kid, "unknown key id")
        if len(nonce) != NONCE_LEN or len(ct) < TAG_LEN:
            raise ContentDecryptError(field, row_id, kid, "malformed ciphertext")
        return AESGCM(key).decrypt(nonce, ct, _aad(field, str(row_id))).decode("utf-8")
    except ContentDecryptError:
        raise
    except ContentKeyConfigError:
        raise ContentDecryptError(field, row_id, kid, "key ring unavailable") from None
    except (InvalidTag, binascii.Error, ValueError, IndexError, UnicodeError):
        # Deliberately generic: never echo token, key bytes or AAD.
        raise ContentDecryptError(field, row_id, kid, "authentication failed") from None


# -- dual-read ----------------------------------------------------------------

def open_value(row_id: str, field: str, stored):
    """Read side. ``None`` and non-strings pass through; plaintext passes through;
    ``enc:p:`` is un-escaped; ``enc:v1:`` is decrypted (ContentDecryptError on failure)."""
    if not isinstance(stored, str):
        return stored
    if stored.startswith(CIPHER_PREFIX):
        return decrypt_field(row_id, field, stored)
    if stored.startswith(ESCAPE_PREFIX):
        return stored[len(ESCAPE_PREFIX):]
    return stored


def current_key_id() -> int:
    return _keys()[0]


def validate_content_keys() -> None:
    """Startup check: parse the ring and round-trip a self-test with every key."""
    _, keys = _keys()
    for kid, key in keys.items():
        nonce = os.urandom(NONCE_LEN)
        probe = AESGCM(key)
        if not hmac.compare_digest(probe.decrypt(nonce, probe.encrypt(nonce, b"selftest", b"aad"), b"aad"), b"selftest"):
            raise ContentKeyConfigError(f"{ENV_VAR} self-test failed for key id {kid}")
    row = "00000000-0000-0000-0000-000000000000"
    if open_value(row, "selftest.field", encrypt_field(row, "selftest.field", "selftest")) != "selftest":
        raise ContentKeyConfigError(f"{ENV_VAR} self-test failed")
