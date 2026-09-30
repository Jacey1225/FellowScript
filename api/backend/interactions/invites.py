"""Shareable invite links (task 20260929-group-invite-links, phase 1).

A generic ``invites`` table (db.py) with a per-``kind`` handler registry, so
phase 2 (subscription-seat invites) plugs in by adding a handler -- no schema
change. Only kind ``'group'`` exists today.

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


def _as_uuid(value: str) -> str | None:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, AttributeError):
        return None


# ── Per-kind handlers ─────────────────────────────────────────────────────────

class GroupInviteHandler:
    """Kind ``'group'``: target_id is groups._id; redeeming appends the user
    to groups.users."""

    kind = "group"

    def lock_group(self, cur, target_id: str):
        """Lock + return (title, users, creator_id, photo_key), or None."""
        cur.execute(
            "SELECT title, COALESCE(users, '{}'), creator_id, photo_key "
            "FROM groups WHERE _id = %s FOR UPDATE",
            (target_id,),
        )
        return cur.fetchone()

    def is_manager(self, group_row, user_id: str) -> bool:
        creator = group_row[2]
        return creator is not None and str(creator) == user_id

    def has_blocked_relationship(self, cur, user_id: str, target_id: str) -> bool:
        """True if ``user_id`` is blocked-by / has blocked ANY current member."""
        cur.execute(
            "SELECT 1 FROM blocked_users b, groups g WHERE g._id = %s AND ("
            "(b.blocker_id = %s AND b.blocked_id::text = ANY(g.users)) OR "
            "(b.blocked_id = %s AND b.blocker_id::text = ANY(g.users))) LIMIT 1",
            (target_id, user_id, user_id),
        )
        return cur.fetchone() is not None

    def add_member(self, cur, user_id: str, target_id: str) -> None:
        cur.execute(
            "UPDATE groups SET users = array_append(COALESCE(users, '{}'), %s) "
            "WHERE _id = %s AND NOT (%s = ANY(COALESCE(users, '{}')))",
            (user_id, target_id, user_id),
        )
        if cur.rowcount != 1:
            raise RuntimeError("group member append affected no row")

    def preview(self, cur, target_id: str, created_by: str) -> dict | None:
        cur.execute(
            "SELECT title, photo_key, COALESCE(users, '{}') FROM groups WHERE _id = %s",
            (target_id,),
        )
        row = cur.fetchone()
        if not row:
            return None
        title, photo_key, users = row
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


HANDLERS = {h.kind: h for h in (GroupInviteHandler(),)}


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
            InviteError: forbidden (not a member), bad_request (value not in
                the configured allowed set), link_limit (soft cap reached).
        """
        cfg = get_invites_config()
        handler = _handler(kind)
        days = cfg.default_expiry_days if expires_in_days is None else expires_in_days
        uses = cfg.default_max_uses if max_uses is None else max_uses
        if days not in cfg.allowed_expiry_days or uses not in cfg.allowed_max_uses:
            raise InviteError("bad_request", 422, "That expiry or use limit isn't allowed.")
        tid = _as_uuid(target_id)
        if tid is None:
            raise InviteError("forbidden", 403, "You can't create an invite link for this group.")
        token = generate_token()
        token_hash = hash_token(token)
        expires_at = datetime.now(timezone.utc) + timedelta(days=days)
        try:
            group = handler.lock_group(self.cur, tid)  # also serializes the cap check
            if not group or self.user_id not in group[1]:
                raise InviteError("forbidden", 403, "You can't create an invite link for this group.")
            self.cur.execute(
                "SELECT COUNT(*) FROM invites WHERE kind = %s AND target_id = %s AND created_by = %s "
                "AND revoked_at IS NULL AND expires_at > NOW() AND use_count < max_uses",
                (kind, tid, self.user_id),
            )
            if self.cur.fetchone()[0] >= cfg.max_active_links_per_user_per_group:
                raise InviteError("link_limit", 409,
                                  "You have too many active links for this group. Revoke one first.")
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
               user=self.user_id, ip=ip, expires_at=expires_at.isoformat(), max_uses=uses)
        return {
            "invite_id": str(invite_id),
            "token": token,
            "url": f"{cfg.public_base_url}/join/{token}",
            "created_at": created_at.isoformat(),
            "expires_at": expires_at.isoformat(),
            "max_uses": uses,
            "use_count": 0,
        }

    # -- list -----------------------------------------------------------------
    def list_active(self, kind: str, target_id: str) -> list[dict]:
        """Active links the caller may see: their own, or all if they manage
        the target (group creator). Metadata only -- never a token.

        Raises:
            InviteError: forbidden (not a member).
        """
        handler = _handler(kind)
        tid = _as_uuid(target_id)
        if tid is None:
            raise InviteError("forbidden", 403, "Not a member of this group")
        try:
            self.cur.execute(
                "SELECT title, COALESCE(users, '{}'), creator_id, photo_key FROM groups WHERE _id = %s",
                (tid,),
            )
            group = self.cur.fetchone()
            if not group or self.user_id not in group[1]:
                raise InviteError("forbidden", 403, "Not a member of this group")
            manager = handler.is_manager(group, self.user_id)
            self.cur.execute(
                "SELECT i._id, i.created_by, u.username, i.created_at, i.expires_at, i.max_uses, i.use_count "
                "FROM invites i JOIN users u ON u._id = i.created_by "
                "WHERE i.kind = %s AND i.target_id = %s AND i.revoked_at IS NULL "
                "AND i.expires_at > NOW() AND i.use_count < i.max_uses "
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
                "expires_at": r[4].isoformat(),
                "max_uses": r[5],
                "use_count": r[6],
                "remaining_uses": r[5] - r[6],
            }
            for r in rows
        ]

    # -- revoke ---------------------------------------------------------------
    def revoke(self, invite_id: str, ip: str = "-") -> None:
        """Revoke one link. Allowed for the link's creator or the target's
        manager (group creator), and only while still a member. Idempotent.

        Raises:
            InviteError: not_found (unknown id OR caller isn't a member --
                indistinguishable), forbidden (member, but neither creator
                nor manager).
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
            group = handler.lock_group(self.cur, str(target_id))
            if not group or self.user_id not in group[1]:
                raise InviteError("not_found", 404, "Invite not found.")
            if str(created_by) != self.user_id and not handler.is_manager(group, self.user_id):
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
        target (all of them for the group creator, else only their own).

        Returns:
            int: number of links revoked.

        Raises:
            InviteError: forbidden (not a member).
        """
        handler = _handler(kind)
        tid = _as_uuid(target_id)
        if tid is None:
            raise InviteError("forbidden", 403, "Not a member of this group")
        try:
            group = handler.lock_group(self.cur, tid)
            if not group or self.user_id not in group[1]:
                raise InviteError("forbidden", 403, "Not a member of this group")
            manager = handler.is_manager(group, self.user_id)
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
                "AND revoked_at IS NULL AND expires_at > NOW() AND use_count < max_uses",
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
        """Join the target via ``token`` as ``self.user_id``.

        Returns:
            dict: ``{"kind", "target_id", "joined", "already_member"}``.

        Raises:
            InviteError: not_found (unknown token), expired, revoked, full,
                blocked (deliberately generic -- never says who blocked whom).
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
            group = handler.lock_group(self.cur, target_id)
            if not group:
                self.conn.rollback()
                _audit("redeem_fail", reason="target_gone", ref=ref, user=self.user_id, ip=ip)
                raise _not_found()
            if self.user_id in group[1]:
                self.conn.rollback()
                _audit("redeem_noop", reason="already_member", invite=invite_id, ref=ref,
                       user=self.user_id, ip=ip)
                return {"kind": kind, "target_id": target_id, "joined": False, "already_member": True}

            if handler.has_blocked_relationship(self.cur, self.user_id, target_id):
                self.conn.rollback()
                _audit("redeem_fail", reason="blocked", invite=invite_id, ref=ref,
                       user=self.user_id, ip=ip)
                raise InviteError("blocked", 403, "You can't join this group.")

            # The single atomic gate: expiry, revocation and max_uses are all
            # enforced by this one statement, so racing redeems of the last
            # use can only ever produce one winner.
            self.cur.execute(
                "UPDATE invites SET use_count = use_count + 1 WHERE _id = %s "
                "AND revoked_at IS NULL AND expires_at > NOW() AND use_count < max_uses "
                "RETURNING use_count",
                (invite_id,),
            )
            if self.cur.fetchone() is None:
                self.cur.execute(
                    "SELECT revoked_at IS NOT NULL, expires_at <= NOW(), use_count >= max_uses "
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

            handler.add_member(self.cur, self.user_id, target_id)
            self.conn.commit()
        except InviteError:
            raise
        except BaseException:
            self.conn.rollback()
            raise
        _audit("redeem", invite=invite_id, ref=ref, kind=kind, target=target_id,
               user=self.user_id, ip=ip)
        return {"kind": kind, "target_id": target_id, "joined": True, "already_member": False}


def purge_target_invites(cur, kind: str, target_id: str) -> None:
    """Delete every invite for a deleted target (no FK, so callers that
    delete a target must call this in the same transaction/connection)."""
    _handler(kind).purge(cur, target_id)
