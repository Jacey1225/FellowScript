from fastapi import APIRouter, HTTPException
from backend.messaging.websockets import GroupsManager, FriendsManager
from schemas.message import Group

group_router = APIRouter(prefix="/groups")
friend_router = APIRouter(prefix="/friends")


# ── Groups ─────────────────────────────────────────────────────────────────────

@group_router.post("/{user_id}", status_code=201)
async def create_group(user_id: str, group: Group):
    manager = GroupsManager(user_id)
    manager.create_group(group.users, group)
    return {"group_id": group.group_id}


@group_router.get("/{user_id}/{group_id}")
async def fetch_group(user_id: str, group_id: str):
    manager = GroupsManager(user_id, group_id)
    result = manager.fetch_group()
    if "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])
    return result


@group_router.get("/{user_id}/{group_id}/notes")
async def fetch_group_notes(user_id: str, group_id: str):
    manager = GroupsManager(user_id, group_id)
    return manager.fetch_notes()


@group_router.get("/{user_id}/{group_id}/highlights")
async def fetch_group_highlights(user_id: str, group_id: str):
    manager = GroupsManager(user_id, group_id)
    return manager.fetch_highlights()


@group_router.put("/{user_id}/{group_id}")
async def update_group(user_id: str, group_id: str, group: Group):
    manager = GroupsManager(user_id, group_id)
    manager.update_group(group)


@group_router.delete("/{user_id}/{group_id}", status_code=204)
async def remove_group(user_id: str, group_id: str):
    manager = GroupsManager(user_id, group_id)
    manager.remove_group()


# ── Friends ────────────────────────────────────────────────────────────────────

@friend_router.get("/{user_id}")
async def get_friends(user_id: str):
    manager = FriendsManager(user_id)
    return manager.get_friends()


@friend_router.get("/{user_id}/{friend_id}")
async def read_friend(user_id: str, friend_id: str):
    manager = FriendsManager(user_id)
    result = manager.read_friend(friend_id)
    if "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])
    return result


@friend_router.post("/{user_id}/request")
async def send_friend_request(user_id: str, friend_username: str):
    manager = FriendsManager(user_id)
    result = manager.send_add_request(friend_username)
    if result and "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])


@friend_router.post("/{user_id}/add", status_code=204)
async def add_friend(user_id: str, friend_username: str):
    manager = FriendsManager(user_id)
    result = manager.add_friend(friend_username)
    if result and "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])


@friend_router.delete("/{user_id}/{friend_id}", status_code=204)
async def remove_friend(user_id: str, friend_id: str):
    manager = FriendsManager(user_id)
    manager.remove_friend(friend_id)
