from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from backend.messaging.websockets import ConnectionManager, FriendsManager, GroupsManager

ws_router = APIRouter(prefix="/message")
manager = ConnectionManager()

@ws_router.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str):
    await manager.connect(user_id, websocket)
    try:
        while True:
            payload = await websocket.receive_json()
            await manager.send_msg(payload)
    except WebSocketDisconnect:
        await manager.disconnect(user_id)

@ws_router.get("/messages/{host_user}/")
async def read_dm(host_user: str, guest_user: str):
    friend_manager = FriendsManager(host_user)
    payload = friend_manager.read_friend(guest_user)
    return {"payload": payload}

@ws_router.post("/friend-request")
async def send_request(user_id: str, friend_user: str):
    friend_manager = FriendsManager(user_id)
    friend_manager.send_add_request(friend_user)

@ws_router.post("/add-friend", status_code=204)
async def add_friend(host_user: str, user_to_add: str):
    friend_manager = FriendsManager(host_user)
    friend_manager.add_friend(user_to_add)

@ws_router.delete("/remove-friend", status_code=204)
async def remove_friend(host_user: str, user_to_del: str):
    friend_manager = FriendsManager(host_user)
    friend_manager.remove_friend(user_to_del)

