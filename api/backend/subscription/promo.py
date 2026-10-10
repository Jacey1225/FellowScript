"""Creator codes + friend invite codes: 50% off a new individual subscriber's
first month (task 20260930-creator-friend-codes, phase 1: web/Stripe).

Design (see docs/architecture/backend.md "Promo codes"):

* The DB is authoritative. One shared Stripe coupon (percent_off, duration=once)
  is applied server-side at Checkout Session creation; creator/referrer ids
  ride along in session metadata. There are no per-code Stripe promotion codes.
* Everything fails closed: any ambiguity or error while evaluating a code
  denies the discount and never grants it.
* A redemption is logged only from the signature-verified
  ``checkout.session.completed`` webhook, idempotently (unique key = Checkout
  Session id) and with an atomic max-redemptions cap.

Config (all env, no implicit defaults, validated eagerly by
``validate_promo_config()`` from main.py's lifespan):
    PROMO_CODES_ENABLED        'true' | 'false'  (feature flag; deploy OFF)
    PROMO_DISCOUNT_PERCENT     integer 1-100     (first-month discount)
    PROMO_VALIDATE_RATE_LIMIT  slowapi/limits string, e.g. '10/minute'
"""
import logging
import os
import re
import secrets
from dataclasses import dataclass
from datetime import datetime, timezone

from db import DBManager

logger = logging.getLogger(__name__)

# Code charset for creator codes (admin-chosen) and generated friend codes.
_CODE_RE = re.compile(r"^[A-Z0-9][A-Z0-9_-]{2,31}$")
_FRIEND_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no 0/O/1/I
_FRIEND_CODE_LEN = 10


class PromoConfigError(RuntimeError):
    """PROMO_* config is missing or invalid."""


@dataclass(frozen=True)
class PromoConfig:
    enabled: bool
    discount_percent: int
    validate_rate_limit: str


_config: PromoConfig | None = None


def validate_promo_config() -> None:
    """Eagerly validate PROMO_* env vars. Call once at startup (main.py lifespan).

    Raises:
        PromoConfigError: with a specific message if any value is unset/invalid.
    """
    global _config
    raw_enabled = os.getenv("PROMO_CODES_ENABLED")
    if raw_enabled is None or raw_enabled.strip().lower() not in ("true", "false"):
        raise PromoConfigError(
            "PROMO_CODES_ENABLED must be set explicitly to 'true' or 'false' "
            "(no implicit default; deploy with 'false')."
        )
    raw_pct = os.getenv("PROMO_DISCOUNT_PERCENT")
    if raw_pct is None or not raw_pct.strip():
        raise PromoConfigError("PROMO_DISCOUNT_PERCENT is not set (integer 1-100, e.g. 50).")
    try:
        pct = int(raw_pct)
    except ValueError:
        raise PromoConfigError(f"PROMO_DISCOUNT_PERCENT ({raw_pct!r}) is not a valid integer.")
    if not (1 <= pct <= 100):
        raise PromoConfigError(f"PROMO_DISCOUNT_PERCENT ({pct}) must be between 1 and 100.")
    raw_rl = os.getenv("PROMO_VALIDATE_RATE_LIMIT")
    if raw_rl is None or not raw_rl.strip():
        raise PromoConfigError("PROMO_VALIDATE_RATE_LIMIT is not set (e.g. '10/minute').")
    try:
        from limits import parse
        parse(raw_rl.strip())
    except Exception:
        raise PromoConfigError(f"PROMO_VALIDATE_RATE_LIMIT ({raw_rl!r}) is not a valid rate-limit string.")
    _config = PromoConfig(raw_enabled.strip().lower() == "true", pct, raw_rl.strip())


def promo_config() -> PromoConfig:
    """Validated config. Raises if validate_promo_config() has not run."""
    if _config is None:
        raise PromoConfigError("Promo config has not been validated; call validate_promo_config() at startup.")
    return _config


def promo_enabled() -> bool:
    """Feature flag. Fails closed (False) if config was never validated."""
    return _config is not None and _config.enabled


def normalize_code(raw) -> str | None:
    """Trim + uppercase; None if not a well-formed code (treated as invalid)."""
    if not isinstance(raw, str):
        return None
    code = raw.strip().upper()
    return code if _CODE_RE.match(code) else None


def generate_friend_code() -> str:
    return "".join(secrets.choice(_FRIEND_ALPHABET) for _ in range(_FRIEND_CODE_LEN))


def generate_creator_code() -> str:
    """Unguessable admin-side creator code: ``FS-`` + 12 chars (~60 bits), from
    the CSPRNG; matches ``_CODE_RE``."""
    return "FS-" + "".join(secrets.choice(_FRIEND_ALPHABET) for _ in range(12))


_OWNER_EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,255}$")


def normalize_owner_email(raw) -> str | None:
    """Trim + lowercase; None if not email-shaped."""
    if not isinstance(raw, str):
        return None
    e = raw.strip().lower()
    return e if _OWNER_EMAIL_RE.match(e) and len(e) <= 255 else None


def _iso(v):
    return v.isoformat() if isinstance(v, datetime) else v


class PromoError(Exception):
    """Admin-surface validation error mapped to HTTP 4xx by the route."""
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


class PromoManager(DBManager):
    """DB access for creators, promo codes, redemptions and eligibility."""

    # ── Eligibility ───────────────────────────────────────────────────────────

    def has_local_paid_history(self, user_id: str) -> bool:
        """True if the user ever held (or currently sits on) a paid plan, per
        local records. Admin comps and the free plan do not count."""
        self.cur.execute(
            "SELECT "
            " EXISTS(SELECT 1 FROM subscriber_history WHERE user_id = %s) "
            " OR EXISTS(SELECT 1 FROM subscriptions WHERE user_id = %s AND plan_type != 'free' "
            "           AND provider IN ('stripe','apple')) "
            " OR EXISTS(SELECT 1 FROM users u JOIN subscriptions s ON s._id = u.subscription_id "
            "           WHERE u._id = %s AND s.plan_type != 'free' AND s.provider != 'admin_comp') "
            " OR EXISTS(SELECT 1 FROM promo_redemptions WHERE user_id = %s)",
            (user_id, user_id, user_id, user_id),
        )
        return bool(self.cur.fetchone()[0])

    def is_new_subscriber(self, user_id: str, email: str) -> bool:
        """Full check used at validate/checkout time: local history plus a
        Stripe lookup by email. Fails closed on any error or missing email."""
        from backend.subscription import stripe_service
        try:
            if self.has_local_paid_history(user_id):
                return False
            if not email:
                return False
            if stripe_service.is_configured() and stripe_service.customer_has_subscription_history(email):
                return False
            return True
        except Exception as e:
            self.conn.rollback()
            logger.error("promo eligibility check failed (denying): %s", e)
            return False

    def evaluate(self, user_id: str, raw_code, member_count: int, email: str) -> dict | None:
        """Return the usable code row for this buyer, or None (uniformly) for
        every failure: malformed/unknown/inactive/expired/exhausted code,
        inactive creator, own friend code, group plan, trial configured, or
        an ineligible buyer. User eligibility is evaluated first so response
        time does not reveal whether a code exists."""
        from backend.subscription.stripe_service import trial_months
        try:
            buyer_ok = self.is_new_subscriber(user_id, email)
            code = normalize_code(raw_code)
            row = self.find_code(code) if code else None
            if not (buyer_ok and row and member_count == 1 and trial_months() == 0):
                return None
            if not row["active"]:
                return None
            if row["requires_owner_email"] and not row["owner_email"]:
                return None  # fail closed: awaiting-email code is never redeemable
            if row["expires_at"] and row["expires_at"] <= datetime.now(timezone.utc):
                return None
            if row["max_redemptions"] is not None and row["redemption_count"] >= row["max_redemptions"]:
                return None
            if row["kind"] == "creator" and not row["creator_active"]:
                return None
            if row["kind"] == "friend" and str(row["referrer_user_id"]) == str(user_id):
                return None
            return row
        except Exception as e:
            self.conn.rollback()
            logger.error("promo evaluate failed (denying): %s", e)
            return None

    def find_code(self, code: str, include_deleted: bool = False) -> dict | None:
        """Code row by text. Soft-deleted codes are invisible unless asked for."""
        self.cur.execute(
            "SELECT p._id, p.code, p.kind, p.creator_id, p.referrer_user_id, p.active, "
            "       p.max_redemptions, p.redemption_count, p.expires_at, COALESCE(c.active, TRUE), "
            "       p.requires_owner_email, p.owner_email "
            "FROM promo_codes p LEFT JOIN creators c ON c._id = p.creator_id WHERE p.code = %s"
            + ("" if include_deleted else " AND p.deleted_at IS NULL"),
            (code,),
        )
        r = self.cur.fetchone()
        if not r:
            return None
        return {
            "id": str(r[0]), "code": r[1], "kind": r[2],
            "creator_id": str(r[3]) if r[3] else None,
            "referrer_user_id": str(r[4]) if r[4] else None,
            "active": r[5], "max_redemptions": r[6], "redemption_count": r[7],
            "expires_at": r[8], "creator_active": r[9],
            "requires_owner_email": bool(r[10]), "owner_email": r[11],
        }

    def get_code_by_id(self, code_id: str) -> dict | None:
        """Includes soft-deleted codes: a checkout that started before the delete
        must still log its redemption and credit the owner reward."""
        self.cur.execute("SELECT code FROM promo_codes WHERE _id = %s", (code_id,))
        r = self.cur.fetchone()
        return self.find_code(r[0], include_deleted=True) if r else None

    # ── Friend invite codes ───────────────────────────────────────────────────

    def get_or_create_friend_code(self, user_id: str) -> str:
        """Idempotent per user (partial unique index makes concurrent calls safe)."""
        for _ in range(8):
            self.cur.execute(
                "SELECT code FROM promo_codes WHERE kind = 'friend' AND referrer_user_id = %s", (user_id,)
            )
            row = self.cur.fetchone()
            if row:
                return row[0]
            self.cur.execute(
                "INSERT INTO promo_codes (code, kind, referrer_user_id, owner_email) "
                "VALUES (%s, 'friend', %s, (SELECT LOWER(email) FROM users WHERE _id = %s)) "
                "ON CONFLICT DO NOTHING",
                (generate_friend_code(), user_id, user_id),
            )
            self.conn.commit()
        raise RuntimeError("could not allocate friend code")

    # ── Redemption logging (webhook) ──────────────────────────────────────────

    def redemption_exists(self, idempotency_key: str) -> bool:
        self.cur.execute("SELECT 1 FROM promo_redemptions WHERE idempotency_key = %s", (idempotency_key,))
        return self.cur.fetchone() is not None

    def get_redemption(self, idempotency_key: str) -> dict | None:
        """The logged redemption for an idempotency key (code id, buyer, whether it
        was logged past the code's cap), or None."""
        self.cur.execute(
            "SELECT code_id, user_id, over_cap FROM promo_redemptions WHERE idempotency_key = %s",
            (idempotency_key,))
        r = self.cur.fetchone()
        return {"code_id": str(r[0]) if r[0] else None, "user_id": str(r[1]), "over_cap": bool(r[2])} if r else None

    def log_redemption(self, *, code_id: str, user_id: str, plan: str, platform: str,
                       store_transaction_id: str, idempotency_key: str,
                       amount_discount_cents: int | None) -> str:
        """Atomically record one completed redemption.

        Returns ``'logged'``, ``'over_cap'`` (row written for admin review but
        not counted against max_redemptions) or ``'duplicate'`` (replayed
        webhook; nothing changed). The code row is locked ``FOR UPDATE`` so the
        cap check/increment is race-safe; the UNIQUE idempotency key makes a
        replay impossible to double-count (the increment is rolled back).
        """
        try:
            self.cur.execute(
                "SELECT code, kind, creator_id, referrer_user_id FROM promo_codes WHERE _id = %s FOR UPDATE",
                (code_id,),
            )
            c = self.cur.fetchone()
            if not c:
                raise PromoError(404, "promo code missing at redemption time")
            self.cur.execute(
                "UPDATE promo_codes SET redemption_count = redemption_count + 1 "
                "WHERE _id = %s AND (max_redemptions IS NULL OR redemption_count < max_redemptions)",
                (code_id,),
            )
            over_cap = self.cur.rowcount == 0
            self.cur.execute(
                "INSERT INTO promo_redemptions (user_id, code_id, code, kind, creator_id, referrer_user_id, "
                " plan, platform, store_transaction_id, idempotency_key, amount_discount_cents, over_cap) "
                "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) "
                "ON CONFLICT (idempotency_key) DO NOTHING RETURNING _id",
                (user_id, code_id, c[0], c[1], c[2], c[3], plan, platform,
                 store_transaction_id, idempotency_key, amount_discount_cents, over_cap),
            )
            if self.cur.fetchone() is None:
                self.conn.rollback()
                return "duplicate"
            self.conn.commit()
            return "over_cap" if over_cap else "logged"
        except Exception:
            self.conn.rollback()
            raise

    # ── Admin: creators ───────────────────────────────────────────────────────

    @staticmethod
    def _creator_dict(r) -> dict:
        return {"id": str(r[0]), "name": r[1], "notes": r[2], "active": r[3],
                "created_at": _iso(r[4]), "updated_at": _iso(r[5])}

    def create_creator(self, name: str, notes: str) -> dict:
        self.cur.execute(
            "INSERT INTO creators (name, notes) VALUES (%s, %s) "
            "RETURNING _id, name, notes, active, created_at, updated_at", (name, notes))
        r = self.cur.fetchone()
        self.conn.commit()
        return self._creator_dict(r)

    def update_creator(self, creator_id: str, fields: dict) -> dict | None:
        allowed = {k: v for k, v in fields.items() if k in ("name", "notes", "active")}
        if not allowed:
            raise PromoError(422, "nothing to update")
        sets = ", ".join(f"{k} = %s" for k in allowed)
        self.cur.execute(
            f"UPDATE creators SET {sets}, updated_at = NOW() WHERE _id = %s "
            "RETURNING _id, name, notes, active, created_at, updated_at",
            [*allowed.values(), creator_id])
        r = self.cur.fetchone()
        self.conn.commit()
        return self._creator_dict(r) if r else None

    def list_creators(self) -> list[dict]:
        self.cur.execute("SELECT _id, name, notes, active, created_at, updated_at FROM creators ORDER BY created_at")
        return [self._creator_dict(r) for r in self.cur.fetchall()]

    # ── Admin: codes ──────────────────────────────────────────────────────────

    @staticmethod
    def _code_dict(r) -> dict:
        return {"id": str(r[0]), "code": r[1], "kind": r[2],
                "creator_id": str(r[3]) if r[3] else None,
                "referrer_user_id": str(r[4]) if r[4] else None,
                "active": r[5], "max_redemptions": r[6], "redemption_count": r[7],
                "expires_at": _iso(r[8]), "created_at": _iso(r[9]), "owner_email": r[10],
                "awaiting_email": bool(r[11]) and not r[10]}

    _CODE_COLS = ("_id, code, kind, creator_id, referrer_user_id, active, max_redemptions, "
                  "redemption_count, expires_at, created_at, owner_email, requires_owner_email")

    def create_creator_code(self, code: str, creator_id: str, max_redemptions: int | None,
                            expires_at, owner_email: str | None = None) -> dict:
        norm = normalize_code(code)
        email = None
        if owner_email is not None:
            email = normalize_owner_email(owner_email)
            if not email:
                raise PromoError(422, "owner_email is not a valid email address")
        if not norm:
            raise PromoError(422, "code must be 3-32 chars: letters, digits, '-' or '_'")
        self.cur.execute("SELECT 1 FROM creators WHERE _id = %s", (creator_id,))
        if not self.cur.fetchone():
            raise PromoError(404, "creator not found")
        self.cur.execute(
            f"INSERT INTO promo_codes (code, kind, creator_id, max_redemptions, expires_at, owner_email) "
            f"VALUES (%s, 'creator', %s, %s, %s, %s) ON CONFLICT (code) DO NOTHING RETURNING {self._CODE_COLS}",
            (norm, creator_id, max_redemptions, expires_at, email))
        r = self.cur.fetchone()
        self.conn.commit()
        if not r:
            raise PromoError(409, "code already exists")
        return self._code_dict(r)

    def update_code(self, code_id: str, fields: dict, actor_id: str | None = None) -> dict | None:
        """Update a code. Creator codes that need an owner email (created blank,
        or whose email was removed) can never be active without one: activating
        is rejected (409) and removing the email forces active=false. Setting an
        email never activates (manual activation). The email is never logged."""
        allowed = {k: v for k, v in fields.items() if k in ("active", "max_redemptions", "expires_at", "owner_email")}
        if not allowed:
            raise PromoError(422, "nothing to update")
        if "owner_email" in allowed and allowed["owner_email"] is not None:
            raw = allowed["owner_email"]
            if isinstance(raw, str) and not raw.strip():
                allowed["owner_email"] = None   # blank == remove
            else:
                allowed["owner_email"] = normalize_owner_email(raw)
                if not allowed["owner_email"]:
                    raise PromoError(422, "owner_email is not a valid email address")
        try:
            self.cur.execute(
                "SELECT kind, owner_email, requires_owner_email, active FROM promo_codes "
                "WHERE _id = %s AND deleted_at IS NULL FOR UPDATE", (code_id,))
            cur_row = self.cur.fetchone()
            if not cur_row:
                self.conn.rollback()
                return None
            kind, cur_email, requires, _cur_active = cur_row
            audit_action = None
            if kind == "creator":
                new_email = allowed["owner_email"] if "owner_email" in allowed else cur_email
                if "owner_email" in allowed and new_email is None and cur_email is not None:
                    requires = True
                    allowed["requires_owner_email"] = True
                    allowed["active"] = False        # removing the email deactivates
                    audit_action = "promo_code_email_removed"
                elif requires and not new_email:
                    if allowed.get("active") is True:
                        self.conn.rollback()
                        raise PromoError(409, "owner email required before this code can be activated")
                    allowed["active"] = False
                if "owner_email" in allowed and new_email and new_email != cur_email:
                    audit_action = "promo_code_email_set"
            sets = ", ".join(f"{k} = %s" for k in allowed)
            self.cur.execute(
                f"UPDATE promo_codes SET {sets} WHERE _id = %s AND deleted_at IS NULL RETURNING {self._CODE_COLS}",
                [*allowed.values(), code_id])
            r = self.cur.fetchone()
            if r and audit_action:
                self.cur.execute(
                    "INSERT INTO promo_audit_log (action, actor_user_id, code_id, detail) VALUES (%s,%s,%s,%s)",
                    (audit_action, actor_id, code_id, ""))
            self.conn.commit()
            return self._code_dict(r) if r else None
        except PromoError:
            raise
        except Exception:
            self.conn.rollback()
            raise

    def delete_code(self, code_id: str) -> bool:
        """Soft-delete a creator code (idempotent). Returns False if the code is
        unknown. Friend codes are rejected (422) so get_or_create_friend_code can
        never silently regenerate one. History rows are untouched."""
        self.cur.execute("SELECT kind, deleted_at FROM promo_codes WHERE _id = %s FOR UPDATE", (code_id,))
        r = self.cur.fetchone()
        if not r:
            self.conn.rollback()
            return False
        if r[0] != "creator":
            self.conn.rollback()
            raise PromoError(422, "only creator codes can be deleted")
        if r[1] is None:
            self.cur.execute(
                "UPDATE promo_codes SET deleted_at = NOW(), active = FALSE WHERE _id = %s", (code_id,))
        self.conn.commit()
        return True

    def list_codes(self, kind: str | None = None, creator_id: str | None = None,
                   limit: int = 100, offset: int = 0) -> list[dict]:
        where, params = ["deleted_at IS NULL"], []
        if kind:
            where.append("kind = %s"); params.append(kind)
        if creator_id:
            where.append("creator_id = %s"); params.append(creator_id)
        w = "WHERE " + " AND ".join(where)
        self.cur.execute(
            f"SELECT {self._CODE_COLS} FROM promo_codes {w} ORDER BY created_at DESC LIMIT %s OFFSET %s",
            [*params, limit, offset])
        return [self._code_dict(r) for r in self.cur.fetchall()]

    def create_creator_with_code(self, name: str, notes: str, owner_email: str | None, code: str | None,
                                 max_redemptions: int | None, expires_at,
                                 actor_id: str | None = None) -> dict:
        """Admin one-shot: create a creator and a creator code attached to
        ``owner_email`` in ONE transaction. With no ``code`` a secure random one
        is generated (retried on the astronomically unlikely collision)."""
        email = None
        if owner_email is not None and owner_email.strip():
            email = normalize_owner_email(owner_email)
            if not email:
                raise PromoError(422, "owner_email is not a valid email address")
        awaiting = email is None   # no email -> created deactivated, flagged awaiting
        norm = None
        if code is not None and code.strip():
            norm = normalize_code(code)
            if not norm:
                raise PromoError(422, "code must be 3-32 chars: letters, digits, '-' or '_'")
        try:
            self.cur.execute(
                "INSERT INTO creators (name, notes) VALUES (%s, %s) "
                "RETURNING _id, name, notes, active, created_at, updated_at", (name, notes))
            creator = self._creator_dict(self.cur.fetchone())
            row = None
            for _ in range(5 if norm is None else 1):
                candidate = norm or generate_creator_code()
                self.cur.execute(
                    f"INSERT INTO promo_codes (code, kind, creator_id, max_redemptions, expires_at, owner_email, active, requires_owner_email) "
                    f"VALUES (%s, 'creator', %s, %s, %s, %s, %s, %s) ON CONFLICT (code) DO NOTHING "
                    f"RETURNING {self._CODE_COLS}",
                    (candidate, creator["id"], max_redemptions, expires_at, email,
                     not awaiting, awaiting))
                row = self.cur.fetchone()
                if row:
                    break
            if not row:
                self.conn.rollback()
                raise PromoError(409, "code already exists")
            out = self._code_dict(row)
            self.cur.execute(
                "INSERT INTO promo_audit_log (action, actor_user_id, code_id, detail) VALUES (%s,%s,%s,%s)",
                ("promo_creator_code_create", actor_id, out["id"], ""))
            self.conn.commit()
            return {"creator": creator, "code": out}
        except PromoError:
            raise
        except Exception:
            self.conn.rollback()
            raise

    def audit(self, action: str, actor_user_id: str | None, code_id: str | None = None, detail: str = "") -> None:
        """Durable admin audit row (ids/reason only)."""
        self.cur.execute(
            "INSERT INTO promo_audit_log (action, actor_user_id, code_id, detail) VALUES (%s,%s,%s,%s)",
            (action, actor_user_id, code_id, detail[:200]))
        self.conn.commit()

    def list_codes_overview(self, kind: str | None = None, limit: int = 100, offset: int = 0) -> list[dict]:
        """Codes with creator name, attached email, redemption count and reward
        counts, for the admin page."""
        where, params = "WHERE p.deleted_at IS NULL", []
        if kind:
            where, params = "WHERE p.deleted_at IS NULL AND p.kind = %s", [kind]
        self.cur.execute(
            "SELECT p._id, p.code, p.kind, p.active, p.owner_email, c.name, p.redemption_count, "
            " p.max_redemptions, p.expires_at, p.created_at, "
            " COALESCE(rw.earned, 0), COALESCE(rw.claimed, 0), p.requires_owner_email, "
            " p.creator_id, c.notes "
            "FROM promo_codes p LEFT JOIN creators c ON c._id = p.creator_id "
            "LEFT JOIN (SELECT code_id, COUNT(*) AS earned, COUNT(*) FILTER (WHERE status='claimed') AS claimed "
            "           FROM owner_rewards WHERE code_id IS NOT NULL GROUP BY code_id) rw ON rw.code_id = p._id "
            f"{where} ORDER BY p.created_at DESC LIMIT %s OFFSET %s", [*params, limit, offset])
        return [{"id": str(r[0]), "code": r[1], "kind": r[2], "active": r[3], "owner_email": r[4],
                 "creator_name": r[5], "redemption_count": r[6], "max_redemptions": r[7],
                 "expires_at": _iso(r[8]), "created_at": _iso(r[9]),
                 "rewards_earned": r[10], "rewards_claimed": r[11],
                 "awaiting_email": bool(r[12]) and not r[4],
                 "creator_id": str(r[13]) if r[13] else None,
                 "creator_notes": r[14]} for r in self.cur.fetchall()]

    # ── Admin: reporting ──────────────────────────────────────────────────────

    def report_by_creator(self) -> list[dict]:
        """Counted (non-over-cap) and over-cap redemptions per creator."""
        self.cur.execute(
            "SELECT c._id, c.name, c.active, "
            " COUNT(r._id) FILTER (WHERE NOT r.over_cap), COUNT(r._id) FILTER (WHERE r.over_cap) "
            "FROM creators c LEFT JOIN promo_redemptions r ON r.creator_id = c._id "
            "GROUP BY c._id, c.name, c.active ORDER BY 4 DESC, c.name")
        return [{"creator_id": str(r[0]), "name": r[1], "active": r[2],
                 "redemptions": r[3], "over_cap_redemptions": r[4]} for r in self.cur.fetchall()]

    def list_redemptions(self, creator_id: str | None = None, kind: str | None = None,
                         limit: int = 100, offset: int = 0) -> list[dict]:
        where, params = [], []
        if creator_id:
            where.append("creator_id = %s"); params.append(creator_id)
        if kind:
            where.append("kind = %s"); params.append(kind)
        w = ("WHERE " + " AND ".join(where)) if where else ""
        self.cur.execute(
            "SELECT _id, user_id, code, kind, creator_id, referrer_user_id, plan, platform, "
            "store_transaction_id, amount_discount_cents, over_cap, created_at "
            f"FROM promo_redemptions {w} ORDER BY created_at DESC LIMIT %s OFFSET %s",
            [*params, limit, offset])
        return [{"id": str(r[0]), "user_id": str(r[1]) if r[1] else None, "code": r[2], "kind": r[3],
                 "creator_id": str(r[4]) if r[4] else None,
                 "referrer_user_id": str(r[5]) if r[5] else None, "plan": r[6], "platform": r[7],
                 "store_transaction_id": r[8], "amount_discount_cents": r[9], "over_cap": r[10],
                 "created_at": _iso(r[11])} for r in self.cur.fetchall()]
