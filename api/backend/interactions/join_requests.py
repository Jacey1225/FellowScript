"""Join requests: the requesting bucket for Explorer listings (flag ``join_requests``).

A signed-in person asks to join a group from its PUBLISHED listing; the group's
owner approves or denies. This is a second path to group membership next to
invite links, so every rule here is deny-by-default and re-read on each call.

Authority and the owner (decision J4): the approver is the group's owner only,
defined as ``groups.creator_id = caller`` AND the caller is a current member AND
the caller is not suspended. ``GroupInviteHandler.is_manager`` is NOT used (it
checks the creator only; ``leave_group`` never clears ``creator_id``). Ownerless
groups and groups whose owner left accept nothing and the sweeper expires their
pending rows.

Approve is ONE transaction: the groups row ``FOR UPDATE`` first (the same order
invite redeem and ``leave_group`` use), then the request row ``FOR UPDATE``,
never the reverse. It re-checks the approver, the request state, the applicant
and the blocks, then appends through ``GroupInviteHandler.apply`` after
``existing_outcome`` / ``redeem_precheck`` (member cap and blocks). It never
creates or reads an invite row or token.

Bounded waits (thread-limiter rule): every transaction that can wait on a row
lock first runs ``set_config('lock_timeout', ..., true)`` (the SET LOCAL
equivalent that accepts a bind parameter) with ``join_requests.lock_timeout_ms``.
``psycopg2.errors.LockNotAvailable`` (SQLSTATE 55P03) is caught around this
module's OWN raw ``cur.execute`` calls, before any ``DBManager`` insertion /
update helper could see it (those log ``DB_WRITE_FAILURE`` at ERROR, which the
watchdog turns into a detection). The transaction is rolled back and the caller
answers 409 ``busy`` with an INFO line and no ERROR.

Denial shape: every "you may not" outcome that could be an oracle is the same
generic 403 (``cannot_request``) or the same 404 (``not_found``). Nothing here
logs notes, usernames, titles or applicant ids; ``JOIN_REQUEST_AUDIT`` lines
carry request, group and (for owner actions) actor ids only.

Reads of ``group_listings`` are limited to the requester's own "my requests"
view (title and public id of the listing they asked about); the accepting
switch is read and written only through ``listings.get_accepting_requests`` and
``listings.set_accepting_requests``.
"""
from __future__ import annotations

import functools
import logging
import unicodedata
import uuid

import psycopg2 as sql
from psycopg2 import errors as pg_errors

from backend.auth.terms import require_current_terms
from backend.interactions import flags, listings, paging
from backend.interactions.attachments import generate_download_url
from backend.interactions.invites import GroupInviteHandler
from backend.interactions.join_requests_config import get_join_requests_config
from backend.interactions.profile_photo import is_own_profile_photo_key
from db import DBManager

logger = logging.getLogger(__name__)

# Statuses a requester sees: denied and expired are the same neutral value.
_REQUESTER_STATUS = {
    "pending": "pending",
    "approved": "approved",
    "denied": "not_approved",
    "expired": "not_approved",
    "withdrawn": "withdrawn",
}

# Hard bounds on list responses (rows are small; presigning a photo is local).
MAX_OWNER_LIST_ROWS = 200
MAX_MY_REQUESTS = 50

_BIDI_CONTROLS = frozenset("‪‫‬‭‮⁦⁧⁨⁩")

_NOT_FOUND = ("not_found", "Not found")
CANNOT_REQUEST_MESSAGE = "You can't request to join this group right now."


class JoinRequestError(Exception):
    """A deliberate HTTP-level outcome; the route maps it to ``HTTPException``."""

    def __init__(self, status: int, code: str, message: str | None = None) -> None:
        super().__init__(code)
        self.status = status
        self.code = code
        self.message = message or code

    def detail(self) -> dict:
        return {"code": self.code, "message": self.message}


def _not_found() -> JoinRequestError:
    return JoinRequestError(404, *_NOT_FOUND)


def _cannot_request() -> JoinRequestError:
    return JoinRequestError(403, "cannot_request", CANNOT_REQUEST_MESSAGE)


def canon(value) -> str | None:
    """Lowercase canonical UUID string, or None."""
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def audit(event: str, *, group: str, request: str, actor: str | None = None) -> None:
    """One INFO line, ids only. The applicant's id is never written here."""
    parts = f"group={group} request={request}"
    if actor:
        parts += f" actor={actor}"
    logger.info("JOIN_REQUEST_AUDIT event=%s %s", event, parts)


def clean_note(raw, max_length: int) -> str | None:
    """Whitespace-normalised plain-text note, or None when blank.

    Raises ``JoinRequestError(422, 'invalid_note')`` for a non-string, a note
    over ``max_length`` characters, a control character or a bidi override.
    """
    if raw is None:
        return None
    if not isinstance(raw, str):
        raise JoinRequestError(422, "invalid_note", "Invalid note")
    if len(raw) > max_length * 4:  # cheap guard before normalising huge input
        raise JoinRequestError(422, "invalid_note", "Invalid note")
    text = " ".join(raw.split())
    if len(text) > max_length:
        raise JoinRequestError(422, "invalid_note", "Invalid note")
    if any(unicodedata.category(c) == "Cc" or c in _BIDI_CONTROLS for c in text):
        raise JoinRequestError(422, "invalid_note", "Invalid note")
    return text or None


def approver_ok(cur, group_id: str, user_id: str) -> bool:
    """The single approver predicate: creator AND current member AND not
    suspended. Lock-free read; the approve transaction re-checks it under the
    group lock. Fail closed on any malformed id."""
    gid, uid = canon(group_id), canon(user_id)
    if gid is None or uid is None:
        return False
    cur.execute(
        "SELECT 1 FROM groups g JOIN users u ON u._id = g.creator_id "
        "WHERE g._id = %s AND g.creator_id = %s AND u.suspended_at IS NULL "
        "AND %s = ANY(COALESCE(g.users, '{}'))",
        (gid, uid, uid),
    )
    return cur.fetchone() is not None


def _expire_pending_for_group(cur, group_id: str) -> int:
    cur.execute(
        "UPDATE group_join_requests SET status = 'expired', decided_at = NOW() "
        "WHERE group_id = %s AND status = 'pending'",
        (group_id,),
    )
    return cur.rowcount


def _transactional(fn):
    """Run a manager method as one transaction.

    Commits on normal return; rolls back on any exception. A 55P03 lock
    timeout becomes ``JoinRequestError(409, 'busy')`` (INFO, never ERROR). The
    lock timeout itself is armed by ``_begin``.
    """

    @functools.wraps(fn)
    def wrapper(self, *args, **kwargs):
        try:
            result = fn(self, *args, **kwargs)
            self.conn.commit()
            return result
        except pg_errors.LockNotAvailable:
            self.conn.rollback()
            logger.info("JOIN_REQUEST busy: lock wait exceeded lock_timeout_ms")
            raise JoinRequestError(409, "busy", "Busy, try again") from None
        except BaseException:
            self.conn.rollback()
            raise

    return wrapper


class JoinRequestsManager(DBManager):
    """Per-request manager. Every public method is one transaction and raises
    ``JoinRequestError`` for a denial."""

    def __init__(self, user_id: str) -> None:
        super().__init__()
        self.user_id = canon(user_id) or ""
        self.cfg = get_join_requests_config()

    # ---- helpers -------------------------------------------------------

    def _begin(self) -> None:
        """Arm the bounded lock wait for this transaction (SET LOCAL semantics)."""
        self.cur.execute(
            "SELECT set_config('lock_timeout', %s, true)", (f"{int(self.cfg.lock_timeout_ms)}ms",)
        )

    def _user_state(self, user_id: str):
        """``(exists, suspended, terms_accepted_at)`` for a user."""
        self.cur.execute(
            "SELECT suspended_at IS NOT NULL, terms_accepted_at FROM users WHERE _id = %s", (user_id,)
        )
        return self.cur.fetchone()

    # ---- requester ------------------------------------------------------

    @_transactional
    def create(self, public_id: str, note: str | None) -> dict:
        """Place a pending request for the listing ``public_id``.

        Returns ``{"status": "pending"|"already_member", "id", "created_at",
        "created"}``. Every refusal other than terms / 422 / busy is the
        uniform 404 (not requestable) or the generic 403 ``cannot_request``.
        """
        uid, cfg, cur = self.user_id, self.cfg, self.cur
        if not uid:
            raise _not_found()
        self._begin()
        # Serialise one user's concurrent creates so the per-user caps are exact.
        cur.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", (f"jrq-user:{uid}",))
        found = listings.listing_requestable(cur, public_id)
        if found is None:
            raise _not_found()
        gid = found["group_id"]
        handler = GroupInviteHandler()
        row = handler.lock_target(cur, gid)  # groups FOR UPDATE: first lock, always
        if row is None:
            raise _not_found()
        # Re-evaluate under the lock (the group may have filled meanwhile).
        if listings.listing_requestable(cur, public_id) is None:
            raise _not_found()
        owner = str(row[2]) if row[2] is not None else None
        if owner is None or not flags.is_enabled("join_requests", owner):
            raise _not_found()  # a request must not exist if its owner cannot see it
        require_current_terms(cur, uid)
        state = self._user_state(uid)
        if state is None:
            raise _not_found()
        suspended, terms_accepted_at = state
        if uid in row[1]:
            return {"status": "already_member", "id": None, "created_at": None, "created": False}
        if suspended:
            raise _cannot_request()
        if cfg.min_account_age_hours > 0:
            # users has no creation timestamp; terms_accepted_at is the best
            # available proxy. Zero (the shipped value) disables the check.
            cur.execute(
                "SELECT %s::timestamptz IS NOT NULL AND %s::timestamptz <= NOW() - make_interval(hours => %s)",
                (terms_accepted_at, terms_accepted_at, cfg.min_account_age_hours),
            )
            if not cur.fetchone()[0]:
                raise _cannot_request()
        if handler.has_blocked_relationship(cur, uid, gid):
            raise _cannot_request()
        cur.execute(
            "SELECT id::text, created_at FROM group_join_requests "
            "WHERE group_id = %s AND user_id = %s AND status = 'pending'",
            (gid, uid),
        )
        existing = cur.fetchone()
        if existing:  # idempotent retry: returns the same request, no new cap use
            return {"status": "pending", "id": existing[0],
                    "created_at": paging.format_timestamp(existing[1]), "created": False}
        # Denied rows: the owner's "never again" flag, or the cooldown window.
        cur.execute(
            "SELECT 1 FROM group_join_requests WHERE group_id = %s AND user_id = %s AND status = 'denied' "
            "AND (block_reapply OR decided_at > NOW() - make_interval(days => %s)) LIMIT 1",
            (gid, uid, cfg.cooldown_days),
        )
        if cur.fetchone():
            raise _cannot_request()
        cur.execute(
            "SELECT "
            "(SELECT count(*) FROM group_join_requests WHERE group_id = %s AND status = 'pending'), "
            "(SELECT count(*) FROM group_join_requests WHERE user_id = %s AND status = 'pending'), "
            "(SELECT count(*) FROM group_join_requests WHERE user_id = %s AND created_at > NOW() - INTERVAL '1 day')",
            (gid, uid, uid),
        )
        per_group, per_user, per_day = cur.fetchone()
        if (per_group >= cfg.max_pending_per_group or per_user >= cfg.max_pending_per_user
                or per_day >= cfg.max_requests_per_user_per_day):
            raise _cannot_request()
        cur.execute(
            "INSERT INTO group_join_requests (group_id, user_id, note) VALUES (%s, %s, %s) "
            "ON CONFLICT (group_id, user_id) WHERE status = 'pending' DO NOTHING "
            "RETURNING id::text, created_at",
            (gid, uid, note),
        )
        inserted = cur.fetchone()
        if inserted is None:  # lost a race that the locks should make impossible
            cur.execute(
                "SELECT id::text, created_at FROM group_join_requests "
                "WHERE group_id = %s AND user_id = %s AND status = 'pending'",
                (gid, uid),
            )
            existing = cur.fetchone()
            if existing is None:
                raise _cannot_request()
            return {"status": "pending", "id": existing[0],
                    "created_at": paging.format_timestamp(existing[1]), "created": False}
        audit("create", group=gid, request=inserted[0])
        return {"status": "pending", "id": inserted[0],
                "created_at": paging.format_timestamp(inserted[1]), "created": True}

    @_transactional
    def withdraw(self, request_id: str) -> dict:
        """Withdraw the caller's own pending request (idempotent)."""
        rid = canon(request_id)
        if rid is None or not self.user_id:
            raise _not_found()
        self._begin()
        self.cur.execute(
            "UPDATE group_join_requests SET status = 'withdrawn', decided_at = NOW() "
            "WHERE id = %s AND user_id = %s AND status = 'pending' RETURNING group_id::text",
            (rid, self.user_id),
        )
        row = self.cur.fetchone()
        if row:
            audit("withdraw", group=row[0], request=rid)
            return {"status": "withdrawn"}
        self.cur.execute(
            "SELECT status FROM group_join_requests WHERE id = %s AND user_id = %s", (rid, self.user_id)
        )
        current = self.cur.fetchone()
        if current is None:
            raise _not_found()
        if current[0] == "withdrawn":
            return {"status": "withdrawn"}
        raise JoinRequestError(409, "not_pending", "This request can no longer be withdrawn")

    @_transactional
    def my_requests(self, public_id: str | None) -> dict:
        """The caller's own requests, newest first. The group id is returned
        only for an approved request whose group the caller still belongs to.
        With ``public_id`` the response also says whether the caller is already
        a member of that listing's group (their own membership: no oracle)."""
        uid = self.user_id
        if not uid:
            raise _not_found()
        params: list = [uid, uid]  # membership test, then r.user_id
        where = "WHERE r.user_id = %s"
        if public_id is not None:
            if not listings.is_public_id(public_id):
                return {"requests": [], "already_member": False}
            where += " AND gl.public_id = %s"
            params.append(public_id)
        params.append(MAX_MY_REQUESTS)
        self.cur.execute(
            "SELECT r.id::text, r.status, r.created_at, gl.public_id, gl.title, r.group_id::text, "
            "(%s = ANY(COALESCE(g.users, '{}'))) "
            "FROM group_join_requests r JOIN groups g ON g._id = r.group_id "
            "LEFT JOIN group_listings gl ON gl.group_id = r.group_id "
            + where + " ORDER BY r.created_at DESC, r.id LIMIT %s",
            params,
        )
        out = []
        for rid, status, created_at, pid, title, group_id, is_member in self.cur.fetchall():
            item = {
                "id": rid,
                "status": _REQUESTER_STATUS.get(status, "not_approved"),
                "created_at": paging.format_timestamp(created_at),
                "public_id": pid,
                "title": title,
            }
            if status == "approved" and is_member:
                item["group_id"] = group_id
            out.append(item)
        result: dict = {"requests": out}
        if public_id is not None:
            self.cur.execute(
                "SELECT %s = ANY(COALESCE(g.users, '{}')) FROM group_listings gl "
                "JOIN groups g ON g._id = gl.group_id WHERE gl.public_id = %s",
                (uid, public_id),
            )
            row = self.cur.fetchone()
            result["already_member"] = bool(row and row[0])
        return result

    # ---- owner ----------------------------------------------------------

    @_transactional
    def list_pending(self, group_id: str) -> dict:
        """Pending requests for a group the caller owns (404 for everyone else)."""
        gid = canon(group_id)
        if gid is None or not approver_ok(self.cur, gid, self.user_id):
            raise _not_found()
        self.cur.execute(
            "SELECT r.id::text, r.user_id::text, u.username, u.profile_photo_key, r.note, r.created_at "
            "FROM group_join_requests r JOIN users u ON u._id = r.user_id "
            "WHERE r.group_id = %s AND r.status = 'pending' "
            "ORDER BY r.created_at DESC, r.id LIMIT %s",
            (gid, MAX_OWNER_LIST_ROWS),
        )
        rows = self.cur.fetchall()
        self.cur.execute(
            "SELECT count(*) FROM group_join_requests WHERE group_id = %s AND status = 'pending'", (gid,)
        )
        pending_count = int(self.cur.fetchone()[0])
        accepting = listings.get_accepting_requests(self.cur, gid)
        requests = []
        for rid, applicant_id, username, photo_key, note, created_at in rows:
            photo_url = generate_download_url(photo_key) if is_own_profile_photo_key(applicant_id, photo_key) else None
            requests.append({
                "id": rid,
                "applicant_user_id": applicant_id,
                "username": username,
                "profile_photo_url": photo_url,
                "note": note,
                "created_at": paging.format_timestamp(created_at),
            })
        return {
            "accepting_requests": accepting,
            "pending_count": pending_count,
            "requests": requests,
        }

    @_transactional
    def approve(self, group_id: str, request_id: str) -> dict:
        """Approve: one transaction, groups row then request row (see module doc).

        Returns ``{"status": "approved", "already_member": bool, "applied": bool}``;
        ``applied`` is True only when this call appended the member.
        """
        gid, rid, me = canon(group_id), canon(request_id), self.user_id
        if gid is None or rid is None or not me:
            raise _not_found()
        self._begin()
        handler = GroupInviteHandler()
        row = handler.lock_target(self.cur, gid)  # groups FOR UPDATE first
        if row is None:
            raise _not_found()
        if row[2] is None or str(row[2]) != me or me not in row[1]:
            raise _not_found()
        state = self._user_state(me)
        if state is None or state[0]:
            raise _not_found()  # suspended or vanished approver
        self.cur.execute(
            "SELECT user_id::text, status FROM group_join_requests "
            "WHERE id = %s AND group_id = %s FOR UPDATE",
            (rid, gid),
        )
        req = self.cur.fetchone()
        if req is None:
            raise _not_found()
        applicant, status = req
        if status == "approved":
            return {"status": "approved", "already_member": applicant in row[1], "applied": False}
        if status != "pending":
            raise JoinRequestError(409, "not_pending", "This request is no longer pending")
        a_state = self._user_state(applicant)
        if a_state is None or a_state[0]:
            self._expire(rid)
            raise JoinRequestError(409, "no_longer_available", "This request is no longer available")
        existing = handler.existing_outcome(self.cur, applicant, gid, row)
        if existing is not None:  # already a member (e.g. added by a direct member-list edit)
            self._decide(rid, "approved", me)
            audit("approve", group=gid, request=rid, actor=me)
            return {"status": "approved", "already_member": True, "applied": False}
        rejected = handler.redeem_precheck(self.cur, applicant, gid, row)
        if rejected is not None:
            reason = rejected[0]
            if reason == "group_full":
                # Stays pending; the owner can raise the cap or remove someone.
                raise JoinRequestError(409, "group_full", "This group is full.")
            self._expire(rid)
            raise JoinRequestError(409, "no_longer_available", "This request is no longer available")
        try:
            handler.apply(self.cur, applicant, gid)
        except RuntimeError:
            raise JoinRequestError(409, "group_full", "This group is full.") from None
        self._decide(rid, "approved", me)
        audit("approve", group=gid, request=rid, actor=me)
        return {"status": "approved", "already_member": False, "applied": True}

    def _decide(self, rid: str, status: str, decided_by: str, block_reapply: bool = False) -> None:
        self.cur.execute(
            "UPDATE group_join_requests SET status = %s, decided_at = NOW(), decided_by = %s, "
            "block_reapply = %s WHERE id = %s",
            (status, decided_by, block_reapply, rid),
        )

    def _expire(self, rid: str) -> None:
        """Mark expired and COMMIT (the caller then raises, and the wrapper's
        rollback has nothing left to undo)."""
        self.cur.execute(
            "UPDATE group_join_requests SET status = 'expired', decided_at = NOW() WHERE id = %s", (rid,)
        )
        self.conn.commit()

    @_transactional
    def deny(self, group_id: str, request_id: str, block_reapply: bool) -> dict:
        """Deny a pending request (conditional UPDATE; idempotent when already denied).
        Applies the cooldown; ``block_reapply`` also stops the applicant asking again."""
        gid, rid, me = canon(group_id), canon(request_id), self.user_id
        if gid is None or rid is None or not approver_ok(self.cur, gid, me):
            raise _not_found()
        self._begin()
        self.cur.execute(
            "UPDATE group_join_requests SET status = 'denied', decided_at = NOW(), decided_by = %s, "
            "block_reapply = %s WHERE id = %s AND group_id = %s AND status = 'pending' RETURNING 1",
            (me, bool(block_reapply), rid, gid),
        )
        if self.cur.fetchone():
            audit("deny", group=gid, request=rid, actor=me)
            return {"status": "denied", "undo_seconds": self.cfg.undo_deny_seconds}
        self.cur.execute(
            "SELECT status FROM group_join_requests WHERE id = %s AND group_id = %s", (rid, gid)
        )
        current = self.cur.fetchone()
        if current is None:
            raise _not_found()
        if current[0] == "denied":
            return {"status": "denied", "undo_seconds": self.cfg.undo_deny_seconds}
        raise JoinRequestError(409, "not_pending", "This request is no longer pending")

    @_transactional
    def undo_deny(self, group_id: str, request_id: str) -> dict:
        """Restore a request the caller denied within ``undo_deny_seconds``.

        The window is measured on the server clock from ``decided_at``. A
        different decider, an expired window or a newer pending request from the
        same applicant (possible when the cooldown is 0) answers 409.
        """
        gid, rid, me = canon(group_id), canon(request_id), self.user_id
        if gid is None or rid is None or not approver_ok(self.cur, gid, me):
            raise _not_found()
        self._begin()
        self.cur.execute(
            "SELECT status FROM group_join_requests WHERE id = %s AND group_id = %s", (rid, gid)
        )
        if self.cur.fetchone() is None:
            raise _not_found()
        try:
            self.cur.execute(
                "UPDATE group_join_requests SET status = 'pending', decided_at = NULL, decided_by = NULL, "
                "block_reapply = FALSE WHERE id = %s AND group_id = %s AND status = 'denied' "
                "AND decided_by = %s AND decided_at > NOW() - make_interval(secs => %s) RETURNING 1",
                (rid, gid, me, self.cfg.undo_deny_seconds),
            )
            restored = self.cur.fetchone()
        except pg_errors.UniqueViolation:
            self.conn.rollback()
            raise JoinRequestError(409, "not_undoable", "This denial can no longer be undone") from None
        if not restored:
            raise JoinRequestError(409, "not_undoable", "This denial can no longer be undone")
        audit("undo_deny", group=gid, request=rid, actor=me)
        return {"status": "pending"}

    @_transactional
    def set_accepting(self, group_id: str, value: bool) -> dict:
        """Owner switch for new requests. Written only through
        ``listings.set_accepting_requests``; pending requests are untouched.
        404 for a non-approver and for a group with no listing alike."""
        gid, me = canon(group_id), self.user_id
        if gid is None or not me:
            raise _not_found()
        self._begin()
        row = GroupInviteHandler().lock_target(self.cur, gid)  # groups FOR UPDATE first
        if row is None or row[2] is None or str(row[2]) != me or me not in row[1]:
            raise _not_found()
        state = self._user_state(me)
        if state is None or state[0]:
            raise _not_found()
        if not listings.set_accepting_requests(self.cur, gid, bool(value)):
            raise _not_found()
        audit("accepting_on" if value else "accepting_off", group=gid, request="-", actor=me)
        return {"accepting": bool(value)}
