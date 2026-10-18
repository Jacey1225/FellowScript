import hashlib
import logging
import secrets
from datetime import datetime, timedelta, timezone

from psycopg2 import Error as PgError

from db import DBManager
from backend.errors import SaveFailedError

logger = logging.getLogger(__name__)

# Sliding window: each session is valid this long from sign-in, and (via
# renew) from its last renewal. The login cookie's max_age derives from this
# same constant (SESSION_TTL_SECONDS) so cookie and row cannot drift apart.
SESSION_TTL_DAYS = 30
SESSION_TTL_SECONDS = SESSION_TTL_DAYS * 24 * 60 * 60

# Hard cap measured from sessions.created_at (sign-in): no amount of activity
# keeps one session alive past this; the user signs in again. Renewal clamps
# expires_at to created_at + this.
SESSION_MAX_AGE_DAYS = 90

# Renewal is throttled: a request only writes when it would push expires_at
# forward by at least this much, so a busy client costs about one UPDATE per
# day instead of one per request.
SESSION_RENEW_MIN_ADVANCE_SECONDS = 24 * 60 * 60


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
        # A "successful" login/signup response with no session actually
        # persisted would leave the caller holding a cookie that can never
        # resolve to a user -- silently broken auth, not a fake success
        # that's merely inconvenient.
        if not self.insertion("sessions", {
            "token_hash": _hash_token(token),
            "user_id":    user_id,
            "expires_at": expires_at,
        }):
            raise SaveFailedError()
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

    def renew(self, token: str | None) -> int | None:
        """Slide a live session's expiry forward; return the cookie max_age (seconds) or None.

        Sliding rule: new expires_at = min(now + SESSION_TTL_DAYS,
        created_at + SESSION_MAX_AGE_DAYS). One atomic UPDATE whose WHERE clause
        requires ``expires_at > NOW()``, so an expired (or unknown) session is
        never extended or revived, even if it expires between a prior resolve()
        and this call. A row with no created_at anchor is never extended (cannot
        enforce the cap). Throttled: only writes when the move is at least
        SESSION_RENEW_MIN_ADVANCE_SECONDS. Returns None when nothing changed
        (throttled, capped, expired, unknown, or a DB error -- the request is
        already authenticated, so a failed renewal is logged and ignored rather
        than failing the request; the session simply keeps its current expiry).

        The returned value is the remaining lifetime of the renewed row, which
        the caller must use as the re-issued cookie's max_age so the cookie
        never outlives the row nor expires before it.
        """
        if not token:
            return None
        try:
            self.cur.execute(
                "WITH cand AS ("
                " SELECT token_hash,"
                "  LEAST(NOW() + make_interval(secs => %s),"
                "        created_at + make_interval(secs => %s)) AS new_exp"
                " FROM sessions WHERE token_hash = %s"
                "  AND expires_at > NOW() AND created_at IS NOT NULL)"
                " UPDATE sessions s SET expires_at = cand.new_exp FROM cand"
                " WHERE s.token_hash = cand.token_hash"
                "  AND cand.new_exp >= s.expires_at + make_interval(secs => %s)"
                " RETURNING EXTRACT(EPOCH FROM (s.expires_at - NOW()))",
                (SESSION_TTL_SECONDS, SESSION_MAX_AGE_DAYS * 24 * 60 * 60,
                 _hash_token(token), SESSION_RENEW_MIN_ADVANCE_SECONDS),
            )
            row = self.cur.fetchone()
            self.conn.commit()
        except PgError as e:
            self.conn.rollback()
            logger.warning("session renew failed (%s)", type(e).__name__)
            return None
        if not row:
            return None
        return max(int(row[0]), 0)

    def purge_expired(self) -> int:
        """Delete every session row already past its expires_at; return the count.

        An expired row can never resolve or renew, so removing it changes no
        behavior. Rows past the hard cap are included (their expires_at is
        always <= created_at + cap). Raises on a DB error so the scheduled job
        can report it.
        """
        try:
            self.cur.execute("DELETE FROM sessions WHERE expires_at < NOW()")
            n = self.cur.rowcount
            self.conn.commit()
        except PgError:
            self.conn.rollback()
            raise
        return n

    def delete_session(self, token: str) -> None:
        """Log out: drop this one session (its cookie's token).

        Idempotent: an already-expired/already-logged-out token is a
        legitimate no-op, not a failure -- a real DB error is still
        visible via db.py's DB_WRITE_FAILURE log line.
        """
        self.delete("sessions", {"token_hash": _hash_token(token)})

    def delete_all_for_user(self, user_id: str) -> None:
        """Log out everywhere: drop every session belonging to this user.

        Idempotent: a user with no active sessions is a legitimate no-op,
        same reasoning as delete_session above.
        """
        self.delete("sessions", {"user_id": user_id})
