from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect
from backend.interactions.websockets import ConnectionManager
from backend.interactions.friends import FriendsManager
from backend.interactions.helpers import save_chime_meeting, load_devotions
from botocore.exceptions import ClientError
import boto3
import uuid

ws_router = APIRouter(prefix="/message")
chime_router = APIRouter(prefix="/chime")
manager = ConnectionManager()


_SIGNAL_TYPES = frozenset({
    "call-invite", "call-accept", "call-reject", "call-end",
    "offer", "answer", "ice-candidate",
    "session-created", "session-joined", "session-left", "talking",
})

chime = boto3.client("chime-sdk-meetings", region_name='us-east-1')


def _get_or_create_meeting(session_id: str) -> dict:
    """Return the existing Chime meeting for a session, creating it if needed.

    Idempotent: concurrent callers reuse the same meeting rather than
    creating duplicate rooms.
    """
    devotions = load_devotions()
    session = devotions.get(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    chime_meeting_id = session.get("chime_meeting_id", "")
    meeting_data     = session.get("chime_meeting", {})

    if chime_meeting_id and meeting_data:
        return meeting_data

    try:
        resp = chime.create_meeting(
            ClientRequestToken=str(uuid.uuid4()),
            MediaRegion='us-east-1',
            ExternalMeetingId=session_id,
        )
    except ClientError as e:
        raise HTTPException(status_code=500, detail=str(e))

    meeting_data     = resp['Meeting']
    chime_meeting_id = meeting_data['MeetingId']
    save_chime_meeting(session_id, chime_meeting_id, meeting_data)
    return meeting_data


def _create_attendee(chime_meeting_id: str, user_id: str) -> dict:
    try:
        resp = chime.create_attendee(
            MeetingId=chime_meeting_id,
            ExternalUserId=user_id,
        )
    except ClientError as e:
        raise HTTPException(status_code=500, detail=str(e))
    return resp['Attendee']


@ws_router.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str, msg_type: str = "chat") -> None:
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


@chime_router.post("/{session_id}")
async def start_meeting(session_id: str) -> dict:
    """Get or create the Chime meeting for a session.

    Returns the full Meeting object needed by the Chime SDK.
    Safe to call multiple times — subsequent callers receive the same meeting.
    """
    meeting = _get_or_create_meeting(session_id)
    return {"Meeting": meeting}


@chime_router.post("/{session_id}/{user_id}/attend")
async def join_meeting(session_id: str, user_id: str) -> dict:
    """Create an attendee token for a user joining a session's Chime meeting.

    The session must already have a Chime meeting (call start_meeting first).
    Returns the Attendee object needed by the Chime SDK.
    """
    devotions = load_devotions()
    session = devotions.get(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    chime_meeting_id = session.get("chime_meeting_id", "")
    if not chime_meeting_id:
        raise HTTPException(status_code=400, detail="No active meeting for this session")

    attendee = _create_attendee(chime_meeting_id, user_id)
    return {"Attendee": attendee}


@ws_router.get("/messages/{host_user}/")
async def read_dm(host_user: str, guest_user: str) -> dict:
    friend_manager = FriendsManager(host_user)
    payload = friend_manager.read_friend(guest_user)
    return {"payload": payload}


@ws_router.post("/friend-request")
async def send_request(user_id: str, friend_user: str) -> None:
    friend_manager = FriendsManager(user_id)
    friend_manager.send_add_request(friend_user)


@ws_router.post("/add-friend", status_code=204)
async def add_friend(host_user: str, user_to_add: str) -> None:
    friend_manager = FriendsManager(host_user)
    friend_manager.add_friend(user_to_add)


@ws_router.delete("/remove-friend", status_code=204)
async def remove_friend(host_user: str, user_to_del: str) -> None:
    friend_manager = FriendsManager(host_user)
    friend_manager.remove_friend(user_to_del)
