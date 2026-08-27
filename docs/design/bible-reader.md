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

Any panel can be dragged to a new position: dropping it on an edge splits the space; dropping it in the center of another panel's tab strip groups them as tabs. The user's arrangement persists across visits (saved to `localStorage`); see `docs/architecture/frontend.md` for the implementation.

A fixed **left dock rail** (vertical icon column, full height below the nav header) sits to the left of the workspace with one icon per panel type. The currently active panel's icon shows filled/gold; every other panel's icon (closed, or open but backgrounded behind another tab) shows as a 60%-opacity outline. Clicking an icon reveals that panel if it's already open, or reopens it into a sensible default dock position if the user closed it — this is now how a closed panel gets brought back, replacing the old "Reset Layout" button (removed; the underlying reset-to-default capability still exists in code but has no UI trigger anymore).

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

### Left Dock Rail
- `ReaderDockRail` component: fixed vertical icon rail, one icon per dockable panel type (Bible, Notes, Highlights, Messaging, Agent Chat)
- Tracks the live dockview layout (`onDidAddPanel`/`onDidRemovePanel`/`onDidActivePanelChange`) so it always reflects which panels are currently open and which one is active
- Clicking a rail icon activates that panel if it's already open (including a backgrounded tab) or reopens it via `reopenPanel` (`frontend/src/lib/readerDockLayout.js`), which docks it back into the same relative position `buildDefaultLayout` would have used
- Desktop only, same `≤1024px` breakpoint as the rest of the dockable workspace

### Notes, Messaging, Agent Chat panels
- **Notes** — personal or group notes, with its own group-selector dropdown
- **Messaging** — friends/group DMs (no agents — see below)
- **Agent Chat** — a horizontal switcher across the top (not the vertical list used before) since this panel is usually docked wide-and-short under the reader; split out from Messaging so both can be positioned independently

---

## Navigation

- Logo / "FellowScript" in `AppNav` → `/` (home)
- Profile avatar (32px circular, gold ring) in `AppNav`'s top-right → `/account` if signed in, `/signin` otherwise
- Book/chapter changes stay within `/reader`

`AppNav`'s desktop top-right shows only the profile avatar and the light/dark theme toggle — no text nav links, and no command-trigger/"Jump or Ask" overlay (removed; passage jumping is done via the mobile branch's own `BibleNavigator` controls and the desktop dockview BIBLE panel). The mobile hamburger `Drawer` still exposes Home/Read/Account as text menu items, independent of the desktop top-right.
