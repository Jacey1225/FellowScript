# Data

FellowScript's data layer handles two things: Bible source content and user-generated content (highlights, notes, messages).

---

## Bible Source

Raw Bible text is stored as PDFs in `data/`:

| File | Translation |
|---|---|
| `ESV Bible.pdf` | English Standard Version |
| `NIV-Bible.pdf` | New International Version |

`backend/bibleHandling/convertDict.py` parses these into a nested dictionary structure at runtime:

```
Bible Dict
└── Book (e.g. "2 Timothy")
    └── Chapter (int, e.g. 1)
        └── Verse (int, e.g. 6) → text (str)
```

---

## User Data

### Highlights

Each highlight record stores:

| Field | Type | Description |
|---|---|---|
| `user_id` | string | The user who created the highlight |
| `book` | string | Bible book name |
| `chapter` | int | Chapter number |
| `verse` | int | Verse number |
| `color` | string | `yellow`, `orange`, `green`, `pink`, or `blue` |
| `visibility` | string | `public` or `private` |

---

### Notes

Each note record stores:

| Field | Type | Description |
|---|---|---|
| `user_id` | string | The author |
| `book` | string | Bible book name |
| `chapter` | int | Chapter number |
| `verse` | int | Verse number |
| `text` | string | Note content |
| `visibility` | string | `public` or `private` |
| `created_at` | datetime | Timestamp |

---

### Messages

Each message record stores:

| Field | Type | Description |
|---|---|---|
| `sender_id` | string | Author |
| `group_id` | string | Study group (null for DMs) |
| `recipient_id` | string | DM target (null for group messages) |
| `text` | string | Message content |
| `sent_at` | datetime | Timestamp |
