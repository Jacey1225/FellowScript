from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from api.backend.interactions.websockets import ConnectionManager
from api.backend.interactions.friends import FriendsManager
ws_router = APIRouter(prefix="/message")
manager = ConnectionManager()


_SIGNAL_TYPES = frozenset({
    "call-invite", "call-accept", "call-reject", "call-end",
    "offer", "answer", "ice-candidate",
    "session-created", "session-joined", "session-left", "talking",
})


@ws_router.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str, msg_type: str = "chat") -> None:
    """Handle a persistent WebSocket connection for a single user.

    Dispatches incoming frames based on the payload's ``type`` field (falling
    back to the ``msg_type`` query param). Chat messages are persisted and
    relayed; signaling frames are relayed only.
    """
    await manager.connect(user_id, websocket)
    try:
        while True:
            payload = await websocket.receive_json()
            effective_type = payload.get("type") or msg_type
            if effective_type in _SIGNAL_TYPES:
                await manager.send_sig(payload)
            else:
                await manager.send_msg(payload)
    except WebSocketDisconnect:
        await manager.disconnect(user_id)


@ws_router.get("/messages/{host_user}/")
async def read_dm(host_user: str, guest_user: str) -> dict:
    """Fetch the direct message history between two users.

    Args:
        host_user: UUID of the requesting user.
        guest_user: UUID of the other party in the conversation.

    Returns:
        dict: ``{"payload": dict}`` containing ``host_msgs`` and ``other_msgs``
            lists as returned by ``FriendsManager.read_friend()``.
    """
    friend_manager = FriendsManager(host_user)
    payload = friend_manager.read_friend(guest_user)
    return {"payload": payload}


@ws_router.post("/friend-request")
async def send_request(user_id: str, friend_user: str) -> None:
    """Send a friend request to another user by username.

    Args:
        user_id: UUID of the user sending the request.
        friend_user: Username of the intended recipient.
    """
    friend_manager = FriendsManager(user_id)
    friend_manager.send_add_request(friend_user)


@ws_router.post("/add-friend", status_code=204)
async def add_friend(host_user: str, user_to_add: str) -> None:
    """Accept a pending friend request and establish a mutual friendship.

    Args:
        host_user: UUID of the user accepting the request.
        user_to_add: Username of the user to add as a friend.
    """
    friend_manager = FriendsManager(host_user)
    friend_manager.add_friend(user_to_add)


@ws_router.delete("/remove-friend", status_code=204)
async def remove_friend(host_user: str, user_to_del: str) -> None:
    """Remove a friend from both users' friend lists.

    Args:
        host_user: UUID of the user initiating the removal.
        user_to_del: UUID of the friend to remove.
    """
    friend_manager = FriendsManager(host_user)
    friend_manager.remove_friend(user_to_del)
