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
)

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
