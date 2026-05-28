from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from backend.interactions.websockets import ConnectionManager
from backend.interactions.friends import FriendsManager
ws_router = APIRouter(prefix="/message")
manager = ConnectionManager()


@ws_router.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str, msg_type: str) -> None:
    """Handle a persistent WebSocket connection for a single user.

    Registers the connection in the ``ConnectionManager``, then listens for
    incoming JSON frames. Each frame is dispatched based on ``msg_type``:

    - ``"chat"``: persisted to the messages store and relayed to recipients.
    - Signaling types (``"call-invite"``, ``"call-accept"``, ``"call-reject"``,
      ``"offer"``, ``"answer"``, ``"ice-candidate"``, ``"call-end"``): relayed
      only — not persisted — to support WebRTC signaling flows.

    The connection is cleaned up automatically on disconnect.

    Args:
        websocket: The active WebSocket connection.
        user_id: UUID of the connecting user; used to key the connection.
        msg_type: Message category for the session, provided as a query param.
    """
    await manager.connect(user_id, websocket)
    try:
        while True:
            payload = await websocket.receive_json()

            if msg_type == "chat":
                await manager.send_msg(payload)
            elif msg_type in ("call-invite", "call-accept", "call-reject",
                              "offer", "answer", "ice-candidate", "call-end"):
                await manager.send_sig(payload)
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
