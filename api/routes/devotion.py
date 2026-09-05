from fastapi import APIRouter, HTTPException, Depends
from schemas.devotion import DevotionRequest, DevotionPlan
from backend.interactions.devotion import DevotionManager
from backend.auth.dependencies import get_current_user, require_match
from backend.moderation.content_filter import check_clean, ContentRejected, rejection_message
import boto3
import logging
import uuid
from botocore.exceptions import ClientError

chime = boto3.client("chime-sdk-meetings", region_name="us-east-1")
devo_router = APIRouter(prefix="/devotions")
logger = logging.getLogger(__name__)

_CHIME_ERROR_DETAIL = "Could not start the call. Please try again."


def _check_devotion_clean(devotion) -> None:
    try:
        check_clean(title=devotion.title, prompts=" | ".join(devotion.prompts))
    except ContentRejected as e:
        raise HTTPException(status_code=422, detail=rejection_message(e))


async def _notify_session_created(db: DevotionManager, devotion: DevotionPlan, session_id: str, creator_id: str) -> None:
    """Push the session's other group/DM members that a new session was
    scheduled -- everyone ``resolve_members`` returns except the creator
    themselves. Per-recipient failure (missing/expired token, a transient
    APNs error) is caught and logged, never allowed to fail the create call
    itself -- same isolation posture as every other push send in this
    project (``scheduler.py``'s jobs, ``websockets.py``'s ``send_msg``).
    """
    from backend.interactions.push import send_push

    session = {
        "creator_id": creator_id,
        "participants": devotion.participants,
        "group_id": devotion.group_id,
    }
    members = [uid for uid in db.resolve_members(session) if uid != creator_id]
    if not members:
        return
    tokens = db.device_tokens_bulk(members)
    creator_name = db.get_username(creator_id) or "Someone"
    body = f'{creator_name} scheduled a new session: "{devotion.title}".' if devotion.title \
        else f"{creator_name} scheduled a new session."
    for uid in members:
        token = tokens.get(uid)
        if not token:
            continue
        try:
            await send_push(
                token, "New Session", body,
                data={"devotion_id": session_id, "group_id": devotion.group_id},
            )
        except Exception as e:
            logger.error("Session-created push failed (%s -> %s): %s", session_id, uid, e)


@devo_router.post("/", status_code=201)
async def create_devotion(req: DevotionRequest, current_user: str = Depends(get_current_user)) -> dict:
    if req.user_id != current_user:
        raise HTTPException(status_code=403, detail="Forbidden")
    _check_devotion_clean(req.devotion)
    db = DevotionManager()
    try:
        session_id = db.save_devotion(req.devotion)
        await _notify_session_created(db, req.devotion, session_id, current_user)
        return {"id": session_id}
    finally:
        db.close()


@devo_router.get("/contact/{contact_id}")
async def get_contact_devotions(contact_id: str, current_user: str = Depends(get_current_user)) -> dict:
    db = DevotionManager()
    try:
        return {"sessions": db.fetch_by_contact(contact_id, viewer_id=current_user)}
    finally:
        db.close()


@devo_router.get("/")
async def fetch_devotion(devotion_id: str, current_user: str = Depends(get_current_user)) -> dict:
    db = DevotionManager()
    try:
        devotion = db.read_devotion(devotion_id)
        if not devotion:
            raise HTTPException(status_code=404, detail="Session not found")
        if not db.is_authorized(devotion.model_dump(), current_user):
            raise HTTPException(status_code=403, detail="Not authorized")
        return devotion.model_dump()
    finally:
        db.close()


@devo_router.put("/")
async def update_devotion(req: DevotionRequest, current_user: str = Depends(get_current_user)) -> dict:
    if req.user_id != current_user:
        raise HTTPException(status_code=403, detail="Forbidden")
    _check_devotion_clean(req.devotion)
    db = DevotionManager()
    try:
        session = db.get_session(req.devotion_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found")
        if not db.is_authorized(session, current_user):
            raise HTTPException(status_code=403, detail="Not authorized")
        ok = db.update_devotion(req.devotion_id, req.devotion)
        if not ok:
            raise HTTPException(status_code=404, detail="Session not found")
        return {"ok": True}
    finally:
        db.close()


@devo_router.post("/join")
async def join_devotion(user_id: str, session_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DevotionManager()
    try:
        session = db.get_session(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found")
        if not db.is_authorized(session, user_id):
            raise HTTPException(status_code=403, detail="Not authorized")
        db.add_participant(session_id, user_id)
        return {"ok": True}
    finally:
        db.close()


@devo_router.post("/leave")
async def leave_devotion(user_id: str, session_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DevotionManager()
    try:
        session = db.get_session(session_id)
        # Missing session: no-op, same as before (idempotent leave).
        if session and not db.is_authorized(session, user_id):
            raise HTTPException(status_code=403, detail="Not authorized")
        db.remove_participant(session_id, user_id)
        return {"ok": True}
    finally:
        db.close()


@devo_router.delete("/")
async def delete_devotion(req: DevotionRequest, current_user: str = Depends(get_current_user)) -> dict:
    if req.user_id != current_user:
        raise HTTPException(status_code=403, detail="Forbidden")
    db = DevotionManager()
    try:
        # Only the session's creator (host) may delete it.
        session = db.read_devotion(req.devotion_id)
        if session is None:
            return {"ok": True}  # already gone — idempotent
        if str(session.creator_id) != str(req.user_id):
            raise HTTPException(status_code=403, detail="Only the session host can delete it.")
        db.remove_devotion(req.devotion_id)
        return {"ok": True}
    finally:
        db.close()


@devo_router.post("/join-call")
async def join_call(session_id: str, user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
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
            import json
            meeting_data = json.loads(meeting_data)

        if not chime_meeting_id:
            try:
                resp = chime.create_meeting(
                    ClientRequestToken=str(uuid.uuid4()),
                    MediaRegion="us-east-1",
                    ExternalMeetingId=session_id,
                )
                meeting_data     = resp["Meeting"]
                chime_meeting_id = meeting_data["MeetingId"]
                db.save_chime_meeting(session_id, chime_meeting_id, meeting_data)
            except ClientError as e:
                logger.error("Chime create_meeting failed for session %s: %s", session_id, e)
                raise HTTPException(status_code=500, detail=_CHIME_ERROR_DETAIL)

        try:
            attendee_resp = chime.create_attendee(
                MeetingId=chime_meeting_id,
                ExternalUserId=user_id,
            )
        except ClientError as e:
            logger.error(
                "Chime create_attendee failed for session %s, meeting %s, user %s: %s",
                session_id, chime_meeting_id, user_id, e,
            )
            raise HTTPException(status_code=500, detail=_CHIME_ERROR_DETAIL)

        return {"Meeting": meeting_data, "Attendee": attendee_resp["Attendee"]}
    finally:
        db.close()
