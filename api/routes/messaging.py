from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect
from backend.interactions.websockets import ConnectionManager
from backend.interactions.friends import FriendsManager
from backend.interactions.devotion import DevotionManager
from botocore.exceptions import ClientError
import boto3
import uuid
import json

ws_router    = APIRouter(prefix="/message")
chime_router = APIRouter(prefix="/chime")
manager      = ConnectionManager()

_SIGNAL_TYPES = frozenset({
    "call-invite", "call-accept", "call-reject", "call-end",
    "offer", "answer", "ice-candidate",
    "session-created", "session-joined", "session-left", "talking",
})

chime = boto3.client("chime-sdk-meetings", region_name="us-east-1")


def _get_or_create_meeting(session_id: str) -> dict:
    """Return the existing Chime meeting for a session, creating it if needed."""
    db = DevotionManager()
    try:
        session = db.get_session(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found")

        chime_meeting_id = session.get("chime_meeting_id", "")
        meeting_data     = session.get("chime_meeting") or {}
        if isinstance(meeting_data, str):
            meeting_data = json.loads(meeting_data)

        if chime_meeting_id and meeting_data:
            return meeting_data

        try:
            resp = chime.create_meeting(
                ClientRequestToken=str(uuid.uuid4()),
                MediaRegion="us-east-1",
                ExternalMeetingId=session_id,
            )
        except ClientError as e:
            raise HTTPException(status_code=500, detail=str(e))

        meeting_data     = resp["Meeting"]
        chime_meeting_id = meeting_data["MeetingId"]
        db.save_chime_meeting(session_id, chime_meeting_id, meeting_data)
        return meeting_data
    finally:
        db.close()


def _create_attendee(chime_meeting_id: str, user_id: str) -> dict:
    try:
        resp = chime.create_attendee(MeetingId=chime_meeting_id, ExternalUserId=user_id)
    except ClientError as e:
        raise HTTPException(status_code=500, detail=str(e))
    return resp["Attendee"]


@ws_router.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str, msg_type: str = "chat") -> None:
    await manager.connect(user_id, websocket)
    try:
        while True:
            payload      = await websocket.receive_json()
            effective_type = payload.get("type") or msg_type
            if effective_type in _SIGNAL_TYPES:
                await manager.send_sig(payload)
            else:
                await manager.send_msg(payload)
    except WebSocketDisconnect:
        await manager.disconnect(user_id)


@chime_router.post("/{session_id}")
async def start_meeting(session_id: str) -> dict:
    """Get or create the Chime meeting for a session."""
    return {"Meeting": _get_or_create_meeting(session_id)}


@chime_router.post("/{session_id}/{user_id}/attend")
async def join_meeting(session_id: str, user_id: str) -> dict:
    """Create an attendee token for a user joining a session's Chime meeting."""
    db = DevotionManager()
    try:
        session = db.get_session(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found")
        chime_meeting_id = session.get("chime_meeting_id", "")
        if not chime_meeting_id:
            raise HTTPException(status_code=400, detail="No active meeting for this session")
        return {"Attendee": _create_attendee(chime_meeting_id, user_id)}
    finally:
        db.close()


@ws_router.get("/messages/{host_user}/")
async def read_dm(host_user: str, guest_user: str) -> dict:
    friend_manager = FriendsManager(host_user)
    try:
        return {"payload": friend_manager.read_friend(guest_user)}
    finally:
        friend_manager.close()


@ws_router.post("/friend-request")
async def send_request(user_id: str, friend_user: str) -> None:
    friend_manager = FriendsManager(user_id)
    try:
        friend_manager.send_add_request(friend_user)
    finally:
        friend_manager.close()


@ws_router.post("/add-friend", status_code=204)
async def add_friend(host_user: str, user_to_add: str) -> None:
    friend_manager = FriendsManager(host_user)
    try:
        friend_manager.add_friend(user_to_add)
    finally:
        friend_manager.close()


@ws_router.delete("/remove-friend", status_code=204)
async def remove_friend(host_user: str, user_to_del: str) -> None:
    friend_manager = FriendsManager(host_user)
    try:
        friend_manager.remove_friend(user_to_del)
    finally:
        friend_manager.close()
