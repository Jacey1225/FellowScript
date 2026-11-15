from pydantic import BaseModel, Field

# The only activity kinds the calendar ever reports.
ACTIVITY_KINDS = ("chat", "note", "bible")


class MonthActivity(BaseModel):
    """One user's calendar month. Only days with activity appear in ``days``."""
    year: int
    month: int
    timezone: str = Field(description="IANA zone used to assign days (users.timezone, UTC fallback)")
    days: dict[str, list[str]] = Field(
        default_factory=dict,
        description="'YYYY-MM-DD' -> sorted subset of ACTIVITY_KINDS; no counts",
    )
