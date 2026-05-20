import os
import json
from fastapi import APIRouter, HTTPException
from schemas.users import User, Note
import uuid
import logging

notes_router = APIRouter(prefix="/notes")
main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
user_path = "data/users.json"
notes_path = "data/notes.json"
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

def load_notes():
    path = os.path.join(main_path, notes_path)
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

def save_notes(notes: dict):
    with open(os.path.join(main_path, notes_path), 'w') as f:
        json.dump(notes, f, indent=2)

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

# -- Notes -----------------------------------------------------------


@notes_router.post("/{user_id}", status_code=201)
async def create_note(user_id: str, note_dict: dict):
    notes = load_notes()
    note_id = str(uuid.uuid4())
    note_dict.setdefault("user", user_id)
    note = Note(**note_dict)
    notes[note_id] = note.model_dump()
    save_notes(notes)
    return {"id": note_id, "data": note.model_dump()}

@notes_router.post("/reply/{note_id}", status_code=201)
async def post_reply(note_id: str, reply: dict):
    notes = load_notes()
    note_to_reply = notes.get(note_id)
    if not note_to_reply:
        return {"error": "cannot find note"}

    reply_note = Note(**reply)
    reply_id = str(uuid.uuid4())
    note_to_reply["replies"].append(reply_id)
    notes[note_id] = note_to_reply
    notes[reply_id] = reply_note.model_dump()
    save_notes(notes)
    return {"id": reply_id}
    
@notes_router.get("/{user_id}")
async def get_notes(user_id: str):
    notes = load_notes()
    result = {}
    for note_id, data in notes.items():
        note = Note(**data)
        if note.user == user_id and not note.is_reply:
            result[note_id] = data
    return result


@notes_router.put("/{user_id}")
async def update_note(user_id: str, note_id: str, note_dict: dict):
    notes = load_notes()
    if note_id not in notes:
        raise HTTPException(status_code=404, detail="Note not found")
    if notes[note_id].get("user") != user_id:
        raise HTTPException(status_code=403, detail="Not authorized")
    notes[note_id] = note_dict
    save_notes(notes)


@notes_router.delete("/{user_id}")
async def delete_note(user_id: str, note_id: str):
    notes = load_notes()
    if note_id not in notes:
        raise HTTPException(status_code=404, detail="Note not found")
    if notes[note_id].get("user") != user_id:
        raise HTTPException(status_code=403, detail="Not authorized")
    del notes[note_id]
    save_notes(notes)
    return {"success": "note deleted"}