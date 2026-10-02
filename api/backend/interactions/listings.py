"""Explorer listings: lifecycle state machine and the helpers other tasks call.

A listing is a public, opt-in description of ONE group, owned by the group's
creator (``groups.creator_id``). It lives in its own table so the public/private
data boundary stays explicit. This module has two halves.

Shared functions (signatures FROZEN at the end of backend step 4 and consumed
verbatim by join-requests; asserted with ``inspect.signature`` in tests). Every
one takes the CALLER'S open cursor, never commits, and composes inside the
caller's transaction so the caller keeps its own lock order (``groups FOR
UPDATE`` first, then ``group_listings``)::

    public_where(alias: str = 'gl') -> str
    listing_requestable(cur, public_id: str) -> None | dict
    set_accepting_requests(cur, group_id: str, value: bool) -> bool
    get_accepting_requests(cur, group_id: str) -> bool | None
    group_has_explorer_presence(cur, group_id: str) -> bool
    live_member_count(cur, group_id: str) -> int
    requeue_for_review(cur, group_id: str, reason: str) -> bool

``ListingsManager`` is the owner-facing manager (one DB connection per
request); the ``admin_*`` functions are the moderation transitions the admin
routes and CLI call. ``hide_in_tx`` / ``remove_in_tx`` run the
``listing_hidden`` lifecycle hooks (``fn(cur, group_id, reason)``) inside the
caller's transaction; this module never imports the join-requests module.

Lifecycle: draft -> pending_review (owner submits with consent and adult
attestation) -> published (admin approve) | rejected (reason code; the owner may
edit and resubmit). published -> unpublished (owner, immediate) -> published
again without a new review when nothing reviewable changed since approval
(``approved_at`` still set), otherwise pending_review. A change to title,
summary, description, church name or free tags (or media, via
``requeue_for_review(..., 'media')``) sends a published listing back to
pending_review. published or pending_review -> hidden (admin, report auto-hide,
owner suspended or gone) -> restored by an admin. Removal is a hard delete.

``public_where`` is the single visibility authority: published AND the group's
creator exists, is still a member and is not suspended. Ambiguity hides.
"""
import logging
import re
import secrets
import string
import uuid
from contextlib import contextmanager
from typing import Any, Mapping

import psycopg2 as sql
from psycopg2.extras import Json

from backend.errors import SaveFailedError
from backend.auth.terms import require_current_terms
from backend.interactions import lifecycle, paging
from backend.interactions.groups import live_member_ids
from backend.interactions.listing_content import (
    CONTENT_COLUMNS,
    REVIEW_COLUMNS,
    ListingError,
    normalise,
    reject_unsafe_text,
)
from backend.interactions.listings_config import ListingsConfig, get_listings_config
from db import DBManager, _redact_db_error

logger = logging.getLogger(__name__)

STATUSES = ("draft", "pending_review", "published", "unpublished", "hidden", "rejected")
# "Explorer presence": the PUT /groups owner-only guard applies while a listing
# is in one of these states.
PRESENCE_STATUSES = ("pending_review", "published", "hidden")
# System-set hide reasons (admin-selectable ones come from config).
REASON_OWNER_SUSPENDED = "owner_suspended"
REASON_OWNER_GONE = "owner_gone"
REASON_REPORTED = "reported"
REASON_BULK = "bulk"

_PUBLIC_ID_RE = re.compile(r"^[0-9A-Za-z]{10}$")
_ALIAS_RE = re.compile(r"^[a-z_][a-z0-9_]*$")
_PUBLIC_ID_ALPHABET = string.ascii_letters + string.digits
_NOT_FOUND = ("not_found", "Not found")


def _not_found() -> ListingError:
    return ListingError(404, *_NOT_FOUND)


def _canon(value) -> str | None:
    """Lowercase canonical UUID string or None."""
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def new_public_id() -> str:
    return "".join(secrets.choice(_PUBLIC_ID_ALPHABET) for _ in range(10))


def is_public_id(value) -> bool:
    return isinstance(value, str) and bool(_PUBLIC_ID_RE.fullmatch(value))


# ---------------------------------------------------------------------------
# Shared functions (frozen interface)
# ---------------------------------------------------------------------------

def owner_present_sql(alias: str) -> str:
    """EXISTS fragment: the group's creator exists, is a current member and is
    not suspended. ``alias`` is the group_listings alias in the caller's query."""
    return (
        "EXISTS (SELECT 1 FROM groups _pw_g JOIN users _pw_u ON _pw_u._id = _pw_g.creator_id "
        f"WHERE _pw_g._id = {alias}.group_id AND _pw_u.suspended_at IS NULL "
        "AND EXISTS (SELECT 1 FROM unnest(_pw_g.users) _pw_m(member_id) "
        "WHERE lower(_pw_m.member_id) = _pw_g.creator_id::text))"
    )


def public_where(alias: str = "gl") -> str:
    """SQL fragment (no bind parameters) selecting publicly visible listings:
    status published, creator non-null, still in ``groups.users``, not
    suspended. The caller supplies the flag check. ``alias`` must be a plain
    identifier (it is interpolated)."""
    if not isinstance(alias, str) or not _ALIAS_RE.fullmatch(alias):
        raise ValueError("alias must be a simple SQL identifier")
    return f"({alias}.status = 'published' AND {owner_present_sql(alias)})"


def live_member_count(cur, group_id: str) -> int:
    """Members that still exist as users, de-duplicated (dead account ids and
    junk strings in ``groups.users`` never count). Built on the shared
    ``groups.live_member_ids`` helper. For SINGLE-group reads only: a page of
    listings must use one set-based aggregate over ``LIVE_MEMBER_JOIN``."""
    return len(live_member_ids(cur, group_id))


def listing_requestable(cur, public_id: str) -> dict | None:
    """The listing a person may ask to join, or None.

    Requires: published and the owner present (``public_where``), the owner
    accepting requests, and the group not full (``max_members`` counted over
    live members only). Returns ``{"group_id", "listing_id", "title"}`` (strings;
    ``listing_id`` is internal, server-side only). No locks are taken.
    """
    if not is_public_id(public_id):
        return None
    cur.execute(
        "SELECT gl.group_id::text, gl._id::text, gl.title, g.max_members "
        "FROM group_listings gl JOIN groups g ON g._id = gl.group_id "
        f"WHERE gl.public_id = %s AND {public_where('gl')} AND gl.accepting_requests",
        (public_id,),
    )
    row = cur.fetchone()
    if row is None:
        return None
    group_id, listing_id, title, cap = row
    if cap is not None and live_member_count(cur, group_id) >= cap:
        return None
    return {"group_id": group_id, "listing_id": listing_id, "title": title}


def set_accepting_requests(cur, group_id: str, value: bool) -> bool:
    """Write ``accepting_requests`` for the group's listing.

    True when a listing row exists and was written; False when the group has no
    listing (or the id is not a UUID). Never raises for a missing listing, so
    the caller can answer its uniform 404 without reading ``group_listings``.
    Does not touch ``updated_at`` (not a reviewable change).
    """
    if not isinstance(value, bool):
        raise ValueError("value must be a bool")
    gid = _canon(group_id)
    if gid is None:
        return False
    cur.execute("UPDATE group_listings SET accepting_requests = %s WHERE group_id = %s", (value, gid))
    return cur.rowcount == 1


def get_accepting_requests(cur, group_id: str) -> bool | None:
    """``accepting_requests`` for the group's listing; None when the group has
    no listing. The only read helper for the owner list."""
    gid = _canon(group_id)
    if gid is None:
        return None
    cur.execute("SELECT accepting_requests FROM group_listings WHERE group_id = %s", (gid,))
    row = cur.fetchone()
    return None if row is None else bool(row[0])


def group_has_explorer_presence(cur, group_id: str) -> bool:
    """True while the group has a listing in pending_review, published or hidden
    (the states in which the PUT /groups owner-only guard applies)."""
    gid = _canon(group_id)
    if gid is None:
        return False
    cur.execute(
        "SELECT 1 FROM group_listings WHERE group_id = %s AND status = ANY(%s) LIMIT 1",
        (gid, list(PRESENCE_STATUSES)),
    )
    return cur.fetchone() is not None


def requeue_for_review(cur, group_id: str, reason: str) -> bool:
    """A reviewable change happened (``reason`` 'text' or 'media').

    The approval is voided (``approved_at`` cleared) for published, unpublished
    and hidden listings; a published listing returns to pending_review. True
    when a status change happened (published -> pending_review). Filter-only
    edits must not call this."""
    if reason not in ("text", "media"):
        raise ValueError("reason must be 'text' or 'media'")
    gid = _canon(group_id)
    if gid is None:
        return False
    cur.execute(
        "UPDATE group_listings SET approved_at = NULL, updated_at = NOW(), "
        "status = CASE WHEN status = 'published' THEN 'pending_review' ELSE status END "
        "WHERE group_id = %s AND status IN ('published', 'unpublished', 'hidden') "
        "RETURNING status = 'pending_review'",
        (gid,),
    )
    row = cur.fetchone()
    return bool(row and row[0])


# ---------------------------------------------------------------------------
# In-transaction helpers (cursor in, no commit)
# ---------------------------------------------------------------------------

def owner_available(cur, group_id: str) -> str | None:
    """None when the group's owner is present; else a hide reason
    (``owner_suspended`` or ``owner_gone``). The caller should hold the group
    row lock."""
    cur.execute(
        "SELECT g.creator_id::text, g.users, (u._id IS NOT NULL), (u.suspended_at IS NOT NULL) "
        "FROM groups g LEFT JOIN users u ON u._id = g.creator_id WHERE g._id = %s",
        (group_id,),
    )
    row = cur.fetchone()
    if row is None:
        return REASON_OWNER_GONE
    creator, users, exists, suspended = row
    if creator is None or not exists:
        return REASON_OWNER_GONE
    if suspended:
        return REASON_OWNER_SUSPENDED
    if not any(isinstance(m, str) and m.lower() == creator for m in (users or [])):
        return REASON_OWNER_GONE
    return None


def _run_hidden_hooks(cur, group_id: str, reason: str) -> None:
    lifecycle.enqueue_s3_deletes(cur, lifecycle.run("listing_hidden", cur, group_id, reason))


def hide_in_tx(cur, group_id: str, reason: str) -> bool:
    """published/pending_review -> hidden and run the ``listing_hidden`` hooks.
    True when a listing changed state."""
    gid = _canon(group_id)
    if gid is None:
        return False
    cur.execute(
        "UPDATE group_listings SET status = 'hidden', hidden_at = NOW(), hidden_reason_code = %s, "
        "updated_at = NOW() WHERE group_id = %s AND status IN ('pending_review', 'published') RETURNING 1",
        (reason, gid),
    )
    if cur.fetchone() is None:
        return False
    _run_hidden_hooks(cur, gid, reason)
    return True


def remove_in_tx(cur, group_id: str, reason: str) -> bool:
    """Hard-delete the group's listing (media rows cascade), running the
    ``listing_hidden`` hooks first when it was visible to anyone. True when a
    row was deleted."""
    gid = _canon(group_id)
    if gid is None:
        return False
    cur.execute("SELECT status FROM group_listings WHERE group_id = %s FOR UPDATE", (gid,))
    row = cur.fetchone()
    if row is None:
        return False
    if row[0] in PRESENCE_STATUSES:
        _run_hidden_hooks(cur, gid, reason)
    cur.execute("DELETE FROM group_listings WHERE group_id = %s", (gid,))
    return cur.rowcount == 1


# ---------------------------------------------------------------------------
# Owner manager
# ---------------------------------------------------------------------------

_OWNER_COLUMNS = (
    "public_id", "group_id::text", "status", "accepting_requests", "title", "summary",
    "description_blocks", "denominations", "goals", "practices", "hobbies", "free_tags",
    "age_ranges", "life_stages", "gender_makeup", "languages", "meeting_format", "frequency",
    "country", "region", "city", "church_name", "consent_version", "consented_at",
    "adult_attested", "approved_at", "reviewed_at", "reject_reason_code", "hidden_reason_code",
    "published_at", "created_at", "updated_at",
)
_OWNER_KEYS = tuple(c.split("::")[0] for c in _OWNER_COLUMNS)
_OWNER_SELECT = ", ".join(_OWNER_COLUMNS)
_TIMESTAMP_KEYS = ("consented_at", "approved_at", "reviewed_at", "published_at", "created_at", "updated_at")
_ARRAY_KEYS = (
    "denominations", "goals", "practices", "hobbies", "free_tags", "age_ranges", "life_stages", "languages",
)

# Everything the content compare needs, read FOR UPDATE under the group lock.
_COMPARE_KEYS = tuple(sorted(CONTENT_COLUMNS - {"city_norm"}))


def _owner_view(row: tuple) -> dict:
    view = dict(zip(_OWNER_KEYS, row))
    for key in _TIMESTAMP_KEYS:
        if view.get(key) is not None:
            view[key] = paging.format_timestamp(view[key])
    for key in _ARRAY_KEYS:
        view[key] = list(view.get(key) or [])
    view["description_blocks"] = view.get("description_blocks") or []
    view["summary"] = view.get("summary") or ""
    view["country"] = view.get("country") or None
    return view


class ListingsManager(DBManager):
    """Owner-facing listing operations for one user (one DB connection)."""

    def __init__(self, user_id: str) -> None:
        self.cfg: ListingsConfig = get_listings_config()  # before connecting: a bad config must not leak a connection
        super().__init__()
        self.user_id = _canon(user_id) or ""

    # -- plumbing -----------------------------------------------------------

    @contextmanager
    def _tx(self, op: str):
        try:
            yield
            self.conn.commit()
        except sql.Error as e:
            logger.error("DB_WRITE_FAILURE op=%s table=group_listings error=%s", op, _redact_db_error(e))
            self.conn.rollback()
            raise SaveFailedError()
        except BaseException:
            self.conn.rollback()
            raise

    def require_terms(self) -> None:
        """403 ``terms_reaccept_required`` unless the owner accepted the current Terms."""
        require_current_terms(self.cur, self.user_id)

    def _lock_owned_group(self, group_id: str, *, lock: bool = True) -> dict:
        """Lock the group row (unless ``lock`` is False, for reads) and prove the
        caller owns it: creator, still a member, not suspended. Anything else is
        the same 404 (no existence oracle for other people's groups)."""
        gid = _canon(group_id)
        if gid is None or not self.user_id:
            raise _not_found()
        self.cur.execute(
            "SELECT g.title, g.creator_id::text, g.users, (u.suspended_at IS NOT NULL) "
            "FROM groups g LEFT JOIN users u ON u._id = g.creator_id "
            "WHERE g._id = %s" + (" FOR UPDATE OF g" if lock else ""),
            (gid,),
        )
        row = self.cur.fetchone()
        if (
            row is None
            or row[1] != self.user_id
            or row[3]
            or not any(isinstance(m, str) and m.lower() == self.user_id for m in (row[2] or []))
        ):
            raise _not_found()
        return {"group_id": gid, "title": row[0]}

    def _fetch(self, group_id: str, *, for_update: bool = False) -> dict | None:
        self.cur.execute(
            f"SELECT {_OWNER_SELECT} FROM group_listings WHERE group_id = %s"
            + (" FOR UPDATE" if for_update else ""),
            (group_id,),
        )
        row = self.cur.fetchone()
        return None if row is None else _owner_view(row)

    # -- reads --------------------------------------------------------------

    def list_groups(self) -> dict:
        """Groups the caller created (and still belongs to) with their listing
        status, plus the cap usage."""
        if not self.user_id:
            return {"groups": [], "listing_cap": self.cfg.per_owner_cap, "listings_used": 0}
        self.cur.execute(
            "SELECT g._id::text, g.title, gl.public_id, gl.status, gl.accepting_requests, "
            "gl.reject_reason_code, gl.hidden_reason_code "
            "FROM groups g LEFT JOIN group_listings gl ON gl.group_id = g._id "
            "WHERE g.creator_id = %s AND EXISTS (SELECT 1 FROM unnest(g.users) m "
            "WHERE lower(m) = g.creator_id::text) "
            "ORDER BY lower(g.title), g._id LIMIT 500",
            (self.user_id,),
        )
        rows = self.cur.fetchall()
        used = self._count_listings()
        self.conn.rollback()
        groups = []
        for gid, title, public_id, status, accepting, reject_code, hidden_code in rows:
            groups.append({
                "group_id": gid,
                "title": title,
                "listing": None if public_id is None else {
                    "public_id": public_id,
                    "status": status,
                    "accepting_requests": bool(accepting),
                    "reject_reason_code": reject_code,
                    "hidden_reason_code": hidden_code,
                },
            })
        return {"groups": groups, "listing_cap": self.cfg.per_owner_cap, "listings_used": used}

    def _count_listings(self) -> int:
        self.cur.execute(
            "SELECT count(*) FROM group_listings gl JOIN groups g ON g._id = gl.group_id "
            "WHERE g.creator_id = %s",
            (self.user_id,),
        )
        return int(self.cur.fetchone()[0])

    def get_listing(self, group_id: str) -> dict:
        """The caller's own listing for a group they own (404 otherwise)."""
        with self._tx("get_listing"):
            self._lock_owned_group(group_id, lock=False)
            view = self._fetch(_canon(group_id))
            if view is None:
                raise _not_found()
            return view

    # -- writes -------------------------------------------------------------

    def save(self, group_id: str, data: Mapping[str, Any], accepting_requests: bool | None = None) -> dict:
        """Create the draft if needed, then apply the fields present in ``data``
        (omitted fields are unchanged). Never changes visibility by itself,
        except that a reviewable change sends a published listing back to
        pending_review. ``accepting_requests`` None leaves the stored value."""
        with self._tx("save_listing"):
            group = self._lock_owned_group(group_id)
            gid = group["group_id"]
            updates = normalise(self.cfg, data)
            existing = self._fetch(gid, for_update=True)
            created = False
            if existing is None:
                self._create_draft(gid, group["title"], updates)
                created = True
                existing = self._fetch(gid, for_update=True)
            elif updates:
                self._apply_updates(gid, existing, updates)
            if accepting_requests is not None:
                set_accepting_requests(self.cur, gid, accepting_requests)
            view = self._fetch(gid)
            if created:
                logger.info("LISTING_CREATED group=%s", gid)
            return view

    def _create_draft(self, gid: str, group_title: str, updates: dict) -> None:
        # Serialise the per-owner cap across this owner's groups.
        self.cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (f"listing_owner:{self.user_id}",))
        if self._count_listings() >= self.cfg.per_owner_cap:
            raise ListingError(
                409, "listing_cap_reached",
                f"You can have up to {self.cfg.per_owner_cap} listings. Delete one to add another.",
            )
        values = dict(updates)
        if "title" not in values:
            # Prefill from the group's current title; the owner confirms or edits it at submit.
            try:
                values.update(normalise(self.cfg, {"title": (group_title or "")[: self.cfg.title_max_length]}))
            except ListingError:
                values["title"] = ""  # an unusable group title is never copied; the owner types one
        columns = sorted(values)
        for column in columns:
            if column not in CONTENT_COLUMNS:
                raise ValueError("unexpected column")
        for _ in range(8):
            self.cur.execute(
                f"INSERT INTO group_listings (public_id, group_id, {', '.join(columns)}) "
                f"VALUES (%s, %s, {', '.join(['%s'] * len(columns))}) "
                "ON CONFLICT (public_id) DO NOTHING RETURNING 1",
                [new_public_id(), gid] + [_adapt(c, values[c]) for c in columns],
            )
            if self.cur.fetchone() is not None:
                return
        raise SaveFailedError()

    def _apply_updates(self, gid: str, existing: dict, updates: dict) -> None:
        columns = sorted(updates)
        for column in columns:
            if column not in CONTENT_COLUMNS:
                raise ValueError("unexpected column")
        # city_norm / description_text are derived: they follow city / description_blocks.
        changed = {
            c for c in columns
            if c not in ("city_norm", "description_text") and _differs(existing, c, updates[c])
        }
        if not changed:
            return
        if "city" in changed:
            changed.add("city_norm")
        if "description_blocks" in changed:
            changed.add("description_text")
        set_sql = ", ".join(f"{c} = %s" for c in sorted(changed))
        self.cur.execute(
            f"UPDATE group_listings SET {set_sql}, updated_at = NOW() WHERE group_id = %s",
            [_adapt(c, updates[c]) for c in sorted(changed)] + [gid],
        )
        if changed & REVIEW_COLUMNS:
            if self.cfg.require_approval:
                requeue_for_review(self.cur, gid, "text")

    def submit(
        self,
        group_id: str,
        *,
        consent: bool,
        adult_attested: bool,
        accepting_requests: bool | None = None,
    ) -> dict:
        """Owner submits the listing for review (or publishes it when review is
        off, or when it was unpublished and nothing reviewable changed since
        approval). Requires consent and the adult attestation."""
        if consent is not True:
            raise ListingError(422, "consent_required", "Please confirm you understand your listing will be public.")
        if adult_attested is not True:
            raise ListingError(
                422, "adult_attestation_required",
                "Please confirm you are 18 or over and that this group is for adults 18 and over.",
            )
        with self._tx("submit_listing"):
            group = self._lock_owned_group(group_id)
            gid = group["group_id"]
            existing = self._fetch(gid, for_update=True)
            if existing is None:
                raise _not_found()
            status = existing["status"]
            if status == "hidden":
                raise ListingError(409, "hidden_by_admin", "This listing is hidden. Contact support to review it.")
            if status in ("pending_review", "published"):
                if accepting_requests is not None:
                    set_accepting_requests(self.cur, gid, accepting_requests)
                return self._fetch(gid)
            if not existing["title"].strip():
                raise ListingError(422, "title_required", "Give your listing a name before you submit it.", "title")
            # Re-check stored text (the youth list or word filter may have changed since the draft).
            reject_unsafe_text(self.cfg, {
                "title": existing["title"], "summary": existing["summary"],
                "church_name": existing["church_name"], "region": existing["region"],
                "city": existing["city"], "free_tags": existing["free_tags"],
                "description_text": self._description_text(gid),
            })
            publish_now = (not self.cfg.require_approval) or (
                status == "unpublished" and existing["approved_at"] is not None
            )
            if publish_now:
                self.cur.execute(
                    "UPDATE group_listings SET status = 'published', published_at = NOW(), "
                    "reject_reason_code = NULL, hidden_at = NULL, hidden_reason_code = NULL, "
                    "consent_version = %s, consented_at = NOW(), adult_attested = TRUE, "
                    "approved_at = COALESCE(approved_at, NOW()), updated_at = NOW() WHERE group_id = %s",
                    (self.cfg.consent_version, gid),
                )
            else:
                self.cur.execute(
                    "UPDATE group_listings SET status = 'pending_review', reject_reason_code = NULL, "
                    "consent_version = %s, consented_at = NOW(), adult_attested = TRUE, updated_at = NOW() "
                    "WHERE group_id = %s",
                    (self.cfg.consent_version, gid),
                )
            if accepting_requests is not None:
                set_accepting_requests(self.cur, gid, accepting_requests)
            return self._fetch(gid)

    def _description_text(self, gid: str) -> str:
        self.cur.execute("SELECT description_text FROM group_listings WHERE group_id = %s", (gid,))
        row = self.cur.fetchone()
        return row[0] if row else ""

    def unpublish(self, group_id: str) -> dict:
        """published/pending_review -> unpublished, immediately."""
        with self._tx("unpublish_listing"):
            group = self._lock_owned_group(group_id)
            gid = group["group_id"]
            existing = self._fetch(gid, for_update=True)
            if existing is None:
                raise _not_found()
            status = existing["status"]
            if status == "unpublished":
                return existing
            if status == "hidden":
                raise ListingError(409, "hidden_by_admin", "This listing is hidden. Contact support to review it.")
            if status not in ("published", "pending_review"):
                raise ListingError(409, "invalid_state", "This listing isn't published.")
            self.cur.execute(
                "UPDATE group_listings SET status = 'unpublished', updated_at = NOW() WHERE group_id = %s",
                (gid,),
            )
            return self._fetch(gid)

    def delete_listing(self, group_id: str) -> None:
        """Hard-delete the caller's listing (runs the ``listing_hidden`` hooks
        first so pending requests expire)."""
        with self._tx("delete_listing"):
            group = self._lock_owned_group(group_id)
            if not remove_in_tx(self.cur, group["group_id"], "owner_deleted"):
                raise _not_found()


def _adapt(column: str, value):
    """Bind value for a content column: JSONB gets ``Json``, arrays stay lists."""
    return Json(value) if column == "description_blocks" else value


def _differs(existing: Mapping, column: str, new) -> bool:
    old = existing.get(column)
    if column in _ARRAY_KEYS:
        return list(old or []) != list(new or [])
    if column == "description_blocks":
        return (old or []) != (new or [])
    if column == "summary":
        return (old or "") != (new or "")
    if column in ("country", "region", "city", "church_name", "gender_makeup", "meeting_format", "frequency"):
        return (old or None) != (new or None)
    return old != new


# ---------------------------------------------------------------------------
# Moderation transitions (admin routes and CLI call these; the caller commits)
# ---------------------------------------------------------------------------

def _lock_by_public_id(cur, public_id: str) -> tuple[str, str]:
    """Lock the group row, then the listing row (the program lock order).
    Returns ``(group_id, status)``; ``ListingError`` 404 when unknown."""
    if not is_public_id(public_id):
        raise _not_found()
    cur.execute("SELECT group_id::text FROM group_listings WHERE public_id = %s", (public_id,))
    row = cur.fetchone()
    if row is None:
        raise _not_found()
    gid = row[0]
    cur.execute("SELECT 1 FROM groups WHERE _id = %s FOR UPDATE", (gid,))
    cur.execute("SELECT status FROM group_listings WHERE group_id = %s FOR UPDATE", (gid,))
    row = cur.fetchone()
    if row is None:
        raise _not_found()
    return gid, row[0]


def admin_approve(cur, public_id: str, admin_id: str) -> dict:
    """pending_review -> published. Refuses when the owner is gone or suspended."""
    gid, status = _lock_by_public_id(cur, public_id)
    if status != "pending_review":
        raise ListingError(409, "invalid_state", "Only a listing in review can be approved.")
    if owner_available(cur, gid) is not None:
        raise ListingError(409, "owner_unavailable", "The owner is no longer able to publish this listing.")
    cur.execute(
        "UPDATE group_listings SET status = 'published', published_at = NOW(), approved_at = NOW(), "
        "reviewed_by = %s, reviewed_at = NOW(), reject_reason_code = NULL, hidden_at = NULL, "
        "hidden_reason_code = NULL, updated_at = NOW() WHERE group_id = %s",
        (_canon(admin_id), gid),
    )
    return {"public_id": public_id, "status": "published"}


def admin_reject(cur, public_id: str, admin_id: str, reason_code: str) -> dict:
    cfg = get_listings_config()
    if reason_code not in cfg.reject_reason_codes:
        raise ListingError(422, "invalid_reason", "Choose one of the listed reasons.", "reason_code")
    gid, status = _lock_by_public_id(cur, public_id)
    if status != "pending_review":
        raise ListingError(409, "invalid_state", "Only a listing in review can be rejected.")
    cur.execute(
        "UPDATE group_listings SET status = 'rejected', reject_reason_code = %s, reviewed_by = %s, "
        "reviewed_at = NOW(), approved_at = NULL, updated_at = NOW() WHERE group_id = %s",
        (reason_code, _canon(admin_id), gid),
    )
    return {"public_id": public_id, "status": "rejected", "reason_code": reason_code}


def admin_hide(cur, public_id: str, admin_id: str, reason_code: str) -> dict:
    """published/pending_review -> hidden (``listing_hidden`` hooks run). The
    reason is one of the configured codes, or a system code (reported, bulk)."""
    cfg = get_listings_config()
    if reason_code not in cfg.hide_reason_codes and reason_code not in (REASON_BULK, REASON_REPORTED):
        raise ListingError(422, "invalid_reason", "Choose one of the listed reasons.", "reason_code")
    gid, status = _lock_by_public_id(cur, public_id)
    if status not in ("pending_review", "published"):
        raise ListingError(409, "invalid_state", "Only a listing in review or published can be hidden.")
    hide_in_tx(cur, gid, reason_code)
    cur.execute("UPDATE group_listings SET reviewed_by = %s WHERE group_id = %s", (_canon(admin_id), gid))
    return {"public_id": public_id, "status": "hidden", "reason_code": reason_code}


def admin_restore(cur, public_id: str, admin_id: str) -> dict:
    """hidden -> published when the approved text is unchanged, else
    pending_review. Refuses when the owner is gone or suspended."""
    gid, status = _lock_by_public_id(cur, public_id)
    if status != "hidden":
        raise ListingError(409, "invalid_state", "Only a hidden listing can be restored.")
    if owner_available(cur, gid) is not None:
        raise ListingError(409, "owner_unavailable", "The owner is no longer able to publish this listing.")
    cur.execute(
        "UPDATE group_listings SET "
        "status = CASE WHEN approved_at IS NOT NULL THEN 'published' ELSE 'pending_review' END, "
        "published_at = CASE WHEN approved_at IS NOT NULL THEN NOW() ELSE published_at END, "
        "hidden_at = NULL, hidden_reason_code = NULL, reviewed_by = %s, reviewed_at = NOW(), "
        "updated_at = NOW() WHERE group_id = %s RETURNING status",
        (_canon(admin_id), gid),
    )
    return {"public_id": public_id, "status": cur.fetchone()[0]}


def admin_remove(cur, public_id: str, admin_id: str) -> dict:
    """Hard delete (``listing_hidden`` hooks run first)."""
    gid, _status = _lock_by_public_id(cur, public_id)
    if not remove_in_tx(cur, gid, "admin_removed"):
        raise _not_found()
    return {"public_id": public_id, "status": "removed"}


# ---------------------------------------------------------------------------
# Suspension, reports, admin queue (cursor in, the caller commits)
# ---------------------------------------------------------------------------

def hide_listings_of_owner(cur, user_id: str) -> int:
    """Hide (reason ``owner_suspended``) every visible listing of a group the
    user created, right now. ``public_where`` already stops showing such a
    listing the moment ``users.suspended_at`` is set; this makes the stored
    state agree and fires the ``listing_hidden`` hooks without waiting for the
    sweeper. Returns the number of listings hidden. Takes each group row lock
    before the listing row (program lock order)."""
    uid = _canon(user_id)
    if uid is None:
        return 0
    cur.execute(
        "SELECT gl.group_id::text FROM group_listings gl JOIN groups g ON g._id = gl.group_id "
        "WHERE g.creator_id = %s AND gl.status IN ('pending_review', 'published') ORDER BY gl.group_id",
        (uid,),
    )
    hidden = 0
    for (gid,) in cur.fetchall():
        cur.execute("SELECT 1 FROM groups WHERE _id = %s FOR UPDATE", (gid,))
        if hide_in_tx(cur, gid, REASON_OWNER_SUSPENDED):
            hidden += 1
    return hidden


def auto_hide_if_reported(cur, listing_id: str) -> dict | None:
    """After a report on a listing is stored: when the number of DISTINCT open
    reporters (the owner's own reports excluded) reaches the configured
    threshold, hide the listing (reason ``reported``) and run the hooks.
    Returns ``{"group_id", "public_id", "reason"}`` when it hid something, else
    None. The caller commits."""
    lid = _canon(listing_id)
    if lid is None:
        return None
    cur.execute(
        "SELECT gl.group_id::text, gl.public_id, g.creator_id::text "
        "FROM group_listings gl JOIN groups g ON g._id = gl.group_id WHERE gl._id = %s",
        (lid,),
    )
    row = cur.fetchone()
    if row is None:
        return None
    gid, public_id, creator = row
    cur.execute("SELECT 1 FROM groups WHERE _id = %s FOR UPDATE", (gid,))
    cur.execute(
        "SELECT count(DISTINCT reporter_id) FROM content_reports "
        "WHERE content_type = 'group_listing' AND content_id = %s AND status = 'open' "
        "AND reporter_id IS DISTINCT FROM %s",
        (lid, creator),
    )
    if cur.fetchone()[0] < get_listings_config().report_auto_hide_threshold:
        return None
    if not hide_in_tx(cur, gid, REASON_REPORTED):
        return None
    logger.info("LISTING_AUTO_HIDDEN group=%s", gid)
    return {"group_id": gid, "public_id": public_id, "reason": REASON_REPORTED}


QUEUE_STATUSES = ("pending_review", "hidden", "published", "rejected")


def admin_queue(cur, status: str = "pending_review", limit: int = 50) -> list[dict]:
    """Moderation queue for admins: oldest first, with the open-report count.
    Admin-only data (group and owner ids are included); never use for a public
    response."""
    if status not in QUEUE_STATUSES:
        raise ListingError(422, "invalid_status", "Unknown status.", "status")
    limit = max(1, min(int(limit), 100))
    cur.execute(
        "SELECT gl.public_id, gl.status, gl.title, gl.summary, gl.group_id::text, g.creator_id::text, "
        "gl.hidden_reason_code, gl.reject_reason_code, gl.updated_at, "
        "(SELECT count(DISTINCT cr.reporter_id) FROM content_reports cr "
        " WHERE cr.content_type = 'group_listing' AND cr.content_id = gl._id AND cr.status = 'open') "
        "FROM group_listings gl LEFT JOIN groups g ON g._id = gl.group_id "
        "WHERE gl.status = %s ORDER BY gl.updated_at, gl.public_id LIMIT %s",
        (status, limit),
    )
    keys = ("public_id", "status", "title", "summary", "group_id", "owner_id",
            "hidden_reason_code", "reject_reason_code", "updated_at", "open_reports")
    items = []
    for r in cur.fetchall():
        item = dict(zip(keys, r))
        item["updated_at"] = paging.format_timestamp(item["updated_at"])
        items.append(item)
    return items
