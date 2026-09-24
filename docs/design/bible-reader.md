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

### Chapter Navigation (iOS, tasks `20260923-bible-tap-chapter-nav` / `20260923-bible-tap-nav-not-working` / `20260924-bible-verse-tap-select-removal`)

`BibleReaderView` (`FellowScript/FellowScript/Bible/BibleReaderView.swift`) navigates
chapters by tap, not swipe: tapping the right ~30% of the reading area
advances to the next chapter, tapping the left ~30% goes back, both via the
existing `changeChapter(forward:)` helper (same `.easeInOut` cross-fade,
same book roll-over at chapter/book boundaries as before). The middle ~40%
of the screen is a neutral band with no chapter-change behavior.

The tap detection (`chapterTapGesture`) is attached directly to the verse
`ScrollView` itself via `.gesture(...)`, computing left/right/neutral zone
membership from the tap's own x-coordinate — **not** a `.background()`/
`.overlay()` layer. An earlier version laid the zones down as a
`.background()` of the ScrollView; that never actually received touches at
runtime, because a ScrollView's backing `UIScrollView` claims every touch
within its own frame via UIKit's front-to-back hit-testing before a sibling
view attached *behind* it ever sees them, so the feature shipped totally
non-functional despite passing its own build/regression tests (source-pin
tests confirm wiring exists, not that a tap actually reaches the handler).
`20260923-bible-tap-nav-not-working` fixed this and added a real
render-and-tap UI test (`BibleChapterTapNavigationUITests`) that drives the
Simulator and asserts the chapter actually changes, closing that
verification gap.

A plain single tap now reaches `chapterTapGesture` everywhere in the reading
area, including on a verse row's own rendered text: `VerseRow` no longer
carries an `.onTapGesture`. It originally did (tap toggled verse selection),
and — since SwiftUI gives a descendant view's own gesture priority over an
ancestor's `.gesture(...)` at the same touch point — that tap-to-select
gesture was winning over `chapterTapGesture` anywhere a verse row rendered,
which meant taps inside either zone's horizontal band never changed chapter
wherever text happened to be on screen. `20260924-bible-verse-tap-select-removal`
removed it for exactly that reason, so a tap anywhere in either zone now
reliably changes chapter regardless of whether a verse row is under the
touch. Verse selection is no longer reachable by tap at all: the gold
`isSelected` tint on `VerseRow` is now driven solely by the existing
search-jump-to-verse path (`pendingScrollVerse`), not by manual interaction.
Long-press is unaffected — it still opens `VerseRow`'s `.contextMenu`
(Highlight/Copy/Add to Note/Share) exactly as before, since SwiftUI surfaces
that via its own long-press recognizer, independent of this tap gesture.

Each zone still carries its own accessibility label/hint ("Previous chapter" /
"Next chapter") via non-hit-testable marker views (`chapterTapZoneAccessibilityMarkers`)
that expose themselves to VoiceOver without ever competing for real touches;
the book/chapter dropdown (`BibleNavDropdown`, tap the toolbar pill) remains
the primary VoiceOver-accessible way to jump to any chapter, and long-press
remains the sole way to reach a verse's own actions. The tap gesture is
disabled while the dropdown is open. This replaced a prior horizontal
`DragGesture` swipe as the sole way to change chapters on this screen.

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

### Dictation / Read Aloud (iOS, task `20260914-dictation-tts`)

`BibleReaderView`'s trailing toolbar (`FellowScript/FellowScript/Bible/BibleReaderView.swift`)
carries a `speaker.wave.2` icon button, appended after the font-size and
bookmark buttons, that reads the current chapter's verses aloud using
on-device `AVSpeechSynthesizer` (Enhanced/Premium-quality voice where
installed, falling back gracefully to the next-best installed voice —
never a cloud TTS provider, so no per-character cost and no network call).
Tapping it again mid-speech stops playback (toggle, not a separate stop
control); the icon fills gold and gently pulses (`variableColor` symbol
animation, suppressed under Reduce Motion) while speaking. Playback also
stops automatically on switching chapter or book, navigating away from the
Bible tab, or the app backgrounding. The shared `SpeechController` service
(`FellowScript/FellowScript/Services/SpeechController.swift`) is a single
app-wide singleton, so starting dictation here also stops any in-flight
reading on the Notes screen (see `docs/design/notes.md`) and vice versa.

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
