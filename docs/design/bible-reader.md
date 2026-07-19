# Bible Reader

The Bible Reader (`/reader`) is the core screen of FellowScript. It uses a three-panel layout: navigation sidebar (left), scripture text (centre), and a toggleable notes or messaging sidebar (right).

---

## Layout

```
┌──────────────┬──────────────────────────┬─────────────────────┐
│   AppNav     │                          │                     │
│              │   [Book / Chapter nav]   │   NotesSidebar      │
│  • Home      │                          │   or               │
│  • Reader    │   2 Timothy              │   MessagingSidebar  │
│  • Account   │   CHAPTER 1              │                     │
│              │                          │   (toggled by icons │
│              │   1 Paul, an apostle…    │    above the panel) │
│              │   3 I thank God…         │                     │
│              │   6 [highlighted] For    │                     │
│              │     this reason…         │                     │
│              │                          │                     │
└──────────────┴──────────────────────────┴─────────────────────┘
```

On narrow screens, `AppNav` and the right sidebar collapse; toggle buttons appear above the scripture text.

---

## Features

### Book / Chapter Navigation
- `BibleNavigator` component: searchable book list → chapter grid
- `ScriptureNav`: previous/next chapter arrows
- `BookmarkButton`: star icon to bookmark the current chapter; bookmarks appear in the Notes sidebar's Highlights tab area

### Highlight Palette
- `HighlightPicker`: six swatches (warm gold, red, green, teal, purple, cream)
- Tap/click a verse to apply the active color; click again to remove
- Highlights are stored per `(user_id, book-chapter-verse)` key; group members' highlights are visible with a different opacity in group view

### Scripture Text
- Rendered verse-by-verse via `BibleCard` components
- Verse numbers displayed inline in a muted gold
- Active highlights overlay the verse text with the stored color at ~25% opacity
- Clicking a highlighted verse opens the highlight picker to remove or recolor

### Right Panel Toggle
Two icons above the right panel switch between:
- **Notes** (`NotesSidebar`) — personal or group notes + highlights
- **Messages** (`MessagingSidebar`) — real-time group chat and DMs

---

## Navigation

- Logo / "FellowScript" in `AppNav` → `/` (home)
- Account icon → `/account`
- Book/chapter changes stay within `/reader`
