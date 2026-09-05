from datetime import datetime, timezone as tzmod
from schemas.users import User
from db import DBManager
from backend.errors import SaveFailedError
from backend.interactions.attachments import generate_download_url
from backend.interactions.blocks import BlockManager
from backend.interactions.bible_text import parse_highlight_key, verse_text


class FriendsManager(DBManager):
    """Handles friend request, acceptance, removal, and DM retrieval."""

    def __init__(self, user_id: str) -> None:
        super().__init__()
        self.user_id = user_id
        result = self.lookup("users", {"_id": user_id})
        if result:
            uid, data = list(result.items())[0]
            self.user = User(user_id=uid, **data)
        else:
            self.user = User()

    def send_add_request(self, friend_username: str) -> dict | None:
        """Append the acting user's ID to the target user's friend_requests list.

        Args:
            friend_username: Username of the user to send the request to.

        Returns:
            dict | None: ``{"error": str}`` if the user is not found or the
                user attempts to add themselves; ``None`` on success.
        """
        result = self.lookup("users", {"username": friend_username})
        if not result:
            return {"error": "User not found"}
        friend_id = list(result.keys())[0]
        if friend_id == self.user_id:
            return {"error": "Cannot add yourself"}
        blocks = BlockManager(self.user_id)
        try:
            if blocks.is_blocked(friend_id):
                return {"error": "Cannot send request"}
        finally:
            blocks.close()
        if not self.insertion("friend_requests", {
            "to_user_id":   friend_id,
            "from_user_id": self.user_id,
        }):
            raise SaveFailedError()
        return None

    def add_friend(self, friend_username: str) -> dict | None:
        """Accept a pending friend request and establish a mutual friendship.

        Args:
            friend_username: Username of the user to accept as a friend.

        Returns:
            dict | None: ``{"error": str}`` if the user is not found;
                ``None`` on success.
        """
        result = self.lookup("users", {"username": friend_username})
        if not result:
            return {"error": "User not found"}
        friend_id = list(result.keys())[0]
        blocks = BlockManager(self.user_id)
        try:
            if blocks.is_blocked(friend_id):
                return {"error": "Cannot add this user"}
        finally:
            blocks.close()
        if not self.insertion("user_friends", {"user_id": self.user_id, "friend_id": friend_id}):
            raise SaveFailedError()
        if not self.insertion("user_friends", {"user_id": friend_id, "friend_id": self.user_id}):
            raise SaveFailedError()
        # Best-effort cleanup of the now-accepted request row -- the
        # friendship itself (the two inserts above) is already established,
        # so a stray/already-gone request row here is not treated as this
        # call's own failure (a real DB error is still visible via db.py's
        # DB_WRITE_FAILURE log line).
        self.delete("friend_requests", {"to_user_id": self.user_id, "from_user_id": friend_id})
        return None

    def get_requests(self) -> list[dict]:
        """Return pending *incoming* friend requests for the acting user.

        Each entry is the sender's public identity, so the account page can show
        who wants to connect.

        Returns:
            list[dict]: ``[{"user_id": str, "username": str,
                "profile_photo_url": str | None}, ...]``.
        """
        self.cur.execute(
            "SELECT u._id, u.username, u.profile_photo_key FROM users u "
            "JOIN friend_requests fr ON u._id = fr.from_user_id "
            "WHERE fr.to_user_id = %s",
            (self.user_id,)
        )
        return [
            {"user_id": r[0], "username": r[1], "profile_photo_url": generate_download_url(r[2])}
            for r in self.cur.fetchall()
        ]

    def get_friends(self) -> list[dict]:
        """Return the full friend list for the acting user.

        Returns:
            list[dict]: List of friend user records with ``hash_pass`` excluded.
        """
        self.cur.execute(
            "SELECT u._id, u.username, u.email, u.profile_photo_key FROM users u "
            "JOIN user_friends uf ON u._id = uf.friend_id "
            "WHERE uf.user_id = %s",
            (self.user_id,)
        )
        return [
            {"user_id": r[0], "username": r[1], "email": r[2], "profile_photo_url": generate_download_url(r[3])}
            for r in self.cur.fetchall()
        ]

    @staticmethod
    def _format_dm_row(from_username: str, row: tuple) -> dict:
        """Shape one ``messages`` row (as selected in ``read_friend``) into
        the dict the client expects, resolving ``attachment_key`` to a
        fresh presigned GET (never handing back the stored key itself --
        see backend/interactions/attachments.py)."""
        _id, text, timestamp, attachment_kind, attachment_key, attachment_meta = row
        return {
            "from_user": from_username,
            "text": text,
            "timestamp": str(timestamp),
            "attachment_kind": attachment_kind,
            "attachment_meta": attachment_meta or {},
            "attachment_url": generate_download_url(attachment_key) if attachment_key else None,
        }

    def read_friend(self, friend_id: str) -> dict:
        """Fetch a friend's profile and the shared DM history.

        Args:
            friend_id: UUID of the friend to retrieve.

        Returns:
            dict: Contains ``friend`` profile (without hash_pass), ``host_msgs``,
                and ``other_msgs``. Returns ``{"error": str}`` if not found.
        """
        result = self.lookup("users", {"_id": friend_id})
        if not result:
            return {"error": "Friend not found"}
        blocks = BlockManager(self.user_id)
        try:
            if blocks.is_blocked(friend_id):
                return {"error": "This contact is unavailable"}
        finally:
            blocks.close()
        _, friend_data = list(result.items())[0]
        # Task 20260904-messaging-attachments: attachment_kind/attachment_meta
        # ride along with text/timestamp; attachment_key itself is never
        # handed to the client -- it's resolved to a fresh, short-lived
        # presigned GET at read time instead (see _format_dm_row below).
        self.cur.execute(
            "SELECT m._id, m.text, m.timestamp, m.attachment_kind, m.attachment_key, m.attachment_meta "
            "FROM messages m "
            "JOIN message_recipients mr ON m._id = mr.message_id "
            "WHERE m.from_user = %s AND mr.user_id = %s AND m.group_id IS NULL",
            (self.user_id, friend_id)
        )
        host_msgs = [
            self._format_dm_row(self.user.username, r) for r in self.cur.fetchall()
        ]
        self.cur.execute(
            "SELECT m._id, m.text, m.timestamp, m.attachment_kind, m.attachment_key, m.attachment_meta "
            "FROM messages m "
            "JOIN message_recipients mr ON m._id = mr.message_id "
            "WHERE m.from_user = %s AND mr.user_id = %s AND m.group_id IS NULL",
            (friend_id, self.user_id)
        )
        other_msgs = [
            self._format_dm_row(friend_data.get("username", ""), r) for r in self.cur.fetchall()
        ]
        # Same raw-key-never-leaves-the-server treatment as hash_pass just
        # below -- friend_data here is a raw `lookup()` row, so
        # profile_photo_key must be popped unconditionally and resolved to a
        # fresh presigned GET (task 20260905-profile-photo).
        friend_view = {k: v for k, v in friend_data.items() if k != "hash_pass"}
        friend_view["profile_photo_url"] = generate_download_url(friend_view.pop("profile_photo_key", None))
        return {
            "friend":     friend_view,
            "host_msgs":  host_msgs,
            "other_msgs": other_msgs,
        }

    def remove_friend(self, friend_id: str) -> None:
        """Remove a friend from both users' friend lists.

        Args:
            friend_id: UUID of the friend to remove.
        """
        # Best-effort/idempotent: either direction may already be gone (a
        # partial prior removal, a race with block_user's own cleanup), so
        # a zero-rows False here is not treated as failure -- a real DB
        # error is still visible via db.py's DB_WRITE_FAILURE log line.
        self.delete("user_friends", {"user_id": self.user_id, "friend_id": friend_id})
        self.delete("user_friends", {"user_id": friend_id, "friend_id": self.user_id})

    # Size of the "check in" nudge candidate pool (see get_friend_activity).
    # Bounded rather than unbounded so the nudge keeps its stated purpose --
    # surfacing a genuinely-neglected friend -- instead of degrading into a
    # pick from the user's entire friend list regardless of recency.
    CHECK_IN_POOL_SIZE = 5

    def get_friend_activity(self, limit: int = 20) -> dict:
        """Friend-activity read surface for the dashboard's Friend Activity
        hero card: each friend's most recent note preview drawn from a
        group note the *viewer* (`self.user_id`) can also see -- plus their
        last-activity timestamp, ordered most-recently-active first, and a
        bounded "check in" nudge candidate pool -- the friends the acting
        user has gone longest without directly messaging.

        Note-preview data source (post `notes.public` repurposing, task
        20260903-notes-public-repurpose): `notes.public` no longer means
        visibility, and a friend's personal notes (`group_id IS NULL`) are
        now unconditionally private to their owner, so they are no longer a
        valid preview source at all -- a friendship alone never implies
        note visibility. Instead this pulls the friend's most recent
        *group* note (`group_id IS NOT NULL`, `is_reply = false`) whose
        group the viewer also currently belongs to (shared membership,
        checked against `groups.users`) -- i.e. only a note the viewer
        could already see for themselves via the group notes feed, never a
        friend's private content. A friend with no such shared-group note
        (including one with only personal notes, or group notes in groups
        the viewer isn't in) simply gets `note_preview: None`.

        The check-in pool is intentionally bounded (`CHECK_IN_POOL_SIZE`,
        capped at the user's actual friend count via `LIMIT`) rather than
        covering the whole friend list: the nudge's purpose is surfacing a
        genuinely-neglected friend, so the client is expected to pick
        (e.g. randomly) from within this "longest since contact" pool, not
        from friends who were recently contacted.

        Block-respecting in both directions via the same defense-in-depth
        `NOT EXISTS` pattern as `ActivityManager.friend_device_tokens`
        (this subsystem's prior IDOR history means block state is
        re-checked here rather than trusted to have fully unwound
        `user_friends` already).

        Highlights (task 20260904-friend-activity-push-triggers, Round 2):
        friendship alone is sufficient grant to see a friend's highlight,
        including its real verse content -- a deliberate widening of the
        prior rule (highlights had zero visibility to anyone, friend or
        not), since unlike notes a highlight never had any group/ownership
        scoping to preserve. This does NOT reopen note/reply visibility --
        the group-membership-gated `note_preview` above is untouched. Each
        friend's most recent highlight (by `highlights.timestamp`) is
        resolved to `highlight_preview`, still subject to the same
        block-respecting `NOT EXISTS` predicate as everything else in this
        query (defense-in-depth, same reasoning as
        `ActivityManager.friend_device_tokens`). Verse text is resolved via
        `bible_text.verse_text`; a lookup miss just leaves `verse_text: None`
        in the preview (client decides how to degrade) rather than dropping
        the whole entry.

        Args:
            limit: Max number of friends to return in `friends_active`
                (bounds the avatar-stack list; the mockup shows one primary
                + a handful of others).

        Returns:
            dict: ``{"friends_active": [{"friend_id", "username",
                "profile_photo_url": str | None, "last_active_at",
                "activity_type": str | None, "note_preview": {"note_id",
                "title", "text", "timestamp"} | None, "highlight_preview":
                {"book", "chapter", "verse", "color", "verse_text": str |
                None, "timestamp"} | None}, ...], "check_in_candidates":
                [{"friend_id", "username", "profile_photo_url": str | None,
                "days_since_contact": int | None}, ...]}``. `friends_active`
                is ordered by `last_active_at` descending (friends with no
                tracked activity sort last). `activity_type` is the friend's
                `last_activity_type` (one of activity.py's NOTE_CREATED/
                NOTE_EDITED/NOTE_REPLIED/VERSE_HIGHLIGHTED, or None) so the
                client can pick per-type title wording without a second
                round trip. `check_in_candidates` is ordered
                longest-since-contact first, capped at `CHECK_IN_POOL_SIZE`
                entries (or the friend count, whichever is smaller), and is
                an empty list only when the user has no friends; a
                candidate's `days_since_contact` is None when that pair has
                never messaged directly (still a valid, arguably stronger,
                nudge candidate -- it sorts as if "longest ago").
        """
        self.cur.execute(
            "SELECT uf.friend_id, u.username, u.profile_photo_key, ua.last_activity_at, ua.last_activity_type, "
            "n._id, n.title, n.text, n.timestamp, "
            "h.key, h.color, h.timestamp "
            "FROM user_friends uf "
            "JOIN users u ON u._id = uf.friend_id "
            "LEFT JOIN user_activity ua ON ua.user_id = uf.friend_id "
            "LEFT JOIN LATERAL ("
            "  SELECT _id, title, text, timestamp FROM notes "
            "  WHERE user_id = uf.friend_id AND is_reply = FALSE "
            "    AND group_id IS NOT NULL "
            "    AND EXISTS ("
            "      SELECT 1 FROM groups g "
            "      WHERE g._id = notes.group_id AND uf.user_id::text = ANY(g.users)"
            "    ) "
            "  ORDER BY timestamp DESC LIMIT 1"
            ") n ON TRUE "
            "LEFT JOIN LATERAL ("
            "  SELECT key, color, timestamp FROM highlights "
            "  WHERE user_id = uf.friend_id "
            "  ORDER BY timestamp DESC LIMIT 1"
            ") h ON TRUE "
            "WHERE uf.user_id = %s "
            "AND NOT EXISTS ("
            "  SELECT 1 FROM blocked_users b "
            "  WHERE (b.blocker_id = uf.friend_id AND b.blocked_id = uf.user_id) "
            "     OR (b.blocker_id = uf.user_id AND b.blocked_id = uf.friend_id)"
            ") "
            "ORDER BY ua.last_activity_at DESC NULLS LAST "
            "LIMIT %s",
            (self.user_id, limit),
        )
        friends_active = []
        for r in self.cur.fetchall():
            (friend_id, username, profile_photo_key, last_active_at, last_activity_type,
             note_id, note_title, note_text, note_ts,
             h_key, h_color, h_ts) = r
            highlight_preview = None
            if h_key:
                parsed = parse_highlight_key(h_key)
                if parsed:
                    book, chapter, verse = parsed
                    highlight_preview = {
                        "book": book,
                        "chapter": chapter,
                        "verse": verse,
                        "color": h_color,
                        "verse_text": verse_text(book, chapter, verse),
                        "timestamp": str(h_ts) if h_ts else None,
                    }
            friends_active.append({
                "friend_id": str(friend_id),
                "username": username,
                "profile_photo_url": generate_download_url(profile_photo_key),
                "last_active_at": str(last_active_at) if last_active_at else None,
                "activity_type": last_activity_type,
                "note_preview": (
                    {"note_id": str(note_id), "title": note_title, "text": note_text, "timestamp": str(note_ts)}
                    if note_id else None
                ),
                "highlight_preview": highlight_preview,
            })

        self.cur.execute(
            "SELECT uf.friend_id, u.username, u.profile_photo_key, "
            "  (SELECT MAX(m.timestamp) FROM messages m "
            "   JOIN message_recipients mr ON mr.message_id = m._id "
            "   WHERE m.group_id IS NULL "
            "     AND ((m.from_user = uf.user_id AND mr.user_id = uf.friend_id) "
            "       OR (m.from_user = uf.friend_id AND mr.user_id = uf.user_id))"
            "  ) AS last_contact "
            "FROM user_friends uf "
            "JOIN users u ON u._id = uf.friend_id "
            "WHERE uf.user_id = %s "
            "AND NOT EXISTS ("
            "  SELECT 1 FROM blocked_users b "
            "  WHERE (b.blocker_id = uf.friend_id AND b.blocked_id = uf.user_id) "
            "     OR (b.blocker_id = uf.user_id AND b.blocked_id = uf.friend_id)"
            ") "
            "ORDER BY last_contact ASC NULLS FIRST "
            "LIMIT %s",
            (self.user_id, self.CHECK_IN_POOL_SIZE),
        )
        check_in_candidates = []
        for friend_id, username, profile_photo_key, last_contact in self.cur.fetchall():
            days_since_contact = None
            if last_contact:
                if last_contact.tzinfo is None:
                    last_contact = last_contact.replace(tzinfo=tzmod.utc)
                days_since_contact = (datetime.now(tzmod.utc) - last_contact).days
            check_in_candidates.append({
                "friend_id": str(friend_id),
                "username": username,
                "profile_photo_url": generate_download_url(profile_photo_key),
                "days_since_contact": days_since_contact,
            })

        return {"friends_active": friends_active, "check_in_candidates": check_in_candidates}
