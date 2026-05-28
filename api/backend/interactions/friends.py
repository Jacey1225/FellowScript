from schemas.users import User
from helpers import (
    fetch_users,
    find_by_username,
    update_users,
    read_messages,
    format_messages
)

class FriendsManager:
    """Handles friend request, acceptance, removal, and DM retrieval."""

    def __init__(self, user_id: str) -> None:
        """Set up the manager for the given user.

        Args:
            user_id: UUID of the acting user.
        """
        self.user_id = user_id
        result = fetch_users([user_id])
        self.user = User()
        if result:
            self.user: User = result[-1]

    def send_add_request(self, friend_username: str) -> dict | None:
        """Append the acting user's ID to the target user's friend_requests list.

        Args:
            friend_username: Username of the user to send the request to.

        Returns:
            dict | None: ``{"error": str}`` if the user is not found or the
                user attempts to add themselves; ``None`` on success.
        """
        result = find_by_username(friend_username)
        if result is None:
            return {"error": "User not found"}
        friend_id, friend_data = result
        if friend_id == self.user_id:
            return {"error": "Cannot add yourself"}
        friend = User.model_validate({"user_id": friend_id, **friend_data})
        if self.user_id not in friend.friend_requests:
            friend.friend_requests.append(self.user_id)
        update_users([friend])
        return None

    def add_friend(self, friend_username: str) -> dict | None:
        """Accept a pending friend request and establish a mutual friendship.

        Adds each user to the other's ``friends`` list and removes the acting
        user's ID from the target's ``friend_requests`` list if present.

        Args:
            friend_username: Username of the user to accept as a friend.

        Returns:
            dict | None: ``{"error": str}`` if the user is not found;
                ``None`` on success.
        """
        result = find_by_username(friend_username)
        if result is None:
            return {"error": "User not found"}
        friend_id, friend_data = result
        friend = User.model_validate({"user_id": friend_id, **friend_data})
        if friend_id not in self.user.friends:
            self.user.friends.append(friend_id)
        if friend_id in self.user.friend_requests:
            self.user.friend_requests.remove(friend_id)
        if self.user_id not in friend.friends:
            friend.friends.append(self.user_id)
        update_users([self.user, friend])
        return None

    def get_friends(self) -> list[dict]:
        """Return the full friend list for the acting user.

        Returns:
            list[dict]: List of friend user records with ``hash_pass`` excluded.
        """
        friends = fetch_users(self.user.friends)
        return [f.model_dump(exclude={"hash_pass"}) for f in friends]

    def read_friend(self, friend_id: str) -> dict:
        """Fetch a friend's profile and the shared DM history.

        Args:
            friend_id: UUID of the friend to retrieve.

        Returns:
            dict: Contains ``friend`` profile (without hash_pass), ``host_msgs``,
                and ``other_msgs``. Returns ``{"error": str}`` if not found.
        """
        friends = fetch_users([friend_id])
        if not friends:
            return {"error": "Friend not found"}
        host_msgs, other_msgs = read_messages(self.user_id, [friend_id])
        return {
            "friend":     friends[0].model_dump(exclude={"hash_pass"}),
            "host_msgs":  format_messages(host_msgs),
            "other_msgs": format_messages(other_msgs),
        }

    def remove_friend(self, friend_id: str) -> None:
        """Remove a friend from both users' friend lists.

        Args:
            friend_id: UUID of the friend to remove.
        """
        if friend_id in self.user.friends:
            self.user.friends.remove(friend_id)
        friends = fetch_users([friend_id])
        if friends:
            other = friends[0]
            if self.user_id in other.friends:
                other.friends.remove(self.user_id)
            update_users([self.user, other])
        else:
            update_users([self.user])
