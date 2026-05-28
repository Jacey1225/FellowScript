from fastapi import APIRouter, HTTPException
from backend.interactions.groups import GroupsManager
from backend.interactions.friends import  FriendsManager
from schemas.message import Group

group_router = APIRouter(prefix="/groups")
friend_router = APIRouter(prefix="/friends")


# ── Groups ─────────────────────────────────────────────────────────────────────

@group_router.post("/{user_id}", status_code=201)
async def create_group(user_id: str, group: Group) -> dict:
    """Create a new study group and add all specified members.

    Args:
        user_id: UUID of the user creating the group.
        group: Group payload containing group_id, title, and initial member list.

    Returns:
        dict: ``{"group_id": str}`` confirming the created group's ID.
    """
    manager = GroupsManager(user_id)
    manager.create_group(group.users, group)
    return {"group_id": group.group_id}


@group_router.get("/{user_id}/{group_id}")
async def fetch_group(user_id: str, group_id: str) -> dict:
    """Fetch full group data including members and message history.

    Args:
        user_id: UUID of the requesting user.
        group_id: ID of the group to retrieve.

    Returns:
        dict: Contains ``group``, ``members``, ``host_msgs``, and ``other_msgs``.

    Raises:
        HTTPException 404: If the group does not exist.
    """
    manager = GroupsManager(user_id, group_id)
    result = manager.fetch_group()
    if "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])
    return result


@group_router.get("/{user_id}/{group_id}/notes")
async def fetch_group_notes(user_id: str, group_id: str) -> dict:
    """Retrieve all public notes shared within a group.

    Args:
        user_id: UUID of the requesting user.
        group_id: ID of the group whose notes to retrieve.

    Returns:
        dict: Mapping of username -> {note_id -> note data} for all public
            notes belonging to the group.
    """
    manager = GroupsManager(user_id, group_id)
    return manager.fetch_notes()


@group_router.get("/{user_id}/{note_id}/{group_id}/replies")
async def fetch_group_replies(user_id: str, note_id: str, group_id: str) -> list[dict] | dict[str, str]:
    """Retrieve all replies attached to a specific note in a group.

    Args:
        user_id: UUID of the requesting user.
        note_id: ID of the parent note whose replies to fetch.
        group_id: ID of the group context.

    Returns:
        list[dict]: List of reply note data dicts on success.
        dict: ``{"error": str}`` if the parent note is not found.
    """
    manager = GroupsManager(user_id, group_id)
    return manager.fetch_replies(note_id)


@group_router.get("/{user_id}/{group_id}/highlights")
async def fetch_group_highlights(user_id: str, group_id: str) -> dict:
    """Retrieve highlight data for all members of a group.

    Args:
        user_id: UUID of the requesting user.
        group_id: ID of the group.

    Returns:
        dict: Mapping of user_id -> highlights dict for every group member.
    """
    manager = GroupsManager(user_id, group_id)
    return manager.fetch_highlights()


@group_router.put("/{user_id}/{group_id}")
async def update_group(user_id: str, group_id: str, group: Group) -> None:
    """Update a group's title and/or member list.

    Args:
        user_id: UUID of the user making the update.
        group_id: ID of the group to update.
        group: Replacement group payload with updated title and users.
    """
    manager = GroupsManager(user_id, group_id)
    manager.update_group(group)


@group_router.delete("/{user_id}/{group_id}", status_code=204)
async def remove_group(user_id: str, group_id: str) -> None:
    """Delete a group and remove it from all members' records.

    Args:
        user_id: UUID of the user initiating the deletion.
        group_id: ID of the group to remove.
    """
    manager = GroupsManager(user_id, group_id)
    manager.remove_group()


# ── Friends ────────────────────────────────────────────────────────────────────

@friend_router.get("/{user_id}")
async def get_friends(user_id: str) -> list[dict]:
    """Return the full friend list for a user.

    Args:
        user_id: UUID of the user whose friends to list.

    Returns:
        list[dict]: List of friend user records (excludes hash_pass).
    """
    manager = FriendsManager(user_id)
    return manager.get_friends()


@friend_router.get("/{user_id}/{friend_id}")
async def read_friend(user_id: str, friend_id: str) -> dict:
    """Fetch a friend's profile and the shared DM history.

    Args:
        user_id: UUID of the requesting user.
        friend_id: UUID of the friend to read.

    Returns:
        dict: Contains ``friend`` profile data, ``host_msgs``, and
            ``other_msgs`` between the two users.

    Raises:
        HTTPException 404: If the friend record is not found.
    """
    manager = FriendsManager(user_id)
    result = manager.read_friend(friend_id)
    if "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])
    return result


@friend_router.post("/{user_id}/request")
async def send_friend_request(user_id: str, friend_username: str) -> None:
    """Send a friend request to a user identified by username.

    Args:
        user_id: UUID of the requesting user.
        friend_username: Username of the intended recipient.

    Raises:
        HTTPException 404: If no user with the given username is found, or
            if the user attempts to add themselves.
    """
    manager = FriendsManager(user_id)
    result = manager.send_add_request(friend_username)
    if result and "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])


@friend_router.post("/{user_id}/add", status_code=204)
async def add_friend(user_id: str, friend_username: str) -> None:
    """Accept a friend request and create a mutual friendship.

    Args:
        user_id: UUID of the user accepting the request.
        friend_username: Username of the user to add.

    Raises:
        HTTPException 404: If the target user is not found.
    """
    manager = FriendsManager(user_id)
    result = manager.add_friend(friend_username)
    if result and "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])


@friend_router.delete("/{user_id}/{friend_id}", status_code=204)
async def remove_friend(user_id: str, friend_id: str) -> None:
    """Remove a friend from both users' friend lists.

    Args:
        user_id: UUID of the user initiating the removal.
        friend_id: UUID of the friend to remove.
    """
    manager = FriendsManager(user_id)
    manager.remove_friend(friend_id)
