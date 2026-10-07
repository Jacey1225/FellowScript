"""Email-ownership verification (task 20261007-email-verification).

Single-use, time-limited, hashed tokens emailed to the account's address.
Modeled on ``password_reset.py``: only the sha256 of the token is stored.

State lives on ``users`` (``email_verified`` / ``email_verified_at`` /
``email_verified_hash``). "Verified" is only true while ``email_verified_hash``
equals the hash of the account's CURRENT lowercased email, so an email change
can never inherit a stale verified flag (fail closed). Nothing here blocks
login; callers gate individual email-linked privileges with
``is_email_verified`` (see ``require_verified_email_if_enabled``).

Logging: user ids only, never an email address or a token.
"""
from __future__ import annotations

import hashlib
import logging
import secrets

from db import DBManager
from backend.auth.email_verification_config import get_email_verification_config
from backend.email.ses_client import EmailSendError, send_email
from backend.email.templates import email_verification_email
from backend.errors import SaveFailedError

logger = logging.getLogger(__name__)


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def email_hash(email: str) -> str:
    return _sha256((email or "").strip().lower())


def is_enabled() -> bool:
    return get_email_verification_config().enabled


def user_email_verified(cur, user_id: str) -> bool:
    """True only if ``user_id``'s CURRENT email is the exact one that was verified.

    Cursor-level so other managers can gate inside their own transaction.
    Missing user, blank email, unset flag or hash mismatch all read as False.
    """
    cur.execute(
        "SELECT email, email_verified, email_verified_hash FROM users WHERE _id = %s", (user_id,))
    row = cur.fetchone()
    if not row:
        return False
    email, verified, verified_hash = row
    if not verified or not verified_hash or not (email or "").strip():
        return False
    return secrets.compare_digest(verified_hash, email_hash(email))


class EmailVerificationManager(DBManager):
    def is_verified(self, user_id: str) -> bool:
        """True only if the user's current email is the exact one verified."""
        return user_email_verified(self.cur, user_id)

    def issue(self, user_id: str) -> str | None:
        """Create a token for the user's current email; return the raw token.

        Returns None (nothing created) when the user is missing, has no email,
        is inside the resend cooldown, or is over the daily cap. Older
        unused tokens are invalidated so only the newest link works.
        """
        cfg = get_email_verification_config()
        try:
            self.cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (user_id,))
            self.cur.execute("SELECT email FROM users WHERE _id = %s", (user_id,))
            row = self.cur.fetchone()
            email = (row[0] or "").strip() if row else ""
            if not email:
                self.conn.rollback()
                return None
            self.cur.execute(
                "SELECT COUNT(*) FILTER (WHERE created_at > NOW() - interval '1 day'), "
                "COALESCE(EXTRACT(EPOCH FROM NOW() - MAX(created_at)), 1e9) "
                "FROM email_verification_tokens WHERE user_id = %s", (user_id,))
            sent_today, since_last = self.cur.fetchone()
            if sent_today >= cfg.max_sends_per_day or float(since_last) < cfg.resend_cooldown_seconds:
                self.conn.rollback()
                return None
            token = secrets.token_urlsafe(32)
            self.cur.execute(
                "UPDATE email_verification_tokens SET used = TRUE WHERE user_id = %s AND NOT used", (user_id,))
            self.cur.execute(
                "INSERT INTO email_verification_tokens (user_id, token_hash, email_hash, expires_at) "
                "VALUES (%s, %s, %s, NOW() + make_interval(mins => %s))",
                (user_id, _sha256(token), email_hash(email), cfg.token_ttl_minutes))
            self.conn.commit()
            return token
        except Exception:
            self.conn.rollback()
            raise SaveFailedError()

    def verify(self, token: str) -> bool:
        """Consume ``token`` and mark the email verified. Uniform False on any failure.

        The single UPDATE ... RETURNING makes the token single-use atomically:
        concurrent submissions of one token cannot both win.
        """
        try:
            self.cur.execute(
                "UPDATE email_verification_tokens SET used = TRUE "
                "WHERE token_hash = %s AND NOT used AND expires_at > NOW() "
                "RETURNING user_id, email_hash", (_sha256(token),))
            row = self.cur.fetchone()
            if not row:
                self.conn.rollback()
                return False
            user_id, issued_for = row
            self.cur.execute("SELECT email FROM users WHERE _id = %s", (user_id,))
            u = self.cur.fetchone()
            # The address changed since the mail went out: the token is spent, not honored.
            if not u or email_hash(u[0] or "") != issued_for:
                self.conn.commit()
                return False
            self.cur.execute(
                "UPDATE users SET email_verified = TRUE, email_verified_at = NOW(), "
                "email_verified_hash = %s WHERE _id = %s", (issued_for, user_id))
            self.conn.commit()
            return True
        except Exception:
            self.conn.rollback()
            logger.error("email verification: verify failed (db error)")
            return False

    def mark_verified(self, user_id: str, email: str) -> None:
        """Record verified for ``email`` on the strength of a provider assertion."""
        self.cur.execute(
            "UPDATE users SET email_verified = TRUE, email_verified_at = NOW(), "
            "email_verified_hash = %s WHERE _id = %s AND LOWER(email) = LOWER(%s)",
            (email_hash(email), user_id, email))
        self.conn.commit()

    def reset(self, user_id: str) -> None:
        """Clear verified state and spend outstanding tokens (email changed). Raises on failure."""
        try:
            self.cur.execute(
                "UPDATE users SET email_verified = FALSE, email_verified_at = NULL, "
                "email_verified_hash = NULL WHERE _id = %s", (user_id,))
            self.cur.execute(
                "UPDATE email_verification_tokens SET used = TRUE WHERE user_id = %s AND NOT used", (user_id,))
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise SaveFailedError()


def send_verification_email(user_id: str, email: str) -> bool:
    """Issue a token and mail it. Never raises; True only if a mail was sent.

    No-op (False) when the feature is off. Failures are logged by user id only.
    """
    cfg = get_email_verification_config()
    if not cfg.enabled or not (email or "").strip():
        return False
    mgr = EmailVerificationManager()
    try:
        token = mgr.issue(user_id)
    except SaveFailedError:
        logger.error("email verification: could not persist token for user %s", user_id)
        return False
    finally:
        mgr.close()
    if not token:
        return False
    subject, html_body, text_body = email_verification_email(cfg.verify_link(token), cfg.token_ttl_minutes)
    try:
        send_email(email, subject, html_body, text_body)
    except EmailSendError:
        logger.error("email verification: send failed for user %s", user_id)
        return False
    return True


def record_provider_verified(user_id: str, email: str) -> None:
    """Best-effort: a sign-in provider asserted ``email`` is verified. Never raises."""
    mgr = None
    try:
        mgr = EmailVerificationManager()
        mgr.mark_verified(user_id, email)
    except Exception:
        logger.error("email verification: provider mark failed for user %s", user_id)
    finally:
        if mgr is not None:
            try:
                mgr.close()
            except Exception:
                pass


def is_email_verified(user_id: str) -> bool:
    mgr = EmailVerificationManager()
    try:
        return mgr.is_verified(user_id)
    finally:
        mgr.close()


def verification_satisfied(user_id: str) -> bool:
    """Gate helper for email-linked privileges.

    True when the feature is off (behavior unchanged) or the user's current
    email is verified. Any lookup error propagates (callers fail closed).
    """
    if not is_enabled():
        return True
    return is_email_verified(user_id)
