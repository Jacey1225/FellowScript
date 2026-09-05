# Critique — Download Section (20260902-download-section) — pass 3 (final)

Reviewed against `intake-brief.md` (desirables + success criteria), `style-brief.md`
(style direction), `design-spec.md` v3, and the artifacts recorded in
`generation.json`.

**This is the third critique pass. The internal bounce cap (2) is spent, so this
pass closes the pipeline regardless.** Per that rule, the residual issues in §4
below are stated honestly rather than used to bounce — they are all minor and
none of them blocks a `/build` pass, but they are real and `escalate: true` is
set in `loop-count.json` so the orchestrator surfaces them to Jacey rather than
letting them pass silently.

## How this pass was reviewed

Not by re-reading the spec's own claims. The deliverable is a coded HTML preview,
so it was served over `http://localhost` and loaded in a real browser:

- `preview.html` at 1440×1000 and 390×900 — accessibility tree captured with
  bounding boxes, console checked.
- `preview-context.html` at 1440×1000 — the new in-context render with the real
  Pricing section above and the real Closing CTA below.
- `preview-1440.png`, `preview-390.png`, `preview-context-1440.png` viewed
  directly, and card surfaces sampled pixel-by-pixel with PIL.
- `frontend/src/pages/Home.jsx` read directly to check the new section's section
  rhythm against the page's existing precedent.
- `ui-ux-pro-max` queried for the contrast, touch-spacing, and disabled-state
  guidelines the section leans on.

Console was clean apart from a `favicon.ico` 404, which is a harness artifact of
serving a bare HTML file, not a fault in the design.

---

## 1. Verdict

**Pass.** This holds up and is ready to hand to `/build`.

All three faults raised in critique pass 2 are confirmed fixed **by measurement,
not by assertion**:

1. **Surface hierarchy inversion — fixed, provably.** Sampled directly from
   `preview-1440.png`: section `INK` = `rgb(23,18,15)`, Windows card =
   `rgb(29,25,21)`, macOS card = `rgb(36,30,27)`. The ordering is now correct on
   every channel and lands within 1/255 of the arithmetic table in spec §5. The
   macOS card reads as unambiguously the brighter, primary path at 1440px and at
   390px. The v2 inversion is gone.
2. **Invented "macOS 12+" copy — fixed.** The metadata line renders the literal
   `macOS ⟨MIN VERSION — TBC⟩` in both the isolated and in-context renders. It is
   visibly unresolved and cannot be mistaken for a settled product claim sitting
   next to the two facts that *are* verified ("Apple silicon & Intel", "3 MB").
3. **Untestable adjacency claims — fixed.** `preview-context-1440.png` and the
   live in-context render show both claims actually landing. The light→dark seam
   at the Pricing boundary is a clean flat transition. The Download section's
   quiet top-right orb and the Closing CTA's much larger centered bloom read as a
   deliberate glow-then-bloom sequence, not two competing smudges.

Everything the style brief called non-negotiable survives into the render, and
every intake desirable is satisfied. Two decisions and two blocking placeholders
need Jacey's or `/build`'s input — none of them are design faults.

---

## 2. What works

**The hierarchy is now built on one comparable scale, and it shows.** The
underlying fix — putting both card surfaces on a single additive
`rgba(255,244,230, α)` tint against `INK` rather than mixing an additive tint
with a subtractive one — is the right structural fix, not a nudge. The spec
carries the per-channel arithmetic so `/build` can re-derive it, and §13 item 7
explicitly warns against re-tuning either card in isolation. That's the kind of
note that prevents the same bug returning six months later.

**The Windows "not available" treatment is genuinely better than the
conventional answer.** `ui-ux-pro-max`'s own disabled-state guideline defaults to
`opacity-50 cursor-not-allowed`. This design rejects that and removes the control
entirely, and the accessibility tree proves it: the Windows card contains zero
focusable nodes, no `role="button"`, no `aria-disabled` theater. A screen reader
encounters descriptive content and moves on; a keyboard user never lands on a
dead target. Meanwhile the card is visually complete rather than looking broken.
This is the strongest single decision in the whole section.

**Dimming is confined to chrome, and contrast holds under measurement.** The
metadata line at `rgba(255,243,228,0.58)` over the brightened macOS surface
computes to **5.94:1** — comfortably clear of the 4.5:1 AA floor, and higher
still on the darker Windows surface. Body copy sits at `0.66`–`0.7` throughout
*both* cards, with no blanket opacity anywhere. The eyebrow `AMBER` on `INK`
measures ~7.7:1. The temptation to "make Windows look more disabled" by dimming
its text was explicitly resisted and the spec forbids it in three places.

**Cross-card baseline alignment is exact.** Measured from the accessibility tree
at both widths: at 1440px both action rows sit at y≈706/707 and both metadata
rows at y=776; at 390px both action rows sit 260px from their own card's top.
The two-trailing-row restructure did what it was meant to do — the cards land as
a genuinely matched pair rather than one drifting below the other.

**Touch and interaction floors clear.** The macOS button measures 51px tall at
both 1440px and 390px (>44px), card gap is ≥20px (>8px minimum), and the button
has an accessible name of "Download for Mac" with the `↓` correctly
`aria-hidden`. Heading structure is right: one `h2` for the section, one `h3` per
card.

**The atmosphere restraint works in context.** The orb clears the card row by
~120px at 1440×1000 and stays clear at short and tall viewports. In the
in-context render it reads as a hint at the top-right edge, and the Closing CTA's
bloom is visibly the brighter, larger event below it. "Download glows, Closing
CTA blooms" is not just a phrase in the brief — it's visible in the render.

**Copy is honest and warm, which is what the brief asked for.** "Still in the
workshop" / "We started on macOS. The Windows build is on the way." / "We'll post
it here first — no signup needed." — no ETA it can't keep, no apology, no
technical placeholder. The sub copy claims a dedicated window and nothing more,
which is exactly what the Tauri app actually does. Nothing here oversells.

**The section is indistinguishable from an original design pass.** This was the
top success criterion, and the in-context render is the evidence: eyebrow rule,
two-tone headline, pricing-grid geometry, badge-top-right slot, pill button —
every element traces to a line in `Home.jsx`.

---

## 3. Issues found

None blocking. Two items below are concrete faults that should be fixed at
`/build` time; they are small enough that bouncing the whole pipeline for them
would be chasing perfection, and the bounce cap is spent regardless.

### Issue A — the Windows action row has a 24px orphan indent that breaks the card's left rail (minor, concrete)

**Confirmed three ways:** visible in `preview-390.png` and `preview-1440.png`, in
the accessibility tree's bounding boxes, and in `preview.html` line 190.

The Windows action slot copies the macOS button's full `padding: 16px 24px` in
order to match its height and keep the cross-card baseline locked. That works for
the height — but the 24px of *horizontal* padding is inherited too, and unlike
the macOS button it isn't carrying a filled pill. So the plain text "Windows 10 &
11" starts 24px to the right of everything else in its card.

The result is three different left edges inside one card:

| Element | Left edge (390px render) |
|---|---|
| Icon badge, "WINDOWS", "Still in the workshop", description | x = 55 |
| "Windows 10 & 11" | **x = 79** |
| "We'll post it here first…" | centered |

The macOS card has no equivalent problem: everything starts at x=55, and its two
centered elements (the button label and the metadata) are centered *within
full-width elements that themselves sit on the rail*, which is a coherent
treatment. The Windows card's action row is the only element in the section that
sits on no rail at all.

This violates the spec's own stated intent for the v3 fix — §6 changed this row
to left-aligned specifically so it would "match the card's own title and
description alignment above it," and the 24px horizontal padding is what stops
that from actually happening. It is most visible at 390px, where the card is
narrow and the indent is a large fraction of the text width.

### Issue B — the Windows card's centered metadata line has nothing above it justifying the centering (minor, same root cause)

On the macOS card, the centered metadata reads as a caption under a full-width
pill button — centering is earned by the element above it. On the Windows card
the same centered treatment sits under a left-ish text line, so it introduces a
third alignment axis rather than echoing a second one. This is a smaller version
of Issue A and shares its fix; it only becomes clearly visible once Issue A is
corrected and the rail above it snaps back to x=55.

---

## 4. Residual items carried forward honestly (not faults, but Jacey should see them)

These are not defects. They are open decisions and known unknowns that this
pipeline deliberately did not close, and they are the reason `escalate: true` is
set — so they reach Jacey rather than being absorbed silently.

**1. Two blocking placeholders remain unfilled, by design.**
`MACOS_DOWNLOAD_URL` (the `.dmg` currently exists only at a local build path and
needs real hosting — GitHub Releases, CDN, or a backend route) and
`MIN_MACOS_VERSION` (`tauri.conf.json` sets no `minimumSystemVersion` at all;
Tauri's framework default of 10.13 is an unset value, not a product decision).
The spec correctly refuses to invent either. Both must be sourced at `/build`
time; the section cannot function without the first.

**2. The doubled dark run is a judgment call the style brief itself flagged for
review.** The in-context render shows it reading fine — but the gap between the
Download card row and the Closing CTA's blockquote measures **280px of
uninterrupted dark** at 1440×1000. For comparison, the page's *only existing*
dark→dark seam (Hero → "How it feels day to day") runs about 180px at the same
viewport, and the section after it opens immediately with an eyebrow + rule to
re-anchor the eye. The Closing CTA has no eyebrow — it opens straight into a
centered blockquote 280px down.

In practice the Closing CTA's bloom rises into the upper part of that gap and
fills it, which is why it doesn't read as a void in the render, and Q8's
preference for generous breathing room cuts in its favor. So this is a watch
item, not a fault. If Jacey reads it as too long at review, the one-line fix is
to give the Download section an asymmetric bottom padding —
`padding: clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px) clamp(60px, 9vh, 120px)` —
which pulls the seam to ~220px without touching any other section.

**3. The Apple mark is a documented departure from an intake desirable.** Intake
expected platform icons as stroke-based `Ico`-style line icons
(`strokeWidth="1.6"`); the style brief and spec deliberately use filled glyphs
instead, arguing that outlined brand marks read as counterfeit. That argument is
correct and the glyph renders cleanly in every viewport checked (the v1 clipping
bug is definitively gone). But it *is* a stated desirable overridden by the
design, so Jacey should get to veto it rather than have it slip through. Related:
spec §7 recommends `/build` source the path from a maintained icon package
(`simple-icons`' `siApple`) rather than the hand-authored path — worth taking,
since a hand-transcribed path is exactly what broke in v1.

**4. The macOS metadata line wraps to two lines at 390px.** Currently that's the
long placeholder text. With a real value it will read roughly "Apple silicon &
Intel · 3 MB · macOS 12 or later" — still likely to wrap on a narrow phone. Not
worth pre-solving; if it looks cramped once the real string is known, dropping to
"Apple silicon & Intel · 3 MB" and moving the OS floor into the card description
is the clean escape.

**5. Neither card `h3` names its platform.** Heading-navigation screen-reader
users hear "Signed, notarized, ready" and "Still in the workshop" with no
platform context, because "MACOS"/"WINDOWS" is a plain `div` above the heading.
Linear reading order is correct, so this clears AA and is genuinely minor — but
if `/build` wants the AAA-where-practical polish the preference profile asks for,
folding the platform name into the `h3` as a separately styled `<span>` costs
nothing.

**6. "Notify me" email capture and Linux remain explicitly out of scope.**
Correctly deferred — both would need decisions (a backend endpoint plus consent
handling; a Linux build that doesn't exist) well beyond a homepage section. The
`auto-fit` grid absorbs a third card with no layout change if Linux ever lands.

---

## 5. Proposed fixes

Two code-level fixes for `/build`, both one-liners:

**Fix for Issue A** — in the Windows card's action slot (spec §6), change:

```
padding: '16px 24px'
```

to:

```
padding: '16px 0'
```

This keeps the row's 52px height, so both cards' action and metadata rows stay
locked to the same baseline (the fix that resolved pass-1's Issue 6 is
untouched), while putting the text back on the card's own left rail at the same
x as the title and description. Do not instead reduce the vertical padding, and
do not delete the slot — the height is load-bearing for cross-card alignment.

**Fix for Issue B** — on the Windows card's metadata line only, change
`textAlign: 'center'` to `textAlign: 'left'`. The macOS card's metadata stays
centered, because there the centering is earned by the full-width pill above it.
After both fixes the Windows card resolves to a single clean left rail and the
macOS card keeps its centered-under-button caption — each internally coherent,
which is what makes the pair read as deliberate rather than accidental.

**Optional, pending Jacey's read of the in-context render** — the asymmetric
bottom padding in §4 item 2, if the 280px dark gap reads as too long.

Everything else in spec v3 should be implemented exactly as written. In
particular, do not re-tune either card's background value in isolation — §5's
shared additive scale is the reason the hierarchy measures correctly, and
changing one surface without re-checking the other against that table is how the
v2 inversion happened.
