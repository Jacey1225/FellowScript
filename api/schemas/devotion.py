from pydantic import BaseModel, Field
import uuid

class DevotionPlan(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    title: str = ""
    time_start: str = ""
    time_end: str = ""
    recurring: bool = False
    group_id: str = ""
    creator_id: str = ""
    participants: list[str] = Field(default_factory=list)
    verses: list[str] = Field(default_factory=list)
    prompts: list[str] = Field(default_factory=list)
    chime_meeting_id: str = ""
    chime_meeting: dict = Field(default_factory=dict)
    summarize: bool = False


class DevotionRequest(BaseModel):
    devotion_id: str
    user_id: str
    devotion: DevotionPlan


class RingRequest(BaseModel):
    """POST /devotions/ring -- ring one or more of a live session's own
    group members to prompt them to join (task 20260916-call-ring-members).
    ``target_ids`` is deliberately a list (not a single id) so one in-call
    multi-select action is one request, with each target then evaluated and
    reported independently (see routes/devotion.py::ring_members)."""
    devotion_id: str
    user_id: str
    target_ids: list[str] = Field(default_factory=list)
