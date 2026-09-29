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

import re
from datetime import datetime, timedelta, timezone

from backend.errors import SaveFailedError
from backend.interactions.announcement_banner import is_announcement_banner_key
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
    "a.publish_at, a.created_at, a.updated_at, a.title_color"
)
_FROM = "FROM group_announcements a LEFT JOIN users u ON u._id = a.creator_id"


class AnnouncementNotFound(Exception):
    """No visible announcement with that id in this group (404)."""


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
         publish_at, created_at, updated_at, title_color) = row
        creator_s = str(creator) if creator else None
        return {
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
            "announcements": [self._serialize(r, creator) for r in rows[:ANNOUNCEMENTS_PAGE_SIZE]],
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
        return {"announcement": self._serialize(row, self._group_creator_id()) if row else None}

    def get_announcement(self, announcement_id: str) -> dict:
        row = self._fetch_row(announcement_id)
        if not row:
            raise AnnouncementNotFound()
        return self._serialize(row, self._group_creator_id())

    # ── writes ────────────────────────────────────────────────────────────

    def create_announcement(self, title: str, description: str | None,
                            banner_key: str | None, publish_at: datetime | None,
                            title_color: str | None = None) -> dict:
        """Insert an announcement. The caller must already have passed the
        free-limit gate. Raises ValueError (validation, incl. bad title_color),
        AnnouncementForbidden (foreign banner key), SaveFailedError."""
        title = normalize_title(title)
        description = normalize_description(description)
        title_color = normalize_title_color(title_color)
        self._check_banner_key(banner_key)
        try:
            self.cur.execute(
                "INSERT INTO group_announcements "
                "(group_id, creator_id, title, description, banner_key, publish_at, title_color) "
                "VALUES (%s, %s, %s, %s, %s, COALESCE(%s, now()), %s) RETURNING _id",
                (self.group_id, self.user_id, title, description, banner_key, publish_at, title_color),
            )
            new_id = self.cur.fetchone()[0]
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise SaveFailedError()
        return self.get_announcement(str(new_id))

    def update_announcement(self, announcement_id: str, fields: dict) -> dict:
        """Partial update. ``fields`` may contain title, description,
        banner_key (None clears), title_color (None resets), publish_at (datetime; only while still
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
        if "publish_at" in fields:
            if fields["publish_at"] is None:
                raise ValueError("publish_at can't be cleared")
            if row[7] <= datetime.now(timezone.utc):
                raise ValueError("A published announcement's publish time can't be changed")
            sets["publish_at"] = fields["publish_at"]
        if not sets:
            raise ValueError("No changes supplied")
        sets["updated_at"] = datetime.now(timezone.utc)
        if not self.update("group_announcements", sets, {"_id": announcement_id, "group_id": self.group_id}):
            raise SaveFailedError()
        old_banner = row[6]
        if "banner_key" in sets and old_banner and old_banner != sets["banner_key"]:
            # Only sweep the old object if no other announcement still points
            # at it (a member could otherwise reference a peer's uploaded key
            # and then delete it by replacing it).
            self.cur.execute(
                "SELECT 1 FROM group_announcements WHERE banner_key = %s LIMIT 1", (old_banner,),
            )
            if not self.cur.fetchone():
                delete_object(old_banner)
        return self.get_announcement(announcement_id)

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
