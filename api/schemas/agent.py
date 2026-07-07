from pydantic import BaseModel, Field
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

_PROMPT_PATH = Path(__file__).parent.parent / "backend" / "interactions" / "agent_prompt.txt"
_DEFAULT_ROLE = _PROMPT_PATH.read_text(encoding="utf-8").strip()

class Agent(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    name: str = Field(default="Spritiual Guide")
    user_id: str = Field(default_factory=str)
    chats: list[str] = Field(default_factory=list)
    role: str = Field(default=_DEFAULT_ROLE)
    enabled: bool = Field(default=True)

class AgentHeartbeats(BaseModel):
    agent_id: str = Field(default_factory=str)
    user_id: str = Field(default_factory=str)
    timestamps: list[Optional[str]] = Field(
        default_factory=lambda: [None] * 31,
        description=(
            "31-item list indexed 0–30, where index i represents day i+1 of the month. "
            "Each slot is either None (no notification) or an ISO-8601 time string."
        )
    )
    prompt: str = Field(default_factory=str)
class AgentMessages(BaseModel):
    chat_id: str
    title: str = Field(default="")
    agent_id: str
    timestamp: datetime = Field(default=datetime.now())
    user_id: str
    content: str = Field(default="")

class AgenticContext(BaseModel):
    heartbeat_id: str = Field(default="")
    user_id: str = Field(default="")
    context: list[str] = Field(default_factory=list)