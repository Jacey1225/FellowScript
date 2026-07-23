from pydantic import BaseModel, Field, field_validator
import uuid
from datetime import datetime
from typing import Optional
from zoneinfo import available_timezones


def _validate_timezone(value: str) -> str:
    if value not in available_timezones():
        raise ValueError(f"Unknown IANA timezone: {value!r}")
    return value

class User(BaseModel):
    user_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    username: str = Field(default_factory=str)
    email: str = Field(default_factory=str)
    hash_pass: str = Field(default_factory=str)
    friends: list[str] = Field(default_factory=list)
    friend_requests: list[str] = Field(default_factory=list)
    groups: list[str] = Field(default_factory=list)
    highlights: dict[str, str] = Field(
        default_factory=dict,
        description="key: 'Book-chapter-verse' e.g. 'Genesis-1-3', value: hex color")
    bookmarks: dict[str, str] = Field(
        default_factory=dict,
        description="key: 'book-chapter' eg. 'Genesis-1'")
    timezone: str = Field(
        default="UTC",
        description="IANA timezone name (e.g. 'America/Los_Angeles'); drives the "
                     "user's local-3am nightly backup schedule")
    # The plan a user belongs to lives in the users.subscription_id column and is
    # managed by SubscriptionsManager; it is intentionally not a User field here
    # (mirrors apple_sub/google_sub, which are columns but not schema fields).

    @field_validator("timezone")
    @classmethod
    def _check_timezone(cls, v: str) -> str:
        return _validate_timezone(v)

class Note(BaseModel):
    title: str = Field(default_factory=str)
    user: str = Field(default_factory=str)
    text: str = Field(default_factory=str)
    public: bool = Field(default_factory=bool)
    group_id: str = Field(default_factory=str)
    verses: list = Field(
        default_factory=list,
        description="list of [book, chapter, verse] references")
    replies: list[str] = Field(
        default_factory=list, 
        description="list of note IDs that were sent as replies to a " \
        "note")
    is_reply: bool = Field(default=False)
    timestamp: str = Field(default_factory=lambda: str(datetime.now()))

class SignUp(BaseModel):
    user_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    username: str = Field(default_factory=str)
    email: str = Field(default_factory=str)
    plain_pass: str = Field(default_factory=str)

class Login(BaseModel):
    username: str = Field(default_factory=str)
    plain_pass: str = Field(default_factory=str)

class UpdateUser(BaseModel):
    username: str | None = None
    email: str | None = None
    plain_pass: str | None = None
    timezone: str | None = None

    @field_validator("timezone")
    @classmethod
    def _check_timezone(cls, v: str | None) -> str | None:
        return _validate_timezone(v) if v is not None else v