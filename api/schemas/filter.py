from pydantic import BaseModel, Field
from typing import Optional 

class Sort(BaseModel):
    date: Optional[bool]
    alpha: bool
    num_replies: bool

class Filter(BaseModel):
    users: Optional[list]
    date: Optional[str]
    book: Optional[str]
    title: Optional[str]