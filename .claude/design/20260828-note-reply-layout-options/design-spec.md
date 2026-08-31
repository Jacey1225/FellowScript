# Design Spec — Note reply-thread layout options, 3-option comparison sheet

Task: `20260828-note-reply-layout-options`
Step 3 — static spec. Source: `intake-brief.md` + `style-brief.md` (both read in full; style brief already carries a fully resolved, internally consistent token set, option matrix, and sample content — no gaps required bouncing back to synthesis). Cross-checked live against source via `codegraph_explore` on `NoteDetailView` (`NotesListView.swift:766-918`) and `Theme.swift` (`WidgetCard`, `goldGradient`) — all cited line numbers and token values in the style brief are confirmed current on disk.

---

## Deliverable

**One comparison sheet image (PNG)**, plus its constituent device-frame captures:

1. **The sheet** — a single composited PNG: a 3-column × 2-row grid of full device frames, captions and rationale/build-cost text under each column, plus one excluded-option note. Exact export size is a generation-stage decision; internal proportions below are fixed.
2. **Six full-device frames**, each **1260 × 2736 px** (matching the two supplied `NoteDetailView`/Notes-list reference screenshots), one per cell: Option A/B/C × {top row: populated/open state, bottom row: option's second state per §"Grid & states" below}.
3. All six frames share one note baseline — the real "Dealing with Failure" note (reference 2), same title/date/body, same status bar, same bloom anchors — and identical sample reply content across every frame that shows replies (see Components → Sample reply content). **Exactly one variable moves per column: reply placement/mechanism.** This is a hard constraint: a comparison sheet where content also changes between columns defeats its purpose.

---

## Layout — comparison sheet composition

- **Sheet ground:** `#151009` — one step darker than `Theme.bgPage` (`#1E1812`) so the six device frames read as floating objects against the sheet, not as one continuous background. Matches the sibling `-continue-button-circle-icon-options` sheet ground so the two artifacts read as a matched pair.
- **Grid:** 3 columns × 2 rows, 24pt gutters between frames (sheet-level gutter, independent of any in-app spacing).
  - Column order, left to right: **A — Continuation**, **B — Docked drawer**, **C — Thread screen**. Same order in both rows.
  - **Top row = populated/open state** (the primary comparison — this is the row the user's eye should land on first).
  - **Bottom row = each option's second state:**
    - A: the scroll position a reader is at *before* reaching the replies (top-of-note view) — demonstrates the discoverability weakness named in the option matrix.
    - B: the docked-bar collapsed state (bar visible, sheet not raised).
    - C: the note screen itself showing only the toolbar count chip (pre-navigation), not the pushed thread screen (that's covered by the top row instead).
- **Captions:** below each device frame, left-aligned under that frame.
- **Chrome per column** (appears once per column, spanning both its rows, beneath the bottom-row frame):
  - Option numeral + name: Playfair Bold, 20pt, `#EDAB3C`.
  - One-line caption: Inter SemiBold, 13pt, `Theme.textPrimary`.
  - One-line rationale: Inter Regular, 11pt, `Theme.textSecondary`.
  - One-line **build-cost / backend-readiness note**: Inter Regular, 11pt, `Theme.textGold` — this is where the backend gap (see Notes carried forward) and, for B specifically, the sheet-on-a-sheet risk, surface at the point of choice rather than being buried in a file.
- **Excluded-option note:** one sentence beneath the grid (Inter Regular, 11pt, `Theme.textSecondary`) stating the side-rail/marginalia idea was considered and excluded, with the one-line reason (no margin to spare on a 1260px-wide full-bleed reading column without contradicting Direction B).
- **Spacing grid:** 4/8/16/24/32pt increments only (`Theme.spacingXS…XL`) — no off-grid values anywhere on the sheet or within any frame's new UI.
- **No emoji anywhere.** SF Symbols only for any inline glyph, in-frame or in sheet chrome.

---

## Components / elements

### A. Baseline, unchanged in every one of the six frames
Status bar, `Theme.bgPage` (`#1E1812`) ground, both warm radial blooms (`#D4922A` @0.20 at (0.12,0.16) r10→380; `#B8761D` @0.12 at (0.92,0.60) r10→340 — `NotesListView.swift:794-799`), toolbar `ghostPill("Close", compact: true)` leading / `gradientPill("Edit", compact: true)` trailing (except Option C's top-row frame, which additionally carries the count-chip affordance in the toolbar), Playfair Bold 22pt title "Dealing with Failure," amber all-caps date line "JUN 9, 2026," the 1pt `goldGradient` hairline, and the serif note body via `NoteHTMLView` with no card wrapper. None of this varies by column — it is the fixed control the reply UI is judged against.

### B. Sample reply content — identical across every frame that shows replies
**3 replies**, "Couple Goals" group context, against the "Dealing with Failure" note:
- 3 distinct authors (distinct `username` values, distinct monogram letters/colors from `goldGradient`).
- Short, encouraging response text — 1-2 lines for two of them, and **one reply long enough to wrap to 3 lines** so line-wrapping and card-height growth are visible in the comparison.
- Each reply: 28pt circular `goldGradient` monogram (leading), 12pt gap, header row (author name · timestamp, baseline-aligned), `spacingSM` (8pt) gap, body text flush at the card's leading padding edge (not indented past the avatar).
- Text content must be byte-identical across A, B, and C wherever replies render — a comparison where the words also change is not a comparison.

### C. Option A — Continuation (inline, end of scroll)
- **Entry affordance:** none needed. A second gold hairline (identical `goldGradient` 1pt Rectangle, reused verbatim) appears after the note body, followed by a section label `REPLIES · 3` (Inter SemiBold 12pt, all-caps, tracking ~1.2, `Theme.textGold` — echoes the existing date-line idiom directly).
- **Open/expanded state (top-row frame):** thread is always open, no toggle. Three reply cards (`.widgetCard()`) stack in `spacingMD` (16pt) increments in the whitespace below the note body — the exact space reference 2 shows as ~30% unused frame height.
- **Composition affordance:** `ghostPill("Add a reply")` (non-compact, 36pt + padding to reach 44pt hit height) below the last card.
- **Overflow behavior (documented, not necessarily rendered if only 3 replies are shown):** beyond ~5 replies, show 5 then a `ghostPill("See all 12")`.
- **Bottom-row frame:** scrolled to the top of the note (title/date/hairline/body visible, replies below the fold) — shows what a reader sees before discovering replies exist, i.e. the discoverability weakness.
- **Empty state:** identical to today's screen — no hairline, no label, no cards, no composer pill.

### D. Option B — Docked drawer (bottom-edge overlay sheet)
- **Entry affordance:** persistent `gradientPill("3 Replies")` docked above the safe area at the bottom edge, with a 3-monogram overlap cluster (partially overlapping 28pt circles, ~8pt stagger) to its leading side, on a `#151009`-toned docking strip distinct from the page ground so it reads as chrome, not content.
- **Open/expanded state (top-row frame):** sheet raised to a medium detent (~55% of frame height), `Theme.radiusXXL` (36) top-corner radius, grabber handle, `#151009` sheet ground (one step darker than page, matching the token used for the sheet-level comparison ground — deliberate echo). Note body visible and dimmed (reduced opacity, not blurred) behind the raised sheet. Three reply cards stack inside the sheet at `spacingMD` spacing; an inline composer field sits at the sheet's largest-detent extent (documented — render at medium detent for the top-row frame, note the composer's presence in the caption rather than requiring a third state).
- **Bottom-row frame:** docked-bar collapsed state — bar and monogram cluster visible above the safe area, sheet not raised, note body fully visible and undimmed above it.
- **Empty state:** docked bar hidden entirely — screen is identical to today's.
- **Build-cost/backend chrome line:** flags the sheet-on-a-sheet risk (see Notes carried forward).

### E. Option C — Thread screen (separate pushed screen)
- **Entry affordance:** compact `ghostPill`-style count chip with `Theme.borderGoldDim`(-derived) stroke plus a small monogram-cluster glyph, placed in the toolbar between Close and Edit (all three toolbar items must still individually clear the 44×44pt touch floor with ≥8pt separation — the existing 32pt compact pills are shipped chrome and out of scope, but the *new* chip is not exempt).
- **Open/expanded state (top-row frame):** a full separate pushed screen (`navigationDestination(for:)` off the existing `NavigationStack` — no new sheet layer). Note collapses to a compact 2-line title+date header card at the top; full reply thread below in stacked `.widgetCard()`s; a composer bar pinned at the bottom of the screen (the only option where writing is first-class chrome, not a secondary pill).
- **Bottom-row frame:** the note-detail screen itself, showing only the toolbar count chip (pre-navigation) — establishes what a user sees before opting into the thread screen.
- **Empty state:** chip absent from the toolbar entirely.
- **Long-thread behavior:** native unbounded scroll — the only option that genuinely scales past a handful of replies.

### F. Deliberately excluded option (stated on the sheet, not rendered)
Side-rail / margin marginalia treatment. Excluded because the 1260px-wide portrait reading column has no margin to spare — a rail wide enough for a 28pt monogram plus legible text would consume ~30% of the column's width, directly against the Direction B decision that exists specifically to keep the note body full-width. State this in one sheet caption line rather than silently omitting it.

---

## Styling

### Palette — locked to existing `Theme` tokens, identical across A/B/C (fixed constants, not per-option variables)

| Role | Token | Value |
|---|---|---|
| Page ground | `Theme.bgPage` | `#1E1812` |
| Bloom 1 / 2 | — | `#D4922A`@0.20 / `#B8761D`@0.12, unchanged anchors |
| Reply card surface | `Theme.cardBg` | `#221508` @ 0.90 |
| Reply card stroke | `Theme.borderGoldDim` | `#D4922A` @ 0.18, 1pt |
| Reply card elevation | `topEdgeHighlight` | white 0.30→clear, 1pt top edge — no drop shadows |
| Reply card radius | `Theme.radiusLG` | 16 |
| Sheet chrome radius (B) | `Theme.radiusXXL` | 36 |
| Author name / reply body | `Theme.textPrimary` | `#F5EAD0` |
| Reply timestamp / section label | `Theme.textGold` | `#D4922A` full opacity — **not** `textGoldMuted` |
| Avatar monogram fill | `Theme.goldGradient` | `#F0AE40 → #B07820` |
| Avatar monogram glyph | — | `#24170A` |
| Divider | `Theme.goldGradient` | 1pt, reused verbatim |
| Primary affordance | `gradientPill` | `#EDAB3C/#D4922A/#B8761D` fill, `#24170A` label |
| Secondary affordance | `ghostPill` | parchment@0.04 fill / parchment@0.14 stroke |
| Sheet ground (outside device frames) | — | `#151009` |

**Forbidden on reply-card surfaces:** `textGoldMuted` (2.94:1 on `cardBg` — fails) and `textMuted` (2.30:1 — fails). Reply metadata uses `textGold` full-opacity or `textSecondary` (5.28:1) only.

### Typography

| Element | Face | Size/weight | Token |
|---|---|---|---|
| Note title *(unchanged)* | Playfair Display Bold | 22 | existing |
| Note date/body *(unchanged)* | existing serif/`sectionLabel` | — | existing |
| Reply section label | Inter SemiBold | 12, all-caps, tracking ~1.2 | `textGold` |
| Reply author name | Inter SemiBold | 14 | `textPrimary` |
| Reply timestamp | Inter Regular | 12 | `textGold` |
| Reply body | Inter Regular | 16, line-height ~1.45 | `textPrimary` |
| Avatar monogram | Inter Bold | 14 | `#24170A` |
| Affordance labels | Inter SemiBold | 12 | via `gradientPill`/`ghostPill` |
| Sheet: option numeral | Playfair Bold | 20 | `#EDAB3C` |
| Sheet: caption | Inter SemiBold | 13 | `textPrimary` |
| Sheet: rationale | Inter Regular | 11 | `textSecondary` |
| Sheet: build-cost note | Inter Regular | 11 | `textGold` |

**Load-bearing decision:** the note body is serif, replies are Inter — that split alone carries "reads as authored content distinct from the parent note." Playfair never appears inside a reply card.

### Imagery / iconography
Avatars are always a single-letter monogram on `goldGradient`, never a photo (no avatar/image field exists on any model). SF Symbols only for any chip/chevron glyphs (toolbar count chip, grabber affordance). No drop shadows anywhere — elevation is `topEdgeHighlight` only, per the app's explicit wholesale removal of shadows.

### Author-less replies (must render correctly in every option)
When a reply's `username` is empty, omit both the monogram and the name entirely; show only the timestamp. This is a documented real state (`Models.swift:183-189`), not a hypothetical — every option's card layout must degrade to this correctly, though the six rendered frames themselves use the fixed 3-named-author sample content per Components → B.

### Touch targets
Every *new* affordance introduced by any option ≥ 44×44pt hit area with ≥8pt separation from neighbors — achieved via non-compact 36pt pill height plus vertical padding, or an expanded `.contentShape`. The existing 32pt `compact: true` toolbar pills (Close/Edit) are shipped chrome, confirmed unchanged, and explicitly out of scope for this pass.

---

## States

- **Empty state (all three options, not separately rendered on the sheet but described in every column's caption):** literally identical to today's screen — no divider, no label, no chip, no docked bar, zero added chrome. Reply UI is earned by content, never rendered speculatively.
- **Populated state:** the top row of the grid, one column per option, per Components C/D/E above.
- **Option-specific secondary state:** the bottom row of the grid, per option (pre-scroll for A, collapsed dock for B, pre-navigation toolbar chip for C) — see Layout → Grid.
- **Long-thread state:** documented only, not separately rendered — A shows 5 + overflow pill, B scrolls internally within its sheet, C is native/unbounded. One sentence per option in the rationale line is sufficient; no seventh frame needed.
- **Press/interaction states:** not rendered (this is a static comparison of placement, not an interaction study) — reuse existing `gradientPill`/`ghostPill` press behavior unchanged; no note needed since no option modifies it.
- No light-mode variant — app is forced `.preferredColorScheme(.dark)` (`NotesListView.swift:874`); confirmed, not assumed.

---

## Generation-needed?

**Yes, new visual assets are required — but not via generative image synthesis (OpenArt).** Two of this deliverable's own success criteria — "stays visually consistent with FellowScript's established visual language" and "realistically buildable against the actual `NoteDetailView`/`FSNote` source" — are only verifiable if the frames are produced by the real token set on the real screen. A generative model would approximate Playfair, approximate `#221508`, and approximate the bloom anchors, and the resulting comparison would not answer the question the user is actually asking. The sibling `-continue-button-circle-icon-options` task reached the same conclusion (`generation.json`: `openart_used: false`).

**Correct generation path — faithful render-and-composite, not text-to-image:**

1. Implement each of the three reply-placement variants as preview-only/throwaway SwiftUI additions extending the real `NoteDetailView` (`NotesListView.swift:766-918`) — reusing `.widgetCard()`, `goldGradient`, `gradientPill`/`ghostPill` verbatim rather than re-deriving them. None of this needs to ship; it needs to render accurately.
2. Populate each with the fixed 3-reply "Couple Goals" sample content (Components → B) so all three carry byte-identical reply text.
3. Capture six on-device or simulator screenshots at **1260 × 2736** — top-row populated/open state and bottom-row secondary state per option — holding the note baseline (title, date, body, bloom, status bar) identical across all six.
4. Composite the six frames plus per-column chrome (numeral, caption, rationale, build-cost line) plus the excluded-option note into the single comparison-sheet PNG per the Layout section above. This compositing step is standard image-composition, not generative synthesis, and should not go through OpenArt.

If the generation stage's only available tool is OpenArt text-to-image, flag this back rather than proceeding with a generative approximation — a hand-composited render built from a real (even preview-only) SwiftUI build against the actual `Theme` tokens is required to meet the stated success criteria.

---

## Notes carried forward, unresolved (informational, not blocking)

- **Which option the user prefers** — the deliverable's entire purpose, not something to pre-decide.
- **Backend gap, surfaced on the sheet itself (build-cost chrome line, all three columns):** `POST /notes/reply/{note_id}`, `GroupsManager.fetch_replies()`, and `GET /community/{user_id}/{note_id}/{group_id}/replies` are all live and working, but that GET route requires a `group_id` path segment, and `GET /notes/{user_id}` (personal notes) hardcodes `"replies": []`. A personal (non-group) note's replies cannot be fetched by the client today, regardless of which option is chosen. The next `/build` pass either scopes to group notes only or adds a small personal-note GET-replies endpoint first.
- **Option B's sheet-on-a-sheet risk, surfaced on the sheet itself (Option B's build-cost chrome line):** `NoteDetailView` is already presented as a sheet from `NotesListView`; a documented prior regression (`NotesListView.swift:851-871`) shows a nested sheet can adopt an unintended compact/centered adaptation, and the existing fix (`.presentationCompactAdaptation(.fullScreenCover)`) is incompatible with a partial-detent drawer, since forcing full-screen would destroy the medium-detent behavior that defines Option B. Real, prior-art-backed build risk — not a reason to drop the option, but must be solved deliberately in `/build`, not discovered there.
- **Dynamic Type** — `Font.inter`/`Font.playfair` use fixed point sizes; this is a pre-existing screen-wide issue, not introduced by the reply UI, but reply cards are the most text-dense new surface and will bite hardest. Not resolvable in a static comparison; flag for `/build`.
- **Group-vs-personal visual divergence** — all six frames render the group case (3 distinct authors, monograms). A future personal-note reply (self-replies, possible empty `username`) would look sparser; the author-less-reply rule above means it degrades correctly, but no separate personal-context frame is rendered (intake asked for passing consideration only).
- **32pt compact toolbar pills vs. the 44pt touch floor** — pre-existing, out of scope for this pass, flagged for a possible separate accessibility pass.
