"""iOS friend-invite redemption through Apple OFFER CODES (task
20261003-ios-friend-offer-code-redeem).

Apple promotional offers only work for current/lapsed subscribers, so a brand-new
iOS subscriber cannot get a first-month discount that way. Offer codes can target
"new subscribers". Flow:

1. The app posts the friend code it was given to ``POST /promo/{user_id}/ios-offer-code``.
2. The server re-validates under every rule (``PromoManager.evaluate``: code
   exists/active/unexpired/under cap, not the caller's own, caller is a new
   subscriber; plus friend-kind only, per-IP and global daily caps, outstanding
   cap) and ONLY THEN asks App Store Connect for ONE one-time-use code
   (``subscriptionOfferCodeOneTimeUseCodes``) against the pre-created offer.
3. The code (and a redeem URL) goes back to the app, which opens Apple's redeem
   sheet. Apple enforces new-subscriber eligibility again on its side.
4. When Apple's verified transaction arrives (``/subscriptions/apple/sync`` or an
   App Store notification) carrying ``offerType == 3`` and our offer's reference
   name, the redemption row for THAT user is marked redeemed, a ``promo_redemptions``
   row is logged and the friend-code owner's reward is credited. Never at issue time.

Everything fails closed: any validator/ASC error or ambiguity denies, and no code
is ever fabricated. This module NEVER creates or modifies an ASC offer (the offer
is created by hand in App Store Connect; ``check_offer`` is a read-only GET).

Idempotency: ``ios_offer_redemptions`` allows one live row per user. A retry
re-reads the SAME ASC batch's values (a GET) and never mints a second batch; a row
left ``pending`` by an ambiguous ASC failure (timeout) blocks re-mint until an
operator reconciles it (a duplicate-mint risk is worse than a stuck user). The code
value is never stored or logged.

Config (env, no implicit defaults, validated eagerly by
``validate_offer_codes_config()`` from main.py's lifespan; flag deploys OFF):
    IOS_OFFER_CODES_ENABLED          'true' | 'false'  (requires PROMO_CODES_ENABLED and
                                     OWNER_REWARDS_ENABLED when 'true')
    IOS_OFFER_CODE_EXPIRY_DAYS       1-180, validity of a minted code
    IOS_OFFER_CODE_RATE_LIMIT        slowapi string, per IP and per user
    IOS_OFFER_CODE_IP_DAILY_CAP      max issuances per hashed client IP per 24h
    IOS_OFFER_CODE_DAILY_MINT_CAP    max ASC mints in total per 24h (quota guard)
    APPLE_ASC_KEY_ID                 App Store Connect API key id (10 chars)
    APPLE_ASC_ISSUER_ID              App Store Connect issuer id (UUID)
    APPLE_ASC_KEY_PATH               path to the ASC API .p8 (read only when enabled; never logged)
    APPLE_OFFER_CODE_ID              ASC ``subscriptionOfferCodes`` resource id of the manual offer
    APPLE_OFFER_CODE_REFERENCE_NAME  the offer's reference name; transactions echo it as offerIdentifier
    APPLE_APP_STORE_ID               numeric App Store app id (redeem URL)
"""
import csv
import io
import logging
import os
import re
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

import httpx

from backend.subscription import apple_service
from backend.subscription.owner_rewards import (
    RewardManager, _hash, normalize_email, rewards_config, rewards_enabled,
)
from backend.subscription.promo import PromoError, promo_enabled

logger = logging.getLogger(__name__)

ASC_BASE = "https://api.appstoreconnect.apple.com"
OFFER_TYPE_OFFER_CODE = 3          # StoreKit transaction offerType for an offer code
_ASC_TIMEOUT = httpx.Timeout(10.0, connect=5.0)
_PREFLIGHT_TTL_S = 600
_CODE_VALUE_RE = re.compile(r"^[A-Za-z0-9]{6,40}$")
_KEY_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
_ASC_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_NAME_RE = re.compile(r"^[A-Za-z0-9_ .-]{1,64}$")
_STORE_ID_RE = re.compile(r"^[0-9]{5,15}$")


class OfferCodesConfigError(RuntimeError):
    """IOS_OFFER_CODE* / APPLE_ASC_* / APPLE_OFFER_CODE_* config is missing or invalid."""


class OfferCodeDenied(Exception):
    """Uniform validation denial (maps to one 400; reveals no reason)."""


class OfferCodeUnavailable(Exception):
    """Validation passed (or may have) but a code could not be issued right now
    (ASC error / pending reconcile / global cap). Maps to 503; nothing fabricated."""


class AscRejected(Exception):
    """ASC answered with a definite HTTP error: the request had no effect."""


class AscAmbiguous(Exception):
    """No definite answer (timeout / transport / unparseable): effect unknown."""


@dataclass(frozen=True)
class OfferCodesConfig:
    enabled: bool
    expiry_days: int
    rate_limit: str
    ip_daily_cap: int
    daily_mint_cap: int
    asc_key_id: str
    asc_issuer_id: str
    asc_key_path: str
    offer_code_id: str
    reference_name: str
    app_store_id: str
    private_key: object = field(default=None, repr=False, compare=False)


_config: OfferCodesConfig | None = None


def _req(name: str) -> str:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        raise OfferCodesConfigError(f"{name} is not set (no implicit default).")
    return raw.strip()


def _req_int(name: str, lo: int, hi: int | None = None) -> int:
    raw = _req(name)
    try:
        v = int(raw)
    except ValueError:
        raise OfferCodesConfigError(f"{name} ({raw!r}) is not a valid integer.")
    if v < lo or (hi is not None and v > hi):
        rng = f"between {lo} and {hi}" if hi is not None else f"at least {lo}"
        raise OfferCodesConfigError(f"{name} ({v}) must be {rng}.")
    return v


def validate_offer_codes_config() -> None:
    """Eagerly validate config. Call once at startup (lifespan), after
    ``validate_promo_config`` and ``validate_owner_rewards_config``.

    All values are validated even with the flag off; the ASC .p8 is read only
    when the flag is on. Messages never contain key material.
    """
    global _config
    raw_enabled = os.getenv("IOS_OFFER_CODES_ENABLED")
    if raw_enabled is None or raw_enabled.strip().lower() not in ("true", "false"):
        raise OfferCodesConfigError(
            "IOS_OFFER_CODES_ENABLED must be set explicitly to 'true' or 'false' "
            "(no implicit default; deploy with 'false')."
        )
    enabled = raw_enabled.strip().lower() == "true"
    expiry_days = _req_int("IOS_OFFER_CODE_EXPIRY_DAYS", 1, 180)
    rl = _req("IOS_OFFER_CODE_RATE_LIMIT")
    try:
        from limits import parse
        parse(rl)
    except Exception:
        raise OfferCodesConfigError(f"IOS_OFFER_CODE_RATE_LIMIT ({rl!r}) is not a valid rate-limit string.")
    ip_cap = _req_int("IOS_OFFER_CODE_IP_DAILY_CAP", 1)
    mint_cap = _req_int("IOS_OFFER_CODE_DAILY_MINT_CAP", 1)
    key_id = _req("APPLE_ASC_KEY_ID")
    if not _KEY_ID_RE.match(key_id):
        raise OfferCodesConfigError("APPLE_ASC_KEY_ID must be a 10-character App Store Connect key id.")
    issuer = _req("APPLE_ASC_ISSUER_ID")
    try:
        uuid.UUID(issuer)
    except ValueError:
        raise OfferCodesConfigError("APPLE_ASC_ISSUER_ID must be a UUID.")
    key_path = _req("APPLE_ASC_KEY_PATH")
    offer_id = _req("APPLE_OFFER_CODE_ID")
    if not _ASC_ID_RE.match(offer_id):
        raise OfferCodesConfigError("APPLE_OFFER_CODE_ID is not a valid App Store Connect resource id.")
    ref = _req("APPLE_OFFER_CODE_REFERENCE_NAME")
    if not _NAME_RE.match(ref):
        raise OfferCodesConfigError("APPLE_OFFER_CODE_REFERENCE_NAME is not a valid offer reference name.")
    store_id = _req("APPLE_APP_STORE_ID")
    if not _STORE_ID_RE.match(store_id):
        raise OfferCodesConfigError("APPLE_APP_STORE_ID must be the numeric App Store app id.")

    private_key = None
    if enabled:
        if not promo_enabled():
            raise OfferCodesConfigError("IOS_OFFER_CODES_ENABLED=true requires PROMO_CODES_ENABLED=true.")
        try:
            if not rewards_config().enabled:
                raise OfferCodesConfigError("IOS_OFFER_CODES_ENABLED=true requires OWNER_REWARDS_ENABLED=true.")
        except OfferCodesConfigError:
            raise
        except Exception:
            raise OfferCodesConfigError("Owner-reward config is not validated; cannot enable iOS offer codes.")
        try:
            from cryptography.hazmat.primitives import serialization
            from cryptography.hazmat.primitives.asymmetric import ec
            with open(key_path, "rb") as fh:
                private_key = serialization.load_pem_private_key(fh.read(), password=None)
            if not isinstance(private_key, ec.EllipticCurvePrivateKey) or private_key.curve.name != "secp256r1":
                raise ValueError("not an EC P-256 key")
        except Exception as e:
            raise OfferCodesConfigError(
                f"APPLE_ASC_KEY_PATH could not be loaded as an EC P-256 PEM key ({type(e).__name__})."
            )
    _config = OfferCodesConfig(enabled, expiry_days, rl, ip_cap, mint_cap, key_id, issuer, key_path,
                               offer_id, ref, store_id, private_key)


def offer_codes_config() -> OfferCodesConfig:
    if _config is None:
        raise OfferCodesConfigError(
            "iOS offer-code config has not been validated; call validate_offer_codes_config() at startup.")
    return _config


def offer_codes_enabled() -> bool:
    """Feature flag. Fails closed (False) if config was never validated or the
    promo/reward flags are off."""
    return _config is not None and _config.enabled and promo_enabled() and rewards_enabled()


# ── App Store Connect client (the only module that talks to ASC for codes) ────

class AscOfferCodeClient:
    """Minimal ASC client. Reads: offer preflight, batch values. The single write
    is creating ONE one-time-use code batch against the configured offer; it never
    creates/edits/deletes an offer. Error messages carry the HTTP status only
    (never bodies, tokens, or code values)."""

    def __init__(self, cfg: OfferCodesConfig, http: httpx.Client | None = None):
        self._cfg = cfg
        self._http = http or httpx.Client(timeout=_ASC_TIMEOUT)

    def _headers(self) -> dict:
        import jwt
        now = int(time.time())
        token = jwt.encode(
            {"iss": self._cfg.asc_issuer_id, "iat": now, "exp": now + 10 * 60, "aud": "appstoreconnect-v1"},
            self._cfg.private_key, algorithm="ES256", headers={"kid": self._cfg.asc_key_id, "typ": "JWT"})
        return {"Authorization": f"Bearer {token}"}

    def _send(self, method: str, path: str, **kw) -> httpx.Response:
        try:
            resp = self._http.request(method, ASC_BASE + path, headers=self._headers(), **kw)
        except Exception as e:
            raise AscAmbiguous(type(e).__name__)
        if resp.status_code >= 500:
            # The server may or may not have acted on a write; reads are harmless.
            raise AscAmbiguous(f"status {resp.status_code}")
        if resp.status_code >= 400:
            raise AscRejected(f"status {resp.status_code}")
        return resp

    def check_offer(self) -> None:
        """Read-only prerequisite check. Raises AscRejected/AscAmbiguous on any
        problem: offer missing, inactive, not new-subscribers-only, or its
        reference name differs from APPLE_OFFER_CODE_REFERENCE_NAME."""
        resp = self._send("GET", f"/v1/subscriptionOfferCodes/{self._cfg.offer_code_id}")
        try:
            attrs = (resp.json().get("data") or {}).get("attributes") or {}
        except Exception:
            raise AscAmbiguous("unparseable offer")
        elig = attrs.get("customerEligibilities")
        if (attrs.get("active") is not True or attrs.get("name") != self._cfg.reference_name
                or not isinstance(elig, list) or set(elig) != {"NEW"}):
            raise AscRejected("offer not active / not new-subscribers / name mismatch")

    def create_one_time_use_batch(self, expiration_date: str) -> str:
        body = {"data": {
            "type": "subscriptionOfferCodeOneTimeUseCodes",
            "attributes": {"numberOfCodes": 1, "expirationDate": expiration_date},
            "relationships": {"offerCode": {"data": {
                "type": "subscriptionOfferCodes", "id": self._cfg.offer_code_id}}},
        }}
        resp = self._send("POST", "/v1/subscriptionOfferCodeOneTimeUseCodes", json=body)
        try:
            batch_id = str((resp.json().get("data") or {}).get("id") or "")
        except Exception:
            raise AscAmbiguous("unparseable batch response")
        if not _ASC_ID_RE.match(batch_id):
            raise AscAmbiguous("missing batch id")
        return batch_id

    def fetch_code(self, batch_id: str) -> str:
        """The single code of a 1-code batch. Raises AscAmbiguous unless exactly
        one well-formed value is returned (ASC generates asynchronously)."""
        if not _ASC_ID_RE.match(batch_id or ""):
            raise AscAmbiguous("bad batch id")
        resp = self._send("GET", f"/v1/subscriptionOfferCodeOneTimeUseCodes/{batch_id}/values")
        values = []
        for row in csv.reader(io.StringIO(resp.text)):
            for cell in row:
                cell = cell.strip()
                if cell and _CODE_VALUE_RE.match(cell):
                    values.append(cell)
        if len(values) != 1:
            raise AscAmbiguous("code not ready")
        return values[0]


_client: AscOfferCodeClient | None = None
_preflight_ok_until = 0.0


def get_client() -> AscOfferCodeClient:
    global _client
    if _client is None:
        _client = AscOfferCodeClient(offer_codes_config())
    return _client


def _preflight(client: AscOfferCodeClient) -> None:
    """Cached read-only offer check. Fail closed on any problem."""
    global _preflight_ok_until
    if time.monotonic() < _preflight_ok_until:
        return
    client.check_offer()
    _preflight_ok_until = time.monotonic() + _PREFLIGHT_TTL_S


def redeem_url(code: str) -> str:
    return (f"https://apps.apple.com/redeem?ctx=offercodes&id={offer_codes_config().app_store_id}"
            f"&code={code}")


# ── Ledger / manager ──────────────────────────────────────────────────────────

class OfferCodeManager(RewardManager):
    """DB access for ios_offer_redemptions. Inherits RewardManager (promo
    evaluate/log_redemption, reward ``_earn``, audit)."""

    def _lock(self, key: str) -> None:
        self.cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (key,))

    def _email(self, user_id: str) -> str:
        return self._user_email(user_id)

    def _fail(self, rid: str, why: str) -> None:
        self.cur.execute("UPDATE ios_offer_redemptions SET status='failed' WHERE _id=%s AND status='pending'", (rid,))
        self._audit("ios_offer_failed", actor=None, detail=f"{rid}:{why}")
        self.conn.commit()

    def request_code(self, user_id: str, raw_code, ip: str, client: AscOfferCodeClient | None = None) -> dict:
        """Validate fully, then issue (or re-read) the caller's one-time-use code.

        Raises OfferCodeDenied for every validation failure (no ASC call made) and
        OfferCodeUnavailable when validation passed but no code can be returned
        now. Returns ``{"offer_code", "redeem_url", "expires_at"}``.
        """
        cfg = offer_codes_config()
        try:
            email = self._email(user_id)
            # Same rules as the web path: exists/active/unexpired/under cap, not the
            # caller's own code, new subscriber (local + Stripe history), member_count 1.
            row = self.evaluate(user_id, raw_code, 1, email)
            ip_hash = _hash("ip:" + ip) if ip else None
            if not row or row["kind"] != "friend" or not row["referrer_user_id"] or not ip_hash:
                raise OfferCodeDenied()

            # Read-only, cached offer preflight BEFORE taking any lock (a network
            # call must never run while holding the global caps lock).
            client = client or get_client()
            try:
                _preflight(client)
            except Exception as e:
                self.conn.rollback()
                logger.error("ios offer preflight failed (closed): %s",
                             e if isinstance(e, (AscRejected, AscAmbiguous)) else type(e).__name__)
                raise OfferCodeUnavailable()

            self._lock("ios_offer_user:" + user_id)
            self.cur.execute(
                "SELECT _id, status, asc_batch_id, expires_at, code_id FROM ios_offer_redemptions "
                "WHERE user_id=%s AND status IN ('pending','issued','redeemed') FOR UPDATE", (user_id,))
            live = self.cur.fetchone()
            if live:
                rid, status, batch_id, expires_at, live_code_id = str(live[0]), live[1], live[2], live[3], \
                    str(live[4]) if live[4] else None
                if status == "redeemed":
                    self.conn.rollback()
                    raise OfferCodeDenied()
                if status == "pending":
                    # Earlier attempt's ASC outcome unknown: never re-mint (duplicate risk).
                    self._audit("ios_offer_pending_blocked", actor=user_id, detail=rid)
                    self.conn.commit()
                    raise OfferCodeUnavailable()
                if expires_at and expires_at > datetime.now(timezone.utc):
                    self.conn.rollback()
                    if live_code_id != row["id"]:
                        raise OfferCodeDenied()
                    return self._reread(client, batch_id, expires_at)
                self.cur.execute("UPDATE ios_offer_redemptions SET status='expired' WHERE _id=%s", (rid,))
                self._audit("ios_offer_expired", actor=user_id, detail=rid)
                # fall through: a fresh issuance replaces the lapsed one.

            # Caps, checked and the row inserted under one global lock (race-safe).
            self._lock("ios_offer_caps")
            if row["max_redemptions"] is not None:
                self.cur.execute(
                    "SELECT COUNT(*) FROM ios_offer_redemptions WHERE code_id=%s AND status IN ('pending','issued')",
                    (row["id"],))
                if row["redemption_count"] + self.cur.fetchone()[0] >= row["max_redemptions"]:
                    self.conn.rollback()
                    raise OfferCodeDenied()
            self.cur.execute(
                "SELECT COUNT(*) FROM ios_offer_redemptions WHERE ip_hash=%s AND created_at > NOW() - INTERVAL '24 hours'",
                (ip_hash,))
            if self.cur.fetchone()[0] >= cfg.ip_daily_cap:
                self._audit("ios_offer_ip_capped", actor=user_id, code=row["id"])
                self.conn.commit()
                raise OfferCodeDenied()
            self.cur.execute(
                "SELECT COUNT(*) FROM ios_offer_redemptions WHERE status != 'failed' "
                "AND created_at > NOW() - INTERVAL '24 hours'")
            if self.cur.fetchone()[0] >= cfg.daily_mint_cap:
                self._audit("ios_offer_daily_capped", actor=user_id, code=row["id"])
                self.conn.commit()
                raise OfferCodeUnavailable()
        except (OfferCodeDenied, OfferCodeUnavailable):
            raise
        except Exception as e:
            self.conn.rollback()
            logger.error("ios offer validation failed (denying): %s", type(e).__name__)
            raise OfferCodeDenied()

        expires_on = (datetime.now(timezone.utc) + timedelta(days=cfg.expiry_days)).date()
        try:
            self.cur.execute(
                "INSERT INTO ios_offer_redemptions (user_id, code_id, referrer_user_id, ip_hash, expires_at) "
                "VALUES (%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING RETURNING _id",
                (user_id, row["id"], row["referrer_user_id"], ip_hash,
                 datetime(expires_on.year, expires_on.month, expires_on.day, 23, 59, 59, tzinfo=timezone.utc)))
            ins = self.cur.fetchone()
            if ins is None:   # a concurrent request reserved it; never mint twice
                self.conn.rollback()
                raise OfferCodeUnavailable()
            rid = str(ins[0])
            self._audit("ios_offer_reserved", actor=user_id, code=row["id"], detail=rid)
            self.conn.commit()
        except OfferCodeUnavailable:
            raise
        except Exception as e:
            self.conn.rollback()
            logger.error("ios offer reserve failed (closed): %s", type(e).__name__)
            raise OfferCodeUnavailable()

        # The one external write. Definite rejection => nothing minted (row failed);
        # ambiguous => leave 'pending' so it is never blindly retried.
        try:
            batch_id = client.create_one_time_use_batch(expires_on.isoformat())
        except AscRejected as e:
            logger.error("ASC rejected offer-code mint: %s", e)
            self._fail(rid, "asc_rejected")
            raise OfferCodeUnavailable()
        except Exception as e:
            logger.error("ASC offer-code mint outcome unknown (row left pending): %s", e)
            self._audit_safe("ios_offer_mint_ambiguous", user_id, rid)
            raise OfferCodeUnavailable()
        try:
            self.cur.execute(
                "UPDATE ios_offer_redemptions SET status='issued', asc_batch_id=%s, issued_at=NOW() "
                "WHERE _id=%s AND status='pending'", (batch_id, rid))
            self._audit("ios_offer_issued", actor=user_id, code=row["id"], detail=rid)
            self.conn.commit()
        except Exception as e:
            self.conn.rollback()
            logger.error("ios offer batch %s could not be recorded (left pending): %s", batch_id, type(e).__name__)
            raise OfferCodeUnavailable()
        return self._reread(client, batch_id, None, rid)

    def _audit_safe(self, action: str, user_id: str, rid: str) -> None:
        try:
            self.conn.rollback()
            self._audit(action, actor=user_id, detail=rid)
            self.conn.commit()
        except Exception:
            self.conn.rollback()

    def _reread(self, client: AscOfferCodeClient, batch_id: str, expires_at, rid: str | None = None) -> dict:
        try:
            code = client.fetch_code(batch_id)
        except Exception as e:
            logger.error("ios offer code not available yet (closed): %s", e if isinstance(e, (AscRejected, AscAmbiguous)) else type(e).__name__)
            raise OfferCodeUnavailable()
        if expires_at is None:
            self.cur.execute("SELECT expires_at FROM ios_offer_redemptions WHERE asc_batch_id=%s", (batch_id,))
            r = self.cur.fetchone()
            expires_at = r[0] if r else None
        return {"offer_code": code, "redeem_url": redeem_url(code),
                "expires_at": expires_at.isoformat() if expires_at else None}

    # -- reconcile (verified Apple transaction)

    def finalize_redeemed(self, user_id: str, transaction_id: str) -> str | None:
        """Mark the user's issued redemption redeemed (keyed on user + redemption
        record + offer identifier + transaction id), log the promo redemption, and
        credit the friend-code owner once. Safe to re-run for the same transaction:
        every step is idempotent, so a replay after a partial failure completes
        the remaining steps. Returns the redemption id, or None if unmatched."""
        try:
            self._lock("ios_offer_user:" + user_id)
            self.cur.execute(
                "SELECT _id, status, apple_transaction_id, code_id, referrer_user_id, ip_hash "
                "FROM ios_offer_redemptions WHERE user_id=%s AND status IN ('issued','redeemed') "
                "ORDER BY created_at DESC LIMIT 1 FOR UPDATE", (user_id,))
            r = self.cur.fetchone()
            if not r:
                self._audit("ios_offer_redeemed_unmatched", owner=user_id, detail="no issued redemption")
                self.conn.commit()
                return None
            rid, status, txn, code_id, referrer, ip_hash = str(r[0]), r[1], r[2], r[3], r[4], r[5]
            if status == "redeemed":
                self.conn.rollback()
                if txn != transaction_id:
                    return None       # a later renewal / different txn: never a second reward
            else:
                self.cur.execute(
                    "UPDATE ios_offer_redemptions SET status='redeemed', redeemed_at=NOW(), apple_transaction_id=%s "
                    "WHERE _id=%s AND status='issued'", (transaction_id, rid))
                if self.cur.rowcount != 1:
                    self.conn.rollback()
                    return None
                self._audit("ios_offer_redeemed", owner=user_id, code=str(code_id) if code_id else None, detail=rid)
                self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise

        if not code_id or not referrer:
            return rid
        key = f"ios-offer:{rid}"
        try:
            result = self.log_redemption(
                code_id=str(code_id), user_id=user_id, plan="individual", platform="apple",
                store_transaction_id=transaction_id, idempotency_key=key, amount_discount_cents=None)
        except PromoError:
            logger.warning("ios offer redemption %s: code vanished; no reward", rid)
            return rid
        existing = self.get_redemption(key)
        if result == "over_cap" or not existing or existing["over_cap"]:
            self.conn.rollback()
            return rid
        self._credit_owner(user_id, str(referrer), str(code_id), ip_hash)
        return rid

    def _credit_owner(self, invitee_id: str, owner_id: str, code_id: str, ip_hash: str | None) -> None:
        """Credit once. Shares the signup reward's idempotency key
        (``signup:<invitee>`` + the per-invitee/email unique indexes), so a user
        who ALSO sent invite_code at signup can never produce two rewards."""
        code = self.get_code_by_id(code_id)
        if not code or not code["active"] or code["kind"] != "friend" \
                or str(code["referrer_user_id"]) != str(owner_id):
            self.conn.rollback()
            return
        norm = normalize_email(self._user_email(invitee_id))
        owner_norm = normalize_email(self._user_email(owner_id))
        if str(owner_id) == str(invitee_id) or not norm or norm == owner_norm:
            self.audit_event("reward_denied_self_referral", owner=owner_id, code=code_id, detail="ios_offer")
            return
        outcome, _rid = self._earn(
            owner_id=owner_id, source="signup", code_id=code_id, code=code["code"],
            idem=f"signup:{invitee_id}", invitee_id=invitee_id, email_hash=_hash(norm), ip_hash=ip_hash)
        if outcome == "earned":
            self.apply_stripe_reward(owner_id)


# ── Entry points used by routes ──────────────────────────────────────────────

def reconcile_offer_code(user_id: str | None, payload: dict) -> None:
    """Hook for a verified Apple transaction payload (apple/sync and notifications).
    Acts only on offerType 3 carrying OUR offer's reference name for the
    individual product. Infrastructure errors PROPAGATE (notification route 500s
    so Apple retries; /apple/sync catches and logs, the app re-syncs on launch)."""
    if not user_id or not offer_codes_enabled():
        return
    cfg = offer_codes_config()
    if payload.get("offerType") != OFFER_TYPE_OFFER_CODE or payload.get("offerIdentifier") != cfg.reference_name:
        return
    if apple_service.member_count_for(payload.get("productId", "")) != 1:
        return
    txn = str(payload.get("transactionId") or "")
    if not txn:
        return
    db = OfferCodeManager()
    try:
        db.finalize_redeemed(str(user_id), txn)
    finally:
        db.close()
