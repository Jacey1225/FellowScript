from fastapi import APIRouter, HTTPException
from schemas.devotion import DevotionRequest, DevotionPlan
from backend.interactions.helpers import (
    save_devotion,
    read_devotion,
    remove_devotion,
    fetch_devotions_by_contact,
    add_session_participant,
    remove_session_participant,
    update_devotion_data,
    save_chime_meeting,
    load_devotions,
)
import boto3
import uuid
from botocore.exceptions import ClientError

chime = boto3.client("chime-sdk-meetings", region_name="us-east-1")

devo_router = APIRouter(prefix="/devotions")


@devo_router.post("/", status_code=201)
async def create_devotion(req: DevotionRequest) -> dict:
    session_id = save_devotion(req.devotion)
    return {"id": session_id}


@devo_router.get("/contact/{contact_id}")
async def get_contact_devotions(contact_id: str) -> dict:
    sessions = fetch_devotions_by_contact(contact_id)
    return {"sessions": sessions}


@devo_router.get("/")
async def fetch_devotion(devotion_id: str) -> dict:
    devotion = read_devotion(devotion_id)
    if not devotion:
        raise HTTPException(status_code=404, detail="Session not found")
    return devotion.model_dump()


@devo_router.put("/")
async def update_devotion(req: DevotionRequest) -> dict:
    ok = update_devotion_data(req.devotion_id, req.devotion)
    if not ok:
        raise HTTPException(status_code=404, detail="Session not found")
    return {"ok": True}


@devo_router.post("/join")
async def join_devotion(user_id: str, session_id: str) -> dict:
    add_session_participant(session_id, user_id)
    return {"ok": True}


@devo_router.post("/leave")
async def leave_devotion(user_id: str, session_id: str) -> dict:
    remove_session_participant(session_id, user_id)
    return {"ok": True}


@devo_router.delete("/")
async def delete_devotion(req: DevotionRequest) -> dict:
    remove_devotion(req.devotion_id)
    return {"ok": True}


@devo_router.post("/join-call")
async def join_call(session_id: str, user_id: str) -> dict:
    devotions = load_devotions()
    session = devotions.get(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    chime_meeting_id = session.get("chime_meeting_id", "")
    meeting_data     = session.get("chime_meeting", {})

    # Create the Chime meeting once — all subsequent joiners reuse it
    if not chime_meeting_id:
        try:
            resp = chime.create_meeting(
                ClientRequestToken=str(uuid.uuid4()),
                MediaRegion="us-east-1",
                ExternalMeetingId=session_id,
            )
            meeting_data     = resp["Meeting"]
            chime_meeting_id = meeting_data["MeetingId"]
            save_chime_meeting(session_id, chime_meeting_id, meeting_data)
        except ClientError as e:
            raise HTTPException(status_code=500, detail=str(e))

    # Each joiner gets their own attendee token
    try:
        attendee_resp = chime.create_attendee(
            MeetingId=chime_meeting_id,
            ExternalUserId=user_id,
        )
    except ClientError as e:
        raise HTTPException(status_code=500, detail=str(e))

    return {
        "Meeting":  meeting_data,
        "Attendee": attendee_resp["Attendee"],
    }
