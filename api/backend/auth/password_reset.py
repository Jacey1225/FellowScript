import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from db import DBManager
from backend.errors import SaveFailedError

RESET_TOKEN_TTL_MINUTES = 30


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class PasswordResetManager(DBManager):
    """Single-use, hashed password-reset tokens emailed to the account's address.

    Mirrors SessionManager: only the token's sha256 hash is ever stored, so a
    database leak alone can't be replayed as a valid reset link.
    """

    def create_token(self, user_id: str) -> str:
        """Issue a new reset token for ``user_id`` and return the raw token
        (the caller embeds it in the emailed reset link — never stored raw)."""
        token = secrets.token_urlsafe(32)
        expires_at = datetime.now(timezone.utc) + timedelta(minutes=RESET_TOKEN_TTL_MINUTES)
        # A token that's emailed but never actually persisted can never be
        # resolved back -- the user would click a reset link that's dead
        # on arrival despite the "email sent" response looking successful.
        if not self.insertion("password_reset_tokens", {
            "user_id":    user_id,
            "token_hash": _hash_token(token),
            "expires_at": expires_at,
        }):
            raise SaveFailedError()
        return token

    def resolve(self, token: str) -> str | None:
        """Return the user_id for a valid, unexpired, unused token — else None."""
        result = self.lookup("password_reset_tokens", {"token_hash": _hash_token(token)})
        if not result:
            return None
        _, data = list(result.items())[0]
        if data.get("used"):
            return None
        expires_at = data.get("expires_at")
        if expires_at is None:
            return None
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        if expires_at < datetime.now(timezone.utc):
            return None
        return str(data.get("user_id"))

    def consume(self, token: str) -> None:
        """Mark a token used so it can never be replayed, even before expiry.

        Callers invoke this only right after ``resolve(token)`` confirmed
        the row is valid, so a False return is a real write failure --
        raising rather than silently continuing matters here specifically:
        if "used" silently failed to persist, the same reset link would
        stay valid and replayable.
        """
        if not self.update("password_reset_tokens", {"used": True}, {"token_hash": _hash_token(token)}):
            raise SaveFailedError()
