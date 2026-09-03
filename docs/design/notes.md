# Notes

The Notes panel (`NotesPanel`, docked in the Reader) has two tabs — Notes and Highlights — and a full rich-text editor for creating and editing notes.

> **`public` is an edit-permission flag, not a visibility flag (as of 2026-09, task `20260903-notes-public-repurpose`).** Visibility is `group_id`-only: an empty/null `group_id` means the note is private to its owner; a set `group_id` means it's visible to every member of that group, regardless of `public`. `public` now controls whether other members of the note's group may *edit* it (deny-by-default — `False`, the column's existing default, means owner-only edit). The note's own owner can always edit/delete it; delete stays owner-only for everyone else, even when `public` is `True`.

---

## Notes Tab

Displays all personal notes (or every group member's notes when a group is selected — display is `group_id`-only, no longer re-filtered by `public`). Notes are always sorted by **creation date, newest first**.

Each note card shows:
- **Title** — Lora serif, bold
- **Editable badge** — gold "Editable" tag, group notes only, shown when `public` is `True` (i.e. other group members may edit this note) — not a visibility indicator (web; see the iOS presentation note below for the iOS treatment, which differs)
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

### iOS presentation (`NoteRow` in `NotesListView.swift`)

The iOS notes list row (`FellowScript/FellowScript/Notes/NotesListView.swift`,
`NoteRow`) shows per-note author identity and edit-permission state
differently from the web `NoteCard` above:

- **Author chip** — for a note in a group segment whose author username was
  successfully captured, the top-right trailing slot shows a small gold
  initials-circle + username label (reusing the app's existing avatar/chip
  vocabulary), sourced from `FSNote.username` (stamped on by
  `NetworkService.fetchGroupNotes` from the response's outer per-member
  username key). The chip never renders on Personal-segment notes (always
  the viewer, so it would be redundant), and never renders a placeholder for
  a group note with a missing/uncaptured username — it's simply omitted.
- **Editable-by-group indicator** — a small `pencil.circle.fill` SF Symbol
  sits next to the note's timestamp, shown only for a group note with
  `public == true` (mirroring the web "Editable" badge), with a combined
  VoiceOver label (e.g. "Jul 19, editable by group"). Personal notes never
  show this indicator — there's no other group member who could edit one
  regardless of the flag — and the old always-shown `globe`/`lock.fill`
  visibility cue (and the Private-Only/Public-Only `VisibilityFilter` sort
  menu that went with it) were removed entirely, since visibility no longer
  depends on `public`.
- **Edit/Delete affordances** — in a group segment, swipe-to-delete and the
  context-menu Delete action are shown only for the note's own author
  (`FSNote.username` matches the viewer) — delete stays owner-only. The
  context-menu Edit action, and `NoteDetailView`'s toolbar Edit pill, are
  shown for the author *or* for any group member when the note's `public`
  flag is `true` — mirroring the backend's `update_note` non-owner branch.
  A non-author, non-public group note is read-only to everyone but its
  author. Personal notes are unaffected, since they're always self-authored.

---

## Highlights Tab

Lists all verse highlights for the user (or group, if a group is selected) as clickable rows, sorted by book → chapter → verse. Clicking a row navigates the reader to that verse.

Group view shows a colored dot and the username of each member's highlight.

---

## Group Selector

A compact dropdown on the right side of the tab bar switches between **Personal** (your own notes) and any study groups you belong to. In group view, all members' notes for that group appear — display is `group_id`-only, not filtered by `public`.

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
- "Allow group to edit" toggle (centre) — switch controlling whether other
  members of the current group may edit this note; shown only when the
  editor is open in a group context (a personal note has no other group
  member to grant edit access to). Group attachment itself is separate and
  automatic: opening the editor from a group tab always tags the note with
  that group's id, independent of this toggle.
- Save button (right)

### Verse bar
Linked verse tags with a `×` to remove; a `+` button opens `VerseSelector` to add more.

### Formatting toolbar
Bold · Italic · Underline · Highlight (`<mark>`) · Text color (six swatches)

All formatting uses `execCommand` on a `contentEditable` div. The toolbar buttons light up gold when the cursor is inside the corresponding format.

### Writing area
- Title: auto-resizing `<textarea>`, large Playfair Display
- Body: `contentEditable` div with placeholder "Start writing…"

### Save failure
If the save is rejected — most commonly a 422 from the Guideline 1.2 content filter (`backend/moderation/content_filter.py`) — the editor stays open with the title/body exactly as typed and shows the server's message (a toast on web, an alert on iOS) instead of closing. As of 2026-08, the filter only rejects genuinely explicit content (ordinary profanity is allowed), and the message names the specific flagged word/phrase in a warm, on-brand tone rather than a generic "contains language that isn't allowed" notice, so the user knows exactly what to revise. The editor only dismisses after a save actually succeeds, so a flagged note can be revised and resubmitted without retyping it.

### iOS presentation (`NoteEditorView.swift`)

The iOS editor (`FellowScript/FellowScript/Notes/NoteEditorView.swift`) uses the same
interactions as above, restyled to match the app's warm-bloom / glass-card visual
language shared with the Dashboard and Chat screens. Appearance-only — every
binding, async save flow, and the fragile `Text`/`RichTextEditorView` ZStack
pairing described above are unchanged.

- **Background** — `Theme.bgPage` plus two `RadialGradient` blooms (same values
  as `ChatRootView`), replacing the old flat `Theme.islandBg` fill.
- **Header, verse bar, format toolbar** — no longer sit on opaque strips; they
  float transparently on the bloom. The format toolbar is wrapped in a single
  `glassCard(cornerRadius: 16)` tile.
- **Writing area** — the Title + body block is wrapped in one
  `glassCard(cornerRadius: 20)` tile, matching how every other content block in
  the app (note cards, group activity, bookmarks) is glass-carded.
- **"+ Verse"** — a solid filled pill (`Theme.gold` fill/stroke) instead of the
  old dashed outline; the `VerseTag` capsule's border uses the same glass
  hairline gradient as `glassCard()` instead of a flat gold stroke.
- **Header controls** — Cancel is a 36×36pt ghost icon chip (`xmark`); the
  edit-permission control is an icon-badge pill (`pencil`/`lock` +
  "Group Can Edit"/"Owner Only") that flips state on tap, shown only for a
  note that has a group (mirrors the web toggle's same group-context gate);
  Save is relocated out of the header to a 48×48pt gradient circular FAB
  pinned bottom-right, floating above the writing card. It shows a
  `checkmark` icon, swaps to a spinner while saving, and is disabled while
  saving — identical state logic to before, just repositioned.
- **Read-only mode** — still hides the edit-permission badge, Save FAB,
  "+ Verse", and toolbar; a small top-trailing `checkmark` icon chip ("Done")
  replaces the old text button in the position where Save would otherwise
  be, and still dismisses the editor.

---

## Note Detail

Tapping a note card opens a detail view showing the full rich-text body (`NoteBody` renderer), linked verse tags, and — in group view — a reply thread with a reply input.

### iOS presentation (`NoteDetailView` in `NotesListView.swift`)

The iOS read-only note viewer (`FellowScript/FellowScript/Notes/NotesListView.swift`,
`NoteDetailView`) ships **Direction B — "Elevated CTA, lighter chrome"** of the
restyle explored in `.claude/pipeline/20260813-note-viewer-mockups/design-notes.md`.
Appearance-only, like the `NoteEditorView` restyle above — `Close`'s `dismiss()`,
`Edit`'s nested `NoteEditorView` sheet wiring (same `onSave` closure, same
`.presentationDetents([.large])` / `.presentationCompactAdaptation(.fullScreenCover)`
pair fixing the sheet-nesting regression from `20260810-note-editor-save-cancel-overlap-v2`),
and the `note.title` / `note.formattedTimestamp` / `note.text` data flow are all
unchanged.

- **Background** — the same `Theme.bgPage` plus two `RadialGradient` blooms
  used by `ChatRootView`/`NoteEditorView`, replacing the old flat fill.
- **Body** — deliberately **not** wrapped in a `glassCard` (unlike
  `NoteEditorView`'s writing area): this is read-only content, and skipping
  the card keeps a long note's reading column full width.
- **Close** — a `ghostPill` (text-only outline capsule, secondary weight),
  nav-bar leading, replacing the old plain `Button("Close")`.
- **Edit** — a `gradientPill` (solid gold-gradient capsule CTA, primary
  weight), nav-bar trailing, replacing the old plain `Button("Edit")`. The
  asymmetric Close/Edit pill weighting mirrors `AccountView`'s CTA hierarchy
  and signals Edit as the primary action from this screen.
- **Date** — rendered through the shared `sectionLabel()` eyebrow treatment
  (tracked, uppercase, muted gold) instead of a plain caption; still hidden
  entirely when `note.formattedTimestamp` is empty.
- **Divider** — a 1pt `Theme.goldGradient` rule in place of the old plain
  `Divider()`, same position/role.

---

## AI-Generated Note Edit Permission (Scheduled Events)

Scheduled agent "heartbeat" events (`AgentHeartbeats`, configured via iOS's
`EventSetupSheet`) can be tied to a group, so the note the agent generates on
fire inherits that group's `group_id`. A dedicated "EDIT PERMISSION" toggle
on the event's Details screen — shown only once a group is selected, mirroring
`NoteEditorView`'s own group-gated control — sets a deny-by-default
`notes_public` field on the heartbeat (`agent_heartbeats.notes_public`,
default `False`). This is stored explicitly at configuration time rather than
inferred from the agent's per-fire response: it's threaded through to every
note that heartbeat generates, controlling whether other group members may
edit that AI-authored note (never whether it's visible — visibility is still
`group_id`-only, same as any other note).

---

## Creation Date Storage

`created_at` is set at INSERT time and never modified on edits. `timestamp` is bumped on every edit. The frontend sorts by `created_at` (falling back to `timestamp` for legacy notes) and displays `created_at` as the date label on each card.
