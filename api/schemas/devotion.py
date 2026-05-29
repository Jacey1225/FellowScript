from pydantic import BaseModel, Field
import uuid

class DevotionPlan(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    title: str = ""
    time_start: str = ""
    time_end: str = ""
    group_id: str = ""
    creator_id: str = ""
    participants: list[str] = Field(default_factory=list)
    verses: list[str] = Field(default_factory=list)
    prompts: list[str] = Field(default_factory=list)

class DevotionRequest(BaseModel):
    devotion_id: str
    user_id: str
    devotion: DevotionPlan
