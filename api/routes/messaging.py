from fastapi import APIRouter, HTTPException, Request, WebSocket, WebSocketDisconnect, Depends
from backend.interactions.websockets import ConnectionManager
from backend.interactions.friends import FriendsManager
from backend.interactions.devotion import DevotionManager
from backend.interactions.attachments import generate_upload_policy, AttachmentConfigError
from backend.interactions.gif_search import search_gifs, GifConfigError, GifSearchError
from backend.auth.dependencies import get_current_user, require_match, authenticate_ws
from backend.rate_limiting import limiter
from schemas.message import UploadUrlRequest
from botocore.exceptions import ClientError
import boto3
import logging
import uuid
import json

ws_router    = APIRouter(prefix="/message")
chime_router = APIRouter(prefix="/chime")
manager      = ConnectionManager()
logger       = logging.getLogger(__name__)

_CHIME_ERROR_DETAIL = "Could not start the call. Please try again."

_SIGNAL_TYPES = frozenset({
    "call-invite", "call-accept", "call-reject", "call-end",
    "offer", "answer", "ice-candidate",
    "session-created", "session-joined", "session-left", "talking",
})

chime = boto3.client("chime-sdk-meetings", region_name="us-east-1")


def _get_or_create_meeting(session_id: str, user_id: str) -> dict:
    """Return the existing Chime meeting for a session, creating it if needed.

    ``user_id`` must be authorized on the session (creator, existing
    participant, or a member of the group/DM it belongs to) -- mirrors the
    check ``devotion.py::join_call`` already applies to the same underlying
    feature; this parallel chime_router implementation was missing it.
    """
    db = DevotionManager()
    try:
        session = db.get_session(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found")
        if not db.is_authorized(session, user_id):
            raise HTTPException(status_code=403, detail="Not authorized")

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
            logger.error("Chime create_meeting failed for session %s: %s", session_id, e)
            raise HTTPException(status_code=500, detail=_CHIME_ERROR_DETAIL)

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
        logger.error("Chime create_attendee failed for meeting %s, user %s: %s", chime_meeting_id, user_id, e)
        raise HTTPException(status_code=500, detail=_CHIME_ERROR_DETAIL)
    return resp["Attendee"]


@ws_router.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str, msg_type: str = "chat") -> None:
    session_user = await authenticate_ws(websocket)
    if session_user is None or session_user != user_id:
        await websocket.close(code=4401)
        return
    await manager.connect(user_id, websocket)
    try:
        try:
            while True:
                payload = await websocket.receive_json()
                # Any frame at all on this socket is proof of life for the
                # heartbeat liveness check (ConnectionManager.run_heartbeat_check)
                # — a real chat/signal send, or a future explicit "pong" reply.
                # This doesn't need to gate the blocking receive_json() call
                # above with its own timeout: the heartbeat's periodic probe
                # runs as an independent background task
                # (ConnectionManager.start_heartbeat), decoupled from whatever
                # this particular connection's receive loop is doing.
                manager.touch(user_id)
                # Never trust the client-supplied sender identity — a connected
                # user could otherwise claim to be anyone in `from_user` and
                # impersonate them in DMs/group chat/call signaling, bypassing
                # block enforcement (which keys off this field).
                payload["from_user"] = session_user
                effective_type = payload.get("type") or msg_type
                if effective_type == "pong":
                    # Client-side reply to our heartbeat ping (not sent by the
                    # current iOS client yet, but harmless/inert here for any
                    # client — including a future one, or the web client —
                    # that does reply) — touch() above already recorded it.
                    continue
                if effective_type in _SIGNAL_TYPES:
                    await manager.send_sig(payload)
                else:
                    await manager.send_msg(payload)
        except WebSocketDisconnect:
            pass
    finally:
        # Previously this only ran on a clean WebSocketDisconnect. Any other
        # exception escaping the loop (e.g. a malformed frame from
        # receive_json(), or a manager dispatch error) left this user's dead
        # socket behind in ConnectionManager.active_connections — every
        # future message sent to them would then hit the same failure, and
        # (before the send_msg/send_sig hardening above) could even crash an
        # unrelated sender's connection loop. Run cleanup on every exit path.
        await manager.disconnect(user_id)


@chime_router.post("/{session_id}")
async def start_meeting(session_id: str, current_user: str = Depends(get_current_user)) -> dict:
    """Get or create the Chime meeting for a session."""
    return {"Meeting": _get_or_create_meeting(session_id, current_user)}


@chime_router.post("/{session_id}/{user_id}/attend")
async def join_meeting(session_id: str, user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Create an attendee token for a user joining a session's Chime meeting."""
    db = DevotionManager()
    try:
        session = db.get_session(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found")
        if not db.is_authorized(session, user_id):
            raise HTTPException(status_code=403, detail="Not authorized")
        chime_meeting_id = session.get("chime_meeting_id", "")
        if not chime_meeting_id:
            raise HTTPException(status_code=400, detail="No active meeting for this session")
        return {"Attendee": _create_attendee(chime_meeting_id, user_id)}
    finally:
        db.close()


@ws_router.get("/messages/{host_user}/")
async def read_dm(host_user: str, guest_user: str, _: str = Depends(require_match("host_user"))) -> dict:
    friend_manager = FriendsManager(host_user)
    try:
        result = friend_manager.read_friend(guest_user)
        if "error" in result:
            raise HTTPException(status_code=404, detail=result["error"])
        return {"payload": result}
    finally:
        friend_manager.close()


@ws_router.post("/upload-url/{user_id}")
@limiter.limit("30/minute")
async def request_upload_url(
    request: Request,
    user_id: str,
    info: UploadUrlRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Issue a presigned S3 POST policy for a direct-to-S3 attachment upload.

    Authenticated + self-scoped (``require_match``): a user can only ever
    request an upload URL for themselves. Deny-by-default -- an
    ``attachment_kind``/``content_type`` combination outside the per-kind
    allowlist is rejected (400) rather than falling back to a generic
    bucket (Security Posture Q2/Q14). The client uploads the raw bytes
    directly to S3 with the returned ``url``/``fields``; the server never
    receives them.

    Raises:
        HTTPException 400: If ``attachment_kind``/``content_type`` isn't a
            recognized, allowed combination.
        HTTPException 503: If attachment uploads aren't configured yet
            (missing S3_BUCKET_NAME/S3_REGION).
    """
    try:
        return generate_upload_policy(user_id, info.attachment_kind, info.content_type)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except AttachmentConfigError as e:
        logger.error("Attachment upload requested but not configured: %s", e)
        raise HTTPException(status_code=503, detail="Attachment uploads are not available right now.")


@ws_router.get("/gif-search")
@limiter.limit("30/minute")
async def gif_search(request: Request, q: str, _: str = Depends(get_current_user)) -> dict:
    """Authenticated GIF search, proxied server-side so the provider API key
    never reaches the client (Security Posture Q2/Q6). Returns only the
    fields the composer needs, not the provider's raw response.

    Rate-limited per client IP (mirrors this file's other endpoints) so one
    account can't burn the shared provider quota/cost for everyone.

    Raises:
        HTTPException 503: If GIF search isn't configured yet (missing/
            unrecognized GIF_PROVIDER or GIF_PROVIDER_API_KEY).
        HTTPException 502: If the configured provider's API call itself fails.
    """
    try:
        results = await search_gifs(q)
    except GifConfigError as e:
        logger.error("GIF search requested but not configured: %s", e)
        raise HTTPException(status_code=503, detail="GIF search is not available right now.")
    except GifSearchError as e:
        logger.warning("GIF search failed: %s", e)
        raise HTTPException(status_code=502, detail="Couldn't reach the GIF search provider — please try again.")
    return {"results": results}


@ws_router.post("/friend-request")
async def send_request(user_id: str, friend_user: str, _: str = Depends(require_match("user_id"))) -> None:
    friend_manager = FriendsManager(user_id)
    try:
        friend_manager.send_add_request(friend_user)
    finally:
        friend_manager.close()


@ws_router.post("/add-friend", status_code=204)
async def add_friend(host_user: str, user_to_add: str, _: str = Depends(require_match("host_user"))) -> None:
    friend_manager = FriendsManager(host_user)
    try:
        friend_manager.add_friend(user_to_add)
    finally:
        friend_manager.close()


@ws_router.delete("/remove-friend", status_code=204)
async def remove_friend(host_user: str, user_to_del: str, _: str = Depends(require_match("host_user"))) -> None:
    friend_manager = FriendsManager(host_user)
    try:
        friend_manager.remove_friend(user_to_del)
    finally:
        friend_manager.close()
