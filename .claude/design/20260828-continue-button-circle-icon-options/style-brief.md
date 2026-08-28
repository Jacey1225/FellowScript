# Style Brief — Circular "Continue" affordance, option set (note-resume widget, Home dashboard)

Task: `20260828-continue-button-circle-icon-options`
Step 2 — reference synthesis. Media type: **static**.

---

## 1. Media type

**`static`.**

Reasoning: the deliverable is a side-by-side comparison of candidate button treatments so the user can pick one. Nothing in the request, desirables, or success criteria asks for animation, transition, or timing — the button's press animation already exists and is explicitly not in scope. A comparison of four near-identical stills is also the only format where the differences are actually *comparable*; motion would add a second variable and make the set harder, not easier, to judge. Confirming intake's high-confidence hint.

Corroborating signal: `.claude/visual-preferences/motion-references/` is **empty** — the curated library has no motion baseline to synthesize a motion language from even if we wanted one.

---

## 2. Unified style direction

### 2.1 Mood

**Lamplight breaking the frame.** The circle should read as a small warm light source pressed onto the card's corner — not as a floating web-style FAB. It is the one lit, saturated, opaque object on a screen otherwise made of dark frosted glass and low-contrast warm greys, and it earns that emphasis by being the card's only action. Calm and devotional, not energetic; warm and material, not neon. The overhang past the card's frame is the whole point: it says "this continues past here," which is semantically the same thing the icon says.

### 2.2 Palette — locked, carried forward unchanged

Nothing in the request asks to change the color story, and the existing tokens already test well, so these are **fixed constants across every option**, not per-option variables:

| Role | Value | Source |
|---|---|---|
| Fill gradient | `#EEAC3F` → `#C88C2C` | prior pill spec / `DashboardComponents.swift:1016` |
| Glyph (light-on-dark options) | `#24170A` | ibid. `:1013` |
| Rim highlight | `#F5D392` @ `0.35` opacity, `1pt` | ibid. `:1028–1038` |
| Two-tone inner circle (option 3) | `#24170A` fill, `Theme.goldLight` `#F0AE40` glyph | `CheckInRow`, `:384–387` |
| Card surface | existing `glassCard` (`Theme.cardBg` `#221508` @ `0.90`) | unchanged |
| Page ground | `Theme.bgPage` `#1E1812` | unchanged |
| Shadow stack | separation `black 0.40, r = gutter+2 (14), 0/0` · ambient `black 0.55, r10, y4` · contact `black 0.40, r3, y1` | ibid. `:1043–1045` |

Contrast, verified rather than assumed (WCAG relative-luminance, non-text UI glyph bar is 3:1):

- `#24170A` on the *darker* gradient end `#C88C2C` — **6.05:1**. Worst case in the set; clears 4.5:1.
- `#24170A` on `#EEAC3F` — 8.9:1.
- `#F0AE40` on `#24170A` (option 3 inner) — **9.1:1**.

All four options are safe on contrast without touching the palette. The app is force-dark per source comments, so there is no light-mode parity check to run.

**One deliberate palette-adjacent change** (see §3.2): the gradient's *direction*. The pill ran `.leading → .trailing`. On a circle a horizontal gradient has no relationship to the top rim highlight or to the ambient shadow's downward `y: 4` offset, so the light reads as coming from three directions at once. All options use `.topLeading → .bottomTrailing`. Same two colors, coherent single light source.

### 2.3 Typography

There is no type *inside* the button any more — removing it is the request. Typography applies only to the comparison sheet's own chrome, and it should stay in-family so the sheet reads as FellowScript material rather than as a generic design-tool export:

- Option captions: SF Pro Text, semibold, 13pt, tracking `0.2` (matching the button's own former `.subheadline.weight(.semibold)` + `tracking(0.2)`), in `Theme.textPrimary` `#F5EAD0`.
- Option numerals: SF Pro Display, bold, 20pt, in `#EEAC3F`.
- One-line rationale under each caption: 11pt regular, `Theme.textSecondary` (`#F5EAD0` @ 0.55).
- No decorative or display faces. No emoji anywhere (icons are SF Symbols only).

### 2.4 Composition & layout

**The hard rule: exactly one variable moves across the set.** Every frame is the same device, same resolution, same scroll position, same content (the "Romans 8 Study Notes" card), same lighting. Only the button changes. A comparison sheet where two things move is not a comparison.

- **Frame:** iPhone portrait at the reference screenshot's native `1206 × 2622`, matching `/tmp/fellowscript-screenshots4/2CF030F5-…png` exactly. Same status bar, same greeting gradient, same tab bar.
- **Detail crops are mandatory, not optional.** A 52pt circle inside a 2622px-tall frame is roughly 2% of the frame height. At full-device scale the difference between `play.fill` and `chevron.right` is a handful of pixels and the user cannot make the choice the deliverable exists to enable. Each option therefore ships as a **pair**: full device frame + a `~2.5×` crop of the card's bottom-right region (roughly 420 × 420 device px around the button, including enough of the card corner and gutter to judge the overlap).
- **Sheet layout:** 2 × 2 grid of device frames on a near-black `#151009` ground (one step darker than `bgPage` so the frames read as floating objects), 24pt gutters, captions below each frame; the four detail crops in a single row beneath, in matching order, at consistent size. Spacing on the app's own 4 / 8 / 16 / 20 / 24pt grid.
- **Geometry principles for the button itself, translated from the pill spec rather than reinvented:**
  - *Overhang law, preserved proportionally.* The pill's trailing edge sat flush with the card's trailing edge; its top edge was inset 42% of island height above the card's bottom edge, with 58% overhanging below. Keep the same 42 / 58 split, now measured against **diameter**. Trailing edge stays flush. This makes the breach read identically to today's and requires no new invention.
  - *Gutter:* 12pt of dark separation between the circle and the card's own frame, exactly as before, produced by the zero-offset separation shadow.
  - *Diameter:* 52pt baseline. Clears the 44pt floor with real slop (44pt exactly leaves none), and lands between the two circular precedents already on this same screen — the 38pt empty-state circle and the 56pt `CheckInRow` outer ring — so it belongs to that family without duplicating either. Option 3 uses 56pt to match `CheckInRow` exactly, since structural kinship is that option's whole thesis.
  - *Icon size:* 34–38% of diameter, matching the two existing precedents (17pt in a 50pt inner = 34%; 14pt in 38pt = 37%). At 52pt that is a **20pt** SF Symbol at `.semibold`.
  - *Optical centering:* `play.fill` and `chevron.right` are both right-weighted glyphs; mathematically centered, they read as sitting too far right inside a circle. Offset **−1.5pt on x** (toward leading) for the triangle, **−1pt** for the chevron. `arrow.right` is balanced and needs no offset. Easy to omit, visibly wrong when omitted.
  - *Filled/outline discipline:* one style per hierarchy level. All candidate glyphs are **filled or heavy-stroke solid** — no mixing a hairline chevron against a solid triangle within the set's shared treatment.
  - *Hit shape:* `.contentShape(Circle())`. The pill needed `.contentShape(Rectangle())` specifically because its chamfer removed real fill near the top-left corner; a circle removes nothing, so the honest circular hit shape is correct and still ≥ 44pt.

### 2.5 Resolving the two structural gaps intake flagged forward

These are answered here so the spec stage inherits a position rather than an open question.

**How the circle meets the card (intake gap: the chamfer/notch has no circular equivalent).**
Baseline for options 1–3: **plain overlap, no notch.** The prior `design-notes.md` already names the zero-offset separation shadow as the *primary* structural separation cue and the flat hairline as merely secondary — and a 12pt dark halo around a circle over a rounded-rect card is fully legible on its own. A notch keyed to a circle would have to be a **concave arc** subtracted from the card path, which is *harder* to build than the current `CGMutablePath` chamfer-fillet and therefore actively works against the request's stated simplicity motive. Option 4 exists to show the user that possibility anyway rather than silently dropping it, because it is the highest-fidelity reading of the prior spec's intent and they should judge it with their eyes.

**Dynamic Type for an icon-only circle (intake gap: label-measurement mechanism doesn't transfer).**
`@ScaledMetric(relativeTo: .subheadline) private var diameter = 52`, **clamped to `52...72`**, with the icon derived as a fixed 38% of the resolved diameter and the 42/58 overhang recomputed from it. This is a genuine simplification: within that clamp a circle can never exceed 45% of card width at any accessibility text size, which means **the prior spec's §4 full-width-plain-capsule fallback becomes unnecessary and can be deleted.** That is a second concrete implementation win to surface in the options alongside `Circle()` replacing the custom path.

**Press state:** keep the existing `ContinueIslandButtonStyle` unchanged (already reduce-motion-aware); opacity/scale only, no bounds shift, inside the 150–300ms band.

### 2.6 The four options

Every option shares §2.2's palette, §2.4's geometry, the 3-shadow stack, and `.accessibilityLabel("Continue reading \(noteTitle)")` (the existing decoupled-label pattern, which matters more now that there is no visible text at all). What varies is glyph + fill treatment + card join.

| # | Glyph | Fill | Card join | Ø | What it's testing |
|---|---|---|---|---|---|
| 1 | `play.fill`, 20pt semibold, −1.5pt x | single-tone amber gradient, top-rim highlight | plain overlap | 52pt | **Maximum continuity.** Same material as today's pill, minimum risk. The control. |
| 2 | `chevron.right`, 20pt bold, −1pt x | amber gradient, rim highlight extended into a gold arc sweep across the top ~140° | plain overlap | 52pt | **Navigational read + lit-lamp quality.** Lighter, more directional glyph; the arc rim is something the pill's silhouette could never carry. |
| 3 | `arrow.right`, 17pt semibold, `#F0AE40` | two-tone: 56pt amber gradient ring + 50pt `#24170A` inner circle | plain overlap | 56pt | **Screen-wide vocabulary agreement.** Structurally identical to `CheckInRow`'s send button 40pt up the same screen, and value-consistent with the empty state's dark circle + gold arrow. Inverts light/dark relationship — the biggest departure of the four. |
| 4 | `play.fill`, as option 1 | as option 1 | **concave arc scoop** cut into the card at radius Ø/2 + 12pt | 52pt | **The notch question, made visible.** Highest fidelity to the prior spec's intent, highest build cost. |

**Deliberately excluded from the set, and why the exclusion should be stated rather than silent:** an outlined / ghost circle (hairline gold stroke, transparent or near-transparent fill). Two independent reasons. (a) The curated before/after reference `before-after-comparisons/f7b734b1608e5c186ce9c0a0b176a96c.webp` shows exactly this — an outlined circular arrow-right CTA on a dark screen — being *replaced* by a solid filled CTA in the redesign half. (b) A `#D4922A`-family hairline on a dark card over a near-black page does not clear the 3:1 non-text-UI contrast bar and reads as secondary, which is wrong for a card's only action. Offering it would spend one of four slots on an option we'd then have to argue against.

**Empty-state reconciliation (intake gap, unraised by the user):** worth a one-line note per option in the sheet rather than a resolution. If the user picks option 3, the empty state's 38pt dark-circle-plus-gold-arrow becomes a smaller sibling of the same construction — fully coherent. If they pick 1, 2, or 4, the populated state is light-fill/dark-glyph while the empty state is dark-fill/light-glyph on the same widget in different states — which is arguably a *useful* distinction (solid warm fill = resume something that exists; recessed dark = start something new), not an inconsistency. Surface the tradeoff; don't decide it for them.

---

## 3. Synthesis rationale

Multiple references, attached and curated. This is a combine-what-they-share case, not a pick-a-favorite case.

### 3.1 What came from where

**Attached — current shipped screenshot** (`/tmp/fellowscript-screenshots4/2CF030F5-4CCD-432A-A7AC-FDD8206F6F8E.png`, viewed directly): the baseline mood ("one saturated warm object on a screen of dark frosted glass"), the exact frame/resolution/scroll position every option must reproduce, and confirmation that the amber pill is currently the *only* fully-opaque saturated element in the note-resume region — which is why §2.1 treats the circle as a light source rather than a generic button.

**Attached — prior pipeline artifacts** (`.claude/pipeline/20260827-continue-island-shape-refinement/intake-spec.md` + `design-notes.md`): the palette table in §2.2 verbatim, the 3-shadow stack, the 12pt gutter, the 4/8/16/20pt grid, and critically the **42/58 overhang split** that §2.4 reuses proportionally against diameter. Also `design-notes.md`'s stated hierarchy — separation shadow primary, hairline secondary — which is the load-bearing argument in §2.5 for why a circle needs no notch.

**Attached — source of truth** (`FellowScript/Dashboard/DashboardComponents.swift`, read at `:370–394`, `:1003–1074`, `:1090–1098`): exact token values and the two circular precedents that gave options 1–3 their sizing band (38pt / 50pt inner / 56pt outer) and gave option 3 its entire construction. Also the `.contentShape(Rectangle())` comment at `:1048–1051` that explains why a circle can honestly use `.contentShape(Circle())` instead.

**Curated — `widgets-dashboard-ui/original-a1de8333c29ebbcc147961ea8fd8ab86.webp`** (opened and upscaled to inspect). The single most directly relevant thing in the whole library: a grid of dark charcoal cards on near-black, with **warm amber circular icon buttons that breach card edges** — one orange circle with a filled play triangle sitting half-on/half-off a card's edge, and an amber card with a dark inner circle holding a light pause glyph. It independently validates three decisions that would otherwise be assertions: that a circle overhanging a dark card needs no notch to read as detached, that a **filled play triangle** is the natural glyph for this exact shape/placement, and that the **two-tone dark-inner-circle** treatment (option 3) is a real member of this visual family rather than a `CheckInRow` one-off.

**Curated — `widgets-dashboard-ui/original-82b43302403ccdd24262aad5e612ea80.webp`** (opened and upscaled). Warm amber-on-dark-glass dashboard with frosted cards and circular icon buttons — the closest palette-and-material sibling to FellowScript in the library. Its glowing **gold arc rim** around a circular element is where **option 2's arc-sweep rim** comes from: it's the honest circular translation of the pill's "top-rim highlight faded via a gradient mask," and it demonstrates the technique working at exactly this scale on exactly this ground. It also shows small dark-glass circular icon buttons riding card edges with faint rims, reinforcing §2.5's plain-overlap position.

**Curated — `widgets-dashboard-ui/827660df4f4cdd6dab949cdcf48ed3e9.webp`** and its thumbnail sibling **`f3cd6ba56b8772f3fd12eb5fd059850f.webp`** (both opened). Dark widget galleries where amber/orange radial glow is consistently used as the *active/energy* accent against near-black. Weight: confirms the taste baseline's warm-glow-on-black preference and that amber earns emphasis rather than merely decorating — supports keeping the fill saturated and opaque instead of glassifying it.

**Curated — `before-after-comparisons/f7b734b1608e5c186ce9c0a0b176a96c.webp`** (opened). Used as **negative** evidence, cited in §2.6: an outlined circular arrow-right CTA on a dark onboarding screen shown in the "Original Design" half, replaced by a solid filled CTA in "Redesigned." This is why the ghost-circle variant is excluded rather than offered.

**Curated — checked and mostly excluded: `mobile-app-screens/`.** Opened `73a4d07e…`, `original-3759e6eb…`, `original-7599502b…`, `9b540707…`. These are predominantly cool-toned (blue/purple/lime) and carry no palette kinship with FellowScript's warm amber-on-dark. One tertiary observation retained: `original-3759e6eb…` puts a solid circular icon button at a card's corner as that card's primary action, corroborating the placement pattern independently of palette. Nothing else from this folder is folded in. `motion-references/` is empty. Stating this rather than pulling the folders in wholesale.

### 3.2 Where the synthesis went beyond any single reference

Three decisions are mine, derived from combining the above rather than copied from any one of them, and each is stated as a choice so it can be argued with:

1. **Gradient direction changed from horizontal to `.topLeading → .bottomTrailing`.** The pill's `.leading → .trailing` had no meaning on a circle and contradicted the top rim highlight and the downward ambient shadow. Every circular button in both curated references is lit from above. Same two hex values; coherent single light source.
2. **Detail crops promoted to a mandatory part of the deliverable.** Derived from the arithmetic in §2.4, not from a reference. Without them the set does not do the job intake defined for it.
3. **The §4 full-width-capsule fallback is retired.** Falls out of the clamped `@ScaledMetric` diameter and is a genuine simplification win the request's own framing ("a circle is generally simpler") invited but didn't anticipate.

---

## 4. Carried-forward gaps

**Resolved here (spec stage should inherit these positions, not re-open them):**
- Number of options → **4**, per the matrix in §2.6.
- Icon candidates → all three the user named appear (`play.fill`, `chevron.right`, `arrow.right`); no fourth glyph invented.
- Circle diameter / sizing logic → 52pt baseline (56pt for option 3), `@ScaledMetric` clamped `52...72`.
- Icon size and weight → 34–38% of diameter, filled/heavy only, with per-glyph optical x-offsets.
- How the circle meets the card → plain overlap for 1–3, concave scoop shown as option 4.
- Dynamic Type mechanism → clamped `@ScaledMetric`; §4 capsule fallback retired.
- Screenshot dimensions → `1206 × 2622`, matching the reference frame exactly, plus `~2.5×` detail crops.
- Whether the rim highlight and 3-shadow stack carry over → yes, unchanged, on all four (option 2 additionally extends the rim into an arc).

**Still open, carried forward:**
- **Which option wins.** By design — this is the deliverable's purpose, not a defect.
- **Empty-state reconciliation** (§2.6). Genuinely undecidable until the user picks; only option 3 resolves it automatically. Needs a one-line note per option in the sheet so the user sees the consequence at choice time.
- **Prior `design-spec.md` revision 4 is still missing from disk.** Its substance was recovered via quotes and code comments and nothing in this brief depends on the missing file, but the documentation gap persists into any follow-up `/build` pass.
- **Option 4's concave-scoop card path is unbuilt and unmeasured.** Its build cost is asserted from reading the existing `ContinueIslandShape` construction, not from having written it. If the user picks 4, the follow-up `/build` pass should expect real geometry work at the arc/rounded-rect join — the same class of tangency problem the chamfer-fillet already needed.
- **Newly surfaced by synthesis:** with `arrow.right` (option 3) also appearing in the empty-state card and as the note-row disclosure chevron `:` at the top of the screen, there is a mild risk of **glyph collision** — the same arrow doing three jobs on one screen. Not enough to drop option 3 (its whole point is kinship), but the spec stage should make sure the detail crop for option 3 includes enough surrounding context that the user can see the repetition and judge it.
- **Rendering approach for the option set is unspecified.** These need to be real screenshots of the app per the success criteria, not AI-generated approximations of it — a token-accurate re-render is the only way "consistent with the existing visual language" is verifiable. Flagging for the generation stage, since a generative image path would fail this deliverable's core criterion.
