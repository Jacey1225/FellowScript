from pydantic import BaseModel, Field, field_validator
import uuid
from datetime import datetime
from typing import Optional
from zoneinfo import available_timezones


def _validate_timezone(value: str) -> str:
    if value not in available_timezones():
        raise ValueError(f"Unknown IANA timezone: {value!r}")
    return value


# Bump whenever Terms.jsx changes materially (e.g. the zero-tolerance rewrite
# this version represents). A version mismatch on login triggers a soft
# re-consent gate (see main.py's login()) rather than silently grandfathering
# accounts into terms they never agreed to.
CURRENT_TERMS_VERSION = "2026-07-27"


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
    terms_accepted_at: str | None = Field(
        default=None,
        description="Server-stamped timestamp of EULA acceptance — never client-supplied")
    terms_version: str | None = Field(
        default=None,
        description="Which CURRENT_TERMS_VERSION was accepted; a mismatch forces re-consent")
    needs_profile_completion: bool = Field(
        default=False,
        description="True when an Apple-created account is missing the username/email "
                     "Apple only ever supplies once (first authorization) — the client "
                     "should prompt the user to set them, since Apple can never resupply "
                     "them later")
    # The plan a user belongs to lives in the users.subscription_id column and is
    # managed by SubscriptionsManager; it is intentionally not a User field here
    # (mirrors apple_sub/google_sub, which are columns but not schema fields).

    @field_validator("terms_accepted_at", mode="before")
    @classmethod
    def _stringify_terms_accepted_at(cls, v):
        # FriendsManager/GroupsManager construct User(**data) straight from
        # DBManager.lookup()'s raw row, which returns a native datetime for
        # TIMESTAMPTZ columns — unlike load_users_data(), which already
        # stringifies it. Coerce here so both call shapes work.
        return str(v) if v is not None else v
    # suspended_at is likewise a column, not a User field — set only by the
    # moderation eject action, mirroring mfa_enabled's exclusion from this model.

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
    theme: str = Field(
        default_factory=str,
        description="short phrase naming the note's central theme; only "
                     "populated for heartbeat-generated notes (note_via_hb), "
                     "which feed it back into that heartbeat's future "
                     "CHAPTERS/VERSES/THEME context -- manually-created notes "
                     "leave this blank")
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
    # validate_default=True is required here: pydantic v2 does NOT run
    # validators on a field's default value unless told to, and the default
    # (False) is exactly the invalid case this validator exists to catch — an
    # omitted field would otherwise silently pass as an unvalidated default.
    terms_accepted: bool = Field(default=False, validate_default=True)

    @field_validator("terms_accepted")
    @classmethod
    def _must_accept_terms(cls, v: bool) -> bool:
        if not v:
            raise ValueError("You must accept the Terms of Service to create an account.")
        return v

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