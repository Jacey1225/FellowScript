# Backend

The backend is written in Python and is split into two domains: Bible data handling and real-time messaging.

---

## `backend/bibleHandling/`

### `convertDict.py`
Responsible for parsing the raw Bible PDF sources (ESV, NIV) in `data/` and converting them into a structured Python dictionary:

```python
# Expected output shape
{
  "2 Timothy": {
    1: {
      1: "Paul, an apostle of Christ Jesus...",
      2: "To Timothy, my dear son...",
      ...
    }
  }
}
```

This dictionary is the single source of truth for all scripture lookups.

---

### `navigation.py`
Handles book and chapter navigation. Given a book name and chapter number, returns the full list of verses for that chapter.

Key responsibilities:
- Validate that a requested book/chapter exists
- Return verse-by-verse text for display in the Bible Reader
- Support search/jump by book name (used by the search bar)

---

### `interactions.py`
Manages all user interactions with scripture text:

**Highlights**
- Save a highlight: `{ user_id, book, chapter, verse, color }`
- Load highlights for a chapter: returns all highlights, filtered by user or visibility

**Notes**
- Save a note: `{ user_id, book, chapter, verse, text, visibility: "public" | "private" }`
- Load notes for a chapter: supports All / Public / Mine filters

---

## `backend/messaging/`

### `websockets.py`
Runs the WebSocket server that powers real-time features:

- **Group chat** — broadcasts messages to all members of a study group
- **Activity status** — when a user highlights, reads, or notes a verse, their status is broadcast to the group so others can see it live (e.g. "James M. is reading verse 7")
- **Direct messages** — routes private messages between two users without broadcasting to the group

---

## Bible Source Data

Located in `data/`:

| File | Translation |
|---|---|
| `ESV Bible.pdf` | English Standard Version |
| `NIV-Bible.pdf` | New International Version |

`convertDict.py` parses these files on startup (or on demand) and caches the result for fast lookups.
