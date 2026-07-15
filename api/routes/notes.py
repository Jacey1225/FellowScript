from fastapi import APIRouter, HTTPException
from schemas.users import Note
from db import DBManager
from datetime import datetime
import uuid
import logging

notes_router = APIRouter(prefix="/notes")
logger = logging.getLogger(__name__)


# ── Highlights ────────────────────────────────────────────────────────────────

@notes_router.get("/highlight/{user_id}")
async def get_highlights(user_id: str) -> dict:
    db = DBManager()
    try:
        # highlights has a composite PK (user_id, key) with no _id column,
        # so lookup() would collapse all rows; use cursor for the read only.
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
        db.insertion(
            "highlights",
            {"user_id": user_id, "key": key, "color": str(color)},
            conflict="(user_id, key) DO UPDATE SET color = EXCLUDED.color",
        )
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
        # bookmarks has a composite PK (user_id, key) with no _id column.
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
        db.insertion(
            "bookmarks",
            {"user_id": user_id, "key": key, "label": str(label)},
            conflict="(user_id, key) DO UPDATE SET label = EXCLUDED.label",
        )
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
        db.insertion("notes", {
            "_id":            reply_id,
            "user_id":        reply_note.user,
            "title":          reply_note.title,
            "text":           reply_note.text,
            "public":         reply_note.public,
            "group_id":       reply_note.group_id or None,
            "is_reply":       True,
            "parent_note_id": note_id,
            "timestamp":      reply_note.timestamp,
        })
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
        db.insertion("notes", {
            "_id":       note_id,
            "user_id":   note.user,
            "title":     note.title,
            "text":      note.text,
            "public":    note.public,
            "group_id":  note.group_id or None,
            "is_reply":  note.is_reply,
            "timestamp": note.timestamp,
        })
        for i, verse in enumerate(note.verses):
            if isinstance(verse, list) and len(verse) >= 3:
                db.insertion("note_verses", {
                    "note_id":  note_id,
                    "position": i,
                    "book":     verse[0],
                    "chapter":  verse[1],
                    "verse":    verse[2],
                })
        return {"id": note_id, "data": note.model_dump()}
    finally:
        db.close()


@notes_router.get("/{user_id}")
async def get_notes(user_id: str) -> dict:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT n._id, n.user_id, n.title, n.text, n.public, n.group_id, n.is_reply, n.timestamp "
            "FROM notes n "
            "WHERE n.user_id = %s AND n.is_reply = false AND n.group_id IS NULL",
            (user_id,)
        )
        rows = db.cur.fetchall()
        result = {}
        for row in rows:
            nid = str(row[0])
            db.cur.execute(
                "SELECT position, book, chapter::text, verse::text "
                "FROM note_verses WHERE note_id = %s ORDER BY position",
                (nid,)
            )
            verses = [[r[1], r[2], r[3]] for r in db.cur.fetchall()]
            result[nid] = {
                "user":      str(row[1] or ""),
                "title":     row[2],
                "text":      row[3],
                "public":    row[4],
                "group_id":  row[5] or "",
                "is_reply":  row[6],
                "timestamp": str(row[7] or ""),
                "verses":    verses,
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
        db.update(
            "notes",
            {
                "title":     note.title,
                "text":      note.text,
                "public":    note.public,
                "group_id":  note.group_id or None,
                "timestamp": datetime.now(),   # bump so lists can sort by last-edited
            },
            {"_id": note_id},
        )
        # Sync note_verses: replace all existing verse rows with the ones from the PUT body.
        db.delete("note_verses", {"note_id": note_id})
        for i, verse in enumerate(note.verses):
            if isinstance(verse, list) and len(verse) >= 3:
                db.insertion("note_verses", {
                    "note_id":  note_id,
                    "position": i,
                    "book":     verse[0],
                    "chapter":  verse[1],
                    "verse":    verse[2],
                })
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
