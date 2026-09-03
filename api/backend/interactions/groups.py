from schemas.users import User
from schemas.message import Group
from db import DBManager
from backend.errors import SaveFailedError


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
        from_uids = {str(uid) for uid in (data.get("from_user", "") for data in messages.values()) if uid}
        usernames: dict[str, str] = {}
        if from_uids:
            self.cur.execute(
                "SELECT _id, username FROM users WHERE _id = ANY(%s::uuid[])",
                (list(from_uids),),
            )
            usernames = {str(r[0]): r[1] for r in self.cur.fetchall()}
        result = []
        for _, data in messages.items():
            from_uid = str(data.get("from_user", "") or "")
            if from_uid in usernames:
                data = {**data, "from_user": usernames[from_uid]}
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
        if not self.insertion("groups", {
            "_id":   group.group_id,
            "title": group.title,
            "users": group.users,
        }):
            raise SaveFailedError()

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
        usernames: list = []
        other_msgs: dict = {}
        if member_ids:
            self.cur.execute(
                "SELECT _id, username FROM users WHERE _id = ANY(%s::uuid[])",
                (member_ids,),
            )
            user_map = {str(r[0]): r[1] for r in self.cur.fetchall()}
            # Roster stays unfiltered for transparency about who's in the
            # group — only their message content is hidden below.
            usernames = [user_map[uid] for uid in member_ids if uid in user_map]

            unblocked_ids = [uid for uid in member_ids if uid not in blocked]
            if unblocked_ids:
                self.cur.execute(
                    "SELECT * FROM messages WHERE from_user = ANY(%s::uuid[]) AND group_id = %s",
                    (unblocked_ids, self.group_id),
                )
                cols = [desc[0] for desc in self.cur.description]
                other_msgs = {
                    row[0]: dict(zip(cols[1:], row[1:]))
                    for row in self.cur.fetchall()
                }
        host_msgs = self.lookup("messages", {"from_user": self.user_id, "group_id": self.group_id})
        return {
            "group":      group_data,
            "members":    usernames,
            "host_msgs":  self.format_messages(host_msgs),
            "other_msgs": self.format_messages(other_msgs),
        }

    def fetch_notes(
        self,
        limit: int = 15,
        cursor_created_at: str | None = None,
        cursor_id: str | None = None,
    ) -> dict:
        """Retrieve one page of non-reply notes belonging to the group,
        newest first, using keyset pagination anchored on
        (created_at, _id) rather than OFFSET -- so a note created or deleted
        between page loads can't shift another row's position and cause
        drift, duplicates, or skipped notes. Blocked-user exclusion
        (Guideline 1.2) happens in the SQL WHERE clause itself, not as a
        post-fetch Python filter, so a full page always contains ``limit``
        visible notes.

        Uses the raw cursor (rather than ``lookup``) because ordering,
        LIMIT, and the blocked-user anti-join aren't expressible through the
        generic helpers.

        Args:
            limit: Max notes to return for this page.
            cursor_created_at: created_at of the last note from the previous
                page. Omit together with cursor_id to fetch the first page.
            cursor_id: _id of the last note from the previous page. Must be
                supplied together with cursor_created_at.

        Returns:
            dict: ``{"notes": {username: {note_id: note data}},
                "next_cursor_created_at": str | None, "next_cursor_id":
                str | None, "has_more": bool}``. has_more is True iff
                exactly ``limit`` rows were returned.
        """
        where = (
            "group_id = %s AND is_reply = false "
            "AND user_id NOT IN ("
            "SELECT blocked_id FROM blocked_users WHERE blocker_id = %s "
            "UNION SELECT blocker_id FROM blocked_users WHERE blocked_id = %s"
            ")"
        )
        params: list = [self.group_id, self.user_id, self.user_id]
        if cursor_created_at is not None and cursor_id is not None:
            where += " AND (created_at, _id) < (%s::timestamptz, %s::uuid)"
            params += [cursor_created_at, cursor_id]
        self.cur.execute(
            "SELECT _id, user_id, title, text, public, group_id, is_reply, "
            "parent_note_id, timestamp, created_at FROM notes "
            f"WHERE {where} "
            "ORDER BY created_at DESC, _id DESC "
            "LIMIT %s",
            params + [limit],
        )
        cols = [desc[0] for desc in self.cur.description]
        rows = self.cur.fetchall()
        row_data = [(str(row[0]), dict(zip(cols[1:], row[1:]))) for row in rows]
        distinct_uids = {str(data.get("user_id")) for _, data in row_data if data.get("user_id")}
        username_map: dict[str, str] = {}
        if distinct_uids:
            self.cur.execute(
                "SELECT _id, username FROM users WHERE _id = ANY(%s::uuid[])",
                (list(distinct_uids),),
            )
            username_map = {str(r[0]): r[1] for r in self.cur.fetchall()}
        group_notes: dict = {}
        for nid, data in row_data:
            uid = data.get("user_id")
            if not uid:
                continue
            username = username_map.get(str(uid), "")
            if username not in group_notes:
                group_notes[username] = {}
            group_notes[username][nid] = data
        has_more = len(rows) == limit
        last = rows[-1] if rows else None
        return {
            "notes": group_notes,
            "next_cursor_created_at": str(last[9]) if last else None,
            "next_cursor_id": str(last[0]) if last else None,
            "has_more": has_more,
        }

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
        member_ids = group_data.get("users", [])
        result: dict = {uid: {} for uid in member_ids}
        if member_ids:
            self.cur.execute(
                "SELECT user_id, key, color FROM highlights WHERE user_id = ANY(%s::uuid[])",
                (member_ids,),
            )
            for user_id, key, color in self.cur.fetchall():
                result.setdefault(str(user_id), {})[key] = color
        return result

    def remove_group(self) -> None:
        """Delete the group. Membership is derived from the groups.users column,
        so deleting the row removes it from every member's view automatically.

        Cascades in Postgres to linked notes, messages, and devotions.
        """
        if not self.group_id:
            return
        # remove_group is only ever called after the caller already loaded
        # this group (routes/community.py), so a False return here is a
        # real write failure, not an expected no-op.
        if not self.delete("groups", {"_id": self.group_id}):
            raise SaveFailedError()

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
        # `existing` above already confirmed the row exists, so a False
        # return is a real write failure, not an expected no-op.
        if not self.update("groups", {"title": group.title, "users": group.users}, {"_id": self.group_id}):
            raise SaveFailedError()
