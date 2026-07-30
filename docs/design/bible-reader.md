# Bible Reader

The Bible Reader (`/reader`) is the core screen of FellowScript. On desktop it's a **VSCode-style dockable workspace**: five panels — Bible Reading, Notes, Highlights, Messaging, and Agent Chat — that the user can freely drag to any edge (split), drop onto another panel (tab together), or resize. On mobile it keeps a simpler fixed layout: scripture text with a bottom tab bar that opens Notes or Messages as a fullscreen overlay.

---

## Desktop Layout (dockable workspace)

Default arrangement on first visit:

```
┌───────────────────────────────┬───────────────────────────┐
│                               │  Notes | Highlights | Msgs │
│      Bible Reading            │  (tabbed together,        │
│   [Book/Chapter nav · Aa ·    │   full height)             │
│    Bookmark] toolbar          │                            │
│                               │                            │
│   2 Timothy — Chapter 1       │                            │
│   1 Paul, an apostle…         │                            │
│   6 [highlighted] For this…   │                            │
├───────────────────────────────┤                            │
│      Agent Chat               │                            │
│   (docked below the reader    │                            │
│    only — not under Notes)    │                            │
└───────────────────────────────┴───────────────────────────┘
```

Any panel can be dragged to a new position: dropping it on an edge splits the space; dropping it in the center of another panel's tab strip groups them as tabs. A **Reset Layout** button (top right) restores this default arrangement at any time. The user's arrangement persists across visits (saved to `localStorage`); see `docs/architecture/frontend.md` for the implementation.

On narrow screens (≤1024px) this entire dockable system is replaced by a fixed layout: scripture text fills the screen, and a bottom tab bar opens Notes or Messages as a fullscreen overlay — no drag/split/tab behavior on mobile.

---

## Features

### Book / Chapter Navigation
- `BibleNavigator` component: searchable book list → chapter grid, rendered as a floating widget so it's never clipped regardless of which panel it's docked in
- Prev/Next chapter buttons at the bottom of the reading pane
- `BookmarkButton`: star icon to bookmark the current chapter; bookmarks list opens the same way
- Both travel with the Bible Reading panel wherever it's docked — they're part of that panel's own toolbar, not a separate page-level bar

### Highlight Palette
- `HighlightPicker`: six swatches (warm gold, red, green, teal, purple, cream)
- Tap/click a verse to apply the active color; click again to remove
- Highlights are stored per `(user_id, book-chapter-verse)` key; group members' highlights are visible with a different opacity in group view
- The **Highlights** panel (separate from the live highlight picker) lists every highlighted verse and can be dragged/tabbed independently of Notes — it has its own copy of the group-selector dropdown so it's never stranded without a way to change groups

### Scripture Text
- Rendered verse-by-verse via `BibleCard` components
- Verse numbers displayed inline in a muted gold
- Active highlights overlay the verse text with the stored color at ~25% opacity
- Clicking a highlighted verse opens the highlight picker to remove or recolor

### Notes, Messaging, Agent Chat panels
- **Notes** — personal or group notes, with its own group-selector dropdown
- **Messaging** — friends/group DMs (no agents — see below)
- **Agent Chat** — a horizontal switcher across the top (not the vertical list used before) since this panel is usually docked wide-and-short under the reader; split out from Messaging so both can be positioned independently

---

## Navigation

- Logo / "FellowScript" in `AppNav` → `/` (home)
- Account icon → `/account`
- Book/chapter changes stay within `/reader`
