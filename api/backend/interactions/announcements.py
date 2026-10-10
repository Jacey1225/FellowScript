"""Group announcements logic (task 20260929-group-announcements).

Lives beside ``groups.py`` rather than inside it. ``AnnouncementsManager``
extends ``GroupsManager`` for its membership check and block list.

Authorization (confirmed by the user 2026-09-29): any member may create;
only the announcement's creator or the group's creator (moderator) may edit,
delete or restore it.

Visibility: an announcement is visible to members once ``publish_at <= now``;
its author additionally sees their own scheduled ones. Soft-deleted rows are
never returned. Errors are raised, never defaulted.
"""

import json
import re
from datetime import datetime, timedelta, timezone

from backend.errors import SaveFailedError
from backend.interactions.announcement_banner import is_announcement_banner_key
from backend.interactions import announcement_extras as extras
from backend.interactions import flags
from backend.interactions.attachments import delete_object, generate_download_url
from backend.interactions.groups import GroupsManager

# Feature flag (Configuration Philosophy: flag new functionality by default).
# A plain module constant, matching this codebase's tunable convention; routes
# return 404 while False.
ANNOUNCEMENTS_ENABLED = True

ANNOUNCEMENT_TITLE_MAX_LENGTH = 255  # VARCHAR(255)
ANNOUNCEMENT_DESCRIPTION_MAX_LENGTH = 5000
ANNOUNCEMENTS_PAGE_SIZE = 50
# publish_at may be scheduled at most this far ahead.
ANNOUNCEMENT_MAX_HORIZON_DAYS = 365
# Window after a delete during which restore (undo) is accepted.
ANNOUNCEMENT_UNDO_GRACE_SECONDS = 120
# Chat-header widget shows the latest published announcement only this long
# after its publish_at (task 20260929-announcement-push-widget).
ANNOUNCEMENT_WIDGET_WINDOW_DAYS = 7

_COLUMNS = (
    "a._id, a.group_id, a.creator_id, u.username, a.title, a.description, a.banner_key, "
    "a.publish_at, a.created_at, a.updated_at, a.title_color, a.title_font, a.bg_theme, "
    "a.links, a.gallery_keys, a.is_event, a.payment_handles, a.capacity"
)

# Task 20261009-announcements-advanced (parts C and D). Server allowlists for the
# title font and background theme keys; the iOS client owns the actual fonts and
# gradients (design tokens), the server only stores a validated key. Both
# features are gated by DB flags that ship OFF (see backend.interactions.flags).
TITLE_FONT_FLAG = "announcement_title_font"
BG_THEME_FLAG = "announcement_bg_theme"
TITLE_FONT_KEYS = frozenset({
    "default", "playfair", "schibsted", "lora", "oswald", "dancing", "nunito", "bebas",
})
BG_THEME_KEYS = frozenset({
    "none",
    "ember", "dusk", "forest", "ocean", "plum", "slate",
    "espresso", "moss", "navy", "wine", "graphite", "ink",
})
# Part E (attachments). One flag per sub-part, all ship OFF.
LINKS_FLAG = "announcement_links"
GALLERY_FLAG = "announcement_gallery"
PAYMENTS_FLAG = "announcement_payments"
RSVP_FLAG = "announcement_rsvp"
_FROM = "FROM group_announcements a LEFT JOIN users u ON u._id = a.creator_id"


class AnnouncementNotFound(Exception):
    """No visible announcement with that id in this group (404)."""


class AnnouncementFull(Exception):
    """Every RSVP spot is taken (409)."""


class AnnouncementForbidden(Exception):
    """Caller may not modify this announcement (403)."""


def parse_publish_at(value: str | None) -> datetime | None:
    """Parse an ISO-8601 timestamp. ``None`` means "publish now" (caller
    decides). Naive timestamps are rejected rather than guessed at.

    Raises:
        ValueError: unparseable, timezone-less, or beyond the horizon.
    """
    if value is None:
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        raise ValueError("publish_at must be an ISO-8601 timestamp")
    if parsed.tzinfo is None:
        raise ValueError("publish_at must include a timezone offset")
    if parsed > datetime.now(timezone.utc) + timedelta(days=ANNOUNCEMENT_MAX_HORIZON_DAYS):
        raise ValueError(f"publish_at can be at most {ANNOUNCEMENT_MAX_HORIZON_DAYS} days ahead")
    return parsed


def normalize_title(title: str) -> str:
    cleaned = (title or "").strip()
    if not cleaned:
        raise ValueError("Title can't be empty")
    if len(cleaned) > ANNOUNCEMENT_TITLE_MAX_LENGTH:
        raise ValueError(f"Title must be {ANNOUNCEMENT_TITLE_MAX_LENGTH} characters or fewer")
    return cleaned


_TITLE_COLOR_RE = re.compile(r"#[0-9A-Fa-f]{6}")


def normalize_title_color(color: str | None) -> str | None:
    """Strict ``#RRGGBB`` (uppercased) or ``None`` (= default parchment).
    Never coerces: 3-digit, named, whitespace-padded or otherwise malformed
    values are rejected. ``fullmatch`` so a trailing newline can't slip by.

    Raises:
        ValueError: not a strict 6-digit hex string.
    """
    if color is None:
        return None
    if not isinstance(color, str) or not _TITLE_COLOR_RE.fullmatch(color):
        raise ValueError("title_color must be a #RRGGBB hex color")
    return color.upper()


def _normalize_key(value, allowed: frozenset, field: str) -> str | None:
    """Exact-match allowlist key or ``None`` (= default). Never coerces case,
    whitespace or type; unknown keys are rejected, not dropped."""
    if value is None:
        return None
    if not isinstance(value, str) or value not in allowed:
        raise ValueError(f"{field} is not a recognised option")
    return value


def normalize_title_font(value) -> str | None:
    return _normalize_key(value, TITLE_FONT_KEYS, "title_font")


def normalize_bg_theme(value) -> str | None:
    return _normalize_key(value, BG_THEME_KEYS, "bg_theme")


def normalize_description(description: str | None) -> str:
    cleaned = (description or "").strip()
    if len(cleaned) > ANNOUNCEMENT_DESCRIPTION_MAX_LENGTH:
        raise ValueError(f"Description must be {ANNOUNCEMENT_DESCRIPTION_MAX_LENGTH} characters or fewer")
    return cleaned


class AnnouncementsManager(GroupsManager):
    """Announcement CRUD for one user/group context."""

    # ── helpers ───────────────────────────────────────────────────────────

    def _group_creator_id(self) -> str | None:
        group = self.lookup("groups", {"_id": self.group_id})
        if not group:
            return None
        _, data = list(group.items())[0]
        creator = data.get("creator_id")
        return str(creator) if creator else None

    def _serialize(self, row: tuple, group_creator: str | None) -> dict:
        (aid, gid, creator, username, title, description, banner_key,
         publish_at, created_at, updated_at, title_color, title_font, bg_theme,
         links, gallery_keys, is_event, payment_handles, capacity) = row
        creator_s = str(creator) if creator else None
        out = {
            "id": str(aid),
            "group_id": str(gid),
            "creator_id": creator_s,
            "creator_username": username,
            "title": title,
            "description": description,
            "banner_url": generate_download_url(banner_key),
            "title_color": title_color,
            "publish_at": publish_at.isoformat(),
            "created_at": created_at.isoformat(),
            "updated_at": updated_at.isoformat(),
            "published": publish_at <= datetime.now(timezone.utc),
            "can_edit": self.user_id == creator_s or (group_creator is not None and self.user_id == group_creator),
        }
        # Flag-gated keys are omitted entirely while off, so the payload is
        # identical to the pre-flag shape. Stored values survive a flag-off
        # period and reappear when it is turned back on.
        if flags.is_enabled(TITLE_FONT_FLAG, self.user_id):
            out["title_font"] = title_font
        if flags.is_enabled(BG_THEME_FLAG, self.user_id):
            out["bg_theme"] = bg_theme
        if flags.is_enabled(LINKS_FLAG, self.user_id):
            out["links"] = links or []
        if flags.is_enabled(GALLERY_FLAG, self.user_id):
            out["gallery"] = [{"key": k, "url": generate_download_url(k)} for k in (gallery_keys or [])]
        if flags.is_enabled(PAYMENTS_FLAG, self.user_id):
            out["is_event"] = bool(is_event)
            out["payment_handles"] = payment_handles or []
        if flags.is_enabled(RSVP_FLAG, self.user_id):
            out["capacity"] = capacity
        return out

    def _serialize_many(self, rows: list, group_creator: str | None) -> list[dict]:
        """Serialize rows, then attach RSVP counts in one batch query."""
        out = [self._serialize(r, group_creator) for r in rows]
        if out and flags.is_enabled(RSVP_FLAG, self.user_id):
            counts = self._rsvp_counts([d["id"] for d in out if d.get("capacity") is not None])
            for d in out:
                if d.get("capacity") is not None:
                    d["rsvp_count"], d["rsvp_joined"] = counts.get(d["id"], (0, False))
        return out

    def _rsvp_counts(self, ids: list[str]) -> dict[str, tuple[int, bool]]:
        """``{announcement_id: (count, caller_joined)}``. Only RSVPs from
        current group members count, so a member who left frees their spot."""
        if not ids:
            return {}
        self.cur.execute(
            "SELECT r.announcement_id, count(*), COALESCE(bool_or(r.user_id::text = %s), FALSE) "
            "FROM group_announcement_rsvps r "
            "JOIN group_announcements a ON a._id = r.announcement_id "
            "JOIN groups g ON g._id = a.group_id "
            "WHERE r.announcement_id = ANY(%s::uuid[]) AND r.user_id::text = ANY(g.users) "
            "GROUP BY r.announcement_id",
            (self.user_id, ids),
        )
        return {str(a): (int(n), bool(j)) for a, n, j in self.cur.fetchall()}

    def _checked_extras(self, given: dict, current: dict) -> dict:
        """Validate the part E fields present in ``given`` and return column
        values to write. ``current`` holds the stored values (defaults on
        create). Non-empty values need their flag on (fail closed, ValueError
        -> 422); empty/null always clears. Raises AnnouncementForbidden for a
        gallery key outside this group's prefix."""
        out: dict = {}

        def gated(flag, name):
            if not flags.is_enabled(flag, self.user_id):
                raise ValueError(f"{name} is not available")

        if "links" in given:
            value = extras.normalize_links(given["links"])
            if value:
                gated(LINKS_FLAG, "links")
            out["links"] = json.dumps(value) if value else None
        if "gallery_keys" in given:
            raw = given["gallery_keys"]
            if isinstance(raw, list):
                for k in raw:
                    if isinstance(k, str) and not is_announcement_banner_key(self.group_id, k):
                        raise AnnouncementForbidden()
            value = extras.normalize_gallery_keys(raw, lambda k: is_announcement_banner_key(self.group_id, k))
            if value:
                gated(GALLERY_FLAG, "gallery_keys")
            out["gallery_keys"] = json.dumps(value) if value else None
        is_event = current["is_event"]
        if "is_event" in given:
            if given["is_event"] is not None and not isinstance(given["is_event"], bool):
                raise ValueError("is_event must be true or false")
            is_event = bool(given["is_event"])
            if is_event:
                gated(PAYMENTS_FLAG, "is_event")
            out["is_event"] = is_event
        if "payment_handles" in given:
            value = extras.normalize_payment_handles(given["payment_handles"])
            if value:
                gated(PAYMENTS_FLAG, "payment_handles")
                if not is_event:
                    raise ValueError("payment_handles need is_event to be true")
            out["payment_handles"] = json.dumps(value) if value else None
        elif not is_event and current["payment_handles"]:
            out["payment_handles"] = None  # event switched off: drop its handles
        if "capacity" in given:
            value = extras.normalize_capacity(given["capacity"])
            if value is not None:
                gated(RSVP_FLAG, "capacity")
            out["capacity"] = value
        return out

    def _checked_style(self, title_font, bg_theme, *, font_given: bool, theme_given: bool) -> dict:
        """Validate the optional style fields. A non-null value while its flag
        is off is rejected (fail closed, ValueError -> 422); an explicit null
        is always accepted (it only clears)."""
        out: dict = {}
        if font_given:
            value = normalize_title_font(title_font)
            if value is not None and not flags.is_enabled(TITLE_FONT_FLAG, self.user_id):
                raise ValueError("title_font is not available")
            out["title_font"] = value
        if theme_given:
            value = normalize_bg_theme(bg_theme)
            if value is not None and not flags.is_enabled(BG_THEME_FLAG, self.user_id):
                raise ValueError("bg_theme is not available")
            out["bg_theme"] = value
        return out

    def _fetch_row(self, announcement_id: str, *, include_deleted: bool = False) -> tuple | None:
        """Row visible to the caller (published, or their own scheduled)."""
        deleted_clause = "" if include_deleted else "AND a.deleted_at IS NULL "
        self.cur.execute(
            f"SELECT {_COLUMNS} {_FROM} "
            f"WHERE a._id = %s AND a.group_id = %s {deleted_clause}"
            "AND (a.publish_at <= now() OR a.creator_id = %s)",
            (announcement_id, self.group_id, self.user_id),
        )
        return self.cur.fetchone()

    def _require_editable(self, row: tuple) -> None:
        creator = str(row[2]) if row[2] else None
        if self.user_id != creator and self.user_id != self._group_creator_id():
            raise AnnouncementForbidden()

    def _check_banner_key(self, key: str | None) -> None:
        if key is not None and not is_announcement_banner_key(self.group_id, key):
            raise AnnouncementForbidden()

    # ── reads ─────────────────────────────────────────────────────────────

    def list_announcements(self) -> dict:
        """Newest-first page: ``{"announcements": [...], "truncated": bool}``.
        Blocked users' announcements are excluded."""
        blocked = list(self._blocked_set())
        self.cur.execute(
            f"SELECT {_COLUMNS} {_FROM} "
            "WHERE a.group_id = %s AND a.deleted_at IS NULL "
            "AND (a.publish_at <= now() OR a.creator_id = %s) "
            "AND (a.creator_id IS NULL OR NOT (a.creator_id::text = ANY(%s))) "
            "ORDER BY a.publish_at DESC, a._id DESC LIMIT %s",
            (self.group_id, self.user_id, blocked, ANNOUNCEMENTS_PAGE_SIZE + 1),
        )
        rows = self.cur.fetchall()
        creator = self._group_creator_id()
        return {
            "announcements": self._serialize_many(rows[:ANNOUNCEMENTS_PAGE_SIZE], creator),
            "truncated": len(rows) > ANNOUNCEMENTS_PAGE_SIZE,
        }

    def latest_widget_announcement(self) -> dict:
        """``{"announcement": <dict> | None}``: the newest published,
        non-deleted announcement from the last ``ANNOUNCEMENT_WIDGET_WINDOW_DAYS``
        days, excluding blocked authors. Unlike the list, an author's own
        still-scheduled rows are never returned."""
        blocked = list(self._blocked_set())
        self.cur.execute(
            f"SELECT {_COLUMNS} {_FROM} "
            "WHERE a.group_id = %s AND a.deleted_at IS NULL "
            "AND a.publish_at <= now() "
            "AND a.publish_at >= now() - make_interval(days => %s) "
            "AND (a.creator_id IS NULL OR NOT (a.creator_id::text = ANY(%s))) "
            "ORDER BY a.publish_at DESC, a._id DESC LIMIT 1",
            (self.group_id, ANNOUNCEMENT_WIDGET_WINDOW_DAYS, blocked),
        )
        row = self.cur.fetchone()
        return {"announcement": self._serialize_many([row], self._group_creator_id())[0] if row else None}

    def get_announcement(self, announcement_id: str) -> dict:
        row = self._fetch_row(announcement_id)
        if not row:
            raise AnnouncementNotFound()
        return self._serialize_many([row], self._group_creator_id())[0]

    # ── writes ────────────────────────────────────────────────────────────

    def create_announcement(self, title: str, description: str | None,
                            banner_key: str | None, publish_at: datetime | None,
                            title_color: str | None = None, title_font: str | None = None,
                            bg_theme: str | None = None, extra: dict | None = None) -> dict:
        """Insert an announcement. The caller must already have passed the
        free-limit gate. Raises ValueError (validation, incl. bad title_color),
        AnnouncementForbidden (foreign banner key), SaveFailedError."""
        title = normalize_title(title)
        description = normalize_description(description)
        title_color = normalize_title_color(title_color)
        style = self._checked_style(title_font, bg_theme,
                                    font_given=title_font is not None, theme_given=bg_theme is not None)
        self._check_banner_key(banner_key)
        ex = self._checked_extras(extra or {}, {"is_event": False, "payment_handles": None})
        try:
            self.cur.execute(
                "INSERT INTO group_announcements "
                "(group_id, creator_id, title, description, banner_key, publish_at, title_color, "
                "title_font, bg_theme, links, gallery_keys, is_event, payment_handles, capacity) "
                "VALUES (%s, %s, %s, %s, %s, COALESCE(%s, now()), %s, %s, %s, %s::jsonb, %s::jsonb, %s, %s::jsonb, %s) "
                "RETURNING _id",
                (self.group_id, self.user_id, title, description, banner_key, publish_at, title_color,
                 style.get("title_font"), style.get("bg_theme"), ex.get("links"), ex.get("gallery_keys"),
                 ex.get("is_event", False), ex.get("payment_handles"), ex.get("capacity")),
            )
            new_id = self.cur.fetchone()[0]
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise SaveFailedError()
        return self.get_announcement(str(new_id))

    def update_announcement(self, announcement_id: str, fields: dict) -> dict:
        """Partial update. ``fields`` may contain title, description,
        banner_key (None clears), title_color (None resets), title_font and
        bg_theme (None resets; non-null needs the feature flag), publish_at (datetime; only while still
        unpublished). Only keys present are applied."""
        row = self._fetch_row(announcement_id)
        if not row:
            raise AnnouncementNotFound()
        self._require_editable(row)
        sets: dict = {}
        if "title" in fields:
            sets["title"] = normalize_title(fields["title"])
        if "description" in fields:
            sets["description"] = normalize_description(fields["description"])
        if "banner_key" in fields:
            self._check_banner_key(fields["banner_key"])
            sets["banner_key"] = fields["banner_key"]
        if "title_color" in fields:
            sets["title_color"] = normalize_title_color(fields["title_color"])  # None resets to default
        sets.update(self._checked_style(
            fields.get("title_font"), fields.get("bg_theme"),
            font_given="title_font" in fields, theme_given="bg_theme" in fields))
        old_gallery = list(row[14] or [])
        ex = self._checked_extras(
            {k: fields[k] for k in ("links", "gallery_keys", "is_event", "payment_handles", "capacity") if k in fields},
            {"is_event": bool(row[15]), "payment_handles": row[16]})
        sets.update(ex)
        if "publish_at" in fields:
            if fields["publish_at"] is None:
                raise ValueError("publish_at can't be cleared")
            if row[7] <= datetime.now(timezone.utc):
                raise ValueError("A published announcement's publish time can't be changed")
            sets["publish_at"] = fields["publish_at"]
        if not sets:
            raise ValueError("No changes supplied")
        sets["updated_at"] = datetime.now(timezone.utc)
        if "capacity" in ex:
            self._guard_capacity_change(announcement_id, ex["capacity"])
        if not self.update("group_announcements", sets, {"_id": announcement_id, "group_id": self.group_id}):
            self.conn.rollback()
            raise SaveFailedError()
        if "gallery_keys" in ex:
            kept = set(json.loads(ex["gallery_keys"]) if ex["gallery_keys"] else [])
            for key in old_gallery:
                if key not in kept and not self._key_in_use(key):
                    delete_object(key)
        old_banner = row[6]
        if "banner_key" in sets and old_banner and old_banner != sets["banner_key"]:
            # Only sweep the old object if no other announcement still points
            # at it (a member could otherwise reference a peer's uploaded key
            # and then delete it by replacing it).
            if not self._key_in_use(old_banner):
                delete_object(old_banner)
        return self.get_announcement(announcement_id)

    def _key_in_use(self, key: str) -> bool:
        """True if any announcement still references this S3 key (banner or gallery)."""
        self.cur.execute(
            "SELECT 1 FROM group_announcements WHERE banner_key = %s OR gallery_keys @> %s::jsonb LIMIT 1",
            (key, json.dumps([key])),
        )
        return self.cur.fetchone() is not None

    def _guard_capacity_change(self, announcement_id: str, new_capacity: int | None) -> None:
        """Runs inside the update transaction (row locked until its commit).
        Lowering capacity below current RSVPs is rejected; clearing it drops
        the RSVPs. Rolls back and raises on rejection."""
        self.cur.execute("SELECT 1 FROM group_announcements WHERE _id = %s FOR UPDATE", (announcement_id,))
        if new_capacity is None:
            self.cur.execute("DELETE FROM group_announcement_rsvps WHERE announcement_id = %s", (announcement_id,))
            return
        taken = self._rsvp_counts([announcement_id]).get(announcement_id, (0, False))[0]
        if new_capacity < taken:
            self.conn.rollback()
            raise ValueError(f"capacity can't be below the {taken} current RSVPs")

    # ── RSVP (a sign-up for the event; never a group membership change) ───

    def _rsvp_lock(self, announcement_id: str) -> tuple:
        """Lock the announcement row and return ``(capacity, publish_at, creator_id)``.
        Deny by default: flag off, missing, deleted, scheduled, not joinable,
        or authored by someone in a block relationship with the caller all
        raise AnnouncementNotFound. Caller is already a verified member."""
        if not flags.is_enabled(RSVP_FLAG, self.user_id):
            raise AnnouncementNotFound()
        self.cur.execute(
            "SELECT capacity, publish_at, creator_id FROM group_announcements "
            "WHERE _id = %s AND group_id = %s AND deleted_at IS NULL FOR UPDATE",
            (announcement_id, self.group_id),
        )
        row = self.cur.fetchone()
        if (not row or row[0] is None or row[1] > datetime.now(timezone.utc)
                or (row[2] is not None and str(row[2]) in self._blocked_set())):
            self.conn.rollback()
            raise AnnouncementNotFound()
        return row

    def rsvp_join(self, announcement_id: str) -> dict:
        """Idempotent. The announcement row is locked (FOR UPDATE) so the
        count check and insert are atomic: concurrent joins cannot overbook.
        Raises AnnouncementNotFound, AnnouncementFull, SaveFailedError."""
        try:
            capacity = self._rsvp_lock(announcement_id)[0]
            counts = self._rsvp_counts([announcement_id])
            taken, joined = counts.get(announcement_id, (0, False))
            if not joined:
                if taken >= capacity:
                    self.conn.rollback()
                    raise AnnouncementFull()
                self.cur.execute(
                    "INSERT INTO group_announcement_rsvps (announcement_id, user_id) VALUES (%s, %s) "
                    "ON CONFLICT DO NOTHING",
                    (announcement_id, self.user_id),
                )
            self.conn.commit()
        except (AnnouncementNotFound, AnnouncementFull):
            raise
        except Exception:
            self.conn.rollback()
            raise SaveFailedError()
        return self.get_announcement(announcement_id)

    def rsvp_leave(self, announcement_id: str) -> dict:
        """Idempotent."""
        try:
            self._rsvp_lock(announcement_id)
            self.cur.execute(
                "DELETE FROM group_announcement_rsvps WHERE announcement_id = %s AND user_id = %s",
                (announcement_id, self.user_id),
            )
            self.conn.commit()
        except AnnouncementNotFound:
            raise
        except Exception:
            self.conn.rollback()
            raise SaveFailedError()
        return self.get_announcement(announcement_id)

    def list_rsvps(self, announcement_id: str) -> dict:
        """Host-only attendee list (announcement creator or group creator).
        Excludes people in a block relationship with the caller."""
        if not flags.is_enabled(RSVP_FLAG, self.user_id):
            raise AnnouncementNotFound()
        row = self._fetch_row(announcement_id)
        if not row:
            raise AnnouncementNotFound()
        self._require_editable(row)
        blocked = list(self._blocked_set())
        self.cur.execute(
            "SELECT r.user_id, u.username, r.created_at FROM group_announcement_rsvps r "
            "JOIN users u ON u._id = r.user_id JOIN groups g ON g._id = %s "
            "WHERE r.announcement_id = %s AND r.user_id::text = ANY(g.users) "
            "AND NOT (r.user_id::text = ANY(%s)) ORDER BY r.created_at, r.user_id",
            (self.group_id, announcement_id, blocked),
        )
        people = [{"user_id": str(u), "username": n, "joined_at": t.isoformat()}
                  for u, n, t in self.cur.fetchall()]
        return {"capacity": row[17], "rsvps": people}

    def delete_announcement(self, announcement_id: str) -> None:
        """Soft delete (tombstone); restorable within the undo grace window."""
        row = self._fetch_row(announcement_id)
        if not row:
            raise AnnouncementNotFound()
        self._require_editable(row)
        if not self.update("group_announcements", {"deleted_at": datetime.now(timezone.utc)},
                           {"_id": announcement_id, "group_id": self.group_id}):
            raise SaveFailedError()

    def restore_announcement(self, announcement_id: str) -> dict:
        """Undo a delete made within ``ANNOUNCEMENT_UNDO_GRACE_SECONDS``.
        Raises AnnouncementNotFound if not tombstoned or the grace lapsed."""
        row = self._fetch_row(announcement_id, include_deleted=True)
        if not row:
            raise AnnouncementNotFound()
        self._require_editable(row)
        self.cur.execute(
            "UPDATE group_announcements SET deleted_at = NULL "
            "WHERE _id = %s AND group_id = %s AND deleted_at IS NOT NULL "
            "AND deleted_at >= now() - (%s || ' seconds')::interval",
            (announcement_id, self.group_id, ANNOUNCEMENT_UNDO_GRACE_SECONDS),
        )
        restored = self.cur.rowcount > 0
        self.conn.commit()
        if not restored:
            raise AnnouncementNotFound()
        return self.get_announcement(announcement_id)
