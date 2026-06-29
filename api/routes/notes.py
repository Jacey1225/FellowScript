from fastapi import APIRouter, HTTPException
from schemas.users import Note
from db import DBManager
import uuid
import logging

notes_router = APIRouter(prefix="/notes")
logger = logging.getLogger(__name__)


# ── Highlights ────────────────────────────────────────────────────────────────
# bookmark and reply routes must be registered before /{user_id} so FastAPI
# does not treat "bookmark" or "reply" as a user_id path segment.

@notes_router.get("/highlight/{user_id}")
async def get_highlights(user_id: str) -> dict:
    db = DBManager()
    try:
        db.cur.execute("SELECT key, color FROM highlights WHERE user_id = %s", (user_id,))
        return {row[0]: row[1] for row in db.cur.fetchall()}
    finally:
        db.close()


@notes_router.post("/highlight/{user_id}")
async def highlight_verse(user_id: str, verse: dict) -> dict:
    book    = verse.get("book")
    chapter = verse.get("chapter")
    verse_n = verse.get("verse")
    color   = verse.get("color")
    if not all([book, chapter, verse_n, color]):
        raise HTTPException(status_code=400, detail="book, chapter, verse, color required")
    key = f"{book}-{chapter}-{verse_n}"
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO highlights (user_id, key, color) VALUES (%s, %s, %s) "
            "ON CONFLICT (user_id, key) DO UPDATE SET color = EXCLUDED.color",
            (user_id, key, str(color))
        )
        db.conn.commit()
        return {"key": key, "color": color}
    finally:
        db.close()


@notes_router.delete("/highlight/{user_id}/{key}")
async def remove_highlight(user_id: str, key: str) -> dict:
    db = DBManager()
    try:
        db.delete("highlights", {"user_id": user_id, "key": key})
        return {"success": "highlight removed"}
    finally:
        db.close()


# ── Bookmarks ─────────────────────────────────────────────────────────────────

@notes_router.get("/bookmark/{user_id}")
async def get_bookmarks(user_id: str) -> dict:
    db = DBManager()
    try:
        db.cur.execute("SELECT key, label FROM bookmarks WHERE user_id = %s", (user_id,))
        return {row[0]: row[1] for row in db.cur.fetchall()}
    finally:
        db.close()


@notes_router.post("/bookmark/{user_id}")
async def add_bookmark(user_id: str, bookmark: dict) -> dict:
    book    = bookmark.get("book")
    chapter = bookmark.get("chapter")
    label   = bookmark.get("label", "")
    if not all([book, chapter]):
        raise HTTPException(status_code=400, detail="book and chapter required")
    key = f"{book}-{chapter}"
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO bookmarks (user_id, key, label) VALUES (%s, %s, %s) "
            "ON CONFLICT (user_id, key) DO UPDATE SET label = EXCLUDED.label",
            (user_id, key, str(label))
        )
        db.conn.commit()
        return {"key": key, "label": label}
    finally:
        db.close()


@notes_router.delete("/bookmark/{user_id}/{key}")
async def remove_bookmark(user_id: str, key: str) -> dict:
    db = DBManager()
    try:
        db.delete("bookmarks", {"user_id": user_id, "key": key})
        return {"success": "bookmark removed"}
    finally:
        db.close()


# ── Notes ─────────────────────────────────────────────────────────────────────

@notes_router.post("/reply/{note_id}", status_code=201)
async def post_reply(note_id: str, reply: dict) -> dict:
    db = DBManager()
    try:
        if not db.lookup("notes", {"_id": note_id}):
            return {"error": "cannot find note"}
        reply_note = Note(**reply)
        reply_id   = str(uuid.uuid4())
        db.cur.execute(
            "INSERT INTO notes (_id, user_id, title, text, public, group_id, is_reply, parent_note_id, timestamp) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)",
            (reply_id, reply_note.user, reply_note.title, reply_note.text,
             reply_note.public, reply_note.group_id or None, True, note_id,
             reply_note.timestamp)
        )
        db.conn.commit()
        return {"id": reply_id}
    finally:
        db.close()


@notes_router.post("/{user_id}", status_code=201)
async def create_note(user_id: str, note_dict: dict) -> dict:
    db = DBManager()
    try:
        note_id = str(uuid.uuid4())
        note_dict.setdefault("user", user_id)
        note = Note(**note_dict)
        db.cur.execute(
            "INSERT INTO notes (_id, user_id, title, text, public, group_id, is_reply, timestamp) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
            (note_id, note.user, note.title, note.text,
             note.public, note.group_id or None, note.is_reply, note.timestamp)
        )
        for i, verse in enumerate(note.verses):
            if isinstance(verse, list) and len(verse) >= 3:
                db.cur.execute(
                    "INSERT INTO note_verses (note_id, position, book, chapter, verse) VALUES (%s,%s,%s,%s,%s)",
                    (note_id, i, verse[0], verse[1], verse[2])
                )
        db.conn.commit()
        return {"id": note_id, "data": note.model_dump()}
    finally:
        db.close()


@notes_router.get("/{user_id}")
async def get_notes(user_id: str) -> dict:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT n._id, n.user_id, n.title, n.text, n.public, n.group_id, n.is_reply, n.timestamp, "
            "COALESCE(array_agg(ARRAY[nv.book, nv.chapter::text, nv.verse::text] ORDER BY nv.position) "
            "FILTER (WHERE nv.note_id IS NOT NULL), '{}') AS verses "
            "FROM notes n LEFT JOIN note_verses nv ON n._id = nv.note_id "
            "WHERE n.user_id = %s AND n.is_reply = false "
            "GROUP BY n._id",
            (user_id,)
        )
        result = {}
        for row in db.cur.fetchall():
            result[str(row[0])] = {
                "user":      str(row[1] or ""),
                "title":     row[2],
                "text":      row[3],
                "public":    row[4],
                "group_id":  row[5] or "",
                "is_reply":  row[6],
                "timestamp": str(row[7] or ""),
                "verses":    list(row[8]) if row[8] else [],
                "replies":   [],
            }
        return result
    finally:
        db.close()


@notes_router.put("/{user_id}")
async def update_note(user_id: str, note_id: str, note_dict: dict) -> None:
    db = DBManager()
    try:
        existing = db.lookup("notes", {"_id": note_id})
        if not existing:
            raise HTTPException(status_code=404, detail="Note not found")
        _, note_data = list(existing.items())[0]
        if str(note_data.get("user_id")) != user_id:
            raise HTTPException(status_code=403, detail="Not authorized")
        note = Note(**note_dict)
        db.cur.execute(
            "UPDATE notes SET title=%s, text=%s, public=%s, group_id=%s WHERE _id=%s",
            (note.title, note.text, note.public, note.group_id or None, note_id)
        )
        db.conn.commit()
    finally:
        db.close()


@notes_router.delete("/{user_id}")
async def delete_note(user_id: str, note_id: str) -> dict:
    db = DBManager()
    try:
        existing = db.lookup("notes", {"_id": note_id})
        if not existing:
            raise HTTPException(status_code=404, detail="Note not found")
        _, note_data = list(existing.items())[0]
        if str(note_data.get("user_id")) != user_id:
            raise HTTPException(status_code=403, detail="Not authorized")
        db.delete("notes", {"_id": note_id})
        return {"success": "note deleted"}
    finally:
        db.close()
