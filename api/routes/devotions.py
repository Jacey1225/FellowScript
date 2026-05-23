import os
import json
from schemas.devotion import DevotionPlan, Session, DevotionRequest
from fastapi import APIRouter

MAIN_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../..")
DEVOTION_PATH = "data/devotions.json"
devo_router = APIRouter(prefix="/devotions")

def load_devotion():
    pass

def set_devotion(devotion: DevotionPlan):
    pass

@devo_router.post("/")
async def create_devotion(req: DevotionRequest):
    pass


@devo_router.delete("/")
async def remove_devotion(req: DevotionRequest):
    pass

@devo_router.get("/")
async def get_devotion(req: DevotionRequest):
    pass

@devo_router.put("/")
async def update_devotion(req: DevotionRequest):
    pass