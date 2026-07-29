from schemas.users import User
from db import DBManager
from backend.interactions.blocks import BlockManager


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
        self.insertion("friend_requests", {
            "to_user_id":   friend_id,
            "from_user_id": self.user_id,
        })
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
        self.insertion("user_friends", {"user_id": self.user_id, "friend_id": friend_id})
        self.insertion("user_friends", {"user_id": friend_id, "friend_id": self.user_id})
        self.delete("friend_requests", {"to_user_id": self.user_id, "from_user_id": friend_id})
        return None

    def get_requests(self) -> list[dict]:
        """Return pending *incoming* friend requests for the acting user.

        Each entry is the sender's public identity, so the account page can show
        who wants to connect.

        Returns:
            list[dict]: ``[{"user_id": str, "username": str}, ...]``.
        """
        self.cur.execute(
            "SELECT u._id, u.username FROM users u "
            "JOIN friend_requests fr ON u._id = fr.from_user_id "
            "WHERE fr.to_user_id = %s",
            (self.user_id,)
        )
        return [{"user_id": r[0], "username": r[1]} for r in self.cur.fetchall()]

    def get_friends(self) -> list[dict]:
        """Return the full friend list for the acting user.

        Returns:
            list[dict]: List of friend user records with ``hash_pass`` excluded.
        """
        self.cur.execute(
            "SELECT u._id, u.username, u.email FROM users u "
            "JOIN user_friends uf ON u._id = uf.friend_id "
            "WHERE uf.user_id = %s",
            (self.user_id,)
        )
        return [{"user_id": r[0], "username": r[1], "email": r[2]} for r in self.cur.fetchall()]

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
        self.cur.execute(
            "SELECT m._id, m.text, m.timestamp FROM messages m "
            "JOIN message_recipients mr ON m._id = mr.message_id "
            "WHERE m.from_user = %s AND mr.user_id = %s AND m.group_id IS NULL",
            (self.user_id, friend_id)
        )
        host_msgs = [
            {"from_user": self.user.username, "text": r[1], "timestamp": str(r[2])}
            for r in self.cur.fetchall()
        ]
        self.cur.execute(
            "SELECT m._id, m.text, m.timestamp FROM messages m "
            "JOIN message_recipients mr ON m._id = mr.message_id "
            "WHERE m.from_user = %s AND mr.user_id = %s AND m.group_id IS NULL",
            (friend_id, self.user_id)
        )
        other_msgs = [
            {"from_user": friend_data.get("username", ""), "text": r[1], "timestamp": str(r[2])}
            for r in self.cur.fetchall()
        ]
        return {
            "friend":     {k: v for k, v in friend_data.items() if k != "hash_pass"},
            "host_msgs":  host_msgs,
            "other_msgs": other_msgs,
        }

    def remove_friend(self, friend_id: str) -> None:
        """Remove a friend from both users' friend lists.

        Args:
            friend_id: UUID of the friend to remove.
        """
        self.delete("user_friends", {"user_id": self.user_id, "friend_id": friend_id})
        self.delete("user_friends", {"user_id": friend_id, "friend_id": self.user_id})
