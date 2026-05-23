from pydantic import BaseModel, Field

class Session(BaseModel):
    title: str
    time_start: str
    time_end: str
    prompts: list[str]
    scripture: list[str] = Field(default_factory=list, description="link -- eg. fellowcsript.com/reader.html#Exodus-12")
    
class DevotionPlan(BaseModel):
    time_start: str
    time_end: str
    title: str
    group_id: str
    sessions: list[Session]

class DevotionRequest(BaseModel):
    devo_id: str
    user_id: str
    devotion: DevotionPlan