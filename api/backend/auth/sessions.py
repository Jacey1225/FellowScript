import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from db import DBManager

SESSION_TTL_DAYS = 30


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class SessionManager(DBManager):
    """Server-side session store backing the login cookie.

    The cookie carries an opaque random token; only its hash is ever stored or
    looked up, so a database leak alone can't be replayed as a live session —
    the same reasoning as storing ``hash_pass`` instead of the plain password.
    """

    def create_session(self, user_id: str) -> str:
        """Issue a new session for ``user_id`` and return the raw cookie token."""
        token = secrets.token_urlsafe(32)
        expires_at = datetime.now(timezone.utc) + timedelta(days=SESSION_TTL_DAYS)
        self.insertion("sessions", {
            "token_hash": _hash_token(token),
            "user_id":    user_id,
            "expires_at": expires_at,
        })
        return token

    def resolve(self, token: str | None) -> str | None:
        """Return the session's user_id if ``token`` is a valid, unexpired session."""
        if not token:
            return None
        result = self.lookup("sessions", {"token_hash": _hash_token(token)})
        if not result:
            return None
        _, data = list(result.items())[0]
        expires_at = data.get("expires_at")
        if expires_at is None:
            return None
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        if expires_at < datetime.now(timezone.utc):
            return None
        return str(data.get("user_id"))

    def delete_session(self, token: str) -> None:
        """Log out: drop this one session (its cookie's token)."""
        self.delete("sessions", {"token_hash": _hash_token(token)})

    def delete_all_for_user(self, user_id: str) -> None:
        """Log out everywhere: drop every session belonging to this user."""
        self.delete("sessions", {"user_id": user_id})
