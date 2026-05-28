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
    """Load all user records from the JSON data store.

    Returns:
        dict: Mapping of user_id -> user data dict. Returns an empty dict
            if the file does not exist or contains invalid JSON.
    """
    path = os.path.join(main_path, user_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def load_notes() -> dict:
    """Load all notes from the JSON data store.

    Returns:
        dict: Mapping of note_id -> note data dict. Returns an empty dict
            if the file does not exist or contains invalid JSON.
    """
    path = os.path.join(main_path, notes_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def save_users(users: dict) -> None:
    """Persist all user records to the JSON data store.

    Args:
        users: Mapping of user_id -> user data dict to write.
    """
    with open(os.path.join(main_path, user_path), "w") as f:
        json.dump(users, f, indent=2)


def save_notes(notes: dict) -> None:
    """Persist all notes to the JSON data store.

    Args:
        notes: Mapping of note_id -> note data dict to write.
    """
    with open(os.path.join(main_path, notes_path), 'w') as f:
        json.dump(notes, f, indent=2)


def fetch_user(user_id: str) -> dict:
    """Look up a single user and return both the User model and the full store.

    Args:
        user_id: UUID of the user to look up.

    Returns:
        dict: On success, ``{"success": User, "users": dict}`` where ``users``
            is the full user mapping needed for subsequent writes. On failure,
            ``{"error": str}``.
    """
    users = load_users()
    data = users.get(user_id)
    if not data:
        return {"error": "cannot find user"}
    return {"success": User(**data), "users": users}


# ── Highlights ────────────────────────────────────────────────────────────────

@notes_router.get("/highlight/{user_id}")
async def get_highlights(user_id: str) -> dict:
    """Return all verse highlights for a user.

    Args:
        user_id: UUID of the user whose highlights to retrieve.

    Returns:
        dict: Mapping of ``"Book-chapter-verse"`` keys to hex color strings.

    Raises:
        HTTPException 404: If the user does not exist.
    """
    result = fetch_user(user_id)
    if "success" not in result:
        raise HTTPException(status_code=404, detail="User not found")
    return result["success"].highlights


@notes_router.post("/highlight/{user_id}")
async def highlight_verse(user_id: str, verse: dict) -> dict:
    """Add or update a highlight color on a specific verse.

    Args:
        user_id: UUID of the user creating the highlight.
        verse: Payload with keys ``book`` (str), ``chapter`` (int|str),
            ``verse`` (int|str), and ``color`` (hex str).

    Returns:
        dict: ``{"key": str, "color": str}`` confirming the stored key and color.

    Raises:
        HTTPException 400: If any of book, chapter, verse, or color is missing.
        HTTPException 404: If the user does not exist.
    """
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
async def remove_highlight(user_id: str, key: str) -> dict:
    """Remove a highlight from a verse.

    Args:
        user_id: UUID of the user whose highlight to remove.
        key: The highlight key in ``"Book-chapter-verse"`` format.

    Returns:
        dict: ``{"success": "highlight removed"}``.

    Raises:
        HTTPException 404: If the user does not exist.
    """
    result = fetch_user(user_id)
    if "success" not in result:
        raise HTTPException(status_code=404, detail="User not found")
    user: User = result["success"]
    user.highlights.pop(key, None)
    result["users"][user_id] = user.model_dump(exclude={"user_id"})
    save_users(result["users"])
    return {"success": "highlight removed"}


# ── Notes ─────────────────────────────────────────────────────────────────────

@notes_router.post("/{user_id}", status_code=201)
async def create_note(user_id: str, note_dict: dict) -> dict:
    """Create a new study note for a user.

    Generates a UUID for the note and writes it to the data store.

    Args:
        user_id: UUID of the note author; injected into the note if not
            already present in ``note_dict``.
        note_dict: Raw note payload matching the ``Note`` schema fields.

    Returns:
        dict: ``{"id": str, "data": dict}`` with the new note's ID and full data.
    """
    notes = load_notes()
    note_id = str(uuid.uuid4())
    note_dict.setdefault("user", user_id)
    note = Note(**note_dict)
    notes[note_id] = note.model_dump()
    save_notes(notes)
    return {"id": note_id, "data": note.model_dump()}


@notes_router.post("/reply/{note_id}", status_code=201)
async def post_reply(note_id: str, reply: dict) -> dict:
    """Attach a reply note to an existing note.

    Creates a new Note record for the reply, assigns it a UUID, and appends
    that UUID to the parent note's ``replies`` list.

    Args:
        note_id: ID of the parent note to reply to.
        reply: Raw note payload for the reply, matching the ``Note`` schema.

    Returns:
        dict: ``{"id": str}`` with the reply note's new ID, or
            ``{"error": str}`` if the parent note is not found.
    """
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
async def get_notes(user_id: str) -> dict:
    """Retrieve all top-level notes authored by a user.

    Excludes reply notes (``is_reply == True``).

    Args:
        user_id: UUID of the user whose notes to retrieve.

    Returns:
        dict: Mapping of note_id -> note data dict for all matching notes.
    """
    notes = load_notes()
    result = {}
    for note_id, data in notes.items():
        note = Note(**data)
        if note.user == user_id and not note.is_reply:
            result[note_id] = data
    return result


@notes_router.put("/{user_id}")
async def update_note(user_id: str, note_id: str, note_dict: dict) -> None:
    """Replace the content of an existing note.

    Args:
        user_id: UUID of the user making the update; must match the note owner.
        note_id: ID of the note to update (passed as a query parameter).
        note_dict: Complete replacement note payload.

    Raises:
        HTTPException 404: If the note does not exist.
        HTTPException 403: If the user does not own the note.
    """
    notes = load_notes()
    if note_id not in notes:
        raise HTTPException(status_code=404, detail="Note not found")
    if notes[note_id].get("user") != user_id:
        raise HTTPException(status_code=403, detail="Not authorized")
    notes[note_id] = note_dict
    save_notes(notes)


@notes_router.delete("/{user_id}")
async def delete_note(user_id: str, note_id: str) -> dict:
    """Permanently delete a note.

    Args:
        user_id: UUID of the user making the request; must match the note owner.
        note_id: ID of the note to delete (passed as a query parameter).

    Returns:
        dict: ``{"success": "note deleted"}``.

    Raises:
        HTTPException 404: If the note does not exist.
        HTTPException 403: If the user does not own the note.
    """
    notes = load_notes()
    if note_id not in notes:
        raise HTTPException(status_code=404, detail="Note not found")
    if notes[note_id].get("user") != user_id:
        raise HTTPException(status_code=403, detail="Not authorized")
    del notes[note_id]
    save_notes(notes)
    return {"success": "note deleted"}
