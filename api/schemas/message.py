from pydantic import BaseModel, Field

class Message(BaseModel):
    from_user: str
    timestamp: str
    to_users: list[str]
    group_id: str | None
    text: str


class Group(BaseModel):
    group_id: str
    title: str
    users: list[str]
