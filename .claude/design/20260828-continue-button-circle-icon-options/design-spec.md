# Design Spec — Circular "Continue" affordance, 4-option comparison sheet

Task: `20260828-continue-button-circle-icon-options`
Step 3 — static spec. Source: `intake-brief.md` + `style-brief.md` (both read in full; style brief already carries a fully resolved, internally consistent geometry/palette/option matrix — no gaps required bouncing back to synthesis).

---

## Deliverable

**One comparison sheet image**, plus its four constituent device-frame pairs, all delivered as PNG:

1. **The sheet** — a single composited PNG, portrait-safe for viewing as one image: a 2×2 grid of full device frames (top) + a matching row of 4 detail crops (bottom), captions and rationale text between. Approximate overall canvas: grid cell width driven by device frame width scaled to fit; exact export size is a generation-stage decision, but the internal proportions below are fixed.
2. **Four full-device frames**, each `1206 × 2622` px (native resolution of the existing reference screenshot `/tmp/fellowscript-screenshots4/2CF030F5-4CCD-432A-A7AC-FDD8206F6F8E.png`), identical in every respect (status bar, greeting gradient header, tab bar, card content, scroll position) except the note-resume card's Continue button.
3. **Four detail crops**, each ~`420 × 420` device px, centered on the card's bottom-right corner, showing the button plus enough of the card edge/gutter to judge the overlap and enough surrounding card content to judge glyph-repetition risk (see Option 3 note below).

All 4 options share one frame/resolution/scroll-position/content baseline (the "Romans 8 Study Notes" card state) — **exactly one variable (the button) moves per option.** This is a hard constraint, not a preference: a comparison where two things move at once defeats the deliverable's purpose.

---

## Layout — comparison sheet composition

- **Ground:** `#151009` (one step darker than `Theme.bgPage` `#1E1812`) so the four device frames read as floating objects, not as part of one continuous background.
- **Grid:** 2×2 arrangement of full device frames, 24pt gutters between frames (sheet's own gutter — independent of the in-app 12pt button gutter).
- **Order:** Option 1 (top-left) → Option 2 (top-right) → Option 3 (bottom-left) → Option 4 (bottom-right), consistent left-to-right/top-to-bottom reading order matching the numbering in the option matrix below.
- **Captions:** below each device frame, left-aligned under that frame — numeral + short name + one-line rationale (see Typography below).
- **Detail-crop row:** single row beneath the 2×2 grid, 4 crops in the same option order, uniform size, same 24pt gutter spacing, each still carrying its own numeral so the row is legible independent of the grid above it.
- **Spacing grid throughout:** 4/8/16/20/24pt increments only (matches the app's own spacing scale) — no arbitrary spacing values.

---

## Components / elements

### A. The four device frames (identical except for one element)
Each frame reproduces, unchanged: status bar, amber-to-dark vertical greeting gradient header, "Romans 8 Study Notes" note-resume card in its current glass-card material (`Theme.cardBg` `#221508` @ 0.90, frosted/blurred), any other visible dashboard cards below the fold at the same scroll position, and the pill-shaped bottom tab bar. Nothing here varies across options — this is the fixed control.

### B. The Continue button — 4 variants (the one thing that varies)

Each variant sits at the note-resume card's bottom-right corner using the **same overhang geometry** across all four:

- Trailing edge of the circle flush with the card's trailing edge (unchanged from the pill).
- 42% of the circle's diameter sits above the card's bottom edge; 58% overhangs below it (the pill's 42/58 split, now measured against diameter instead of island height).
- 12pt gutter of dark separation between circle and card frame, produced by the zero-offset separation shadow (not a stroke).
- Shadow stack, identical across all 4: separation (`black @0.40`, radius = gutter+2 = 14pt, 0/0 offset) · ambient (`black @0.55`, radius 10, y+4) · contact (`black @0.40`, radius 3, y+1).
- Rim highlight: `#F5D392 @ 0.35`, 1pt, faded via gradient mask along the top edge (option 2 extends this into a full arc — see below).
- Fill gradient direction: `.topLeading → .bottomTrailing` (not the pill's horizontal `.leading → .trailing` — this is a deliberate synthesis change so the light direction agrees with the top rim highlight and the downward ambient shadow).
- `.accessibilityLabel("Continue reading \(noteTitle)")` applies to every variant (decoupled from visible content, unchanged pattern).
- Hit target: `.contentShape(Circle())`, always ≥ 44×44pt regardless of the 52/56pt visual diameter.

| # | Glyph | Fill treatment | Card join | Diameter | Icon size/weight | Optical offset | What it tests |
|---|---|---|---|---|---|---|---|
| **1** | `play.fill` | Single-tone `#EEAC3F → #C88C2C` gradient fill, glyph `#24170A`, standard top-rim highlight (not extended) | Plain overlap, no notch | 52pt | 20pt, semibold | −1.5pt x (toward leading) | Maximum continuity with today's pill — same material, minimum risk. The control option. |
| **2** | `chevron.right` | Same amber gradient fill, glyph `#24170A`, rim highlight **extended into a gold arc sweep across the top ~140°** of the circle | Plain overlap, no notch | 52pt | 20pt, bold | −1pt x | Navigational read + "lit lamp" quality; the arc rim is a treatment the pill's silhouette could never carry. |
| **3** | `arrow.right` | **Two-tone nested circle**: 56pt outer ring in the amber gradient, 50pt inner circle filled `#24170A`, glyph `#F0AE40` centered in the inner circle | Plain overlap, no notch | 56pt (outer) | 17pt, semibold | none (arrow.right is optically balanced) | Screen-wide vocabulary agreement — structurally identical to `CheckInRow`'s send button and the empty-state's dark-circle/gold-arrow pattern. Inverts the light/dark relationship — the biggest departure of the four. |
| **4** | `play.fill` | Identical to option 1 | **Concave arc scoop** cut into the card's own path at radius = (diameter/2) + 12pt, centered on the circle | 52pt | 20pt, semibold | −1.5pt x | Makes the "notch question" visible — highest fidelity to the prior pill spec's chamfer/notch intent, and the highest build cost of the four. |

**Deliberately excluded, and stated as such on the sheet:** a ghost/outline circle (hairline gold stroke, transparent fill). Two reasons carried from the style brief: (a) the curated before/after reference shows exactly this treatment being *replaced* by a solid fill in a redesign, i.e. evidence pointing the other way; (b) a hairline stroke on this palette fails the 3:1 non-text-UI contrast floor and would read as secondary on a card's only action. State the exclusion in a caption note rather than silently dropping it.

### C. Sheet chrome (captions, numerals, rationale text)
- Numerals: SF Pro Display, bold, 20pt, `#EEAC3F`.
- Captions: SF Pro Text, semibold, 13pt, tracking 0.2, `#F5EAD0` (`Theme.textPrimary`).
- One-line rationale per option: 11pt regular, `#F5EAD0 @ 0.55` (`Theme.textSecondary`) — pull directly from the "What it tests" column above.
- One-line empty-state-reconciliation note per option (see Styling → States below) at the same 11pt secondary weight.
- No emoji, no decorative/display faces — SF Symbols only for any inline glyphs in the chrome itself.

---

## Styling

### Palette — locked across all 4 options, not a per-option variable
| Role | Value |
|---|---|
| Button fill gradient | `#EEAC3F → #C88C2C`, direction `.topLeading → .bottomTrailing` |
| Glyph, light-on-dark options (1, 2, 4) | `#24170A` |
| Rim highlight | `#F5D392 @ 0.35`, 1pt |
| Option 3 inner circle | fill `#24170A`, glyph `#F0AE40` |
| Card surface | `Theme.cardBg` `#221508 @ 0.90` (existing `glassCard`) |
| Page ground (in-frame) | `Theme.bgPage` `#1E1812` |
| Sheet ground (outside frames) | `#151009` |
| Shadow stack | separation `black @0.40, r14, 0/0` · ambient `black @0.55, r10, y4` · contact `black @0.40, r3, y1` |

Verified contrast (non-text UI glyph bar, 3:1 minimum): `#24170A` on `#C88C2C` = 6.05:1 (worst case); `#24170A` on `#EEAC3F` = 8.9:1; `#F0AE40` on `#24170A` = 9.1:1. All four options clear the bar without any palette adjustment. No light-mode variant needed — app is forced dark.

### Typography
Covered under Layout/Components C above — applies only to sheet chrome, since none of the four button variants carries any visible text (that's the point of the redesign).

### Imagery / iconography
All glyphs are SF Symbols, filled or heavy-stroke solid — never mix a hairline glyph against a solid one within the shared treatment. Icon size is 34–38% of circle diameter in all cases (20pt in 52pt = ~38%; 17pt in 56pt-outer/50pt-inner construction = ~34%), matching the two existing circular precedents on this same screen (`CheckInRow`'s 17pt-in-50pt send button, the empty state's 14pt-in-38pt arrow button).

### Sizing / Dynamic Type behavior (documented on the sheet as a caption note, not rendered as a separate state)
`@ScaledMetric(relativeTo: .subheadline) private var diameter = 52`, clamped `52...72`; icon fixed at 38% of resolved diameter; 42/58 overhang split recomputed from the resolved diameter. Within this clamp the circle can never exceed 45% of card width at any accessibility text size, which retires the prior pill spec's §4 full-width-capsule fallback entirely — call this out as a stated implementation win, not just an incidental detail.

---

## States

This deliverable is a static comparison sheet, not an interactive control, so no loading/empty/error chrome is rendered on the sheet itself. Two state-adjacent notes belong in the chrome as one-liners per option (not as separate rendered variants):

1. **Press state (unrendered, documented only):** all four options keep the existing `ContinueIslandButtonStyle` unchanged — scale to 0.96 with one-step fill darkening over 150ms ease-out; Reduce Motion substitutes a brief opacity dip instead of the scale transform. No option changes this; note it in one caption line rather than rendering a fifth "pressed" frame per option (would double the sheet size for a mechanic that isn't in question).
2. **Empty-state reconciliation (unrendered, documented only):** one line per option noting the consequence of picking it — Option 3 makes the populated-state button a scaled sibling of the empty state's existing 38pt dark-circle/gold-arrow button (fully coherent); Options 1, 2, and 4 leave the populated state light-fill/dark-glyph against the empty state's dark-fill/light-glyph, which is a defensible intentional distinction (solid warm fill = resume something existing; recessed dark = start something new) rather than an inconsistency — state the tradeoff, don't resolve it.

No dark/light-mode variant is needed (app is forced dark).

---

## Generation-needed?

**Yes, new visual assets are required — but not via generative image synthesis (OpenArt).** This deliverable's own success criterion is that each option is a token-accurate reproduction of the real app, verifiable against `DashboardComponents.swift`'s actual values — a generative model approximating "an amber circular button on a dark card" would fail that criterion outright (visible in the curated reference material as exactly the kind of drift this pipeline should avoid).

The correct generation path is a **faithful render-and-composite pipeline**, not text-to-image generation:

1. Implement each of the 4 button variants against the existing `NoteResumeCard` / `ContinueIslandShape` construction in `FellowScript/FellowScript/Dashboard/DashboardComponents.swift` (a throwaway/preview-only branch or SwiftUI preview variant is sufficient — this does not need to ship) — a plain `Circle()` clip is simpler than the current custom `CGMutablePath` chamfer-fillet, so this is a strictly easier build than what's already shipped, except for Option 4's concave-scoop card path, which needs new arc/rounded-rect tangency geometry comparable in complexity to the existing chamfer-fillet join.
2. Capture each of the 4 variants as a real on-device or simulator screenshot at `1206 × 2622`, holding frame/scroll/content constant per the Layout section above.
3. Derive each `~420×420` detail crop directly from its full-frame screenshot (a crop, not a re-render).
4. Composite the 4 full frames + 4 crops + captions/rationale text into the single comparison-sheet PNG per the Layout section above — this compositing step (grid arrangement, ground color, caption typography) is standard image-composition/design tooling, not generative synthesis, and should not go through OpenArt either.

If the generation stage's only available tool is OpenArt text-to-image, flag this back rather than proceeding with a generative approximation — a hand-composited render from real screenshots (even a placeholder/mock rendering of the 4 variants using precise coordinate/color overlays on a copy of the reference screenshot, if a live SwiftUI build isn't feasible in this pass) is required to meet the stated success criteria.

---

## Notes carried forward unresolved (informational, not blocking)

- Which option the user ultimately prefers — the deliverable's entire purpose, not something to pre-decide.
- Option 4's concave-scoop card path is unbuilt/unmeasured; flag real geometry work if picked.
- Glyph-collision risk for Option 3 (`arrow.right` also appears as the empty-state affordance and as a note-row disclosure chevron on the same screen) — the Option 3 detail crop must include enough surrounding card/screen context for the user to see and judge this repetition, not just the isolated button.
- The prior `design-spec.md` "revision 4" file referenced by intake is still missing from disk; nothing in this spec depends on it, and its substance was recovered via quotes/comments already cited in the intake and style briefs.
