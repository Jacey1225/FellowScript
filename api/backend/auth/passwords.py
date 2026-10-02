"""Password verification helper.

Apple and Google sign-in accounts are created with ``hash_pass = ""``.
``bcrypt.checkpw`` raises ``ValueError`` ("Invalid salt") for an empty or
malformed hash, which used to surface as a 500 from ``/login`` and
``/auth/mfa/disable``. This helper turns every such case into a plain
``False`` so callers return the same 401 for every failure cause (no
account-type oracle).
"""
import bcrypt


def verify_password(plain: str, stored_hash: str) -> bool:
    """Return True only when ``plain`` matches the bcrypt ``stored_hash``.

    Returns False for an empty, missing, or invalid hash. Never raises for a
    bad hash and never logs (the inputs are secrets).
    """
    if not stored_hash or not isinstance(stored_hash, str):
        return False
    try:
        return bcrypt.checkpw(plain.encode(), stored_hash.encode())
    except (ValueError, TypeError):
        return False
