"""iOS friend-invite redemption through Apple OFFER CODES (task
20261003-ios-friend-offer-code-redeem).

Apple promotional offers only work for current/lapsed subscribers, so a brand-new
iOS subscriber cannot get a first-month discount that way. Offer codes can target
"new subscribers". Flow:

1. The app posts the friend code it was given to ``POST /promo/{user_id}/ios-offer-code``.
2. The server re-validates under every rule (``PromoManager.evaluate``: code
   exists/active/unexpired/under cap, not the caller's own, caller is a new
   subscriber; plus friend-kind only, per-IP and global daily caps, outstanding
   cap) and ONLY THEN hands out ONE code from a POOL.
3. Apple only allows one-time-use batches of 500-25,000 codes, so a batch of
   ``IOS_OFFER_CODE_BATCH_SIZE`` codes is created (the one ASC write) only when no
   usable batch exists. Per issuance the server atomically reserves the next index
   of the batch (``ios_offer_batches.next_index``), reads the batch values from ASC
   (generated asynchronously; "not ready" fails closed) and returns the code at that
   index plus a redeem URL. The app opens Apple's redeem sheet. Apple enforces
   new-subscriber eligibility again on its side.
4. When Apple's verified transaction arrives (``/subscriptions/apple/sync`` or an
   App Store notification) carrying ``offerType == 3`` and our offer's reference
   name, the redemption row for THAT user is marked redeemed, a ``promo_redemptions``
   row is logged and the friend-code owner's reward is credited. Never at issue time.

Everything fails closed: any validator/ASC error, ambiguity, pool exhaustion, a
batch inside the expiry safety margin, or values not ready denies with a 503 and an
operator-visible ``promo_audit_log`` event; no code is ever fabricated. This module
NEVER creates or modifies an ASC offer (the offer is created by hand in App Store
Connect; ``check_offer`` is a read-only GET).

Idempotency: ``ios_offer_redemptions`` allows one live row per user and each row
owns one unique (batch, index). A retry re-reads the SAME index and never takes a
second one. A batch create whose outcome is unknown stays ``pending`` and blocks
another create for an hour. Code values are never stored or logged.

Config (env, no implicit defaults, validated eagerly by
``validate_offer_codes_config()`` from main.py's lifespan; flag deploys OFF):
    IOS_OFFER_CODES_ENABLED          'true' | 'false'  (requires PROMO_CODES_ENABLED and
                                     OWNER_REWARDS_ENABLED when 'true')
    IOS_OFFER_CODE_EXPIRY_DAYS       7-180, validity of a pool batch / its codes
    IOS_OFFER_CODE_RATE_LIMIT        slowapi string, per IP and per user
    IOS_OFFER_CODE_IP_DAILY_CAP      max issuances per hashed client IP per 24h
    IOS_OFFER_CODE_DAILY_MINT_CAP    max codes ISSUED in total per 24h
    IOS_OFFER_CODE_BATCH_SIZE        codes per pool batch, 500-25000 (Apple's limits)
    IOS_OFFER_CODE_DAILY_BATCH_CAP   max ASC batch creations per 24h
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
# Never hand out a code from a batch that expires within this margin (the user
# needs time to open the redeem sheet) and don't pile a new batch request on a
# pending one whose outcome is unknown for this long.
_EXPIRY_SAFETY_MARGIN = timedelta(days=3)
_PENDING_BATCH_BLOCK = timedelta(hours=1)
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
    batch_size: int
    daily_batch_cap: int
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
    expiry_days = _req_int("IOS_OFFER_CODE_EXPIRY_DAYS", 7, 180)
    rl = _req("IOS_OFFER_CODE_RATE_LIMIT")
    try:
        from limits import parse
        parse(rl)
    except Exception:
        raise OfferCodesConfigError(f"IOS_OFFER_CODE_RATE_LIMIT ({rl!r}) is not a valid rate-limit string.")
    ip_cap = _req_int("IOS_OFFER_CODE_IP_DAILY_CAP", 1)
    mint_cap = _req_int("IOS_OFFER_CODE_DAILY_MINT_CAP", 1)
    batch_size = _req_int("IOS_OFFER_CODE_BATCH_SIZE", 500, 25000)   # Apple's batch limits
    batch_cap = _req_int("IOS_OFFER_CODE_DAILY_BATCH_CAP", 1)
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
    _config = OfferCodesConfig(enabled, expiry_days, rl, ip_cap, mint_cap, batch_size, batch_cap, key_id, issuer, key_path,
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
    is creating a one-time-use code batch (pool) against the configured offer; it never
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

    def create_one_time_use_batch(self, number_of_codes: int, expiration_date: str) -> str:
        """Create ONE pool batch. Apple requires 500-25,000 codes per batch."""
        body = {"data": {
            "type": "subscriptionOfferCodeOneTimeUseCodes",
            "attributes": {"numberOfCodes": number_of_codes, "expirationDate": expiration_date},
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

    def fetch_values(self, batch_id: str) -> list[str]:
        """All code values of a batch, de-duplicated and SORTED (so an index is
        stable across fetches regardless of CSV order). ASC generates values
        asynchronously: no usable values raises AscAmbiguous (not ready)."""
        if not _ASC_ID_RE.match(batch_id or ""):
            raise AscAmbiguous("bad batch id")
        resp = self._send("GET", f"/v1/subscriptionOfferCodeOneTimeUseCodes/{batch_id}/values")
        values = set()
        for row in csv.reader(io.StringIO(resp.text)):
            for cell in row:
                cell = cell.strip()
                if cell and _CODE_VALUE_RE.match(cell):
                    values.add(cell)
        if not values:
            raise AscAmbiguous("codes not ready")
        return sorted(values)


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
    """DB access for the offer-code pool (ios_offer_batches) and the per-user
    ledger (ios_offer_redemptions). Inherits RewardManager (promo
    evaluate/log_redemption, reward ``_earn``, audit)."""

    def _lock(self, key: str) -> None:
        self.cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (key,))

    def _email(self, user_id: str) -> str:
        return self._user_email(user_id)

    def _audit_safe(self, action: str, user_id: str | None, detail: str | None) -> None:
        try:
            self.conn.rollback()
            self._audit(action, actor=user_id, detail=detail)
            self.conn.commit()
        except Exception:
            self.conn.rollback()

    # -- request path

    def request_code(self, user_id: str, raw_code, ip: str, client: AscOfferCodeClient | None = None) -> dict:
        """Validate fully, then issue (or re-read) the caller's one-time-use code.

        Raises OfferCodeDenied for every validation failure (no ASC call made) and
        OfferCodeUnavailable when validation passed but no code can be returned
        now. Returns ``{"offer_code", "redeem_url", "expires_at"}``.

        Stages (no network call ever runs while holding a lock):
        1. validate + read-only offer preflight; if the user already holds an
           issued index, re-read that SAME index's code (idempotent retry).
        2. make sure a usable, ready pool batch exists (create one only if none).
        3. under locks, re-check, reserve the next index atomically and insert
           the user's row (unique per user and per (batch, index)).
        4. read the batch values from ASC and take the code at the reserved index.
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

            client = client or get_client()
            try:
                _preflight(client)
            except Exception as e:
                self.conn.rollback()
                logger.error("ios offer preflight failed (closed): %s",
                             e if isinstance(e, (AscRejected, AscAmbiguous)) else type(e).__name__)
                raise OfferCodeUnavailable()

            live = self._locked_checks(user_id, row, ip_hash, cfg)
            self.conn.rollback()      # release locks before any network call
        except (OfferCodeDenied, OfferCodeUnavailable):
            self.conn.rollback()
            raise
        except Exception as e:
            self.conn.rollback()
            logger.error("ios offer validation failed (denying): %s", type(e).__name__)
            raise OfferCodeDenied()
        if live is not None:
            return self._code_for(client, user_id, live)

        try:
            self._ensure_ready_batch(client, cfg, user_id)
        except OfferCodeUnavailable:
            raise
        except Exception as e:
            self.conn.rollback()
            logger.error("ios offer pool preparation failed (closed): %s", type(e).__name__)
            raise OfferCodeUnavailable()

        try:
            live = self._locked_checks(user_id, row, ip_hash, cfg)
            if live is not None:      # a concurrent request of the same user got there first
                self.conn.rollback()
            else:
                live = self._reserve(user_id, row, ip_hash)
        except OfferCodeUnavailable:
            self.conn.rollback()
            raise
        except OfferCodeDenied:
            self.conn.rollback()
            raise
        except Exception as e:
            self.conn.rollback()
            logger.error("ios offer reserve failed (closed): %s", type(e).__name__)
            raise OfferCodeUnavailable()
        return self._code_for(client, user_id, live)

    def _locked_checks(self, user_id: str, row: dict, ip_hash: str, cfg: OfferCodesConfig) -> dict | None:
        """Take the user and caps locks (left held; caller commits/rolls back) and
        evaluate the per-user ledger and caps. Returns the user's existing valid
        ``issued`` row (to re-read) or None when a fresh issuance may proceed.
        Raises OfferCodeDenied / OfferCodeUnavailable (after rolling back)."""
        self._lock("ios_offer_user:" + user_id)
        self.cur.execute(
            "SELECT r._id, r.status, r.expires_at, r.code_id, r.code_index, b.asc_batch_id "
            "FROM ios_offer_redemptions r LEFT JOIN ios_offer_batches b ON b._id = r.batch_id "
            "WHERE r.user_id=%s AND r.status IN ('pending','issued','redeemed') FOR UPDATE OF r", (user_id,))
        live = self.cur.fetchone()
        if live:
            rid, status, expires_at, live_code_id, code_index, asc_batch_id = (
                str(live[0]), live[1], live[2], str(live[3]) if live[3] else None, live[4], live[5])
            if status == "redeemed":
                self.conn.rollback()
                raise OfferCodeDenied()
            if status == "pending":
                # Legacy row from the abandoned single-code design: it never got
                # a code (Apple rejects 1-code batches), so close it.
                self.cur.execute("UPDATE ios_offer_redemptions SET status='failed' WHERE _id=%s", (rid,))
                self._audit("ios_offer_legacy_pending_closed", actor=user_id, detail=rid)
            elif expires_at and expires_at > datetime.now(timezone.utc) and asc_batch_id and code_index is not None:
                if live_code_id != row["id"]:
                    self.conn.rollback()
                    raise OfferCodeDenied()
                return {"rid": rid, "asc_batch_id": asc_batch_id, "code_index": code_index,
                        "expires_at": expires_at}
            else:
                self.cur.execute("UPDATE ios_offer_redemptions SET status='expired' WHERE _id=%s", (rid,))
                self._audit("ios_offer_expired", actor=user_id, detail=rid)

        # Caps, evaluated under one global lock so concurrent requests can't overshoot.
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
        # Cap on codes ISSUED (batch creations are capped separately).
        self.cur.execute(
            "SELECT COUNT(*) FROM ios_offer_redemptions WHERE status != 'failed' "
            "AND created_at > NOW() - INTERVAL '24 hours'")
        if self.cur.fetchone()[0] >= cfg.daily_mint_cap:
            self._audit("ios_offer_daily_capped", actor=user_id, code=row["id"])
            self.conn.commit()
            raise OfferCodeUnavailable()
        return None

    def _usable_batch(self, lock: bool, ready_only: bool) -> dict | None:
        self.cur.execute(
            "SELECT _id, asc_batch_id, number_of_codes, next_index, expires_at, ready_at FROM ios_offer_batches "
            "WHERE status='active' AND next_index < number_of_codes AND expires_at > NOW() + %s"
            + (" AND ready_at IS NOT NULL" if ready_only else "")
            + " ORDER BY (ready_at IS NULL), created_at LIMIT 1" + (" FOR UPDATE" if lock else ""),
            (_EXPIRY_SAFETY_MARGIN,))
        r = self.cur.fetchone()
        if not r:
            return None
        return {"id": str(r[0]), "asc_batch_id": r[1], "n": r[2], "next_index": r[3],
                "expires_at": r[4], "ready_at": r[5]}

    def _ensure_ready_batch(self, client: AscOfferCodeClient, cfg: OfferCodesConfig, user_id: str) -> None:
        """Guarantee a usable batch whose values ASC has finished generating.
        Creates a batch only when no usable one exists; not-ready, exhaustion,
        cap and ASC errors all fail closed (OfferCodeUnavailable) with an audit."""
        batch = self._usable_batch(lock=False, ready_only=False)
        self.conn.rollback()
        if batch is None:
            batch = self._create_batch(client, cfg, user_id)
        if batch["ready_at"] is not None:
            return
        try:
            values = client.fetch_values(batch["asc_batch_id"])
            if len(values) != batch["n"]:
                raise AscAmbiguous("values incomplete")
        except Exception as e:
            logger.error("ios offer batch values not ready (closed): %s",
                         e if isinstance(e, (AscRejected, AscAmbiguous)) else type(e).__name__)
            self._audit_safe("ios_offer_pool_not_ready", user_id, batch["id"])
            raise OfferCodeUnavailable()
        self.cur.execute("UPDATE ios_offer_batches SET ready_at=NOW() WHERE _id=%s AND ready_at IS NULL",
                         (batch["id"],))
        self.conn.commit()

    def _create_batch(self, client: AscOfferCodeClient, cfg: OfferCodesConfig, user_id: str) -> dict:
        """Create ONE pool batch at ASC (the only write to ASC). The row is
        committed ``pending`` BEFORE the call so an ambiguous outcome is never
        blindly retried and every attempt counts against the daily batch cap."""
        self._lock("ios_offer_batch")
        existing = self._usable_batch(lock=False, ready_only=False)
        if existing:
            self.conn.rollback()
            return existing
        self.cur.execute("SELECT 1 FROM ios_offer_batches WHERE status='pending' AND created_at > NOW() - %s LIMIT 1",
                         (_PENDING_BATCH_BLOCK,))
        if self.cur.fetchone():
            self._audit("ios_offer_batch_pending_blocked", actor=user_id)
            self.conn.commit()
            raise OfferCodeUnavailable()
        # The creator activates its batch without holding the batch lock, so it
        # can flip pending->active between the two checks above; re-check.
        existing = self._usable_batch(lock=False, ready_only=False)
        if existing:
            self.conn.rollback()
            return existing
        self.cur.execute("SELECT COUNT(*) FROM ios_offer_batches WHERE created_at > NOW() - INTERVAL '24 hours'")
        if self.cur.fetchone()[0] >= cfg.daily_batch_cap:
            self._audit("ios_offer_batch_capped", actor=user_id)
            self.conn.commit()
            raise OfferCodeUnavailable()
        expires_on = (datetime.now(timezone.utc) + timedelta(days=cfg.expiry_days)).date()
        expires_at = datetime(expires_on.year, expires_on.month, expires_on.day, 23, 59, 59, tzinfo=timezone.utc)
        self.cur.execute(
            "INSERT INTO ios_offer_batches (number_of_codes, expires_at) VALUES (%s,%s) RETURNING _id",
            (cfg.batch_size, expires_at))
        bid = str(self.cur.fetchone()[0])
        self._audit("ios_offer_batch_reserved", actor=user_id, detail=bid)
        self.conn.commit()      # releases the batch lock before the network call

        try:
            asc_id = client.create_one_time_use_batch(cfg.batch_size, expires_on.isoformat())
        except AscRejected as e:
            logger.error("ASC rejected offer-code batch: %s", e)
            self.cur.execute("UPDATE ios_offer_batches SET status='failed' WHERE _id=%s AND status='pending'", (bid,))
            self._audit("ios_offer_batch_failed", actor=user_id, detail=bid)
            self.conn.commit()
            raise OfferCodeUnavailable()
        except Exception as e:
            logger.error("ASC offer-code batch outcome unknown (row left pending): %s", e)
            self._audit_safe("ios_offer_batch_ambiguous", user_id, bid)
            raise OfferCodeUnavailable()
        try:
            self.cur.execute("UPDATE ios_offer_batches SET status='active', asc_batch_id=%s "
                             "WHERE _id=%s AND status='pending'", (asc_id, bid))
            self._audit("ios_offer_batch_created", actor=user_id, detail=bid)
            self.conn.commit()
        except Exception as e:
            self.conn.rollback()
            logger.error("ios offer batch %s could not be recorded (left pending): %s", bid, type(e).__name__)
            raise OfferCodeUnavailable()
        return {"id": bid, "asc_batch_id": asc_id, "n": cfg.batch_size, "next_index": 0,
                "expires_at": expires_at, "ready_at": None}

    def _reserve(self, user_id: str, row: dict, ip_hash: str) -> dict:
        """Atomically take the next index of a ready batch and record it on the
        user's row, in the caller's open transaction (locks already held)."""
        self._lock("ios_offer_pool")
        batch = self._usable_batch(lock=True, ready_only=True)
        if batch is None:
            self._audit("ios_offer_pool_exhausted", actor=user_id)
            self.conn.commit()
            raise OfferCodeUnavailable()
        index = batch["next_index"]
        self.cur.execute("UPDATE ios_offer_batches SET next_index = next_index + 1 WHERE _id=%s", (batch["id"],))
        self.cur.execute(
            "INSERT INTO ios_offer_redemptions (user_id, code_id, referrer_user_id, ip_hash, status, "
            "batch_id, code_index, asc_batch_id, expires_at, issued_at) "
            "VALUES (%s,%s,%s,%s,'issued',%s,%s,%s,%s,NOW()) RETURNING _id",
            (user_id, row["id"], row["referrer_user_id"], ip_hash, batch["id"], index,
             batch["asc_batch_id"], batch["expires_at"]))
        rid = str(self.cur.fetchone()[0])
        self._audit("ios_offer_issued", actor=user_id, code=row["id"], detail=rid)
        self.conn.commit()
        return {"rid": rid, "asc_batch_id": batch["asc_batch_id"], "code_index": index,
                "expires_at": batch["expires_at"]}

    def _code_for(self, client: AscOfferCodeClient, user_id: str, live: dict) -> dict:
        """Read the batch values from ASC and return the code at the user's
        reserved index (deterministic: values are sorted). Not ready / short /
        any ASC error fails closed; the reservation stays, so a retry gets the
        same index."""
        try:
            values = client.fetch_values(live["asc_batch_id"])
            code = values[live["code_index"]]
        except Exception as e:
            logger.error("ios offer code not available yet (closed): %s",
                         e if isinstance(e, (AscRejected, AscAmbiguous)) else type(e).__name__)
            self._audit_safe("ios_offer_code_not_ready", user_id, live["rid"])
            raise OfferCodeUnavailable()
        expires_at = live["expires_at"]
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
