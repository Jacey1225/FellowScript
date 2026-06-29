from pydantic import BaseModel, Field
import uuid
from datetime import datetime

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