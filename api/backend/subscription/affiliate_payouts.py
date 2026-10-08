"""Affiliate payout details storage (task 20261008-affiliate-payout-details).

US / USD bank details an affiliate gives us for MANUAL payout. Nothing here moves
money. Rules this module enforces (see the task's security.json threat model):

* Routing number, account number, holder name and account type are AES-256-GCM
  encrypted per field (``payout_crypto``); only the two last-4 strings are stored
  in the clear. ``masked_view`` is the ONLY shape ever returned to an affiliate.
* The affiliate is the lowercased creator-code owner email resolved by the route
  from the session (``AffiliateManager.resolve_affiliate``); nothing client-side
  names the subject.
* Writes need a fresh re-auth proof: a random token whose sha256 is stored, bound
  to (user_id, purpose), single use, short TTL, consumed atomically in the same
  transaction as the write. The emailed code is a dedicated, purpose-separated
  secret with its own per-code attempt cap and a per-user lockout.
* Nothing in this module logs, formats or raises with a submitted/stored value.
  Log lines carry the subject id and an outcome code only. Plaintext holders are
  the ``_Plain`` wrapper below, whose repr is redacted.
* The audit table never holds values (not even last-4).
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import re
import secrets
import unicodedata
import uuid

import psycopg2 as sql

from db import DBManager
from backend.auth.passwords import verify_password
from backend.subscription import payout_crypto
from backend.subscription.affiliates_config import PayoutsConfig

logger = logging.getLogger(__name__)

PURPOSE_WRITE = "payout_write"
PURPOSE_REVEAL = "payout_admin_reveal"
ACCOUNT_TYPES = ("checking", "savings")
FIELDS = ("routing", "account", "holder", "type")

_ROUTING_RE = re.compile(r"[0-9]{9}")
_ACCOUNT_RE = re.compile(r"[0-9]{4,17}")
_NAME_OK = re.compile(r"[ '\-.]")
_CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")
_REQUIRED = frozenset({"routing_number", "account_number", "account_type", "holder_name"})


class PayoutError(Exception):
    """Carries a fixed, value-free ``code`` (never user input)."""

    def __init__(self, code: str, status: int = 400):
        super().__init__(code)
        self.code = code
        self.status = status


class _Plain:
    """Holds decrypted/submitted plaintext; repr/str are redacted."""
    __slots__ = ("v",)

    def __init__(self, v: str):
        self.v = v

    def __repr__(self) -> str:  # pragma: no cover - trivial
        return "<redacted>"

    __str__ = __repr__


# -- validation (server side is authoritative) -------------------------------

def valid_routing(s) -> bool:
    if not isinstance(s, str) or not _ROUTING_RE.fullmatch(s):
        return False
    d = [int(c) for c in s]
    return (3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])) % 10 == 0


def valid_account(s) -> bool:
    return isinstance(s, str) and bool(_ACCOUNT_RE.fullmatch(s))


def normalize_holder(s) -> str | None:
    if not isinstance(s, str):
        return None
    n = unicodedata.normalize("NFC", s).strip()
    n = re.sub(r" {2,}", " ", n)
    if not 2 <= len(n) <= 100 or _CTRL_RE.search(n):
        return None
    for ch in n:
        cat = unicodedata.category(ch)
        if not (cat[0] in ("L", "M") or _NAME_OK.fullmatch(ch)):
            return None
    return n


def validate_fields(body: dict) -> dict:
    """Return the cleaned fields or raise ``PayoutError('invalid_<field>')``."""
    if set(body) != _REQUIRED:
        raise PayoutError("invalid_request")
    routing, account = body.get("routing_number"), body.get("account_number")
    if not valid_routing(routing):
        raise PayoutError("invalid_routing_number")
    if not valid_account(account):
        raise PayoutError("invalid_account_number")
    if body.get("account_type") not in ACCOUNT_TYPES:
        raise PayoutError("invalid_account_type")
    holder = normalize_holder(body.get("holder_name"))
    if holder is None:
        raise PayoutError("invalid_holder_name")
    return {"routing": routing, "account": account, "type": body["account_type"], "holder": holder}


# -- masking: the single place a display form is produced -------------------

def mask_name(name: str) -> str:
    return " ".join((w[0] + "•••") if w else "" for w in name.split(" "))


def masked_view(last: dict | None) -> dict:
    """``last`` is None when nothing is stored. Never contains a full number."""
    if last is None:
        return {"status": "not_set"}
    return {
        "status": "set",
        "routing_last4": last["routing_last4"],
        "account_last4": last["account_last4"],
        "account_type": last["account_type"],
        "holder_name_masked": last["holder_masked"],
        "updated_at": last["updated_at"].isoformat() if last["updated_at"] else None,
    }


def _h(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def clean_ua(ua: str | None) -> str:
    return _CTRL_RE.sub("", (ua or ""))[:200]


class PayoutManager(DBManager):
    def __init__(self, cfg: PayoutsConfig):
        super().__init__()
        self.cfg = cfg

    # -- audit (always value-free) -------------------------------------------
    def audit(self, event: str, actor_id: str | None, subject: str | None,
              ip: str | None = None, ua: str | None = None, reason: str | None = None,
              commit: bool = True) -> None:
        self.cur.execute(
            "INSERT INTO affiliate_payout_audit (event_type, actor_id, subject, ip, user_agent, reason) "
            "VALUES (%s,%s,%s,%s,%s,%s)",
            (event, actor_id, subject, (ip or "")[:64], clean_ua(ua), (reason or None)))
        if commit:
            self.conn.commit()

    # -- re-auth ---------------------------------------------------------------
    def _locked(self, user_id: str) -> bool:
        self.cur.execute(
            "SELECT COUNT(*) FROM affiliate_payout_audit WHERE actor_id = %s AND event_type = 'reauth_failed' "
            "AND created_at > NOW() - make_interval(mins => %s)", (user_id, self.cfg.lockout_minutes))
        return self.cur.fetchone()[0] >= self.cfg.lockout_failures

    def user_account(self, user_id: str) -> tuple[str, bool]:
        """(account email, has_password) for the session user."""
        self.cur.execute("SELECT email, hash_pass FROM users WHERE _id = %s", (user_id,))
        row = self.cur.fetchone()
        if not row:
            raise PayoutError("forbidden", 403)
        return row[0], bool((row[1] or "").strip())

    def issue_code(self, user_id: str, purpose: str) -> str:
        """Create a fresh emailed code (older unverified ones are voided). Raises
        ``PayoutError('rate_limited', 429)`` over the hourly cap or during lockout."""
        if self._locked(user_id):
            raise PayoutError("locked", 429)
        self.cur.execute(
            "SELECT COUNT(*) FROM affiliate_payout_proofs WHERE user_id = %s AND purpose = %s "
            "AND created_at > NOW() - INTERVAL '1 hour'", (user_id, purpose))
        if self.cur.fetchone()[0] >= self.cfg.code_issues_per_hour:
            raise PayoutError("rate_limited", 429)
        self.cur.execute(
            "UPDATE affiliate_payout_proofs SET used = TRUE WHERE user_id = %s AND purpose = %s AND NOT used",
            (user_id, purpose))
        code = f"{secrets.randbelow(1_000_000):06d}"
        self.cur.execute(
            "INSERT INTO affiliate_payout_proofs (user_id, purpose, code_hash, code_expires_at) "
            "VALUES (%s,%s,%s, NOW() + make_interval(secs => %s))",
            (user_id, purpose, _h(code), self.cfg.code_ttl_seconds))
        self.conn.commit()
        return code

    def verify_reauth(self, user_id: str, purpose: str, code, password, ip: str, ua: str) -> str:
        """Check the emailed code (+ password when the account has one) and mint a
        single-use proof token. Every failure is the same ``reauth_failed``."""
        if self._locked(user_id):
            raise PayoutError("locked", 429)
        _, has_pw = self.user_account(user_id)
        ok = isinstance(code, str) and re.fullmatch(r"[0-9]{6}", code) is not None
        # Newest live code row; its attempt counter is bumped (and committed)
        # BEFORE the comparison so a crash can never grant a free guess.
        self.cur.execute(
            "SELECT id, code_hash FROM affiliate_payout_proofs WHERE user_id = %s AND purpose = %s "
            "AND NOT used AND token_hash IS NULL AND code_expires_at > NOW() AND attempts < %s "
            "ORDER BY created_at DESC LIMIT 1 FOR UPDATE", (user_id, purpose, self.cfg.max_code_attempts))
        row = self.cur.fetchone()
        if row:
            self.cur.execute("UPDATE affiliate_payout_proofs SET attempts = attempts + 1 WHERE id = %s", (row[0],))
        self.conn.commit()
        code_ok = bool(row) and ok and hmac.compare_digest(_h(code), row[1])
        pw_ok = True
        if has_pw:
            self.cur.execute("SELECT hash_pass FROM users WHERE _id = %s", (user_id,))
            stored = self.cur.fetchone()[0]
            pw_ok = isinstance(password, str) and 0 < len(password) <= 256 and verify_password(password, stored)
        if not (code_ok and pw_ok):
            self.audit("reauth_failed", user_id, None, ip, ua)
            raise PayoutError("reauth_failed", 403)
        token = secrets.token_urlsafe(32)
        self.cur.execute(
            "UPDATE affiliate_payout_proofs SET token_hash = %s, "
            "proof_expires_at = NOW() + make_interval(secs => %s) WHERE id = %s AND token_hash IS NULL AND NOT used",
            (_h(token), self.cfg.proof_ttl_seconds, row[0]))
        if self.cur.rowcount != 1:
            self.conn.rollback()
            raise PayoutError("reauth_failed", 403)
        self.conn.commit()
        return token

    def _consume_proof(self, user_id: str, purpose: str, token) -> None:
        """Atomic single-use consume; caller commits (or rolls back) with its write."""
        if not isinstance(token, str) or not 20 <= len(token) <= 128:
            raise PayoutError("reauth_required", 403)
        self.cur.execute(
            "UPDATE affiliate_payout_proofs SET used = TRUE WHERE user_id = %s AND purpose = %s "
            "AND token_hash = %s AND NOT used AND proof_expires_at > NOW() RETURNING id",
            (user_id, purpose, _h(token)))
        if self.cur.fetchone() is None:
            self.conn.rollback()
            raise PayoutError("reauth_required", 403)

    # -- details ---------------------------------------------------------------
    def _decode_row(self, row) -> dict:
        row_id, routing_last4, account_last4, type_enc, holder_enc, updated_at = row
        rid = str(row_id)
        holder = _Plain(payout_crypto.decrypt(holder_enc, rid, "holder"))
        return {"routing_last4": routing_last4, "account_last4": account_last4,
                "account_type": payout_crypto.decrypt(type_enc, rid, "type"),
                "holder_masked": mask_name(holder.v), "updated_at": updated_at}

    def get_view(self, owner_email: str) -> dict:
        self.cur.execute(
            "SELECT row_id, routing_last4, account_last4, type_enc, holder_enc, updated_at "
            "FROM affiliate_payout_details WHERE owner_email = %s", (owner_email,))
        row = self.cur.fetchone()
        if row is None:
            return masked_view(None)
        try:
            return masked_view(self._decode_row(row))
        except payout_crypto.PayoutDecryptError:
            logger.error("payout details undecryptable subject_hash=%s", _h(owner_email)[:12])
            raise PayoutError("unavailable", 503) from None

    def save(self, user_id: str, owner_email: str, proof, body: dict, ip: str, ua: str) -> bool:
        """Create or replace. Returns True when it was an update."""
        f = validate_fields(body)
        try:
            self._consume_proof(user_id, PURPOSE_WRITE, proof)
            self.cur.execute("SELECT row_id FROM affiliate_payout_details WHERE owner_email = %s FOR UPDATE",
                             (owner_email,))
            existing = self.cur.fetchone()
            rid = str(existing[0]) if existing else str(uuid.uuid4())
            enc = {k: payout_crypto.encrypt(f[k], rid, k) for k in FIELDS}
            self.cur.execute(
                "INSERT INTO affiliate_payout_details (owner_email, row_id, routing_enc, account_enc, holder_enc, "
                "type_enc, routing_last4, account_last4) VALUES (%s,%s,%s,%s,%s,%s,%s,%s) "
                "ON CONFLICT (owner_email) DO UPDATE SET routing_enc = EXCLUDED.routing_enc, "
                "account_enc = EXCLUDED.account_enc, holder_enc = EXCLUDED.holder_enc, type_enc = EXCLUDED.type_enc, "
                "routing_last4 = EXCLUDED.routing_last4, account_last4 = EXCLUDED.account_last4, updated_at = NOW()",
                (owner_email, rid, enc["routing"], enc["account"], enc["holder"], enc["type"],
                 f["routing"][-4:], f["account"][-4:]))
            self.audit("update" if existing else "create", user_id, owner_email, ip, ua, commit=False)
            self.conn.commit()
            return bool(existing)
        except PayoutError:
            raise
        except (sql.Error, payout_crypto.PayoutKeyConfigError):
            self.conn.rollback()
            logger.error("payout save failed (%s)", "db")
            raise PayoutError("save_failed", 500) from None

    def delete(self, user_id: str, owner_email: str, proof, ip: str, ua: str) -> bool:
        try:
            self._consume_proof(user_id, PURPOSE_WRITE, proof)
            self.cur.execute("DELETE FROM affiliate_payout_details WHERE owner_email = %s", (owner_email,))
            deleted = self.cur.rowcount > 0
            if deleted:
                self.audit("delete", user_id, owner_email, ip, ua, commit=False)
            self.conn.commit()
            return deleted
        except PayoutError:
            raise
        except sql.Error:
            self.conn.rollback()
            logger.error("payout delete failed (%s)", "db")
            raise PayoutError("delete_failed", 500) from None

    # -- admin ---------------------------------------------------------------
    def admin_list(self) -> list[dict]:
        self.cur.execute(
            "SELECT owner_email, routing_last4, account_last4, updated_at FROM affiliate_payout_details "
            "ORDER BY updated_at DESC LIMIT 500")
        return [{"owner_email": r[0], "routing_last4": r[1], "account_last4": r[2],
                 "updated_at": r[3].isoformat()} for r in self.cur.fetchall()]

    def reveals_last_hour(self, admin_id: str) -> int:
        self.cur.execute(
            "SELECT COUNT(*) FROM affiliate_payout_audit WHERE actor_id = %s AND event_type = 'reveal' "
            "AND created_at > NOW() - INTERVAL '1 hour'", (admin_id,))
        return self.cur.fetchone()[0]

    def reveal(self, admin_id: str, subject: str, proof, reason: str, ip: str, ua: str) -> dict | None:
        """Decrypted details for one record. The audit row is committed BEFORE any
        decryption (fail closed: an audit failure means no reveal). Returns None
        when the record does not exist (the proof is still consumed)."""
        if self.reveals_last_hour(admin_id) >= self.cfg.reveal_per_hour:
            raise PayoutError("rate_limited", 429)
        try:
            self._consume_proof(admin_id, PURPOSE_REVEAL, proof)
            self.audit("reveal", admin_id, subject, ip, ua, reason, commit=False)
            self.conn.commit()
        except PayoutError:
            raise
        except sql.Error:
            self.conn.rollback()
            logger.error("payout reveal audit failed (%s)", "db")
            raise PayoutError("reveal_failed", 500) from None
        self.cur.execute(
            "SELECT row_id, routing_enc, account_enc, holder_enc, type_enc FROM affiliate_payout_details "
            "WHERE owner_email = %s", (subject,))
        row = self.cur.fetchone()
        if row is None:
            return None
        rid = str(row[0])
        try:
            out = {"routing_number": payout_crypto.decrypt(row[1], rid, "routing"),
                   "account_number": payout_crypto.decrypt(row[2], rid, "account"),
                   "holder_name": payout_crypto.decrypt(row[3], rid, "holder"),
                   "account_type": payout_crypto.decrypt(row[4], rid, "type")}
        except payout_crypto.PayoutDecryptError:
            raise PayoutError("unavailable", 503) from None
        return out

    # -- retention -----------------------------------------------------------
    def purge(self) -> int:
        """Hard-delete details that are inactive for ``retention_inactive_days``,
        or whose owner no longer has an active creator code / user account.
        One value-free audit row per purged affiliate. Returns the count."""
        self.cur.execute(
            "DELETE FROM affiliate_payout_details d WHERE d.updated_at < NOW() - make_interval(days => %s) "
            "OR NOT EXISTS (SELECT 1 FROM users u WHERE LOWER(u.email) = d.owner_email) "
            "OR NOT EXISTS (SELECT 1 FROM promo_codes p JOIN creators c ON c._id = p.creator_id "
            "  WHERE p.kind = 'creator' AND p.deleted_at IS NULL AND p.active AND c.active "
            "  AND LOWER(p.owner_email) = d.owner_email) "
            "RETURNING d.owner_email", (self.cfg.retention_inactive_days,))
        subjects = [r[0] for r in self.cur.fetchall()]
        for s in subjects:
            self.audit("retention_purge", None, s, commit=False)
        self.conn.commit()
        return len(subjects)

    def purge_proofs(self) -> None:
        self.cur.execute("DELETE FROM affiliate_payout_proofs WHERE created_at < NOW() - INTERVAL '1 day'")
        self.conn.commit()
