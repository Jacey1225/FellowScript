# System Architecture Overview

FellowScript is structured as a client-server application with a Python backend, a web frontend, and real-time messaging over WebSockets.

---

## Folder Structure

```
FellowScript/
├── frontend/               # UI — HTML/CSS/JS (or framework TBD)
├── backend/
│   ├── bibleHandling/
│   │   ├── convertDict.py  # Converts Bible source data into a usable dict structure
│   │   ├── interactions.py # Highlight, note, and annotation logic
│   │   └── navigation.py   # Book/chapter navigation and lookup
│   └── messaging/
│       └── websockets.py   # Real-time group chat and activity broadcast
├── api/                    # API route definitions
├── data/
│   ├── ESV Bible.pdf       # ESV Bible source
│   └── NIV-Bible.pdf       # NIV Bible source
├── docs/                   # This documentation (MkDocs)
├── mkdocs.yml
└── README.md
```

---

## Data Flow

```
User Action (frontend)
        │
        ▼
   REST API (api/)
        │
        ├──▶ bibleHandling/navigation.py   → fetch book/chapter text
        ├──▶ bibleHandling/interactions.py → save/load highlights & notes
        └──▶ messaging/websockets.py       → broadcast activity & chat
        │
        ▼
   Response to frontend
```

---

## Key Modules

| Module | Responsibility |
|---|---|
| `bibleHandling/convertDict.py` | Parses Bible PDFs into a structured dictionary keyed by book → chapter → verse |
| `bibleHandling/navigation.py` | Handles book/chapter lookup and returns verse-level text |
| `bibleHandling/interactions.py` | Manages highlights (color, user, verse) and notes (text, visibility, author) |
| `messaging/websockets.py` | WebSocket server for real-time group chat and member activity updates |
| `api/` | REST endpoints consumed by the frontend |
| `frontend/` | Renders the UI — home page, Bible reader, notes, community tabs |

---

## Communication

- **REST** — Used for fetching Bible text, loading notes/highlights, and saving new ones
- **WebSocket** — Used for real-time group chat messages and live member activity status
