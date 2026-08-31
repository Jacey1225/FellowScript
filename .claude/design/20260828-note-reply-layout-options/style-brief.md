# Style Brief — Note reply-thread layout options (`NoteDetailView`, iOS)

Task: `20260828-note-reply-layout-options`
Step 2 — reference synthesis. Media type: **static**.

---

## 1. Media type

**`static`.**

Reasoning: the deliverable is "3 different layouts... report back to me on them" so the user can visually compare and pick one for a later `/build` pass. Nothing in the request names motion, transition, duration, or timing. More decisively, the thing being compared is *placement* — where replies live relative to the note body — and placement is fully legible in a still. Rendering three animated reveals would introduce a second variable (transition feel) that the user was not asked to judge and that would actively obscure the placement comparison. Confirming intake's high-confidence hint.

Corroborating signals:
- `.claude/visual-preferences/motion-references/` is **empty** — no motion baseline exists in the curated library to synthesize a motion language from.
- The sibling precedent `20260828-continue-button-circle-icon-options` shipped `media_type: static` for the same "N options, user picks" deliverable shape, and its `generation.json` records `openart_used: false` — real captures, not generative renders. See §5.

Each option still gets a **one-line transition note** in §3, but as `/build` handoff metadata, not as part of the rendered deliverable.

---

## 2. Unified style direction

### 2.1 Mood

**A private page, and other people's voices in the margin.**

`NoteDetailView` today is deliberately the quietest screen in the app: no glass card, no chrome, a serif column of the user's own writing floating directly on the warm bloom. That is a *reading* posture, and the reply feature must not convert it into a *feed* posture. The governing idea across all three options is therefore **authorship contrast** — the note stays un-carded, full-bleed, serif, first-person; replies arrive as discrete, contained, carded, sans-serif objects that visibly belong to someone else. The reply surface is a guest on this page, not a co-owner of it.

The second governing idea is **conditional silence.** The request's own framing is "*some* of them will have replies." A note with no replies must look exactly like it looks today — zero added chrome, zero "0 replies" label, zero empty affordance. Reply UI is earned by content, never rendered speculatively.

### 2.2 Palette — locked to existing tokens, zero new hex

Every value below is an existing `Theme` token from `FellowScript/Theme/Theme.swift`. Nothing is invented; nothing is a raw literal at a call site. These are **fixed constants across all three options**, not per-option variables — placement is the only thing that varies.

| Role | Token | Value | Note |
|---|---|---|---|
| Page ground | `Theme.bgPage` | `#1E1812` | unchanged |
| Bloom layer 1 | — | `#D4922A` @ 0.20, center (0.12, 0.16), r 10→380 | unchanged, `NotesListView.swift:794-795` |
| Bloom layer 2 | — | `#B8761D` @ 0.12, center (0.92, 0.60), r 10→340 | unchanged, `:797-798` |
| Reply card surface | `Theme.cardBg` | `#221508` @ 0.90 | **the authorship signal** — see §2.4 |
| Reply card stroke | `Theme.borderGoldDim` | `#D4922A` @ 0.18, 1pt | via `.widgetCard()` |
| Reply card elevation | `topEdgeHighlight` | white 0.30 → clear, 1pt top edge | the app's only elevation language; no drop shadows |
| Reply card radius | `Theme.radiusLG` | 16 | via `.widgetCard()` |
| Sheet chrome radius (Option B) | `Theme.radiusXXL` | 36 | **already exists for exactly this purpose** — added for `SessionCreatorSheet`'s bottom-sheet chrome (`Theme.swift:62-67`) |
| Author name | `Theme.textPrimary` | `#F5EAD0` | |
| Reply body | `Theme.textPrimary` | `#F5EAD0` | |
| Reply timestamp | `Theme.textGold` | `#D4922A` (full opacity) | **not** `textGoldMuted` — see contrast table |
| Section label / count | `Theme.textGold` | `#D4922A` | matches the existing `sectionLabel` date-line idiom |
| Avatar monogram fill | `Theme.goldGradient` | `#F0AE40` → `#B07820`, ↘ | |
| Avatar monogram glyph | — | `#24170A` | same value `gradientPill` already uses (`NotesListView.swift:885`) |
| Divider | `Theme.goldGradient` | 1pt `Rectangle` | reuses the existing hairline verbatim (`:814-816`) |
| Primary affordance | `gradientPill` | `#EDAB3C`/`#D4922A`/`#B8761D` fill, `#24170A` label | reuse the local helper, do not re-roll |
| Secondary affordance | `ghostPill` | `parchment` @ 0.04 fill, `parchment` @ 0.14 stroke | ibid. |

**Contrast, computed rather than assumed** (WCAG relative luminance, reply text composited over `cardBg #221508`):

| Pair | Ratio | Verdict |
|---|---|---|
| `textPrimary` `#F5EAD0` on `cardBg` | ~13:1 | pass |
| `textGold` `#D4922A` on `cardBg` | **6.76:1** | pass — use for timestamps/counts |
| `textSecondary` `#F5EAD0` @0.55 on `cardBg` | **5.28:1** | pass — acceptable alternate for timestamps |
| `textGoldMuted` `#D4922A` @0.55 on `cardBg` | **2.94:1** | **FAIL** — forbidden for any reply text |
| `textMuted` `#F5EAD0` @0.28 on `cardBg` | **2.30:1** | **FAIL** — forbidden for any reply text |
| `#24170A` on gold-gradient dark end `#B07820` | ~6.1:1 | pass (monogram, pill labels) |

This is a real trap worth naming: the muted amber tokens are the *intuitive* pick for a secondary timestamp and they do not clear 4.5:1 on the card surface. Reply metadata uses `textGold` at full opacity or `textSecondary`. The app is force-dark (`.preferredColorScheme(.dark)`, `NotesListView.swift:874`), so there is no light-mode parity check to run — intake's suspicion on this point is confirmed, and it is not an open question.

### 2.3 Typography — the authorship split

| Element | Face | Size | Weight | Token |
|---|---|---|---|---|
| Note title *(unchanged)* | Playfair Display | `fontDisplayMD` 22 | Bold | existing |
| Note date *(unchanged)* | existing `sectionLabel` | — | — | existing |
| Note body *(unchanged)* | serif via `NoteHTMLView` | — | — | existing |
| Reply section label | Inter | `fontXS` 12 | SemiBold | all-caps, tracking ~1.2, `textGold` — echoes the date-line idiom directly above it |
| Reply author name | Inter | `fontSM` 14 | SemiBold | `textPrimary` |
| Reply timestamp | Inter | `fontXS` 12 | Regular | `textGold` |
| Reply body | Inter | `fontBody` 16 | Regular | `textPrimary`, line-height ~1.45 |
| Avatar monogram | Inter | `fontSM` 14 | Bold | `#24170A` |
| Affordance labels | Inter | `fontXS` 12 | SemiBold | via `gradientPill`/`ghostPill` |

**The serif/sans split is the load-bearing typographic decision.** The note body is serif and the replies are Inter. That single contrast does most of the work of "reads as authored content distinct from the parent note" without needing heavier devices like indentation rails or bubble tails. Playfair is reserved for the note's own title and never appears inside a reply.

`.font(.inter(...))` sizes are fixed points today, which conflicts with Dynamic Type. Flagged in §6 rather than silently specced around.

### 2.4 Composition & layout principles

**The card *is* the authorship boundary.** `NoteDetailView` intentionally has no `glassCard` wrapper — the file's own header comment (`:760-765`) calls this a deliberate "Direction B" choice so a long note's reading column stays full width. Reply cards therefore reintroduce the `.widgetCard()` surface the note body specifically refuses. That inversion is not an inconsistency with Direction B; it is the cleanest available expression of it. Full-bleed = yours. Carded = someone else's.

Shared geometry across all three options:

- **Reply card:** `.widgetCard(padding: Theme.spacingMD)` — `cardBg`, `radiusLG` 16, `borderGoldDim` 1pt, `topEdgeHighlight`. `spacingMD` (16) between stacked cards. No drop shadows anywhere (the app dropped them wholesale, `Theme.swift:160-171`).
- **Reply card internals:** 28pt circular `goldGradient` monogram (leading) → 12pt gap → header row (author name · timestamp, baseline-aligned) → `spacingSM` (8) → body text. Body text starts flush at the card's leading padding edge, **not** indented past the avatar — a 28pt indent on a 375pt-wide phone wastes reading width for no gain.
- **Avatar = single-letter monogram, never a photo.** Confirmed by source: there is no avatar/image field on any model; the app's established identity idiom is a first-letter initial (`FSUser.initials`, `Models.swift:30`; `:356`). `FSNote` itself carries only `username` and has no `initials` helper, so the reply view derives the letter locally — same pattern, one line.
- **Author-less replies are a real case, not an edge case.** `Models.swift:183-189` documents that an empty `username` means "no author to show, never a placeholder." When `username` is empty, drop the monogram and the name entirely and show the timestamp alone. Every option must render correctly with the identity row absent.
- **Spacing grid:** the app's own 4 / 8 / 16 / 24 / 32 scale (`Theme.spacingXS…XL`). No off-grid values.
- **Touch targets:** every new affordance ≥ 44×44pt with ≥ 8pt separation. `gradientPill`/`ghostPill` at `compact: true` are 32pt tall — **below the floor**. New reply affordances use the non-compact 36pt variant plus vertical padding to reach 44pt of hit area, or `.contentShape` with an expanded frame. The existing 32pt toolbar pills are shipped chrome and out of scope.
- **Sample content, fixed across all three frames:** **3 replies** in a shared-group context (the "Couple Goals" group from the list-view filter row), against the real "Dealing with Failure" note from reference 2. Three distinct authors, short encouraging responses, one of them long enough to wrap to 3 lines so line-wrapping and card growth are visible. Identical text in every option — a comparison sheet where the content also changes is not a comparison.
- **Empty state = literally today's screen.** No divider, no label, no chip, no docked bar. Options differ in *how much they add when replies exist*, and agree completely on adding nothing when they don't.

### 2.5 The comparison sheet itself

- **Frame:** iPhone portrait at **1260 × 2736**, matching the two supplied device screenshots exactly. Same status bar treatment, same bloom, same toolbar.
- **Sheet ground:** `#151009` — one step darker than `bgPage` so device frames read as floating objects. Deliberately the same sheet ground the sibling `-continue-button-circle-icon-options` task used, so the two comparison sheets read as a matched set of FellowScript design artifacts.
- **Grid:** 3 columns × 2 rows. **Top row = populated/open state** (the primary comparison). **Bottom row = the option's second state** — for A the scrolled-to-top view showing what the reader sees before reaching replies, for B the collapsed docked-bar state, for C the note screen with only the header count chip. Consistent column order A / B / C in both rows.
- **Chrome:** option numeral in Playfair Bold 20pt `#EDAB3C`; caption in Inter SemiBold 13pt `textPrimary`; one-line rationale in Inter Regular 11pt `textSecondary`; a one-line **build-cost / backend note** per column in `textGold` 11pt (this is where the §6 gaps surface at the point of choice, not buried in a file). 24pt gutters.
- **No emoji anywhere.** SF Symbols only for any glyph.

---

## 3. The three options

Spread along a single coherent axis — **disclosure distance** — so the set covers the space rather than clustering. Each option's *entry affordance also lives in a different region of the screen*, directly honoring the user's "replies showing up in different areas."

| | **A — Continuation** | **B — Docked drawer** | **C — Thread screen** |
|---|---|---|---|
| Reply location | inline, end of the scroll | bottom-edge overlay sheet | separate pushed screen |
| Entry affordance region | end of body content | persistent bottom edge | top toolbar |
| Entry affordance | none needed — a second gold hairline + `REPLIES · 3` label; the thread simply follows | `gradientPill` "3 Replies" docked above the safe area, with a 3-monogram overlap cluster to its leading side | compact `ghostPill` count chip with `borderGold` stroke + monogram cluster, in the toolbar between Close and Edit |
| Open/expanded state | thread is always open; cards stack in the whitespace below the body (the reference screenshot shows ample unused room there) | sheet rises to a medium detent (~55%) with `radiusXXL` 36 chrome and a grabber; note body dims behind and stays visible | full screen: note collapses to a 2-line title+date header card, full thread below, composer pinned at bottom |
| Empty state | nothing rendered — identical to today | docked bar hidden entirely | chip absent from toolbar |
| Reply composition | `ghostPill` "Add a reply" below the last card | inline composer inside the sheet at the largest detent | composer permanently pinned — the only option where writing is first-class |
| Long-thread behavior | show 5, then a `ghostPill` "See all 12" | sheet scrolls internally to `.large` | native, unbounded — the only option that genuinely scales |
| Transition note *(handoff only, not rendered)* | none — content simply exists | detent spring, ~300ms, reduced-motion aware | standard `NavigationStack` push |
| Strength | zero new chrome; purest expression of "quiet reading screen"; cheapest to build | replies reachable at any scroll position regardless of note length; body stays a pure reading column | scales to real conversation; best fit for group/community notes; cleanest composer story |
| Weakness | on a long note, replies are invisible until the reader scrolls to the very bottom — poor discoverability, which is the exact case reference 2 shows | adds persistent chrome to the screen most deliberately kept clean; **carries a documented technical risk** (see §6) | highest disclosure cost; you leave the note to read responses to it; most build work |

**Deliberately excluded, stated rather than silent: a side rail / margin marginalia treatment.** It is genuinely attractive for a reading app and it is the first idea the "different areas" invitation suggests. It is excluded because iPhone portrait at 1260px has no margin to spare — a rail wide enough to hold a 28pt monogram plus legible text would take ~30% of the reading column, directly contradicting the Direction B decision (`:760-765`) that exists specifically to keep that column full width. Offering it would spend one of three slots on an option we would then have to argue against. Worth a single sentence on the sheet so the user knows it was considered.

---

## 4. Synthesis rationale

**Multiple references — attached and curated.** This is a combine-what-they-share case, not a pick-a-favorite case.

### From the attached references

**Reference 2, the note-detail screenshot** (`…1787974822376-1543102953492189224.png`, opened with Read). The baseline everything extends: the Close/Edit pill hierarchy, the Playfair title, the amber all-caps date line, the 1pt gold hairline, the serif body flowing full-width with no card. It also supplied the single most consequential observation — roughly the bottom 30% of that frame is empty warm ground below the note text. That whitespace is what makes Option A viable without redesigning anything, and its presence in a *short* note is also what exposes Option A's weakness on a *long* one.

**Reference 1, the Notes list screenshot** (opened with Read). Two things: the group-filter pill row (Personal / Couple Goals / Cus Group / Family), which is why §2.4 fixes the sample content in a **group** context rather than a personal one; and the confirmation that carded surfaces on this warm ground are the app's normal container idiom — so §2.4's "cards mean someone else's words" reads as in-language, not as a new invention.

**References 4–7, the source files** (`api/routes/notes.py`, `interactions/groups.py`, `Models.swift`, `NotesListView.swift`, all read directly this session, plus `Theme/Theme.swift` which I pulled in additionally). These converted the entire palette/typography section from assertion into citation — every token in §2.2 is a real `Theme` constant at a real line number. Three specific finds changed the design rather than merely documenting it:
1. `Theme.radiusXXL = 36` already exists, added specifically for bottom-sheet chrome (`SessionCreatorSheet`). Option B's sheet has a correct radius token waiting for it — it is not a new invention.
2. The elevation language is `topEdgeHighlight`, not shadows, and shadows were dropped *wholesale* as an explicit decision. Any reply card carrying a drop shadow would be off-system.
3. `Models.swift:183-189` — an empty `username` is a real, documented state, and the app's rule is to show *nothing* rather than a placeholder. That produced the author-less-reply requirement in §2.4, which no reference image would have revealed.

**Reference 3, the sibling task** (`-continue-button-circle-icon-options/`, its `intake-brief.md`, `style-brief.md`, and `synthesis.json` read this session). Structural precedent for the artifact shape: locked-palette-plus-one-varying-axis, an option matrix table, an explicitly-excluded-option paragraph with reasons, and gaps split into "resolved here" vs "still open." Its `generation.json` also settled §5 — that pipeline rendered **real SwiftUI captures, `openart_used: false`**.

### From the curated library (`.claude/visual-preferences/`)

Matched on Deliverable (an iOS app screen) → **`mobile-app-screens/`**. Weighted as heavily as the attached references, per Jacey's own taste baseline.

- **`mobile-app-screens/3c4c0fbc9bd9b8ed91585053f9cc3a5f.jpg`** — the strongest match in the entire library. A near-black warm ground with ember/orange accents, a high-contrast serif display headline against sans-serif UI text, and, critically, **a rounded dark panel docked at the bottom of the phone with a grabber handle**, holding a stack of identity-marked rows, while the screen's main content stays visible above it. That is Option B, rendered, in this exact palette family. It independently validates three things §2 would otherwise merely assert: that a docked bottom panel is coherent on a warm-dark reading screen rather than feeling bolted on; that serif-display-plus-sans-UI is the right typographic split for this material (supporting §2.3); and that a generous sheet corner radius is what makes the panel read as chrome rather than as content. Its presentation format — one device on a dark canvas with a side caption block and corner metadata — also informed §2.5's sheet chrome.
- **`mobile-app-screens/9710930a3a46fb30000cf826307fd7a2.webp`** — amber/gold on near-black, glass cards, capsule toggles, circular gold accent buttons, floating pill tab bar. The closest palette-and-material sibling to FellowScript in the library, and confirmation that stacked carded content on a warm-dark ground stays legible at phone scale. Its **three-phones-on-a-flat-ground presentation** is directly where §2.5's 3-column device grid comes from.
- **`mobile-app-screens/original-51d91f02f19c0e901f3da59b74cd69b4.webp`** — warm copper radial bloom on black (the same bloom device `NoteDetailView` already uses), composed as a large detail screen alongside a panel of stacked secondary rows. Corroborates that "one primary content column + a stack of subordinate entries" holds together on this exact ground, which is Option A's whole structure.
- **`mobile-app-screens/still-5c7c5e64ca7336c0f06fa0af0c789f55.webp`** — structural rather than chromatic (it is neutral-dark, not amber). A dark detail screen where body copy is followed by a labeled section of **circular per-person identity chips with names beneath**, and a two-up pairing of a collapsed vs. expanded state of the same screen. Two contributions: it is the pattern behind the monogram-cluster entry affordance in Options B and C, and its collapsed/expanded pairing is why §2.5 renders **two states per option** rather than one.
- **`mobile-app-screens/9d6988320a1065b7bc89fe783a175f59.webp`** — light contribution only: a warm amber-to-dark gradient trio of screens on a flat dark ground, reinforcing the 3-up comparison format and the warm-on-black taste baseline.
- **`before-after-comparisons/f7b734b1608e5c186ce9c0a0b176a96c.webp`** — used for **presentation format only**, not style: labeled two-up device frames on a dark ground with serif italic column titles above each. §2.5's per-column numeral-plus-caption chrome follows it. Its actual UI content (a cool-toned social onboarding screen) contributes nothing here.

**Checked and explicitly excluded, rather than pulled in wholesale:** the remaining `mobile-app-screens/` entries (`73a4d07e…` ski/blue, `original-3759e6eb…` purple, `original-7599502b…` lime-on-black, `36ebd1d5…` orange-on-white, `b3f90ded…` sage-green, `still-3e3fd610…` sage mental-health, `still-55476d…` lime crypto) — all carry no palette or material kinship with FellowScript's warm amber-on-dark and would dilute rather than sharpen the direction. **`web-hero-landing/`** is the wrong medium entirely (desktop marketing pages). **`widgets-dashboard-ui/`** was the sibling task's primary source but is desktop/widget-scale here and contributes nothing to a phone reading screen. **`motion-references/`** is empty and moot given `media_type: static`.

### From `ui-ux-pro-max` (loaded), `design-system` (loaded)

The `--design-system` query for "reading journal notes app dark warm serif content-first" returned a **light-mode, paper-background "Newsletter / Content First" landing-page pattern** — a genuine mismatch for a force-dark native reading screen, and I am **not** using its palette. Stating that rather than presenting an off-target result as data. Two things from it are worth keeping: its typography record independently matched this product to a *warm scholarly serif* mood (academia / parchment / library, Cormorant Garamond + Crimson Pro), corroborating that Playfair-serif-for-content is the right instinct for FellowScript's notes; and its "Avoid" list (excessive decoration, complex shadows, 3D) aligns exactly with the app's existing no-shadow flat/hairline elevation language.

From the UX and SwiftUI queries, applied concretely rather than recited: the 44×44pt touch floor and 8pt separation (which is what caught the 32pt `compact` pill problem in §2.4); the 4.5:1 body-text contrast bar (which is what caught the `textGoldMuted` failure in §2.2); Dynamic Type support (§6); reduced-motion awareness for Option B's detent; and `navigationDestination(for:)` over `NavigationLink(destination:)` for Option C, which `NoteDetailView`'s existing `NavigationStack` already supports.

### Where the synthesis went beyond any single reference

Four decisions are mine, derived by combining the above, stated as choices so they can be argued with:

1. **The un-carded/carded inversion as the authorship signal** (§2.4). The Direction B comment explains why the *note* has no card; nothing in any reference says replies should therefore *have* one. Making the note's most distinctive property into the mechanism that separates it from replies is the synthesis step.
2. **The serif/sans split doing the work instead of indentation or bubbles** (§2.3). Chat-style bubbles and indent rails are the default reply idioms and both would import a messaging vocabulary this screen does not have. The app already ships two typefaces with a clear division of labor; using that division is cheaper and more in-language.
3. **Disclosure distance as the deliberate axis** (§3). The user invited variety; an axis makes the three options *comparable* rather than merely different, which is what "enables a confident choice" requires.
4. **Two rendered states per option** (§2.5). Follows from the request's own "some of them will have replies" conditionality, and from the curated collapsed/expanded pairing — but it is a decision about the deliverable's shape, not something any reference dictated.

---

## 5. Rendering approach (flag for the generation stage)

**These must be real SwiftUI simulator captures at 1260 × 2736, not generative images.** Two success criteria — "stays visually consistent with FellowScript's established visual language" and "realistically buildable against the actual `NoteDetailView`/`FSNote` source" — are only *verifiable* if the frames are produced by the real token set on the real screen. A generative render would approximate Playfair, approximate `#221508`, and approximate the bloom anchors, and the resulting comparison would not answer the question the user is asking. The sibling task reached the same conclusion and recorded `openart_used: false`. Expect **six device frames plus one composed comparison sheet**, not one asset.

---

## 6. Carried-forward gaps

### Resolved here — the spec stage should inherit these positions, not re-open them

- Number of options → **3**, per §3. Carried forward as a first-class requirement per intake's flag: three distinct rendered placements, not one locked design.
- Which three mechanisms → inline continuation / docked bottom drawer / pushed thread screen, along a disclosure-distance axis. Side-rail marginalia excluded with reasons (§3).
- Palette → locked to existing `Theme` tokens, zero new hex, identical across all three options.
- Reply metadata color → `textGold` or `textSecondary`. `textGoldMuted` and `textMuted` **forbidden** on card surfaces (2.94:1 / 2.30:1).
- Sample content → 3 replies, 3 distinct authors, group ("Couple Goals") context, one wrapping to 3 lines, identical across all frames.
- Avatar treatment → single-letter monogram on `goldGradient`, never a photo; no image field exists on any model.
- Author-less replies → identity row omitted entirely, per `Models.swift:183-189`.
- Empty state → today's screen exactly, no added chrome, in all three options.
- Long threads → common-case scope (show ~5 + overflow pill for A, internal scroll for B, native for C). Deep pagination out of scope.
- Frame dimensions → 1260 × 2736, matching the supplied screenshots.
- Light/dark variants → **moot, confirmed not assumed.** `.preferredColorScheme(.dark)` at `NotesListView.swift:874`. Dark only.
- Reply composition affordance → included in each option's description as secondary, per intake's read that the request is primarily about *display*.
- Rendering path → real captures, not OpenArt (§5).

### Still open, carried forward

- **Which option wins.** By design — that is the deliverable's purpose, not a defect.
- **The backend gap, carried forward verbatim and surfaced on the sheet itself.** `POST /notes/reply/{note_id}` works, `GroupsManager.fetch_replies()` works, and `GET /community/{user_id}/{note_id}/{group_id}/replies` is live — but that route **requires a `group_id` path segment**, and `GET /notes/{user_id}` hardcodes `"replies": []`. **A personal (non-group) note's replies cannot be fetched by the client at all today.** All three options are equally affected; none of them designs around it. Consequence for the user's choice: the next `/build` pass either scopes to group notes only, or adds a small personal-note GET-replies endpoint first. Per §2.5 this appears as a line of chrome on the comparison sheet so the choice is made with it visible, not discovered afterward.
- **Newly surfaced by synthesis — Option B carries a documented, previously-hit technical risk.** `NoteDetailView` is *itself* presented as a sheet from `NotesListView`. `NotesListView.swift:851-871` documents a real, reproduced, racy regression from exactly this "sheet-on-a-sheet" path: a nested sheet can adopt a small centered form-sheet compact adaptation instead of the intended presentation, and `.presentationDetents` alone did **not** prevent it — the existing Edit sheet needed `.presentationCompactAdaptation(.fullScreenCover)` to escape it. A *partial-detent* reply drawer cannot use that escape hatch, because forcing `.fullScreenCover` is precisely what would destroy the medium-detent behavior that makes Option B Option B. This is not a reason to drop Option B, but it is real, prior-art-backed build risk that the user should see at choice time and that a `/build` pass must solve deliberately rather than discover. Belongs on the sheet as Option B's build-cost line.
- **Newly surfaced by synthesis — Dynamic Type.** `Font.inter(_:)`/`Font.playfair(_:)` take fixed CGFloat point sizes (`Theme.swift:135-140`), so nothing on this screen currently scales with the user's text-size setting. The SwiftUI guideline ("scalable fonts, not `.font(.system(size:))`") is already violated by the existing screen, so the reply UI is not introducing the problem — but reply cards are multi-line text-dense surfaces where it will bite hardest, and Option A's "show 5 then overflow" cutoff is the piece most sensitive to it. Not resolvable in a static comparison; flagged for `/build`.
- **Group-vs-personal visual divergence is acknowledged but not separately tracked.** All three options render the group case (multiple distinct authors, monogram identity). A future personal-note reply — self-replies, empty `username`, no monogram — would look meaningfully sparser. §2.4's author-less rule means every option degrades correctly, but no separate personal-context frame is rendered. Intake asked only for "passing consideration"; this is it.
- **The 32pt `compact` pill vs. the 44pt touch floor.** §2.4 sets the rule for *new* affordances. The existing Close/Edit toolbar pills are shipped chrome at 32pt and are explicitly out of scope here — but it is a live accessibility issue on this screen that a `/build` pass may want to pick up separately.
- **No deadline was given.**
