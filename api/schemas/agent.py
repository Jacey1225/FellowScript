from pydantic import BaseModel, Field
import uuid
from datetime import datetime

class Agent(BaseModel):
    agent_id: str = Field(default=str(uuid.uuid4))
    chats: list[str] = Field(default_factory=list)
    role: str = Field(default_factory=str)
    heartbeats: dict[datetime, str] = Field(default_factory=dict)

class AgentMessages(BaseModel):
    chat_id: str
    title: str = Field(default="")
    agent_id: str
    timestamp: datetime = Field(default=datetime.now())
    user_id: str
    content: str = Field(default="")

