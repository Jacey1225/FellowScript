import os
import json
from fastapi import APIRouter, HTTPException
from schemas.devotion import DevotionRequest, DevotionPlan
from backend.interactions.helpers import (
    save_devotion, 
    read_devotion,
    remove_devotion)

devo_router = APIRouter(prefix="/devotions")

@devo_router.post("/")
async def create_devotion(req: DevotionRequest):
    save_devotion(req.devotion)

@devo_router.get("/")
async def fetch_devotion(devotion_id: str):
    devotion = read_devotion(devotion_id)
    return devotion

@devo_router.delete("/")
async def delete_devotion(req: DevotionRequest):
    remove_devotion(req.devo_id)
