"""Owner rewards: 50% off the code owner's NEXT month (task 20260929...
20261001-promo-owner-rewards), layered on the promo-code system in ``promo.py``.

Design (see docs/architecture/backend.md "Owner rewards"):

* ``owner_rewards`` is the ledger and the source of truth. A reward moves
  ``earned -> claimed | expired``. Every earn carries a UNIQUE idempotency key
  (``signup:<invitee id>`` / ``purchase:<redemption key>``); partial unique
  indexes also allow only one signup reward per invitee account and per
  invitee email. Cap checks and the insert run under per-owner / per-IP
  Postgres advisory locks so concurrent signups cannot slip past a cap.
* Earn triggers: (a) a new account created with a friend invite code,
  (b) a completed (logged, within-cap) purchase with a creator code, rewarding
  the user whose email is attached to the code. The owner must hold an
  individual, active, paid Stripe/Apple subscription at earn time, otherwise the
  reward is dropped (audited), never held.
* Redemption. Stripe owners: the shared once-off coupon is attached to their
  Stripe subscription server-side (next invoice) and the ledger row is marked
  ``claimed`` in the same DB transaction (row locked ``FOR UPDATE SKIP
  LOCKED``). Apple owners: the app calls the claim endpoint, which reserves the
  oldest reward (nonce + TTL) and returns an ES256 promotional-offer signature;
  the reward only becomes ``claimed`` when the verified Apple transaction
  carrying the offer arrives via /apple/sync or an App Store notification AND
  its ``appAccountToken`` equals the reward's current ledger nonce. A new
  signature is never issued while an earlier one may still be redeemable at
  Apple (see ``claim_apple``), so one reward yields at most one discounted month.
* Stacking: rewards queue FIFO and apply one at a time (one per billing month).
* Everything fails closed: any error or ambiguity denies/defers, never grants.

Config (env, no implicit defaults, validated eagerly by
``validate_owner_rewards_config()`` from main.py's lifespan; the flag deploys OFF):
    OWNER_REWARDS_ENABLED               'true' | 'false'
    OWNER_REWARD_PERCENT                1-100
    OWNER_REWARD_EXPIRY_DAYS            positive int (earned -> expired)
    OWNER_REWARD_CAP_COUNT              max rewards earned per owner per window
    OWNER_REWARD_CAP_WINDOW_DAYS        rolling window for the caps below
    OWNER_REWARD_MAX_OUTSTANDING        max earned-unclaimed-unexpired per owner
    OWNER_REWARD_IP_CAP_COUNT           max signup rewards credited per client IP per window
    OWNER_REWARD_CLAIM_RATE_LIMIT       slowapi string, e.g. '5/minute'
    OWNER_REWARD_APPLE_RESERVATION_MINUTES  how long an Apple signature reserves a reward
    OWNER_REWARD_HASH_SALT              >=16 chars; HMAC key for email/IP hashes
    APPLE_PROMO_KEY_ID                  App Store Connect subscription key id
    APPLE_PROMO_KEY_PATH                path to the .p8 (loaded only when enabled; never logged)
    APPLE_PROMO_OFFERS                  JSON {productId: offerIdentifier} for ALL 8 products
                                        (post price-cut codes are versioned: invite_reward_50_v2[_N];
                                        any [A-Za-z0-9_]{1,64} id is accepted)
    APPLE_BUNDLE_ID                     (existing) bundle id used in the signed string
"""
import hashlib
import hmac
import json
import logging
import os
import re
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone

from backend.auth.email_verification import is_enabled as email_verification_enabled, user_email_verified
from backend.subscription import apple_service
from backend.subscription.promo import PromoError, PromoManager, normalize_code, promo_enabled

logger = logging.getLogger(__name__)

_APPLE_USERNAME_NS = uuid.UUID("5d0f6b3e-6f0e-4d2b-9a55-3c7f0b6a9e11")
_KEY_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
_OFFER_ID_RE = re.compile(r"^[A-Za-z0-9_]{1,64}$")
_EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,255}$")

# Apple accepts a promotional-offer signature only while its embedded timestamp is
# recent (documented window: 24h). We treat a signature as possibly redeemable
# for the full window PLUS a clock-skew margin, and never issue a second one for
# the same owner until the first is provably dead. Protocol constants, not config.
APPLE_SIGNATURE_VALID_HOURS = 24
APPLE_SIGNATURE_SKEW_MARGIN_HOURS = 1
_APPLE_SIGNATURE_DEAD_AFTER_HOURS = APPLE_SIGNATURE_VALID_HOURS + APPLE_SIGNATURE_SKEW_MARGIN_HOURS
# SQL: the instant after which an issued signature can no longer be redeemed.
# (COALESCE covers a row signed before apple_signature_expires_at existed.)
_SIG_DEAD_AT_SQL = ("COALESCE(apple_signature_expires_at, "
                    "apple_reserved_until + make_interval(hours => %d))" % _APPLE_SIGNATURE_DEAD_AFTER_HOURS)
_SIG_LIVE_SQL = f"(apple_nonce IS NOT NULL AND {_SIG_DEAD_AT_SQL} > NOW())"


class OwnerRewardsConfigError(RuntimeError):
    """OWNER_REWARD* / APPLE_PROMO_* config is missing or invalid."""


@dataclass(frozen=True)
class OwnerRewardsConfig:
    enabled: bool
    percent: int
    expiry_days: int
    cap_count: int
    cap_window_days: int
    max_outstanding: int
    ip_cap_count: int
    claim_rate_limit: str
    reservation_minutes: int
    hash_salt: str
    apple_key_id: str
    apple_key_path: str
    apple_offers: dict
    bundle_id: str
    private_key: object = field(default=None, repr=False, compare=False)


_config: OwnerRewardsConfig | None = None


def _req(name: str) -> str:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        raise OwnerRewardsConfigError(f"{name} is not set (no implicit default).")
    return raw.strip()


def _req_int(name: str, lo: int, hi: int | None = None) -> int:
    raw = _req(name)
    try:
        v = int(raw)
    except ValueError:
        raise OwnerRewardsConfigError(f"{name} ({raw!r}) is not a valid integer.")
    if v < lo or (hi is not None and v > hi):
        rng = f"between {lo} and {hi}" if hi is not None else f"at least {lo}"
        raise OwnerRewardsConfigError(f"{name} ({v}) must be {rng}.")
    return v


def validate_owner_rewards_config() -> None:
    """Eagerly validate owner-reward config. Call once at startup (lifespan).

    All values are validated even with the flag off. Only when the flag is ON is
    the Apple .p8 file read/parsed (so a flag-off deploy never needs the key on
    disk) and PROMO_CODES_ENABLED required to be on too.

    Raises:
        OwnerRewardsConfigError: with a specific message on any problem. Messages
            never contain key material.
    """
    global _config
    raw_enabled = os.getenv("OWNER_REWARDS_ENABLED")
    if raw_enabled is None or raw_enabled.strip().lower() not in ("true", "false"):
        raise OwnerRewardsConfigError(
            "OWNER_REWARDS_ENABLED must be set explicitly to 'true' or 'false' "
            "(no implicit default; deploy with 'false')."
        )
    enabled = raw_enabled.strip().lower() == "true"
    percent = _req_int("OWNER_REWARD_PERCENT", 1, 100)
    expiry_days = _req_int("OWNER_REWARD_EXPIRY_DAYS", 1)
    cap_count = _req_int("OWNER_REWARD_CAP_COUNT", 1)
    cap_window = _req_int("OWNER_REWARD_CAP_WINDOW_DAYS", 1)
    max_out = _req_int("OWNER_REWARD_MAX_OUTSTANDING", 1)
    ip_cap = _req_int("OWNER_REWARD_IP_CAP_COUNT", 1)
    resv = _req_int("OWNER_REWARD_APPLE_RESERVATION_MINUTES", 1, 1440)
    rl = _req("OWNER_REWARD_CLAIM_RATE_LIMIT")
    try:
        from limits import parse
        parse(rl)
    except Exception:
        raise OwnerRewardsConfigError(f"OWNER_REWARD_CLAIM_RATE_LIMIT ({rl!r}) is not a valid rate-limit string.")
    salt = _req("OWNER_REWARD_HASH_SALT")
    if len(salt) < 16:
        raise OwnerRewardsConfigError("OWNER_REWARD_HASH_SALT must be at least 16 characters.")
    key_id = _req("APPLE_PROMO_KEY_ID")
    if not _KEY_ID_RE.match(key_id):
        raise OwnerRewardsConfigError("APPLE_PROMO_KEY_ID must be a 10-character App Store Connect key id.")
    key_path = _req("APPLE_PROMO_KEY_PATH")
    bundle_id = _req("APPLE_BUNDLE_ID")
    raw_offers = _req("APPLE_PROMO_OFFERS")
    try:
        offers = json.loads(raw_offers)
    except ValueError:
        raise OwnerRewardsConfigError("APPLE_PROMO_OFFERS is not valid JSON.")
    if not isinstance(offers, dict) or set(offers) != set(apple_service.APPLE_PRODUCTS):
        raise OwnerRewardsConfigError(
            "APPLE_PROMO_OFFERS must map exactly the products "
            f"{sorted(apple_service.APPLE_PRODUCTS)} to offer identifiers."
        )
    for pid, oid in offers.items():
        if not isinstance(oid, str) or not _OFFER_ID_RE.match(oid):
            raise OwnerRewardsConfigError(f"APPLE_PROMO_OFFERS[{pid!r}] is not a valid offer identifier.")
    if len(set(offers.values())) != len(offers):
        raise OwnerRewardsConfigError("APPLE_PROMO_OFFERS offer identifiers must be unique per product.")

    private_key = None
    if enabled:
        if not promo_enabled():
            raise OwnerRewardsConfigError("OWNER_REWARDS_ENABLED=true requires PROMO_CODES_ENABLED=true.")
        try:
            from cryptography.hazmat.primitives import serialization
            from cryptography.hazmat.primitives.asymmetric import ec
            with open(key_path, "rb") as fh:
                private_key = serialization.load_pem_private_key(fh.read(), password=None)
            if not isinstance(private_key, ec.EllipticCurvePrivateKey) or private_key.curve.name != "secp256r1":
                raise ValueError("not an EC P-256 key")
        except OwnerRewardsConfigError:
            raise
        except Exception as e:
            # Type/class only: never echo key bytes.
            raise OwnerRewardsConfigError(
                f"APPLE_PROMO_KEY_PATH could not be loaded as an EC P-256 PEM key ({type(e).__name__})."
            )
    _config = OwnerRewardsConfig(
        enabled, percent, expiry_days, cap_count, cap_window, max_out, ip_cap, rl, resv,
        salt, key_id, key_path, dict(offers), bundle_id, private_key,
    )


def rewards_config() -> OwnerRewardsConfig:
    if _config is None:
        raise OwnerRewardsConfigError(
            "Owner-reward config has not been validated; call validate_owner_rewards_config() at startup.")
    return _config


def rewards_enabled() -> bool:
    """Feature flag. Fails closed (False) if config was never validated or the
    promo flag is off."""
    return _config is not None and _config.enabled and promo_enabled()


# ── Pure helpers ──────────────────────────────────────────────────────────────

def normalize_email(email) -> str | None:
    """Canonical form for dedupe: trim+lowercase, drop ``+tag``; for Gmail also
    drop dots and fold googlemail.com. None if not email-shaped."""
    if not isinstance(email, str):
        return None
    e = email.strip().lower()
    if not _EMAIL_RE.match(e):
        return None
    local, domain = e.rsplit("@", 1)
    local = local.split("+", 1)[0]
    if domain in ("gmail.com", "googlemail.com"):
        local, domain = local.replace(".", ""), "gmail.com"
    return f"{local}@{domain}" if local else None


def _hash(value: str) -> str:
    return hmac.new(rewards_config().hash_salt.encode(), value.encode(), hashlib.sha256).hexdigest()


def apple_application_username(user_id: str) -> str:
    """Stable, non-PII per-user token used as the offer's applicationUsername
    (the iOS client must set it as the purchase's appAccountToken)."""
    return str(uuid.uuid5(_APPLE_USERNAME_NS, str(user_id)))


def _norm_token(v) -> str | None:
    """Canonical lowercase UUID string of an appAccountToken, or None if absent or
    not a UUID."""
    if not isinstance(v, str):
        return None
    try:
        return str(uuid.UUID(v.strip()))
    except ValueError:
        return None


def _iso(v):
    return v.isoformat() if isinstance(v, datetime) else v


# ── Ledger ────────────────────────────────────────────────────────────────────

class RewardManager(PromoManager):
    """DB access for the owner-reward ledger. Inherits PromoManager (code lookup,
    audit helper) and its connection."""

    # -- helpers

    def _audit(self, action: str, *, owner=None, reward=None, code=None, actor=None, detail: str = "") -> None:
        """Append to promo_audit_log inside the caller's transaction. Ids and
        reason codes only."""
        self.cur.execute(
            "INSERT INTO promo_audit_log (action, actor_user_id, owner_user_id, reward_id, code_id, detail) "
            "VALUES (%s,%s,%s,%s,%s,%s)", (action, actor, owner, reward, code, detail[:200]))
        logger.info("reward_audit action=%s owner=%s reward=%s code=%s detail=%s",
                    action, owner, reward, code, detail[:200])

    def audit_event(self, action: str, **kw) -> None:
        self._audit(action, **kw)
        self.conn.commit()

    def _expire_due(self, owner_id: str) -> None:
        self.cur.execute(
            "UPDATE owner_rewards SET status='expired' WHERE owner_user_id=%s AND status='earned' "
            "AND expires_at <= NOW() AND NOT " + _SIG_LIVE_SQL, (owner_id,))
        if self.cur.rowcount:
            self._audit("reward_expired", owner=owner_id, detail=f"count={self.cur.rowcount}")

    def owner_subscription(self, owner_id: str) -> dict | None:
        """The owner's individual, active, paid Stripe/Apple plan (they must be
        its host), else None. Free, admin_comp, group and non-active plans never
        qualify."""
        self.cur.execute(
            "SELECT s.provider, s.stripe_subscription_id, s.apple_original_transaction_id "
            "FROM users u JOIN subscriptions s ON s._id = u.subscription_id "
            "WHERE u._id = %s AND s.user_id = u._id AND s.provider IN ('stripe','apple') "
            "AND s.plan_type != 'free' AND s.max_members = 1 AND s.status = 'active'", (owner_id,))
        r = self.cur.fetchone()
        return {"provider": r[0], "stripe_subscription_id": r[1] or "",
                "apple_original_transaction_id": r[2] or ""} if r else None

    def _user_email(self, user_id: str) -> str:
        self.cur.execute("SELECT email FROM users WHERE _id = %s", (user_id,))
        r = self.cur.fetchone()
        return (r[0] or "") if r else ""

    # -- earn

    def _earn(self, *, owner_id: str, source: str, code_id: str, code: str, idem: str,
              invitee_id: str | None, email_hash: str | None, ip_hash: str | None) -> tuple[str, str | None]:
        """Insert one reward after cap checks. Returns (outcome, reward_id).
        outcome: earned | duplicate | skipped_no_subscription | skipped_cap |
        skipped_outstanding | skipped_ip_cap. Atomic per owner/IP via advisory locks."""
        cfg = rewards_config()
        try:
            # Fixed lock order (ip, then owner) so concurrent earns cannot deadlock.
            if ip_hash:
                self.cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("owner_reward_ip:" + ip_hash,))
            self.cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("owner_reward:" + owner_id,))
            if not self.owner_subscription(owner_id):
                self._audit("reward_skipped_no_subscription", owner=owner_id, code=code_id, detail=source)
                self.conn.commit()
                return "skipped_no_subscription", None
            self._expire_due(owner_id)
            self.cur.execute(
                "SELECT COUNT(*) FROM owner_rewards WHERE owner_user_id=%s "
                "AND earned_at > NOW() - make_interval(days => %s)", (owner_id, cfg.cap_window_days))
            if self.cur.fetchone()[0] >= cfg.cap_count:
                self._audit("reward_skipped_cap", owner=owner_id, code=code_id, detail=source)
                self.conn.commit()
                return "skipped_cap", None
            self.cur.execute(
                "SELECT COUNT(*) FROM owner_rewards WHERE owner_user_id=%s AND status='earned'", (owner_id,))
            if self.cur.fetchone()[0] >= cfg.max_outstanding:
                self._audit("reward_skipped_outstanding", owner=owner_id, code=code_id, detail=source)
                self.conn.commit()
                return "skipped_outstanding", None
            if ip_hash:
                self.cur.execute(
                    "SELECT COUNT(*) FROM owner_rewards WHERE source='signup' AND invitee_ip_hash=%s "
                    "AND earned_at > NOW() - make_interval(days => %s)", (ip_hash, cfg.cap_window_days))
                if self.cur.fetchone()[0] >= cfg.ip_cap_count:
                    self._audit("reward_skipped_ip_cap", owner=owner_id, code=code_id, detail=source)
                    self.conn.commit()
                    return "skipped_ip_cap", None
            self.cur.execute(
                "INSERT INTO owner_rewards (owner_user_id, source, code_id, code, invitee_user_id, "
                " invitee_email_hash, invitee_ip_hash, percent, idempotency_key, expires_at) "
                "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s, NOW() + make_interval(days => %s)) "
                "ON CONFLICT DO NOTHING RETURNING _id",
                (owner_id, source, code_id, code, invitee_id, email_hash, ip_hash,
                 cfg.percent, idem, cfg.expiry_days))
            row = self.cur.fetchone()
            if row is None:
                self.conn.rollback()
                return "duplicate", None
            rid = str(row[0])
            self._audit("reward_earned", owner=owner_id, reward=rid, code=code_id, detail=source)
            self.conn.commit()
            return "earned", rid
        except Exception:
            self.conn.rollback()
            raise

    def earn_signup(self, invitee_id: str, invitee_email: str, raw_code, ip: str) -> tuple[str, str | None, str | None]:
        """Credit the friend-code owner for a new account. Returns
        (outcome, reward_id, owner_id). Never raises for a bad code; raises only
        on infrastructure errors (the caller swallows them: no reward, signup ok)."""
        code = normalize_code(raw_code)
        row = self.find_code(code) if code else None
        if not row or row["kind"] != "friend" or not row["active"] or not row["referrer_user_id"]:
            return "ignored", None, None
        if row["expires_at"] and row["expires_at"] <= datetime.now(timezone.utc):
            return "ignored", None, None
        owner_id = row["referrer_user_id"]
        norm = normalize_email(invitee_email)
        owner_norm = normalize_email(self._user_email(owner_id))
        if str(owner_id) == str(invitee_id) or not norm or norm == owner_norm:
            self.audit_event("reward_denied_self_referral", owner=owner_id, code=row["id"])
            return "denied_self_referral", None, owner_id
        outcome, rid = self._earn(
            owner_id=owner_id, source="signup", code_id=row["id"], code=row["code"],
            idem=f"signup:{invitee_id}", invitee_id=invitee_id, email_hash=_hash(norm),
            ip_hash=_hash("ip:" + ip) if ip else None)
        return outcome, rid, owner_id

    def _earn_friend_purchase(self, code_row: dict, buyer_id: str) -> tuple[str, str | None, str | None]:
        """Credit the inviter when an invitee redeems their friend code at a
        completed, signature-verified Stripe Checkout.

        Shares the ``signup:<invitee>`` idempotency key (and the per-invitee /
        per-email unique indexes, source 'signup') with ``earn_signup``, so an
        invitee who both signed up with the code AND redeemed it can credit the
        inviter at most once, in either order. Same eligibility as signup: owner
        must hold a real paid individual plan, caps apply, self-referral denied.
        The webhook has no client IP, so the per-IP cap is not applied here; the
        redemption itself already required a paid, discounted first purchase by
        a buyer with no paid history (see ``_log_promo_redemption``)."""
        owner_id = code_row.get("referrer_user_id")
        if not owner_id or not code_row.get("active"):
            return "ignored", None, None
        idem = f"signup:{buyer_id}"
        # Replay / signup-already-credited fast path (clean no-op, no spurious
        # skipped_* audit). The UNIQUE key + ON CONFLICT in _earn stay the
        # race-safe guarantee.
        self.cur.execute("SELECT 1 FROM owner_rewards WHERE idempotency_key = %s", (idem,))
        if self.cur.fetchone():
            self.conn.rollback()
            return "duplicate", None, owner_id
        norm = normalize_email(self._user_email(str(buyer_id)))
        owner_norm = normalize_email(self._user_email(owner_id))
        if str(owner_id) == str(buyer_id) or not norm or norm == owner_norm:
            self.audit_event("reward_denied_self_referral", owner=owner_id, code=code_row["id"], detail="checkout")
            return "denied_self_referral", None, owner_id
        outcome, rid = self._earn(
            owner_id=owner_id, source="signup", code_id=code_row["id"], code=code_row["code"],
            idem=idem, invitee_id=str(buyer_id), email_hash=_hash(norm), ip_hash=None)
        return outcome, rid, owner_id

    def resolve_owner_by_email(self, owner_email: str) -> str | None:
        """The one user whose account email equals the code's attached email
        (users.email is UNIQUE, but compare case-insensitively and fail closed on
        any ambiguity)."""
        self.cur.execute("SELECT _id FROM users WHERE LOWER(email) = %s LIMIT 2", (owner_email.lower(),))
        rows = self.cur.fetchall()
        return str(rows[0][0]) if len(rows) == 1 else None

    def earn_purchase(self, code_row: dict, buyer_id: str, redemption_key: str) -> tuple[str, str | None, str | None]:
        """Credit a code owner for a logged (within-cap) purchase: the creator-code
        owner (``purchase:<session>`` key) or, for a friend code redeemed at
        Stripe Checkout, the inviter (``signup:<buyer>`` key, see
        ``_earn_friend_purchase``)."""
        if code_row.get("kind") == "friend":
            return self._earn_friend_purchase(code_row, buyer_id)
        if code_row.get("kind") != "creator" or not code_row.get("creator_active", True):
            return "ignored", None, None
        idem = f"purchase:{redemption_key}"
        # Replay fast path: a reward for this purchase already exists, so there is
        # nothing to (re)credit. Checked before the cap checks so a replay of an
        # already-credited purchase is a clean no-op rather than a spurious
        # 'skipped_cap'. The UNIQUE key + ON CONFLICT in _earn remain the
        # race-safe guarantee against double-grant.
        self.cur.execute("SELECT 1 FROM owner_rewards WHERE idempotency_key = %s", (idem,))
        if self.cur.fetchone():
            self.conn.rollback()
            return "duplicate", None, None
        self.cur.execute("SELECT owner_email FROM promo_codes WHERE _id = %s", (code_row["id"],))
        r = self.cur.fetchone()
        owner_email = (r[0] or "").strip() if r else ""
        if not owner_email:
            return "ignored", None, None
        owner_id = self.resolve_owner_by_email(owner_email)
        if not owner_id:
            self.audit_event("reward_skipped_no_owner", code=code_row["id"], detail="purchase")
            return "skipped_no_owner", None, None
        if owner_id == str(buyer_id):
            self.audit_event("reward_denied_self_referral", owner=owner_id, code=code_row["id"], detail="purchase")
            return "denied_self_referral", None, owner_id
        # The owner was resolved purely by email equality, so (when email
        # verification is enabled) only an account that has proven ownership of
        # that address may collect. Skipped, not lost: a webhook replay after the
        # owner verifies re-attempts crediting (idempotent key).
        if email_verification_enabled() and not user_email_verified(self.cur, owner_id):
            self.audit_event("reward_skipped_unverified_owner", code=code_row["id"], detail="purchase")
            return "skipped_unverified_owner", None, None
        outcome, rid = self._earn(
            owner_id=owner_id, source="purchase", code_id=code_row["id"], code=code_row["code"],
            idem=idem, invitee_id=None, email_hash=None, ip_hash=None)
        return outcome, rid, owner_id

    # -- Stripe redemption

    def apply_stripe_reward(self, owner_id: str) -> str | None:
        """Apply the oldest earned reward to the owner's Stripe subscription
        (discounting the next invoice) and mark it claimed atomically. Returns the
        reward id applied, or None (nothing eligible / deferred / error: all fail
        closed and leave the reward earned for a later attempt)."""
        from backend.subscription import stripe_service
        try:
            sub = self.owner_subscription(owner_id)
            if not sub or sub["provider"] != "stripe" or not sub["stripe_subscription_id"] \
                    or not stripe_service.is_configured():
                self.conn.rollback()
                return None
            self.cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("owner_reward:" + owner_id,))
            self._expire_due(owner_id)
            self.cur.execute(
                "SELECT _id, percent FROM owner_rewards WHERE owner_user_id=%s AND status='earned' "
                "AND expires_at > NOW() AND apple_nonce IS NULL ORDER BY earned_at LIMIT 1 "
                "FOR UPDATE SKIP LOCKED", (owner_id,))
            row = self.cur.fetchone()
            if not row:
                self.conn.commit()
                return None
            rid, pct = str(row[0]), int(row[1])
            if not stripe_service.apply_owner_reward(sub["stripe_subscription_id"], pct, rid):
                self._audit("reward_apply_deferred", owner=owner_id, reward=rid, detail="stripe")
                self.conn.commit()
                return None
            self.cur.execute(
                "UPDATE owner_rewards SET status='claimed', claimed_via='stripe', claim_ref=%s, "
                "claimed_at=NOW() WHERE _id=%s AND status='earned'", (sub["stripe_subscription_id"], rid))
            if self.cur.rowcount != 1:
                self.conn.rollback()
                return None
            self._audit("reward_claimed", owner=owner_id, reward=rid, detail="stripe")
            self.conn.commit()
            return rid
        except Exception as e:
            self.conn.rollback()
            logger.error("stripe owner reward apply failed (deferred): %s", type(e).__name__)
            return None

    def owner_for_stripe_sub(self, stripe_sub_id: str) -> str | None:
        self.cur.execute("SELECT user_id FROM subscriptions WHERE stripe_subscription_id=%s AND provider='stripe'",
                         (stripe_sub_id,))
        r = self.cur.fetchone()
        return str(r[0]) if r and r[0] else None

    # -- Apple redemption

    def claim_apple(self, user_id: str) -> dict:
        """Reserve the oldest earned reward and return a promotional-offer
        signature. Raises PromoError (404 uniform) for every denial; any other
        exception propagates (route maps to 500, nothing granted).

        Double-claim protection: a signature stays redeemable at Apple until its
        embedded timestamp ages out, regardless of our own reservation window. So
        while ANY earned reward of this owner carries a signature that may still be
        live (``_SIG_LIVE_SQL``), no new signature is issued (409). Only once the
        old one is provably dead is the reward re-signed, replacing the ledger
        nonce (the old nonce can then never finalize). The nonce is a fresh UUID
        used both as the signature nonce and as ``applicationUsername`` -- the
        client sets it as the purchase's ``appAccountToken``, so the verified
        transaction echoes it back and finalization can bind to exactly this
        reservation. Everything runs under the per-owner advisory lock.
        """
        cfg = rewards_config()
        try:
            self.cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("owner_reward:" + user_id,))
            sub = self.owner_subscription(user_id)
            if not sub or sub["provider"] != "apple":
                raise PromoError(404, "Not found")
            product = apple_service.product_for_member_count(1)
            offer = cfg.apple_offers.get(product or "")
            if not product or not offer:
                raise PromoError(404, "Not found")
            self._expire_due(user_id)
            self.cur.execute(
                "SELECT 1 FROM owner_rewards WHERE owner_user_id=%s AND status='earned' AND " + _SIG_LIVE_SQL,
                (user_id,))
            if self.cur.fetchone():
                raise PromoError(409, "A reward claim is already in progress. Try again later.")
            self.cur.execute(
                "SELECT _id FROM owner_rewards WHERE owner_user_id=%s AND status='earned' AND expires_at > NOW() "
                "ORDER BY earned_at LIMIT 1 FOR UPDATE", (user_id,))
            row = self.cur.fetchone()
            if not row:
                raise PromoError(404, "Not found")
            rid = str(row[0])
            nonce = str(uuid.uuid4())
            # One clock (the DB's) for the signed timestamp and the recorded death time.
            self.cur.execute("SELECT clock_timestamp()")
            signed_at = self.cur.fetchone()[0]
            ts_ms = int(signed_at.timestamp() * 1000)
            sig = apple_service.sign_promotional_offer(
                cfg.private_key, key_id=cfg.apple_key_id, bundle_id=cfg.bundle_id, product_id=product,
                offer_id=offer, application_username=nonce,
                nonce=nonce, timestamp_ms=ts_ms)
            self.cur.execute(
                "UPDATE owner_rewards SET apple_nonce=%s, apple_reserved_until=NOW() + make_interval(mins => %s), "
                "apple_signature_expires_at = %s + make_interval(hours => %s) "
                "WHERE _id=%s AND status='earned'",
                (nonce, cfg.reservation_minutes, signed_at, _APPLE_SIGNATURE_DEAD_AFTER_HOURS, rid))
            if self.cur.rowcount != 1:
                raise RuntimeError("reward changed during claim")
            self._audit("reward_apple_signed", owner=user_id, reward=rid, actor=user_id)
            self.conn.commit()
            return sig
        except Exception:
            self.conn.rollback()
            raise

    def finalize_apple_claim(self, user_id: str, transaction_id: str, product_id: str,
                             offer_id: str, claim_token: str | None = None) -> str | None:
        """Reconcile a verified Apple transaction that carries one of our
        promotional offers: mark the reward whose CURRENT reservation nonce equals
        the transaction's ``appAccountToken`` as claimed. Returns the reward id,
        or None when nothing changed.

        Guards (each independently prevents a second grant):
        * the transaction id is idempotent (replay is a no-op; also a UNIQUE
          partial index on (claimed_via, claim_ref));
        * the token must equal a reward's current ``apple_nonce`` for THIS owner;
          a stale/retired/foreign/missing token matches nothing (audited, no
          grant), so a superseded signature can never finalize;
        * the claim is an atomic conditional UPDATE on ``status='earned' AND
          apple_nonce=<token>``, so a reward finalizes at most once; a second
          transaction carrying an already-finalized nonce is audited as a
          duplicate redemption and grants nothing further.
        """
        cfg = rewards_config()
        if not rewards_enabled() or not transaction_id or cfg.apple_offers.get(product_id or "") != offer_id:
            return None
        token = _norm_token(claim_token)
        try:
            self.cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("owner_reward:" + user_id,))
            self.cur.execute("SELECT 1 FROM owner_rewards WHERE claimed_via='apple' AND claim_ref=%s",
                             (transaction_id,))
            if self.cur.fetchone():
                self.conn.rollback()
                return None
            row = None
            if token:
                self.cur.execute(
                    "SELECT _id, status FROM owner_rewards WHERE owner_user_id=%s AND apple_nonce=%s "
                    "FOR UPDATE", (user_id, token))
                row = self.cur.fetchone()
            if not row:
                self._audit("reward_apple_redeemed_unmatched", owner=user_id,
                            detail="no matching reservation" if token else "no claim token")
                self.conn.commit()
                return None
            rid, status = str(row[0]), row[1]
            if status != "earned":
                self._audit("reward_apple_duplicate_redemption", reward=rid, owner=user_id, detail=status)
                self.conn.commit()
                return None
            self.cur.execute(
                "UPDATE owner_rewards SET status='claimed', claimed_via='apple', claim_ref=%s, claimed_at=NOW() "
                "WHERE _id=%s AND status='earned' AND apple_nonce=%s", (transaction_id, rid, token))
            if self.cur.rowcount != 1:
                self.conn.rollback()
                return None
            self._audit("reward_claimed", owner=user_id, reward=rid, detail="apple")
            self.conn.commit()
            return rid
        except Exception:
            self.conn.rollback()
            raise

    def user_for_apple_txn(self, original_transaction_id: str) -> str | None:
        self.cur.execute("SELECT user_id FROM subscriptions WHERE apple_original_transaction_id=%s "
                         "AND provider='apple' LIMIT 1", (original_transaction_id,))
        r = self.cur.fetchone()
        return str(r[0]) if r and r[0] else None

    # -- summary

    def summary(self, user_id: str) -> dict:
        self._expire_due(user_id)
        self.conn.commit()
        self.cur.execute(
            "SELECT COUNT(*) FILTER (WHERE status='earned'), COUNT(*) FILTER (WHERE status='claimed'), "
            "COUNT(*) FILTER (WHERE status='expired'), "
            "MIN(expires_at) FILTER (WHERE status='earned') FROM owner_rewards WHERE owner_user_id=%s",
            (user_id,))
        e, c, x, nxt = self.cur.fetchone()
        sub = self.owner_subscription(user_id)
        self.cur.execute(
            "SELECT EXISTS(SELECT 1 FROM owner_rewards WHERE owner_user_id=%s AND status='earned' "
            "AND " + _SIG_LIVE_SQL + ")", (user_id,))
        in_progress = bool(self.cur.fetchone()[0])
        cfg = rewards_config()
        return {
            "percent_off": cfg.percent, "earned": e, "claimed": c, "expired": x,
            "next_expiry": _iso(nxt), "provider": sub["provider"] if sub else None,
            "can_claim_apple": bool(sub and sub["provider"] == "apple" and e > 0 and not in_progress),
            "apple_application_username": apple_application_username(user_id),
        }

    # -- admin reporting

    def reward_counts_by_code(self) -> dict:
        self.cur.execute(
            "SELECT code_id, COUNT(*), COUNT(*) FILTER (WHERE status='claimed') FROM owner_rewards "
            "WHERE code_id IS NOT NULL GROUP BY code_id")
        return {str(r[0]): {"rewards_earned": r[1], "rewards_claimed": r[2]} for r in self.cur.fetchall()}


# ── Fail-closed entry points used by routes ──────────────────────────────────

def credit_signup_reward(invitee_id: str, invitee_email: str, raw_code, ip: str) -> None:
    """Called after account creation. Never raises and never changes the signup
    result: on any error no reward is granted (logged by class only)."""
    if not raw_code or not rewards_enabled():
        return
    db = None
    try:
        db = RewardManager()
        outcome, _rid, owner_id = db.earn_signup(invitee_id, invitee_email, raw_code, ip)
        if outcome == "earned" and owner_id:
            db.apply_stripe_reward(owner_id)
    except Exception as e:
        logger.error("signup reward credit failed (no reward): %s", type(e).__name__)
    finally:
        if db is not None:
            try:
                db.close()
            except Exception:
                pass


def credit_purchase_reward(code_id: str, buyer_id: str, redemption_key: str) -> None:
    """Credit the code owner for a logged (within-cap) purchase: creator-code
    owner, or the friend-code inviter (shared ``signup:<buyer>`` key).

    Retry-safe: the reward is keyed ``purchase:<redemption_key>`` (UNIQUE), so
    calling this again for the same purchase (webhook replay) is a no-op once the
    reward exists and never double-grants. Ineligible/permanent outcomes (no
    owner, owner not subscribed, cap, self-referral, unknown code) return
    normally and grant nothing (fail closed). Infrastructure/transient errors
    PROPAGATE (type logged, never the message) so the Stripe webhook can 500 and
    let Stripe re-deliver; the redemption is already durably logged, and the
    replay re-attempts crediting. The follow-on Stripe discount application
    (``apply_stripe_reward``) is itself best-effort and leaves the reward
    ``earned`` for a later attempt, so it never raises here.
    """
    if not rewards_enabled():
        return
    db = None
    try:
        db = RewardManager()
        code = db.get_code_by_id(code_id)
        if not code:
            return
        outcome, _rid, owner_id = db.earn_purchase(code, buyer_id, redemption_key)
        if outcome == "earned" and owner_id:
            db.apply_stripe_reward(owner_id)
    except Exception as e:
        logger.error("purchase reward credit failed (will be retried by webhook replay): %s", type(e).__name__)
        raise
    finally:
        if db is not None:
            try:
                db.close()
            except Exception:
                pass


def reconcile_apple_offer(user_id: str | None, payload: dict) -> None:
    """Mark a reserved reward claimed when a verified Apple transaction payload
    carries one of our promotional offers (offerType 2 = promotional). Idempotent on the
    transaction id. Infrastructure errors PROPAGATE so the notification route
    can 500 and let Apple retry; /apple/sync catches and logs them (the app
    re-syncs on every launch)."""
    if not user_id or not rewards_enabled():
        return
    offer_id = payload.get("offerIdentifier")
    if not offer_id or payload.get("offerType") != 2:
        return
    db = RewardManager()
    try:
        db.finalize_apple_claim(user_id, str(payload.get("transactionId") or ""),
                                payload.get("productId") or "", offer_id,
                                payload.get("appAccountToken"))
    finally:
        db.close()
