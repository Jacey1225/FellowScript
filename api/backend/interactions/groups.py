from schemas.users import User
from schemas.message import Group
from db import DBManager


class GroupsManager(DBManager):
    """Handles all group-level data operations for a single user/group context."""

    def __init__(self, user_id: str, group_id: str = "") -> None:
        super().__init__()
        self.user_id  = user_id
        self.group_id = group_id
        result = self.lookup("users", {"_id": user_id})
        if result:
            uid, data = list(result.items())[0]
            self.user = User(user_id=uid, **data)
        else:
            self.user = User()

    def _blocked_set(self) -> set[str]:
        """IDs in a blocked relationship with self.user_id, either direction —
        Guideline 1.2: a block must hide that user's content from the blocker's
        feed. One query, reused by every fetch method below."""
        self.cur.execute(
            "SELECT blocked_id FROM blocked_users WHERE blocker_id = %s "
            "UNION SELECT blocker_id FROM blocked_users WHERE blocked_id = %s",
            (self.user_id, self.user_id),
        )
        return {str(r[0]) for r in self.cur.fetchall()}

    def is_member(self) -> bool:
        """True if ``self.user_id`` belongs to ``self.group_id``'s member list."""
        group = self.lookup("groups", {"_id": self.group_id})
        if not group:
            return False
        _, group_data = list(group.items())[0]
        return self.user_id in (group_data.get("users") or [])

    def format_messages(self, messages: dict) -> list[dict]:
        result = []
        for _, data in messages.items():
            from_uid = data.get("from_user", "")
            user_result = self.lookup("users", {"_id": from_uid})
            if user_result:
                _, udata = list(user_result.items())[0]
                data = {**data, "from_user": udata.get("username", from_uid)}
            result.append(data)
        return result

    def create_group(self, users: list[str], group: Group) -> None:
        """Create a new group and add it to each member's groups list.

        Args:
            users: List of user IDs to add as initial members.
            group: ``Group`` schema instance with group_id, title, and users.
        """
        # Membership lives in the groups.users column; GET /user derives each
        # user's group list from it, so no separate per-user sync is needed.
        self.insertion("groups", {
            "_id":   group.group_id,
            "title": group.title,
            "users": group.users,
        })

    def fetch_group(self) -> dict:
        """Retrieve full group data including members and message history.

        Returns:
            dict: Contains ``group`` metadata, ``members`` list, ``host_msgs``,
                and ``other_msgs``. Returns ``{"error": str}`` if the group
                does not exist.
        """
        group = self.lookup("groups", {"_id": self.group_id})
        if not group:
            return {"error": "Group not found"}
        _, group_data = list(group.items())[0]
        member_ids = [u for u in group_data.get("users", []) if u != self.user_id]
        blocked    = self._blocked_set()
        usernames  = []
        other_msgs = {}
        for uid in member_ids:
            user = self.lookup("users", {"_id": uid})
            if user:
                _, udata = list(user.items())[0]
                # Roster stays unfiltered for transparency about who's in the
                # group — only their message content is hidden below.
                usernames.append(udata.get("username", ""))
            if uid in blocked:
                continue
            msgs = self.lookup("messages", {"from_user": uid, "group_id": self.group_id})
            other_msgs.update(msgs)
        host_msgs = self.lookup("messages", {"from_user": self.user_id, "group_id": self.group_id})
        return {
            "group":      group_data,
            "members":    usernames,
            "host_msgs":  self.format_messages(host_msgs),
            "other_msgs": self.format_messages(other_msgs),
        }

    def fetch_notes(self, limit: int | None = None, offset: int | None = None, order: str = "desc") -> dict:
        """Retrieve public, non-reply notes belonging to the group, ordered
        by timestamp and optionally paginated.

        Uses the raw cursor (rather than ``lookup``) because ordering and
        LIMIT/OFFSET aren't expressible through the generic helpers.

        Args:
            limit: Max notes to return; omit for the full unpaginated set
                (preserves historical behavior for existing callers).
            offset: Notes to skip, for paging; omit for the full set.
            order: "asc" or "desc" timestamp direction. Changing it changes
                what "next page" means, so a caller paging through results
                must keep it fixed across the sequence.

        Returns:
            dict: Mapping of username -> {note_id -> note data dict} for
                qualifying notes in the requested page (or all of them, if
                limit/offset are omitted).
        """
        group_notes: dict = {}
        blocked = self._blocked_set()
        direction = "ASC" if order == "asc" else "DESC"
        query = (
            "SELECT _id, user_id, title, text, public, group_id, is_reply, "
            "parent_note_id, timestamp, created_at FROM notes "
            "WHERE group_id = %s AND is_reply = false "
            f"ORDER BY timestamp {direction}, _id {direction}"
        )
        params: list = [self.group_id]
        if limit is not None:
            query += " LIMIT %s"
            params.append(limit)
        if offset is not None:
            query += " OFFSET %s"
            params.append(offset)
        self.cur.execute(query, params)
        cols = [desc[0] for desc in self.cur.description]
        for row in self.cur.fetchall():
            nid, data = row[0], dict(zip(cols[1:], row[1:]))
            uid = data.get("user_id")
            if not uid or uid in blocked:
                continue
            user = self.lookup("users", {"_id": uid})
            username = ""
            if user:
                _, udata = list(user.items())[0]
                username = udata.get("username", "")
            if username not in group_notes:
                group_notes[username] = {}
            group_notes[username][nid] = data
        return group_notes

    def fetch_replies(self, note_id: str) -> list[dict]:
        """Retrieve all replies for a given note.

        Args:
            note_id: ID of the parent note whose replies to fetch.

        Returns:
            list[dict]: List of reply note dicts.
        """
        blocked = self._blocked_set()
        replies = self.lookup("notes", {"is_reply": True, "parent_note_id": note_id})
        return [r for r in replies.values() if str(r.get("user_id")) not in blocked]

    def fetch_highlights(self) -> dict:
        """Retrieve highlight data for all members of the group.

        Returns:
            dict: Mapping of user_id -> {key -> color} for every group member.
        """
        group = self.lookup("groups", {"_id": self.group_id})
        if not group:
            return {}
        _, group_data = list(group.items())[0]
        result = {}
        for uid in group_data.get("users", []):
            self.cur.execute("SELECT key, color FROM highlights WHERE user_id = %s", (uid,))
            result[uid] = {row[0]: row[1] for row in self.cur.fetchall()}
        return result

    def remove_group(self) -> None:
        """Delete the group. Membership is derived from the groups.users column,
        so deleting the row removes it from every member's view automatically.

        Cascades in Postgres to linked notes, messages, and devotions.
        """
        if not self.group_id:
            return
        self.delete("groups", {"_id": self.group_id})

    def update_group(self, group: Group) -> None:
        """Replace a group's title and member list.

        Args:
            group: Replacement ``Group`` instance with updated title and users.
        """
        if not self.group_id:
            return
        existing = self.lookup("groups", {"_id": self.group_id})
        if not existing:
            return
        # groups.users is the single source of membership; GET /user derives each
        # member's group list from it, so updating this column is sufficient.
        self.update("groups", {"title": group.title, "users": group.users}, {"_id": self.group_id})
