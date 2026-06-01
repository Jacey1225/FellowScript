import os
import json
from schemas.users import User, Note
from schemas.message import Group
from backend.interactions.helpers import (
    fetch_users,
    update_users,
    read_messages,
    format_messages,
    load_notes
)

groups_path = "data/groups.json"
main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../..")


def load_groups() -> dict:
    """Load all group records from the JSON data store.

    Returns:
        dict: Mapping of group_id -> group data dict. Returns an empty dict
            if the file does not exist or contains invalid JSON.
    """
    path = os.path.join(main_path, groups_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def save_groups(groups: dict) -> None:
    """Persist all group records to the JSON data store.

    Args:
        groups: Mapping of group_id -> group data dict to write.
    """
    with open(os.path.join(main_path, groups_path), 'w') as f:
        json.dump(groups, f, indent=2)



class GroupsManager:
    """Handles all group-level data operations for a single user/group context."""

    def __init__(self, user_id: str, group_id: str = "") -> None:
        """Set up the manager for the given user and optional group.

        Args:
            user_id: UUID of the acting user.
            group_id: ID of the group context. Defaults to ``""`` for
                operations that don't require a specific group.
        """
        self.user_id  = user_id
        self.group_id = group_id
        result = fetch_users([user_id])
        self.user: User = result[-1] if result else User()

    def create_group(self, users: list[str], group: Group) -> None:
        """Create a new group and add it to each member's groups list.

        Args:
            users: List of user IDs to add as initial members.
            group: ``Group`` schema instance with group_id, title, and users.
        """
        groups = load_groups()
        groups[group.group_id] = {"title": group.title, "users": group.users}
        save_groups(groups)

        members = fetch_users(users)
        for member in members:
            if group.group_id not in member.groups:
                member.groups.append(group.group_id)
        update_users(members)

    def fetch_group(self) -> dict:
        """Retrieve full group data including members and message history.

        Returns:
            dict: Contains ``group`` metadata, ``members`` list, ``host_msgs``,
                and ``other_msgs``. Returns ``{"error": str}`` if the group
                does not exist.
        """
        groups = load_groups()
        group  = groups.get(self.group_id)
        if not group:
            return {"error": "Group not found"}
        other_users = [u for u in group["users"] if u != self.user_id]
        usernames = fetch_users(other_users)
        host_msgs, other_msgs = read_messages(self.user_id, other_users, self.group_id)

        return {
            "group":      group,
            "members":    usernames,
            "host_msgs":  format_messages(host_msgs),
            "other_msgs": format_messages(other_msgs),
        }

    def fetch_notes(self) -> dict:
        """Retrieve all public, non-reply notes belonging to the group.

        Returns:
            dict: Mapping of username -> {note_id -> note data dict} for
                all qualifying notes in the group.
        """
        notes = load_notes()
        group_notes: dict = {}

        for note_id, data in notes.items():
            note = Note(**data)
            if note.group_id != self.group_id or note.is_reply:
                continue
            user = fetch_users([note.user])
            if not user:
                continue
            username = user[-1].username
            if username not in group_notes:
                group_notes[username] = {}
            group_notes[username][note_id] = note.model_dump(exclude={"user"})

        return group_notes

    def fetch_replies(self, note_id: str) -> list[dict] | dict:
        """Retrieve all replies for a given note, with usernames resolved.

        Args:
            note_id: ID of the parent note whose replies to fetch.

        Returns:
            list[dict]: List of reply note dicts with ``user`` replaced by
                the author's username.
            dict: ``{"error": str}`` if the parent note is not found.
        """
        notes = load_notes()
        note_info = notes.get(note_id)
        note_replies: list = []

        if not note_info:
            return {"error": "cannot find note"}
        note = Note(**note_info)
        reply_ids = note.replies
        for _id in reply_ids:
            reply_info = notes.get(_id)
            if not reply_info:
                continue
            reply = Note(**reply_info)
            reply_uid = reply.user
            user_info = fetch_users([reply_uid])
            if not user_info:
                continue
            user = user_info[-1]
            username = user.username
            reply.user = username
            note_replies.append(reply.model_dump())

        return note_replies

    def fetch_highlights(self) -> dict:
        """Retrieve highlight data for all members of the group.

        Returns:
            dict: Mapping of user_id -> highlights dict for every group member.
        """
        groups  = load_groups()
        group   = groups.get(self.group_id, {})
        members = fetch_users(group.get("users", []))
        return {u.user_id: u.highlights for u in members}

    def remove_group(self) -> None:
        """Delete the group and remove it from all members' records.

        No-ops silently if ``group_id`` is empty or the group does not exist.
        """
        if not self.group_id:
            return
        groups = load_groups()
        group  = groups.pop(self.group_id, None)
        if not group:
            return
        save_groups(groups)
        members = fetch_users(group.get("users", []))
        for member in members:
            if self.group_id in member.groups:
                member.groups.remove(self.group_id)
        update_users(members)

    def update_group(self, group: Group) -> None:
        """Replace a group's title and member list.

        Adds the group to any new members' ``groups`` list. Does not remove
        the group from users who were removed from the member list.

        Args:
            group: Replacement ``Group`` instance with updated title and users.
        """
        if not self.group_id:
            return
        groups = load_groups()
        if self.group_id not in groups:
            return
        groups[self.group_id] = {"title": group.title, "users": group.users}
        users = fetch_users(group.users)
        for user in users:
            if self.group_id not in user.groups:
                user.groups.append(self.group_id)
        save_groups(groups)
        update_users(users)

