from fastapi import APIRouter, HTTPException, Depends, Query
from backend.interactions.groups import GroupsManager
from backend.interactions.friends import  FriendsManager
from backend.auth.dependencies import require_match
from backend.moderation.content_filter import check_clean, ContentRejected, rejection_message
from schemas.message import Group
from routes.notes import NOTES_PAGE_SIZE

group_router = APIRouter(prefix="/groups")
friend_router = APIRouter(prefix="/friends")


# ── Groups ─────────────────────────────────────────────────────────────────────

@group_router.post("/{user_id}", status_code=201)
async def create_group(user_id: str, group: Group, _: str = Depends(require_match("user_id"))) -> dict:
    """Create a new study group and add all specified members.

    Args:
        user_id: UUID of the user creating the group.
        group: Group payload containing group_id, title, and initial member list.

    Returns:
        dict: ``{"group_id": str}`` confirming the created group's ID.
    """
    try:
        check_clean(title=group.title)
    except ContentRejected as e:
        raise HTTPException(status_code=422, detail=rejection_message(e))
    manager = GroupsManager(user_id)
    manager.create_group(group.users, group)
    return {"group_id": group.group_id}


@group_router.get("/{user_id}/{group_id}")
async def fetch_group(user_id: str, group_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Fetch full group data including members and message history.

    Args:
        user_id: UUID of the requesting user.
        group_id: ID of the group to retrieve.

    Returns:
        dict: Contains ``group``, ``members``, ``host_msgs``, and ``other_msgs``.

    Raises:
        HTTPException 404: If the group does not exist.
        HTTPException 403: If the caller is not a member of the group.
    """
    manager = GroupsManager(user_id, group_id)
    if not manager.is_member():
        raise HTTPException(status_code=403, detail="Not a member of this group")
    result = manager.fetch_group()
    if "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])
    return result


@group_router.get("/{user_id}/{group_id}/notes")
async def fetch_group_notes(
    user_id: str,
    group_id: str,
    cursor_created_at: str | None = Query(default=None, description="created_at of the last note seen on the previous page; omit (with cursor_id) to fetch the first page"),
    cursor_id: str | None = Query(default=None, description="_id of the last note seen on the previous page; omit (with cursor_created_at) to fetch the first page"),
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Retrieve one page of public notes shared within a group, newest
    first, using keyset pagination anchored on (created_at, _id). Blocked
    users' notes are excluded at the SQL level, so a full page always
    contains NOTES_PAGE_SIZE visible notes.

    Args:
        user_id: UUID of the requesting user.
        group_id: ID of the group whose notes to retrieve.
        cursor_created_at: created_at of the last note from the previous
            page. Omit together with cursor_id to fetch the first page.
        cursor_id: _id of the last note from the previous page. Must be
            supplied together with cursor_created_at.

    Returns:
        dict: ``{"notes": {username: {note_id: note data}},
            "next_cursor_created_at": str | None, "next_cursor_id":
            str | None, "has_more": bool}``. Pass next_cursor_created_at/
            next_cursor_id back as cursor_created_at/cursor_id to fetch the
            following page; has_more is False once the true end of the
            group's notes has been reached.

    Raises:
        HTTPException 403: If the caller is not a member of the group.
    """
    manager = GroupsManager(user_id, group_id)
    if not manager.is_member():
        raise HTTPException(status_code=403, detail="Not a member of this group")
    return manager.fetch_notes(limit=NOTES_PAGE_SIZE, cursor_created_at=cursor_created_at, cursor_id=cursor_id)


@group_router.get("/{user_id}/{note_id}/{group_id}/replies")
async def fetch_group_replies(user_id: str, note_id: str, group_id: str, _: str = Depends(require_match("user_id"))) -> list[dict] | dict[str, str]:
    """Retrieve all replies attached to a specific note in a group.

    Args:
        user_id: UUID of the requesting user.
        note_id: ID of the parent note whose replies to fetch.
        group_id: ID of the group context.

    Returns:
        list[dict]: List of reply note data dicts on success.
        dict: ``{"error": str}`` if the parent note is not found.

    Raises:
        HTTPException 403: If the caller is not a member of the group.
    """
    manager = GroupsManager(user_id, group_id)
    if not manager.is_member():
        raise HTTPException(status_code=403, detail="Not a member of this group")
    return manager.fetch_replies(note_id)


@group_router.get("/{user_id}/{group_id}/highlights")
async def fetch_group_highlights(user_id: str, group_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Retrieve highlight data for all members of a group.

    Args:
        user_id: UUID of the requesting user.
        group_id: ID of the group.

    Returns:
        dict: Mapping of user_id -> highlights dict for every group member.

    Raises:
        HTTPException 403: If the caller is not a member of the group.
    """
    manager = GroupsManager(user_id, group_id)
    if not manager.is_member():
        raise HTTPException(status_code=403, detail="Not a member of this group")
    return manager.fetch_highlights()


@group_router.put("/{user_id}/{group_id}")
async def update_group(user_id: str, group_id: str, group: Group, _: str = Depends(require_match("user_id"))) -> None:
    """Update a group's title and/or member list.

    Args:
        user_id: UUID of the user making the update.
        group_id: ID of the group to update.
        group: Replacement group payload with updated title and users.

    Raises:
        HTTPException 403: If the caller is not a member of the group.
    """
    manager = GroupsManager(user_id, group_id)
    if not manager.is_member():
        raise HTTPException(status_code=403, detail="Not a member of this group")
    try:
        check_clean(title=group.title)
    except ContentRejected as e:
        raise HTTPException(status_code=422, detail=rejection_message(e))
    manager.update_group(group)


@group_router.delete("/{user_id}/{group_id}", status_code=204)
async def remove_group(user_id: str, group_id: str, _: str = Depends(require_match("user_id"))) -> None:
    """Delete a group and remove it from all members' records.

    Args:
        user_id: UUID of the user initiating the deletion.
        group_id: ID of the group to remove.

    Raises:
        HTTPException 403: If the caller is not a member of the group.
    """
    manager = GroupsManager(user_id, group_id)
    if not manager.is_member():
        raise HTTPException(status_code=403, detail="Not a member of this group")
    manager.remove_group()


# ── Friends ────────────────────────────────────────────────────────────────────

@friend_router.get("/{user_id}")
async def get_friends(user_id: str, _: str = Depends(require_match("user_id"))) -> list[dict]:
    """Return the full friend list for a user.

    Args:
        user_id: UUID of the user whose friends to list.

    Returns:
        list[dict]: List of friend user records (excludes hash_pass).
    """
    manager = FriendsManager(user_id)
    return manager.get_friends()


@friend_router.get("/{user_id}/requests")
async def get_friend_requests(user_id: str, _: str = Depends(require_match("user_id"))) -> list[dict]:
    """Return pending incoming friend requests for the user.

    NOTE: declared before ``/{user_id}/{friend_id}`` so the literal ``requests``
    segment matches first (routes resolve in definition order).

    Returns:
        list[dict]: ``[{"user_id": str, "username": str}, ...]`` of requesters.
    """
    manager = FriendsManager(user_id)
    try:
        return manager.get_requests()
    finally:
        manager.close()


@friend_router.get("/{user_id}/activity")
async def get_friend_activity(user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Friend-activity read surface for the dashboard's Friend Activity hero
    card.

    NOTE: declared before ``/{user_id}/{friend_id}`` so the literal
    ``activity`` segment matches first (routes resolve in definition
    order), same reasoning as ``/{user_id}/requests`` above.

    Args:
        user_id: UUID of the requesting user (their own friend list only).

    Returns:
        dict: ``{"friends_active": [...], "check_in": {...} | None}`` --
            see ``FriendsManager.get_friend_activity`` for the full shape.
    """
    manager = FriendsManager(user_id)
    try:
        return manager.get_friend_activity()
    finally:
        manager.close()


@friend_router.get("/{user_id}/{friend_id}")
async def read_friend(user_id: str, friend_id: str, _: str = Depends(require_match("user_id"))) -> dict:
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
async def send_friend_request(user_id: str, friend_username: str, _: str = Depends(require_match("user_id"))) -> None:
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
async def add_friend(user_id: str, friend_username: str, _: str = Depends(require_match("user_id"))) -> None:
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
async def remove_friend(user_id: str, friend_id: str, _: str = Depends(require_match("user_id"))) -> None:
    """Remove a friend from both users' friend lists.

    Args:
        user_id: UUID of the user initiating the removal.
        friend_id: UUID of the friend to remove.
    """
    manager = FriendsManager(user_id)
    manager.remove_friend(friend_id)
