# API Overview

The `api/` folder defines the REST endpoints that the frontend consumes. All endpoints return JSON.

---

## Bible Endpoints

### `GET /api/bible/books`
Returns a list of all available book names.

**Response:**
```json
["Genesis", "Exodus", ..., "2 Timothy", ..., "Revelation"]
```

---

### `GET /api/bible/{book}/{chapter}`
Returns all verses for a given book and chapter.

**Example:** `GET /api/bible/2 Timothy/1`

**Response:**
```json
{
  "book": "2 Timothy",
  "chapter": 1,
  "verses": {
    "1": "Paul, an apostle of Christ Jesus...",
    "2": "To Timothy, my dear son...",
    "6": "For this reason I remind you to fan into flame..."
  }
}
```

---

## Highlight Endpoints

### `GET /api/highlights/{book}/{chapter}`
Returns all highlights for a chapter. Includes the requesting user's private highlights and all public highlights.

### `POST /api/highlights`
Saves a new highlight.

**Body:**
```json
{
  "book": "2 Timothy",
  "chapter": 1,
  "verse": 6,
  "color": "green",
  "visibility": "public"
}
```

---

## Notes Endpoints

### `GET /api/notes/{book}/{chapter}?filter=all|public|mine`
Returns notes for a chapter, filtered by the `filter` query parameter.

### `POST /api/notes`
Saves a new note.

**Body:**
```json
{
  "book": "2 Timothy",
  "chapter": 1,
  "verse": 6,
  "text": "Fan into flame — this is active. The flame is already there.",
  "visibility": "public"
}
```

---

## Messaging

Real-time messaging (group chat and DMs) is handled via **WebSocket**, not REST. See [Backend — messaging/websockets.py](../architecture/backend.md) for details.
