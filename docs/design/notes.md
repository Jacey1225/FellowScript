# Notes

The Notes sidebar (`NotesSidebar`) appears in the right panel of the Reader. It has two tabs — Notes and Highlights — and a full rich-text editor for creating and editing notes.

---

## Notes Tab

Displays all personal notes (or group public notes when a group is selected). Notes are always sorted by **creation date, newest first**.

Each note card shows:
- **Title** — Lora serif, bold
- **Public badge** — gold tag if the note is shared with the group
- **Verse references** — clickable tags (`Genesis 1:1`) that navigate the reader to that verse
- **Body preview** — up to 3 lines of plain text (HTML stripped)
- **Creation date** — small, right-aligned, muted label: "Today", "Yesterday", "Jul 16", or "Jul 16, 2025" for older years

```
┌────────────────────────────────┐
│ Fan into Flame         [✏] [🗑]│
│ 2 Tim 1:6                      │
│ This is active. The gift of    │
│ God is already in you, waiting │
│ to be stirred up…              │
│                       Jul 19   │
└────────────────────────────────┘
```

---

## Highlights Tab

Lists all verse highlights for the user (or group, if a group is selected) as clickable rows, sorted by book → chapter → verse. Clicking a row navigates the reader to that verse.

Group view shows a colored dot and the username of each member's highlight.

---

## Group Selector

A compact dropdown on the right side of the tab bar switches between **Personal** (your own notes) and any study groups you belong to. In group view, all members' public notes appear.

---

## Filter & Sort Panel

The filter icon (top-right of the Notes header) opens a panel with:
- **Sort by date** — Newest first / Oldest first
- **Filter by** — Book, Title, Date, or User (group view only)

---

## Note Editor

Opening a note or tapping **New** replaces the sidebar with a full editor:

### Header bar
- Cancel button (left)
- Public toggle (centre) — switch to share the note with the current group
- Save button (right)

### Verse bar
Linked verse tags with a `×` to remove; a `+` button opens `VerseSelector` to add more.

### Formatting toolbar
Bold · Italic · Underline · Highlight (`<mark>`) · Text color (six swatches)

All formatting uses `execCommand` on a `contentEditable` div. The toolbar buttons light up gold when the cursor is inside the corresponding format.

### Writing area
- Title: auto-resizing `<textarea>`, large Playfair Display
- Body: `contentEditable` div with placeholder "Start writing…"

---

## Note Detail

Tapping a note card opens a detail view showing the full rich-text body (`NoteBody` renderer), linked verse tags, and — in group view — a reply thread with a reply input.

---

## Creation Date Storage

`created_at` is set at INSERT time and never modified on edits. `timestamp` is bumped on every edit. The frontend sorts by `created_at` (falling back to `timestamp` for legacy notes) and displays `created_at` as the date label on each card.
