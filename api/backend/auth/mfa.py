import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from db import DBManager
from backend.errors import SaveFailedError

MFA_CODE_TTL_MINUTES = 10


def _hash_code(code: str) -> str:
    return hashlib.sha256(code.encode()).hexdigest()


def _generate_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


class MFAManager(DBManager):
    """Single-use, hashed 6-digit codes for the email-based 2FA login challenge
    and for confirming an email address before 2FA is turned on.

    Mirrors SessionManager/PasswordResetManager: only the code's sha256 hash
    is ever stored, so a database leak alone can't be replayed as a valid code.
    """

    def create_code(self, user_id: str) -> str:
        """Issue a new code for ``user_id`` and return the raw digits to email."""
        code = _generate_code()
        expires_at = datetime.now(timezone.utc) + timedelta(minutes=MFA_CODE_TTL_MINUTES)
        # A code that's emailed but never actually persisted can never be
        # verified back -- the user would be locked out of a login/setup
        # flow that looked like it succeeded.
        if not self.insertion("mfa_codes", {
            "user_id":    user_id,
            "code_hash":  _hash_code(code),
            "expires_at": expires_at,
        }):
            raise SaveFailedError()
        return code

    def verify(self, user_id: str, code: str) -> bool:
        """Check ``code`` against the most recent unused, unexpired code for
        this user. Consumes it (marks used) on success so it can't be replayed."""
        result = self.lookup("mfa_codes", {"user_id": user_id, "code_hash": _hash_code(code)})
        if not result:
            return False
        code_id, data = list(result.items())[0]
        if data.get("used"):
            return False
        expires_at = data.get("expires_at")
        if expires_at is None:
            return False
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        if expires_at < datetime.now(timezone.utc):
            return False
        # code_id was just resolved above, so the row is known to exist --
        # a False return here is a real write failure. Raising rather than
        # still returning True matters here specifically: if the "used"
        # flag silently failed to persist, the same code would stay valid
        # and replayable, undermining the single-use guarantee this table
        # exists for.
        if not self.update("mfa_codes", {"used": True}, {"_id": code_id}):
            raise SaveFailedError()
        return True

    def set_enabled(self, user_id: str, enabled: bool) -> None:
        # Called only for the authenticated caller's own account (routes
        # enforce require_match upstream), so the row is known to exist.
        if not self.update("users", {"mfa_enabled": enabled}, {"_id": user_id}):
            raise SaveFailedError()

    def is_enabled(self, user_id: str) -> bool:
        result = self.lookup("users", {"_id": user_id})
        if not result:
            return False
        _, data = list(result.items())[0]
        return bool(data.get("mfa_enabled"))
