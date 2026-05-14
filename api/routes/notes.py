import os
import json
from fastapi import APIRouter, HTTPException
from schemas.users import User
import uuid
import logging

notes_router = APIRouter(prefix="/notes")
main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
user_path = "data/users.json"
logger = logging.getLogger(__name__)

def load_users() -> dict:
    path = os.path.join(main_path, user_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}

def save_users(users: dict) -> None:
    with open(os.path.join(main_path, user_path), "w") as f:
        json.dump(users, f, indent=2)

def fetch_user(user_id: str) -> dict:
    users = load_users()
    data = users.get(user_id)
    if not data:
        return {"error": "cannot find user"}
    return {"success": User(**data), "users": users}

@notes_router.get("/highlight/{user_id}")
async def get_highlights(user_id: str):
    result = fetch_user(user_id)
    if "success" not in result:
        raise HTTPException(status_code=404, detail="User not found")
    return result["success"].highlights


@notes_router.post("/highlight/{user_id}")
async def highlight_verse(user_id: str, verse: dict):
    result = fetch_user(user_id)
    if "success" not in result:
        raise HTTPException(status_code=404, detail="User not found")
    user: User = result["success"]
    logger.info("user fetch success")
    logger.info(f"received highlight payload: {verse}")

    book    = verse.get("book")
    chapter = verse.get("chapter")
    verse_n = verse.get("verse")
    color   = verse.get("color")

    logger.info(f"book={book!r}  chapter={chapter!r}  verse={verse_n!r}  color={color!r}")

    if not all([book, chapter, verse_n, color]):
        logger.info("a value in info dict is missing")
        raise HTTPException(status_code=400, detail="book, chapter, verse, color required")

    logger.info("found all keys in info dict")
    key = f"{book}-{chapter}-{verse_n}"
    logger.info(f"fetched key: {key} for highlight")
    user.highlights[key] = str(color)
    result["users"][user_id] = user.model_dump(exclude={"user_id"})
    save_users(result["users"])
    return {"key": key, "color": color}


@notes_router.delete("/highlight/{user_id}/{key}")
async def remove_highlight(user_id: str, key: str):
    result = fetch_user(user_id)
    if "success" not in result:
        raise HTTPException(status_code=404, detail="User not found")
    user: User = result["success"]
    user.highlights.pop(key, None)
    result["users"][user_id] = user.model_dump(exclude={"user_id"})
    save_users(result["users"])
    return {"success": "highlight removed"}


@notes_router.post("/{user_id}", status_code=201)
async def create_note(user_id: str, note: dict):
    result = fetch_user(user_id)
    if "success" not in result:
        raise HTTPException(status_code=404, detail="User not found")
    user: User = result["success"]
    note_id = str(uuid.uuid4())
    user.notes[note_id] = {
        "title":  note.get("title", "Note"),
        "text":   note.get("text", ""),
        "public": note.get("public", False),
        "verses": note.get("verses", [[], []]),
    }
    result["users"][user_id] = user.model_dump(exclude={"user_id"})
    save_users(result["users"])
    return {"id": note_id, **user.notes[note_id]}


@notes_router.get("/{user_id}")
async def get_notes(user_id: str):
    result = fetch_user(user_id)
    if "success" not in result:
        raise HTTPException(status_code=404, detail="User not found")
    user: User = result["success"]
    return user.notes


@notes_router.put("/{user_id}")
async def update_note(user_id: str, note: dict):
    result = fetch_user(user_id)
    if "success" not in result:
        raise HTTPException(status_code=404, detail="User not found")
    user: User = result["success"]
    _id = note.get("_id", "")
    if _id not in user.notes:
        raise HTTPException(status_code=404, detail="Note not found")
    existing = user.notes[_id]
    existing["title"]  = note.get("title",  existing.get("title", "Note"))
    existing["text"]   = note.get("text",   existing.get("text", ""))
    existing["public"] = note.get("public", existing.get("public", False))
    existing["verses"] = note.get("verses", existing.get("verses", [[], []]))
    user.notes[_id] = existing
    result["users"][user_id] = user.model_dump(exclude={"user_id"})
    save_users(result["users"])
    return {"id": _id, **existing}


@notes_router.delete("/{user_id}")
async def delete_note(user_id: str, notes: list[str]):
    result = fetch_user(user_id)
    if "success" not in result:
        raise HTTPException(status_code=404, detail="User not found")
    user: User = result["success"]
    for _id in notes:
        user.notes.pop(_id, None)
    result["users"][user_id] = user.model_dump(exclude={"user_id"})
    save_users(result["users"])
    return {"success": "note(s) deleted"}