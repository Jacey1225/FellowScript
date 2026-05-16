from pydantic import BaseModel, Field
import uuid

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
    notes: dict[str, dict] = Field(default_factory=dict, description="note_id: Note")

class Note(BaseModel):
    title: str = Field(default_factory=str)
    user: str = Field(default_factory=str)
    text: str = Field(default_factory=str)
    public: bool = Field(default_factory=bool)
    group_id: str = Field(default_factory=str)
    verses: tuple[tuple, tuple] = Field(
        description="(book_start, chapter_start, verse_start), "
        "(book_end, chapter_end, verse_end)")
    replies: list[str] = Field(
        default_factory=list, 
        description="list of note IDs that were sent as replies to a " \
        "note")
    is_reply: bool = Field(default=False)

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