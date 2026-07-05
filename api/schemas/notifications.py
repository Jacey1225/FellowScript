from pydantic import BaseModel, Field
from typing import Optional

class Notification(BaseModel):
    user_id: str
    name: str
    prompt: str
    timestamps: list[Optional[str]] = Field(
        default_factory=lambda: [None] * 31,
        description=(
            "31-item list indexed 0–30, where index i represents day i+1 of the month. "
            "Each slot is either None (no notification) or an ISO-8601 time string."
        )
    )
    
