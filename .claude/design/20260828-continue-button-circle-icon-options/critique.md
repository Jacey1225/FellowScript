# Critique — Circular "Continue" affordance, option comparison sheet

Task: `20260828-continue-button-circle-icon-options`
Step 5 — critique, **pass 3 (final)**. Bounce cap of 2 was already spent before this pass began (`loop-count.json` → `critique: 2`, `critique_note`), so per the pipeline's own rule this pass records a **pass regardless of residual issues**, with `escalate: true` so the orchestrator surfaces them to the user instead of looping.

Reviewed: `intake-brief.md`, `style-brief.md`, `design-spec.md`, `generation.json`, and all 12 rendered PNGs under `assets/`. Deliverable is a static image set, not a live page — no browser review applies, and generation correctly bypassed OpenArt (`openart_used: false`, per `design-spec.md`'s "Generation-needed?" section), so there is no `historyId` to open. Everything below was measured in pixels on the actual renders, not judged by eye alone.

---

## Verdict

**Pass — with escalation.** The deliverable does the job intake defined for it: five real, app-rendered options a user can compare and choose from, all faithful to the locked palette, all buildable because they were literally built. Every blocking fault from bounce 2 is genuinely fixed and independently verified here.

Four residual issues remain, none blocking, one of them material enough that the user should know about it before choosing: **the detail crops clip the top ~26% of the button**, which removes the bright core of option 2's gold arc entirely and most of option 4's scoop — i.e. exactly the two features those options exist to test. The full device frames still show both correctly, so the set is usable; but the crop row, which `style-brief.md` §2.4 made mandatory precisely because the frames are too small, under-serves two of the five panels.

Escalating rather than bouncing, per the cap.

---

## What works

Verified, not assumed.

**The notch is genuinely gone — the blocking fault from bounce 2 is fixed.** Sampling the card's own boundary across x on `variant1/2/3/3b_full.png`: the card's bottom edge sits **flat at y=1809 from x=600 all the way out to x=930**, with the 1 pt hairline at y=1810 and the page ground reached by y=1840. There is no chamfered cut, no diagonal, no early boundary at y≈1782. Bounce 2's `NotchedCardMaterial`/`useNotch: true` leftover is verifiably absent, and `generation.json` root-caused it correctly rather than patching the symptom.

**The breach is now real and measures to spec.** Amber disc bounding boxes: options 1/2 `x 990–1145, y 1747–1902` = **156 × 156 px = 52 pt exactly**; options 3/3b `168 × 168 px = 56 pt exactly`; option 4 `156 × 156`. Against the card's true bottom edge (y≈1810.5, allowing for the rim highlight's cream pixels falling outside a strict amber test), **~64 px of the 156 px diameter sits above the card edge = 41–42%**, with 58% overhanging — the pill's 42/58 overhang law, correctly translated to diameter. Trailing edges are flush at x=1145 for every variant. `variant3_context.png` shows this unambiguously at native scale: a flat, unbroken card edge with the button clearly sitting on top of it.

**Single-variable discipline holds across 1/2/3/3b.** A pixel diff of each variant against `variant1_full.png` returns bounding boxes confined to the button region only — `variant2` differs solely within `(903, 1650)–(1206, 1994)`, `variant3` and `variant3b` within `(870, 1642)–(1206, 2011)`. Status bar, greeting gradient, `FriendActivityHeroCard`'s relative-date label, card copy, tab bar: byte-identical. Capturing all five in one 42-second XCUITest session was the right call and it demonstrably worked.

**Option 2's `.strokeBorder` fix is exact.** Sweeping the outer silhouette radius every 15° around the circle, option 2 matches option 1 at *every* angle (77.6–78.6 px on both). The arc's own bright pixels run r=72→77, entirely inside the r=78 fill edge. Zero bleed, zero silhouette difference, no encroachment into the 12 pt gutter. Bounce 2's issue 2 is closed.

**Option 2's gradient fade is real and correctly oriented.** Angular delta profile against option 1 at r=75: full brightness `(245, 217, 164)` holds from −45° to +45°, then ramps smoothly down through −55°/+55° (delta 79/76) and −65°/+65° (35/31) to noise by ±70°. That is a ~90° full-bright core with a ~25° ramp at each end, ~140° total, **centred on the top** — which is what §2.2's "faded via a gradient mask" asks for. `generation.json` disclosing the angle-convention false start (AngularGradient's 0° is at the right, not the top) rather than hiding it is the right behaviour.

**The footer correction landed.** The locked-token block now reads "Rim highlight: options 1 and 4 keep the standard #F5D392 @0.35, 1pt top-fade rim. Option 2 is the one exception… #FBE8C0 @0.8, 2pt arc, drawn with .strokeBorder…" and the card-join paragraph now describes the plain-card fix accurately. Bounce 2's issues 1(d) and 6 are both closed.

**Option 3's honesty survived, and 3b was actually produced.** Re-measured independently: option 3's inner fill is `(36, 23, 10)` = **1.01:1** against page ground `#1E1812`; option 3b's is `(139, 91, 48)` = **3.04:1**. Both numbers on the sheet are correct as stated. Generation did not silently recolour the locked token — it stated the measurement and offered a mitigated sibling, which is the right editorial call.

**Glyph contrast clears every bar.** Measured on the renders rather than from the token table: `#24170A` glyph against the fill at the darkest sampled point = **6.37:1** (option 1), **6.52:1** (option 2), **6.37:1** (option 4). Option 3's `#F0AE40` on `#24170A` = **9.01:1**. All well past the 3:1 non-text-UI floor and past 4.5:1 too.

**Touch target and accessibility carry.** 52 pt / 56 pt diameters clear the 44 × 44 pt floor with real slop, `.contentShape(Circle())` is honest for a circle, and the icon-only button keeps `.accessibilityLabel("Continue reading \(noteTitle)")` — which is the specific thing `ui-ux-pro-max`'s priority-1 row flags as the anti-pattern for icon-only buttons ("Icon-only buttons without labels"). The set does not fall into it.

**Every intake desirable is satisfied.** Circle ✓. Icon not text ✓. Bottom-right placement ✓. Overlay/breach preserved and now verifiably visible ✓. Warm amber-on-dark continuity ✓ (palette locked, nothing drifted). 44 pt floor ✓. Dynamic Type addressed via clamped `@ScaledMetric` and documented on the sheet ✓. All three user-named glyph candidates present ✓. Multi-option, real rendered screenshots ✓. Realistic implementability — the strongest possible evidence, since each option was compiled and captured from the actual app rather than approximated.

**Source hygiene, third time.** `DashboardComponents.swift` restored from a pre-edit backup and verified byte-identical by MD5 and direct diff, `_TempScreenshotTest.swift` deleted, repo-wide grep for `CONTINUE_VARIANT` returns zero, and a clean production build confirmed afterward.

---

## Issues found (residual — recorded, not bounced)

### 1. The detail crops clip the top ~26% of the button, which removes option 2's arc core and most of option 4's scoop (material)

`style-brief.md` §2.4 makes detail crops **mandatory**, with an explicit reason: at full-device scale "the difference between `play.fill` and `chevron.right` is a handful of pixels and the user cannot make the choice the deliverable exists to enable." The crop row is therefore where the comparison actually happens. It is mis-framed.

Measured on `variant1_crop.png` (280 × 230 native): the disc's widest amber row is at crop y=40, and the disc is 156 px across, so **the disc's top edge falls at crop y = −38** — roughly 40 px (13 pt, ~26% of the button) is cut off above the crop's top boundary. The card's bottom edge lands at **crop y≈23 of 230 = 10% of crop height**; bounce 1's fix had certified this at 43%, so this is a regression on a dimension a previous pass had already corrected.

Consequences, in order of severity:

- **Option 2's arc is effectively absent from its own detail crop.** The arc's full-brightness core spans ±45° around the top, which lands between crop y=−38 and y=−15 — entirely above the frame. Counting pixels matching the arc's measured colour in `variant2_crop.png` returns **zero**. Only the two faded tips survive. A pixel diff of `variant1_crop` vs `variant2_crop` shows 1,455 pixels differing by >60, and they are dominated by the glyph swap, not the arc. The user comparing crop 1 against crop 2 is being shown a chevron-vs-triangle choice, not the arc treatment that is option 2's stated thesis.
- **Option 4's scoop reads as a faint curve in the corner, not "a clean, deliberate bay."** The scoop's arc (radius 114 px = (52/2)+12 pt, centred on the button — geometry verified: predicted scoop top y=1782.5 at x=1060, measured 1784) wraps the button's upper-left, which is the clipped region. `generation.json`'s description of this crop overstates what it shows.
- **The overlap mechanic can't be judged from the crops.** With only 23 px of card material above the button and the button's top edge outside the frame, the 12 pt gutter and the breach — the one thing intake said must not change — are visible in the full frames and in `variant3_context.png`, but not in the crop row.

Root cause is arithmetic and checkable: `generation.json` states the crop top was "set 30px below the note's measured body-copy bottom (y=1749)" → crop top ≈ y=1779–1787, while the button's top edge is at y=1747. The crop box was optimised for not clipping text and never checked against the button.

**Fix:** raise the shared crop box top to ~y=1700 (≈47 px above the button's top edge, giving the full 12 pt gutter plus a band of card material) and grow the box to ~280 × 290 so the card's bottom edge lands near 35–40% of crop height. Verify afterward by confirming the amber bbox's `miny` is strictly greater than 0 in every crop, and that `variant2_crop.png` contains a contiguous band of the arc's full-brightness colour.

### 2. The sheet wastes ~39% of its canvas, and the device frames shrank from the previous pass (real, cosmetic)

The sheet is 2050 × 3867. The 2 × 2 frame grid occupies **x = 40–987 only** (two 460 px frames, 28 px gutter), and the "option 3 in context" block occupies x = 40–1186. Only the five-across crop row uses the full width (x = 40–2009). Everything to the right of x≈990 is empty ground for roughly 3,000 px of vertical run — about **39% of the sheet's area is dead space**, and it is dead space with content hard against the left edge, so the sheet reads as unbalanced rather than as deliberately airy.

It also costs the deliverable something concrete: frames went from **584 px wide in the bounce-1 sheet to 460 px here** (−21%), putting the Continue button at 59 px on the sheet. Bounce 1 explicitly treated enlarging the frames as the fix that made "the button differences readable in the frames themselves." That gain was partly given back.

**Fix:** lay the four device frames out as a **single row of four** across the full 2050 px width (≈474 px each at 24 pt gutters) directly above the five crops, in matching reading order. This eliminates the dead column entirely, keeps frame size, cuts sheet height from ~3867 to ~2600, and puts each frame vertically above its own crop. Alternatively, narrow the canvas to ~1030 px and wrap the crop row 3 + 2.

### 3. Option 3b fixes the body's contrast by destroying the two-tone read and the glyph's contrast — and the sheet doesn't say so (real)

3b's inner fill at **3.04:1** against page ground is exactly what the previous pass asked for, and it's stated honestly. But two ratios that were fine in option 3 are not fine in 3b, and neither is measured on the sheet:

| Relationship | Option 3 | Option 3b |
|---|---|---|
| Glyph `#F0AE40` vs inner fill | **9.01:1** | **2.98:1** — *below the 3:1 non-text-UI floor* |
| Outer ring vs inner fill | **5.99:1** | **1.98:1** |

So 3b buys a legible body at the price of a glyph that fails the same contrast bar the sheet uses to justify excluding the ghost-circle variant, and a ring/inner separation so weak that the "two-tone nested circle" construction — option 3's entire thesis, its structural kinship with `CheckInRow` — collapses into what reads as a single muddy-brown disc. This is visible in the crop row: 3b looks like a dirty version of option 1, not like a sibling of the send button.

The previous pass offered three mitigations ("lift the inner fill… **or** thicken the ring to 5–6 pt, **or** add a faint inner amber glow — one of the three, not all"). Lifting the fill alone was the one that most directly attacks the ring/glyph relationship.

**Fix:** re-render 3b with the inner fill lifted only to ~`#3A2410` (≈1.9:1 vs ground, still short) **combined with** a 5–6 pt ring and a 1 pt inner rim highlight, so the object reads as solid via its edge rather than via its field — or keep `#8C5C30` but switch the glyph to `#24170A` (which would measure ≈4.9:1 against it) and accept the light/dark inversion. Either way, state the achieved glyph-vs-fill and ring-vs-fill ratios on the sheet next to the existing 3.04:1, so the user sees the whole trade rather than half of it.

### 4. Option 4's card is 25 pt taller than every other option's, so two variables move in that panel (real, partially unavoidable)

`style-brief.md` §2.4's hard rule: "exactly one variable moves across the set." Measured at x=300: options 1/2/3/3b all share a card spanning y 1527–1809 (283 px); **option 4's card spans y 1526–1882 (357 px)** — 74 px ≈ 25 pt taller. Card top and all body copy are identical (text rows 1432–1755 in both), so the growth is bottom padding only, and it carries the button down with it (disc at y 1819–1974 vs 1747–1902). Each card keeps its own correct 42/58 split, so nothing is *wrong* internally; but in the 2 × 2 grid, option 4's panel differs from its neighbours in card height and button position as well as in card join.

`generation.json` discloses this and justifies it as needed "to clear the scoop near the note text," which is plausible in SwiftUI terms (padding resolves against the text block's full-width frame, not its rendered glyphs). Worth noting the visual check goes the other way: the note's second line ends near x≈560, while the scoop's arc never reaches left of x≈953 at any y above the card's bottom, so a shared card height would likely not have collided in practice.

**Fix:** re-render option 4 with the same card height as 1/2/3/3b (shallower bottom padding, scoop centred on the unchanged button position at y=1824.5), and verify the note text is uncollided. If a real collision does appear, keep the taller card but say so in option 4's own caption — right now the caption attributes the whole visual difference to the scoop.

### 5. The footer heading says "all 4 options" on a sheet that now has five panels (trivial)

"Locked tokens (all 4 options unless noted)" and "Shadow stack, identical across all 4" predate 3b's addition. 3b is correctly framed elsewhere as a comparison aid rather than a fifth co-equal option, but the token block should say "all options" or name 3b explicitly.

### 6. Option 4's scoop still meets the card's bottom edge in an unfilleted cusp (unchanged, out of scope)

Carried forward from bounce 1 and bounce 2 unchanged, and correctly left alone. Belongs to the follow-up `/build` pass if the user picks option 4.

---

## Proposed fixes — priority order for any follow-up pass

All generation-side; the spec needs no revision.

1. **Re-cut the detail crops** with the top at ~y=1700 and a ~280 × 290 box, then verify amber `miny > 0` in all five and a contiguous full-brightness arc band in crop 2. *(Issue 1 — highest value: it restores the comparison the crop row exists to enable.)*
2. **Re-lay the sheet** as one row of four frames above the crop row, killing the dead right column. *(Issue 2.)*
3. **Re-render 3b** with ring-weight plus rim rather than fill-lift alone, and publish all three of its contrast ratios. *(Issue 3.)*
4. **Equalise option 4's card height** or caption the difference. *(Issue 4.)*
5. **Amend the footer heading** to cover five panels. *(Issue 5.)*

Not for fixing: issue 6's fillet.

---

## Residual issues carried to the user (why `escalate: true`)

The bounce cap is spent, so these ship as-is. Stated plainly rather than glossed:

- **Options 2 and 4 are under-represented in the detail-crop row.** Judge those two from their full device frames and from `variant3_context.png`, not from crops 2 and 5. This is the one residual that could actually skew a choice.
- **Option 3b is not yet a fair test of the two-tone idea.** Its body is legible but its glyph (2.98:1) and its ring/inner separation (1.98:1) are worse than option 3's. Treat the 3 ↔ 3b pair as bracketing a trade, not as one good and one bad answer.
- **Option 4's panel carries a taller card**, so part of what distinguishes it visually is padding, not the scoop.
- **The sheet is compositionally left-heavy** with ~39% empty canvas, and its frames are smaller than the previous revision's.
- **Which option wins stays open by design** — that is the deliverable's purpose.
- **Empty-state reconciliation stays open**, correctly documented per option in the sheet chrome.
- **Option 3's 1.01:1 inner fill against the page ground** is a genuine property of `design-spec.md`'s own locked `#24170A` / `#1E1812` pairing at this geometry, not an implementation slip. It remains stated rather than silently recoloured.
- **Option 4's build cost is real** — arc/rounded-rect tangency plus the unfilleted cusp — and lands on the follow-up `/build` pass if chosen.
- **The prior `design-spec.md` "revision 4" is still missing from disk.** Nothing in this pass depends on it; the documentation gap follows any `/build` pass forward.

---

## Bounce accounting

`loop-count.json` → `critique: 2` (cap), `escalate: true`. This pass records **pass** per the cap rule. Nothing found here would have justified a third bounce on its own: the deliverable satisfies every desirable in `intake-brief.md` and holds to `style-brief.md`'s locked palette, geometry law, and single-variable rule everywhere except option 4's card height. The residuals above are refinements the user can weigh at choice time, and the crop-framing fix is a ten-minute re-cut if they want it before deciding.
