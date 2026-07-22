from fastapi import APIRouter, HTTPException, Depends
from schemas.devotion import DevotionRequest
from backend.interactions.devotion import DevotionManager
from backend.auth.dependencies import get_current_user, require_match
import boto3
import uuid
from botocore.exceptions import ClientError

chime = boto3.client("chime-sdk-meetings", region_name="us-east-1")
devo_router = APIRouter(prefix="/devotions")


@devo_router.post("/", status_code=201)
async def create_devotion(req: DevotionRequest, current_user: str = Depends(get_current_user)) -> dict:
    if req.user_id != current_user:
        raise HTTPException(status_code=403, detail="Forbidden")
    db = DevotionManager()
    try:
        session_id = db.save_devotion(req.devotion)
        return {"id": session_id}
    finally:
        db.close()


@devo_router.get("/contact/{contact_id}")
async def get_contact_devotions(contact_id: str, _: str = Depends(get_current_user)) -> dict:
    db = DevotionManager()
    try:
        return {"sessions": db.fetch_by_contact(contact_id)}
    finally:
        db.close()


@devo_router.get("/")
async def fetch_devotion(devotion_id: str, _: str = Depends(get_current_user)) -> dict:
    db = DevotionManager()
    try:
        devotion = db.read_devotion(devotion_id)
        if not devotion:
            raise HTTPException(status_code=404, detail="Session not found")
        return devotion.model_dump()
    finally:
        db.close()


@devo_router.put("/")
async def update_devotion(req: DevotionRequest, current_user: str = Depends(get_current_user)) -> dict:
    if req.user_id != current_user:
        raise HTTPException(status_code=403, detail="Forbidden")
    db = DevotionManager()
    try:
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
        db.add_participant(session_id, user_id)
        return {"ok": True}
    finally:
        db.close()


@devo_router.post("/leave")
async def leave_devotion(user_id: str, session_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DevotionManager()
    try:
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
                raise HTTPException(status_code=500, detail=str(e))

        try:
            attendee_resp = chime.create_attendee(
                MeetingId=chime_meeting_id,
                ExternalUserId=user_id,
            )
        except ClientError as e:
            raise HTTPException(status_code=500, detail=str(e))

        return {"Meeting": meeting_data, "Attendee": attendee_resp["Attendee"]}
    finally:
        db.close()
