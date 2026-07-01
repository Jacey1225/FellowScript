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
        usernames  = []
        other_msgs = {}
        for uid in member_ids:
            user = self.lookup("users", {"_id": uid})
            if user:
                _, udata = list(user.items())[0]
                usernames.append(udata.get("username", ""))
            msgs = self.lookup("messages", {"from_user": uid, "group_id": self.group_id})
            other_msgs.update(msgs)
        host_msgs = self.lookup("messages", {"from_user": self.user_id, "group_id": self.group_id})
        return {
            "group":      group_data,
            "members":    usernames,
            "host_msgs":  self.format_messages(host_msgs),
            "other_msgs": self.format_messages(other_msgs),
        }

    def fetch_notes(self) -> dict:
        """Retrieve all public, non-reply notes belonging to the group.

        Returns:
            dict: Mapping of username -> {note_id -> note data dict} for
                all qualifying notes in the group.
        """
        group_notes: dict = {}
        notes = self.lookup("notes", {"group_id": self.group_id, "is_reply": False})
        for nid, data in notes.items():
            uid = data.get("user_id")
            if not uid:
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
        replies = self.lookup("notes", {"is_reply": True, "parent_note_id": note_id})
        return list(replies.values())

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
        """Delete the group. Cascades to linked notes, messages, and devotions."""
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
        self.update("groups", {"title": group.title, "users": group.users}, {"_id": self.group_id})
