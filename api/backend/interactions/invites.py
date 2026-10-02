"""Shareable invite links (task 20260929-group-invite-links, phase 1).

A generic ``invites`` table (db.py) with a per-``kind`` handler registry, so
phase 2 (subscription-seat invites) plugs in by adding a handler -- no schema
change. Kinds: ``'group'`` (phase 1) and ``'subscription'`` (phase 2: a link
creates a pending join *request* for the plan owner to accept -- it never
grants membership by itself).

Security properties (see the intake spec's threat model):
  * Tokens are 256-bit CSPRNG (``secrets.token_urlsafe(32)``); only the
    SHA-256 hex digest is stored. The plaintext is returned exactly once, by
    ``create``; nothing else ever returns or logs it (logs carry the first 8
    hex chars of the hash as a reference).
  * ``preview`` reveals only group name/photo, inviter username, member count,
    and answers every not-currently-usable token (unknown, malformed, expired,
    revoked, exhausted, feature off) with the identical ``NOT_FOUND`` error.
  * ``redeem`` is atomic: the group row is locked, blocked-pair checks run
    against every current member, then a single
    ``UPDATE invites ... WHERE use_count < max_uses AND not expired/revoked
    RETURNING`` consumes a use and the member is appended -- all in one
    transaction, rolled back on any failure. An existing member is an
    idempotent success that consumes no use.
  * Fails closed: any unexpected condition raises; nothing defaults open.
"""
from __future__ import annotations

import hashlib
import logging
import re
import secrets
import uuid
from datetime import datetime, timedelta, timezone

from backend.interactions.attachments import generate_download_url
from backend.interactions.invites_config import get_invites_config
from db import DBManager
from backend.subscription.subscriptions import is_plan_lapsed, user_holds_other_paid_plan

logger = logging.getLogger(__name__)

TOKEN_BYTES = 32  # 256 bits
# Untrusted input is truncated before hashing so a huge body can't burn CPU.
MAX_TOKEN_INPUT_LEN = 128
_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")


class InviteError(Exception):
    """A client-actionable invite failure. ``code`` is a stable machine value
    the clients switch on; ``message`` is safe to show verbatim."""

    def __init__(self, code: str, status: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.status = status
        self.message = message

    def detail(self) -> dict:
        return {"code": self.code, "message": self.message}


def _not_found() -> InviteError:
    # One body for unknown/malformed/expired/revoked/exhausted/disabled on the
    # public preview path, and for unknown tokens on redeem.
    return InviteError("not_found", 404, "This invite link isn't valid anymore.")


def generate_token() -> str:
    return secrets.token_urlsafe(TOKEN_BYTES)


def hash_token(token: str) -> str:
    return hashlib.sha256(str(token)[:MAX_TOKEN_INPUT_LEN].encode("utf-8", "ignore")).hexdigest()


def is_well_formed_token(token: str) -> bool:
    return isinstance(token, str) and bool(_TOKEN_RE.match(token))


def _ref(token_hash: str) -> str:
    """Redacted reference safe for logs."""
    return token_hash[:8]


def _audit(event: str, **fields) -> None:
    parts = " ".join(f"{k}={v}" for k, v in fields.items())
    logger.info("INVITE_AUDIT event=%s %s", event, parts)


def audit(event: str, **fields) -> None:
    """Public audit hook (subscription accept/decline/request events reuse the
    INVITE_AUDIT line format). Callers must pass only ids/refs, never tokens."""
    _audit(event, **fields)


def _as_uuid(value: str) -> str | None:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, AttributeError):
        return None


# ── Per-kind handlers ─────────────────────────────────────────────────────────
#
# A handler adapts the generic create/list/revoke/preview/redeem machinery to
# one kind of target. "Target row" is whatever ``lock_target``/``read_target``
# return; only the handler interprets it. Interface:
#
#   limits(cfg)                          per-kind create tunables
#   lock_target(cur, tid) / read_target  row (locked FOR UPDATE / plain) or None
#   is_actor(row, uid)                   may uid create/list/reset links?
#   is_manager(row, uid)                 may uid see/revoke every link?
#   create_precheck(cur, row, tid)       raise InviteError if not linkable now
#   revoke_nonactor_error()              error for a non-actor revoking
#   existing_outcome(cur, uid, tid, row) (reason, result) no-op, or None
#   redeem_precheck(cur, uid, tid, row)  (reason, InviteError) rejection, or None
#   apply(cur, uid, tid) -> bool         perform the redeem effect; False = no-op
#   success_result                       redeem response fields when applied
#   preview(cur, tid, created_by)        public info dict, or None (not found)
#   purge(cur, tid)                      drop the target's invites

class _Limits:
    def __init__(self, default_days, allowed_days, default_uses, allowed_uses, max_active, limit_msg):
        self.default_days = default_days
        self.allowed_days = allowed_days
        self.default_uses = default_uses
        self.allowed_uses = allowed_uses
        self.max_active = max_active
        self.limit_msg = limit_msg


class GroupInviteHandler:
    """Kind ``'group'``: target_id is groups._id; redeeming appends the user
    to groups.users."""

    kind = "group"
    # Group links never expire (expires_at stored NULL); the group
    # expiry config keys are deprecated and ignored here.
    permanent = True
    forbidden_create_msg = "You can't create an invite link for this group."
    forbidden_msg = "Not a member of this group"
    success_result = {"joined": True, "already_member": False}

    def limits(self, cfg) -> _Limits:
        return _Limits(cfg.default_expiry_days, cfg.allowed_expiry_days, cfg.default_max_uses,
                       cfg.allowed_max_uses, cfg.max_active_links_per_user_per_group,
                       "You have too many active links for this group. Revoke one first.")

    def lock_target(self, cur, target_id: str):
        """Lock + return (title, users, creator_id, photo_key, max_members), or None."""
        cur.execute(
            "SELECT title, COALESCE(users, '{}'), creator_id, photo_key, max_members "
            "FROM groups WHERE _id = %s FOR UPDATE",
            (target_id,),
        )
        return cur.fetchone()

    def read_target(self, cur, target_id: str):
        cur.execute(
            "SELECT title, COALESCE(users, '{}'), creator_id, photo_key, max_members "
            "FROM groups WHERE _id = %s",
            (target_id,),
        )
        return cur.fetchone()

    def is_actor(self, row, user_id: str) -> bool:
        return user_id in row[1]

    def is_manager(self, row, user_id: str) -> bool:
        creator = row[2]
        return creator is not None and str(creator) == user_id

    def create_precheck(self, cur, row, target_id: str) -> None:
        return None

    def revoke_nonactor_error(self) -> InviteError:
        return InviteError("not_found", 404, "Invite not found.")

    def existing_outcome(self, cur, user_id: str, target_id: str, row):
        if user_id in row[1]:
            return "already_member", {"joined": False, "already_member": True}
        return None

    def redeem_precheck(self, cur, user_id: str, target_id: str, row):
        # Member cap (groups.max_members, NULL = unlimited). ``row`` was read
        # under the group row lock, so this is atomic with the append. Existing
        # members never reach here (existing_outcome returns first).
        if row[4] is not None and len(row[1]) >= row[4]:
            return "group_full", InviteError("group_full", 409, "This group is full.")
        if self.has_blocked_relationship(cur, user_id, target_id):
            return "blocked", InviteError("blocked", 403, "You can't join this group.")
        return None

    def has_blocked_relationship(self, cur, user_id: str, target_id: str) -> bool:
        """True if ``user_id`` is blocked-by / has blocked ANY current member."""
        cur.execute(
            "SELECT 1 FROM blocked_users b, groups g WHERE g._id = %s AND ("
            "(b.blocker_id = %s AND b.blocked_id::text = ANY(g.users)) OR "
            "(b.blocked_id = %s AND b.blocker_id::text = ANY(g.users))) LIMIT 1",
            (target_id, user_id, user_id),
        )
        return cur.fetchone() is not None

    def apply(self, cur, user_id: str, target_id: str) -> bool:
        cur.execute(
            "UPDATE groups SET users = array_append(COALESCE(users, '{}'), %s) "
            "WHERE _id = %s AND NOT (%s = ANY(COALESCE(users, '{}'))) "
            "AND (max_members IS NULL OR COALESCE(cardinality(users), 0) < max_members)",
            (user_id, target_id, user_id),
        )
        if cur.rowcount != 1:
            raise RuntimeError("group member append affected no row")
        return True

    def preview(self, cur, target_id: str, created_by: str) -> dict | None:
        cur.execute(
            "SELECT title, photo_key, COALESCE(users, '{}'), max_members FROM groups WHERE _id = %s",
            (target_id,),
        )
        row = cur.fetchone()
        if not row:
            return None
        title, photo_key, users, max_members = row
        if max_members is not None and len(users) >= max_members:
            return None  # full group: uniform not_found, and the cap isn't leaked
        inviter = None
        if str(created_by) in users:  # a departed inviter's name isn't shown
            cur.execute("SELECT username FROM users WHERE _id = %s", (created_by,))
            u = cur.fetchone()
            inviter = u[0] if u else None
        return {
            "kind": self.kind,
            "group_name": title,
            "photo_url": generate_download_url(photo_key),
            "inviter_username": inviter,
            "member_count": len(users),
        }

    def purge(self, cur, target_id: str) -> None:
        cur.execute("DELETE FROM invites WHERE kind = 'group' AND target_id = %s", (target_id,))


class SubscriptionInviteHandler:
    """Kind ``'subscription'``: target_id is subscriptions._id. Only the plan
    owner (subscriptions.user_id) may create/list/revoke/reset links, and only
    on an active group plan with more than one seat. Redeeming NEVER changes
    users.subscription_id: it inserts a pending ``subscription_request`` that
    the owner must accept (SubscriptionsManager.accept_request, which re-checks
    capacity under a row lock). Target row:
    (owner_id, plan_type, status, max_members, current_period_end)."""

    kind = "subscription"
    permanent = False
    forbidden_create_msg = "Only the plan owner can create invite links."
    forbidden_msg = "Only the plan owner can manage invite links."
    success_result = {"joined": False, "already_member": False, "requested": True, "pending": True}

    _COLS = "user_id, plan_type, status, max_members, current_period_end"

    def limits(self, cfg) -> _Limits:
        return _Limits(cfg.subscription_default_expiry_days, cfg.subscription_allowed_expiry_days,
                       cfg.subscription_default_max_uses, cfg.subscription_allowed_max_uses,
                       cfg.max_active_links_per_subscription,
                       "You have too many active links for this plan. Revoke one first.")

    def lock_target(self, cur, target_id: str):
        cur.execute(f"SELECT {self._COLS} FROM subscriptions WHERE _id = %s FOR UPDATE", (target_id,))
        return cur.fetchone()

    def read_target(self, cur, target_id: str):
        cur.execute(f"SELECT {self._COLS} FROM subscriptions WHERE _id = %s", (target_id,))
        return cur.fetchone()

    def is_actor(self, row, user_id: str) -> bool:
        return row[0] is not None and str(row[0]) == user_id

    is_manager = is_actor

    @staticmethod
    def _eligible(row) -> bool:
        """Active (non-lapsed) group plan with more than one seat."""
        _, plan_type, status, max_members, cpe = row
        return (
            plan_type == "group"
            and status in ("trialing", "active")
            and (max_members or 1) > 1
            and not is_plan_lapsed(cpe)
        )

    @staticmethod
    def _member_count(cur, target_id: str) -> int:
        cur.execute("SELECT COUNT(*) FROM users WHERE subscription_id = %s", (target_id,))
        return cur.fetchone()[0]

    def _joinable(self, cur, row, target_id: str) -> bool:
        return self._eligible(row) and self._member_count(cur, target_id) < (row[3] or 1)

    def create_precheck(self, cur, row, target_id: str) -> None:
        if not self._eligible(row):
            raise InviteError(
                "not_eligible", 409,
                "Invite links are only available on an active group plan with more than one seat.")

    def revoke_nonactor_error(self) -> InviteError:
        return InviteError("forbidden", 403, "Only the plan owner can manage invite links.")

    def existing_outcome(self, cur, user_id: str, target_id: str, row):
        cur.execute("SELECT subscription_id FROM users WHERE _id = %s", (user_id,))
        r = cur.fetchone()
        if r and r[0] and str(r[0]) == target_id:  # includes the owner
            return "already_member", {"joined": False, "already_member": True,
                                      "requested": False, "pending": False}
        cur.execute(
            "SELECT 1 FROM subscription_request WHERE subscription_id = %s AND from_user_id = %s",
            (target_id, user_id))
        if cur.fetchone():
            return "already_requested", {"joined": False, "already_member": False,
                                         "requested": False, "pending": True}
        return None

    def redeem_precheck(self, cur, user_id: str, target_id: str, row):
        # Plan not active/group/multi-seat, or no open seat: uniform not_found.
        if not self._joinable(cur, row, target_id):
            return "plan_unavailable", _not_found()
        if user_holds_other_paid_plan(cur, user_id, target_id):
            return "other_plan", InviteError(
                "other_plan", 409,
                "You're already on a paid plan. Leave it before asking to join another.")
        cur.execute(
            "SELECT 1 FROM blocked_users b JOIN users u ON u.subscription_id = %s "
            "WHERE (b.blocker_id = %s AND b.blocked_id = u._id) "
            "OR (b.blocked_id = %s AND b.blocker_id = u._id) LIMIT 1",
            (target_id, user_id, user_id),
        )
        if cur.fetchone() is not None:
            return "blocked", InviteError("blocked", 403, "You can't join this plan.")
        cur.execute("SELECT COUNT(*) FROM subscription_request WHERE subscription_id = %s", (target_id,))
        if cur.fetchone()[0] >= get_invites_config().max_pending_requests_per_subscription:
            return "pending_cap", _not_found()
        return None

    def apply(self, cur, user_id: str, target_id: str) -> bool:
        """Insert the pending request. False if a concurrent path already did."""
        cur.execute(
            "INSERT INTO subscription_request (subscription_id, from_user_id) VALUES (%s, %s) "
            "ON CONFLICT DO NOTHING",
            (target_id, user_id),
        )
        return cur.rowcount == 1

    def preview(self, cur, target_id: str, created_by: str) -> dict | None:
        row = self.read_target(cur, target_id)
        if not row or not self._joinable(cur, row, target_id):
            return None
        cur.execute("SELECT username FROM users WHERE _id = %s", (row[0],))
        u = cur.fetchone()
        return {"kind": self.kind, "inviter_username": u[0] if u else None, "plan_type": "group"}

    def purge(self, cur, target_id: str) -> None:
        cur.execute("DELETE FROM invites WHERE kind = 'subscription' AND target_id = %s", (target_id,))


HANDLERS = {h.kind: h for h in (GroupInviteHandler(), SubscriptionInviteHandler())}


def _handler(kind: str):
    h = HANDLERS.get(kind)
    if h is None:
        raise ValueError(f"unknown invite kind {kind!r}")
    return h


# ── Manager ───────────────────────────────────────────────────────────────────

class InvitesManager(DBManager):
    """All invite persistence for one authenticated (or, for preview,
    anonymous) caller. Routes must construct it, call one operation, and
    ``close()``. Every mutating operation commits or rolls back its own
    transaction."""

    def __init__(self, user_id: str | None = None) -> None:
        super().__init__()
        self.user_id = user_id

    # -- create ---------------------------------------------------------------
    def create(self, kind: str, target_id: str, expires_in_days: int | None,
               max_uses: int | None, ip: str = "-") -> dict:
        """Mint a new link. Returns the plaintext token exactly once.

        Raises:
            InviteError: forbidden (not an actor: group member / plan owner),
                not_eligible (subscription plan can't take links),
                bad_request (value not in the configured allowed set),
                link_limit (soft cap reached).
        """
        cfg = get_invites_config()
        handler = _handler(kind)
        lim = handler.limits(cfg)
        uses = lim.default_uses if max_uses is None else max_uses
        if handler.permanent:
            # Group links never expire; any client-sent expires_in_days
            # (old clients) is accepted and ignored.
            days = None
        else:
            days = lim.default_days if expires_in_days is None else expires_in_days
        if (days is not None and days not in lim.allowed_days) or uses not in lim.allowed_uses:
            raise InviteError("bad_request", 422, "That expiry or use limit isn't allowed.")
        tid = _as_uuid(target_id)
        if tid is None:
            raise InviteError("forbidden", 403, handler.forbidden_create_msg)
        token = generate_token()
        token_hash = hash_token(token)
        expires_at = None if days is None else datetime.now(timezone.utc) + timedelta(days=days)
        try:
            row = handler.lock_target(self.cur, tid)  # also serializes the cap check
            if not row or not handler.is_actor(row, self.user_id):
                raise InviteError("forbidden", 403, handler.forbidden_create_msg)
            handler.create_precheck(self.cur, row, tid)
            self.cur.execute(
                "SELECT COUNT(*) FROM invites WHERE kind = %s AND target_id = %s AND created_by = %s "
                "AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > NOW()) AND use_count < max_uses",
                (kind, tid, self.user_id),
            )
            if self.cur.fetchone()[0] >= lim.max_active:
                raise InviteError("link_limit", 409, lim.limit_msg)
            self.cur.execute(
                "INSERT INTO invites (token_hash, kind, target_id, created_by, expires_at, max_uses) "
                "VALUES (%s, %s, %s, %s, %s, %s) RETURNING _id, created_at",
                (token_hash, kind, tid, self.user_id, expires_at, uses),
            )
            invite_id, created_at = self.cur.fetchone()
            self.conn.commit()
        except BaseException:
            self.conn.rollback()
            raise
        _audit("create", invite=invite_id, ref=_ref(token_hash), kind=kind, target=tid,
               user=self.user_id, ip=ip, expires_at=expires_at.isoformat() if expires_at else "never", max_uses=uses)
        return {
            "invite_id": str(invite_id),
            "token": token,
            "url": f"{cfg.public_base_url}/join/{token}",
            "created_at": created_at.isoformat(),
            "expires_at": expires_at.isoformat() if expires_at else None,
            "max_uses": uses,
            "use_count": 0,
        }

    # -- list -----------------------------------------------------------------
    def list_active(self, kind: str, target_id: str) -> list[dict]:
        """Active links the caller may see: their own, or all if they manage
        the target (group creator / plan owner). Metadata only -- never a token.

        Raises:
            InviteError: forbidden (not an actor).
        """
        handler = _handler(kind)
        tid = _as_uuid(target_id)
        if tid is None:
            raise InviteError("forbidden", 403, handler.forbidden_msg)
        try:
            row = handler.read_target(self.cur, tid)
            if not row or not handler.is_actor(row, self.user_id):
                raise InviteError("forbidden", 403, handler.forbidden_msg)
            manager = handler.is_manager(row, self.user_id)
            self.cur.execute(
                "SELECT i._id, i.created_by, u.username, i.created_at, i.expires_at, i.max_uses, i.use_count "
                "FROM invites i JOIN users u ON u._id = i.created_by "
                "WHERE i.kind = %s AND i.target_id = %s AND i.revoked_at IS NULL "
                "AND (i.expires_at IS NULL OR i.expires_at > NOW()) AND i.use_count < i.max_uses "
                + ("" if manager else "AND i.created_by = %s ")
                + "ORDER BY i.created_at DESC",
                (kind, tid) if manager else (kind, tid, self.user_id),
            )
            rows = self.cur.fetchall()
            self.conn.rollback()  # read-only; release the snapshot
        except BaseException:
            self.conn.rollback()
            raise
        return [
            {
                "invite_id": str(r[0]),
                "created_by_username": r[2],
                "is_mine": str(r[1]) == self.user_id,
                "created_at": r[3].isoformat(),
                "expires_at": r[4].isoformat() if r[4] else None,
                "max_uses": r[5],
                "use_count": r[6],
                "remaining_uses": r[5] - r[6],
            }
            for r in rows
        ]

    # -- revoke ---------------------------------------------------------------
    def revoke(self, invite_id: str, ip: str = "-") -> None:
        """Revoke one link. Allowed for the link's creator or the target's
        manager, and only while still an actor. Idempotent.

        Raises:
            InviteError: not_found (unknown id; for groups also a non-member --
                indistinguishable), forbidden (known non-owner of a
                subscription, or a group member who is neither creator nor
                manager).
        """
        iid = _as_uuid(invite_id)
        if iid is None:
            raise InviteError("not_found", 404, "Invite not found.")
        try:
            self.cur.execute("SELECT kind, target_id, created_by, token_hash FROM invites WHERE _id = %s", (iid,))
            row = self.cur.fetchone()
            if not row:
                raise InviteError("not_found", 404, "Invite not found.")
            kind, target_id, created_by, token_hash = row
            handler = _handler(kind)
            target = handler.lock_target(self.cur, str(target_id))
            if not target:
                raise InviteError("not_found", 404, "Invite not found.")
            if not handler.is_actor(target, self.user_id):
                raise handler.revoke_nonactor_error()
            if str(created_by) != self.user_id and not handler.is_manager(target, self.user_id):
                raise InviteError("forbidden", 403, "You can't revoke this invite link.")
            self.cur.execute(
                "UPDATE invites SET revoked_at = NOW() WHERE _id = %s AND revoked_at IS NULL", (iid,))
            self.conn.commit()
        except BaseException:
            self.conn.rollback()
            raise
        _audit("revoke", invite=iid, ref=_ref(token_hash), kind=kind, target=target_id,
               user=self.user_id, ip=ip)

    def reset(self, kind: str, target_id: str, ip: str = "-") -> int:
        """Revoke every active link the caller is allowed to revoke for this
        target (all of them for the manager, else only their own).

        Returns:
            int: number of links revoked.

        Raises:
            InviteError: forbidden (not an actor).
        """
        handler = _handler(kind)
        tid = _as_uuid(target_id)
        if tid is None:
            raise InviteError("forbidden", 403, handler.forbidden_msg)
        try:
            row = handler.lock_target(self.cur, tid)
            if not row or not handler.is_actor(row, self.user_id):
                raise InviteError("forbidden", 403, handler.forbidden_msg)
            manager = handler.is_manager(row, self.user_id)
            self.cur.execute(
                "UPDATE invites SET revoked_at = NOW() WHERE kind = %s AND target_id = %s "
                "AND revoked_at IS NULL " + ("" if manager else "AND created_by = %s ")
                + "RETURNING _id",
                (kind, tid) if manager else (kind, tid, self.user_id),
            )
            count = len(self.cur.fetchall())
            self.conn.commit()
        except BaseException:
            self.conn.rollback()
            raise
        _audit("reset", kind=kind, target=tid, user=self.user_id, revoked=count, ip=ip)
        return count

    # -- preview --------------------------------------------------------------
    def preview(self, token: str, ip: str = "-") -> dict:
        """Minimal public info for a currently-usable token.

        Raises:
            InviteError: the uniform ``not_found`` for every unusable token.
        """
        token_hash = hash_token(token)
        try:
            self.cur.execute(
                "SELECT kind, target_id, created_by FROM invites WHERE token_hash = %s "
                "AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > NOW()) AND use_count < max_uses",
                (token_hash,),
            )
            row = self.cur.fetchone()
            info = None
            if row and row[0] in HANDLERS and is_well_formed_token(token):
                info = HANDLERS[row[0]].preview(self.cur, str(row[1]), str(row[2]))
            self.conn.rollback()
        except BaseException:
            self.conn.rollback()
            raise
        if info is None:
            _audit("preview_miss", ref=_ref(token_hash), ip=ip)
            raise _not_found()
        _audit("preview", ref=_ref(token_hash), ip=ip)
        return info

    # -- redeem ---------------------------------------------------------------
    def redeem(self, token: str, ip: str = "-") -> dict:
        """Redeem ``token`` as ``self.user_id``: a group link joins the group;
        a subscription link only files a pending join request.

        Returns:
            dict: ``{"kind", "target_id", "joined", "already_member"}`` plus,
                for subscriptions, ``"requested"`` (a new request was filed)
                and ``"pending"`` (a request is awaiting the owner).

        Raises:
            InviteError: not_found (unknown token / unusable target), expired,
                revoked, full, blocked (deliberately generic -- never says who
                blocked whom), other_plan (subscription only; caller's own state).
        """
        token_hash = hash_token(token)
        ref = _ref(token_hash)
        try:
            self.cur.execute(
                "SELECT _id, kind, target_id FROM invites WHERE token_hash = %s", (token_hash,))
            row = self.cur.fetchone()
            if not row or row[1] not in HANDLERS or not is_well_formed_token(token):
                self.conn.rollback()
                _audit("redeem_fail", reason="not_found", ref=ref, user=self.user_id, ip=ip)
                raise _not_found()
            invite_id, kind, target_id = str(row[0]), row[1], str(row[2])
            handler = HANDLERS[kind]

            # Lock the target first (consistent order: target, then invite).
            target = handler.lock_target(self.cur, target_id)
            if not target:
                self.conn.rollback()
                _audit("redeem_fail", reason="target_gone", ref=ref, user=self.user_id, ip=ip)
                raise _not_found()

            existing = handler.existing_outcome(self.cur, self.user_id, target_id, target)
            if existing is not None:
                reason, extra = existing
                self.conn.rollback()
                _audit("redeem_noop", reason=reason, invite=invite_id, ref=ref,
                       user=self.user_id, ip=ip)
                return {"kind": kind, "target_id": target_id, **extra}

            rejected = handler.redeem_precheck(self.cur, self.user_id, target_id, target)
            if rejected is not None:
                reason, err = rejected
                self.conn.rollback()
                _audit("redeem_fail", reason=reason, invite=invite_id, ref=ref,
                       user=self.user_id, ip=ip)
                raise err

            # The single atomic gate: expiry, revocation and max_uses are all
            # enforced by this one statement, so racing redeems of the last
            # use can only ever produce one winner.
            self.cur.execute(
                "UPDATE invites SET use_count = use_count + 1 WHERE _id = %s "
                "AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > NOW()) AND use_count < max_uses "
                "RETURNING use_count",
                (invite_id,),
            )
            if self.cur.fetchone() is None:
                self.cur.execute(
                    "SELECT revoked_at IS NOT NULL, COALESCE(expires_at <= NOW(), false), use_count >= max_uses "
                    "FROM invites WHERE _id = %s", (invite_id,))
                st = self.cur.fetchone()
                self.conn.rollback()
                if st is None:
                    reason, err = "not_found", _not_found()
                elif st[0]:
                    reason, err = "revoked", InviteError("revoked", 410, "This invite link was revoked.")
                elif st[1]:
                    reason, err = "expired", InviteError("expired", 410, "This invite link has expired.")
                elif st[2]:
                    reason, err = "full", InviteError("full", 409, "This invite link has reached its limit.")
                else:
                    reason, err = "not_found", _not_found()
                _audit("redeem_fail", reason=reason, invite=invite_id, ref=ref, user=self.user_id, ip=ip)
                raise err

            if not handler.apply(self.cur, self.user_id, target_id):
                # A concurrent path already produced the effect: no-op, and the
                # use consumed above is rolled back with it.
                self.conn.rollback()
                _audit("redeem_noop", reason="already_requested", invite=invite_id, ref=ref,
                       user=self.user_id, ip=ip)
                return {"kind": kind, "target_id": target_id, "joined": False, "already_member": False,
                        "requested": False, "pending": True}
            self.conn.commit()
        except InviteError:
            raise
        except BaseException:
            self.conn.rollback()
            raise
        _audit("redeem", invite=invite_id, ref=ref, kind=kind, target=target_id,
               user=self.user_id, ip=ip,
               outcome="requested" if kind == "subscription" else "joined")
        return {"kind": kind, "target_id": target_id, **handler.success_result}


def purge_target_invites(cur, kind: str, target_id: str) -> None:
    """Delete every invite for a deleted target (no FK, so callers that
    delete a target must call this in the same transaction/connection)."""
    _handler(kind).purge(cur, target_id)


def revoke_member_group_invites(cur, group_id: str, member_ids) -> int:
    """Revoke (``revoked_at = NOW()``, the same state ``revoke``/``reset`` use)
    every still-active kind='group' link for ``group_id`` created by any of
    ``member_ids``. Called when members leave or are removed, so a former
    member's permanent link can't outlive their membership (task
    20261002-revoke-leaving-member-invite-links).

    Runs on the caller's cursor and does NOT commit: the caller must already
    hold the groups row lock (the same lock redeem takes first -- order is
    always group row, then invite rows) and commits the membership change and
    this revoke together, so a failure here rolls back the membership change
    (fail closed). Idempotent: only rows with ``revoked_at IS NULL`` match.
    Subscription-kind links are never touched.

    Returns:
        int: number of links revoked.
    """
    ids = [str(m) for m in dict.fromkeys(member_ids or []) if m]
    if not ids:
        return 0
    cur.execute(
        "UPDATE invites SET revoked_at = NOW() WHERE kind = 'group' AND target_id = %s "
        "AND revoked_at IS NULL AND created_by::text = ANY(%s::text[])",
        (group_id, ids),
    )
    count = cur.rowcount
    if count:
        _audit("auto_revoke", kind="group", target=group_id, members=len(ids), count=count)
    return count
