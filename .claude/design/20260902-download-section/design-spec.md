# Design Spec — Download Section (20260902-download-section) — v3

Implementation-ready spec for a new `<section>` inserted into
`~/Vscode/FellowScript/frontend/src/pages/Home.jsx`. Every token below is
either lifted verbatim from the live file (confirmed by direct read,
2026-09-02) or a named derivation from an existing pattern in that file — no
new visual vocabulary is introduced. This file is both the generation prompt
and the `/build`-stage implementation brief.

## Revision notes (v3 — respec after second critique bounce)

`critique.md` (pass 2) rendered v2's actual markup in a browser and sampled
it pixel-by-pixel. All four of pass 1's blocking faults were confirmed
genuinely fixed by measurement, not by re-reading the spec's own claims:
clean unclipped Apple glyph, orb clear of the card row, z-index guard
holding, both cards' trailing rows aligned. Three *new* faults surfaced only
because there was finally a render to look at:

1. The "recessed" Windows card composited brighter than the "primary" macOS
   card — a measured inversion of style-brief's non-negotiable hierarchy,
   caused by mixing a subtractive tint (macOS) with an additive tint
   (Windows) on two scales that aren't comparable. Fixed in §5/§6 below by
   re-deriving both surfaces as additive tints on one shared scale, with the
   arithmetic shown so it's independently checkable.
2. The preview printed "macOS 12+" as settled copy — a value §8 marks
   Blocking and explicitly forbids inventing, and nothing in the repo
   supports it. Fixed in §8 with a placeholder-rendering rule.
3. The preview showed the section alone on a blank page, so the design's
   central adjacency claims (second dark run bookending the page; orb
   glow → Closing CTA bloom sequence) were untestable. Fixed in §12 with a
   required in-context render.

Plus one minor fix (§6 action-slot register) carried over from the same
critique pass. Nothing in the *direction* changed again — placement, the
recessed-not-disabled Windows treatment, chrome-not-text dimming, filled
brand glyphs, and Standard-tier hover all carry over unchanged from v1/v2/
the style brief. This is the third and final spec pass in this pipeline.

---

## 1. Deliverable

- **What**: one new React section (`{/* ══ On your desktop ══ */}`), inserted
  into `Home.jsx` **between the Pricing section (line ~378 close) and the
  Closing CTA section (line ~380 open)**.
- **Format**: JSX using the file's existing inline-style-object convention —
  no Tailwind, no CSS modules, no new dependencies. Two new small helper
  components (`AppleMark`, `WinMark` — inline SVGs) alongside the existing
  `Ico`/`Check`/`PillButton`/`Blobs` helpers at the top of the file.
- **Not in scope for this pipeline**: working the actual PR — this spec hands
  `/build` a structure precise enough to implement with minimal
  interpretation, per the intake brief.

---

## 2. Placement & section rhythm (decided in style-brief, restated as a build instruction)

Insert directly after the Pricing `</section>` and before the Closing CTA
`<section>`. This creates a second dark (`INK`) run that bookends the page
(Hero → How it feels day to day is the first dark run; Download → Closing CTA
is the second), leaving the light run (Everything you need → Pricing, with
the dark Built for Community section already sitting between them as it does
today) fully intact. Do not reorder any other section.

---

## 3. Section shell

```
position: relative
overflow: hidden
padding: clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px)
background: INK   // #17120F
```

Inner content wrapper — **fixes critique Issue 3 (orb painted over the
headline)**:

```
position: relative   // NEW — was missing in v1
zIndex: 1             // NEW — was missing in v1
maxWidth: 1240
margin: '0 auto'
```

This matches the guard the live Community section already carries at
`Home.jsx:283`. Absolutely positioned elements paint above non-positioned
in-flow siblings; v1 dropped this guard and the orb washed over the eyebrow,
headline and sub copy (worst at mobile widths). With the guard in place, all
text and both cards sit above the atmosphere layer regardless of any
positioning change made to the orb.

**Atmosphere — single side-anchored orb (not the `Blobs` component) — fixes
critique Issue 2 (inverted hierarchy):**

```jsx
<div style={{ position: 'absolute', inset: 0, overflow: 'hidden', pointerEvents: 'none' }}>
  <div style={{
    position: 'absolute',
    top: 'clamp(-140px, -9vh, -70px)',
    right: 'clamp(-60px, -6vw, -20px)',
    width: 'clamp(260px, 28vw, 420px)',
    height: 'clamp(260px, 28vw, 420px)',
    borderRadius: '50%',
    background: 'radial-gradient(circle at 45% 40%, rgba(240,179,106,0.24) 0%, rgba(164,74,45,0.16) 42%, rgba(23,18,15,0) 74%)',
    filter: 'blur(12px)',
  }} />
</div>
```

What changed from v1 and why:

- **Vertical offset is now `vh`/`px`-based, not `%`.** `top` as a percentage
  on an absolutely positioned element resolves against its containing
  block's *height* — but the section's height is `auto` (content-driven), and
  percentage offsets against an auto-height containing block are undefined/
  effectively inert. v1's `top: '6%'` was quietly not doing what it looked
  like it did. `vh` (viewport height) is well-defined regardless of the
  section's own height and gives predictable behavior across breakpoints.
- **Shrunk and pulled up so it clears the card row.** At 1440px, this puts
  the orb's visible extent (after `overflow: hidden` clips the negative-top
  portion) roughly in the top ~280–320px of the section — behind the eyebrow
  and headline only. The card grid doesn't start until roughly y≈450–500px
  (padding-top + eyebrow + headline + sub copy + margins), so there's
  ~150–200px of clearance between the orb's lowest visible pixel and the top
  of the card row at 1280px, 1440px, and 1920px. **Verify this clearance in
  the rendered preview (§12) at those three widths** before calling it
  settled — the arithmetic above is the design intent, not a substitute for
  looking at it rendered.
- **Right-edge math**: at 1440px this anchors the orb's visible sliver
  against the top-right corner, clearing the card grid's right edge by a
  comfortable margin once combined with the vertical clearance above (the
  orb ends well before the card row begins, so horizontal overlap with the
  Windows card's column no longer matters — there's nothing there for it to
  overlap *vertically*). At 1920px+ the orb sits almost entirely off-canvas,
  which is correct — it should read as a hint at the edge, not a feature.
- **`minWidth`/`minHeight` floor dropped from 380 to 260** so mobile widths
  don't force an oversized circle. Combined with the z-index guard above,
  even if the orb reads faintly across the top of a narrow viewport it can no
  longer sit visually on top of any text.
- Alpha values (`0.24`/`0.16`) are unchanged from the style brief — still
  quieter than the Closing CTA's centered `0.4`/`0.28` bloom immediately
  below it, preserving the "Download glows, Closing CTA blooms" rule.
- Do not use the multi-orb `Blobs` component here.

---

## 4. Content structure, top to bottom

1. **Eyebrow** — `// ON YOUR DESKTOP`
2. **Two-tone headline**
3. **Sub copy** (one sentence, states the honest reason to want the desktop app)
4. **Two-card grid** (macOS · Windows)

### 4.1 Eyebrow

```
fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em',
textTransform: 'uppercase', color: AMBER,
paddingBottom: 22, borderBottom: '1px solid rgba(255,244,230,0.14)',
marginBottom: 56
```
Copy: `// ON YOUR DESKTOP` — exact match to every other dark-section eyebrow
(`// HOW IT FEELS DAY TO DAY`, `// BUILT FOR COMMUNITY`).

### 4.2 Headline — copy revised (minor, non-blocking critique note)

```
fontFamily: HEAD_FONT, fontWeight: 400,
fontSize: 'clamp(32px, 4.2vw, 62px)', lineHeight: 1.03, letterSpacing: '-0.03em',
color: '#FFF9F0', margin: '0 0 24px'
```

```jsx
<h2 style={{ ... }}>
  Out of the browser, <span style={{ color: 'rgba(255,249,240,0.42)' }}>into a window of its own.</span>
</h2>
```

Why this changed from v1's "Off the browser, onto your desktop.": critique
flagged that phrasing for (a) repeating "desktop" from the eyebrow two lines
above, and (b) a slightly off-idiom "off the browser" (English takes "out of
the browser"). The style brief's own alternate candidate ("Read on your
desktop, wherever the browser isn't") has the same repetition problem, so
this respec uses new copy instead — it keeps the two-tone pattern, fixes the
idiom, and doesn't reuse "desktop." Sized and weighted to match the Built for
Community headline exactly, same as v1.

### 4.3 Sub copy — wording fixed (critique Issue 10)

```
fontFamily: BODY_FONT, fontSize: 16.5, lineHeight: 1.7,
color: 'rgba(255,243,228,0.66)', maxWidth: '34em', margin: '0 0 clamp(48px, 7vh, 88px)'
```

```
The desktop app opens straight into your reading — one calm window, no
tabs, no browser chrome, sitting right where you left it.
```

v1 ended "...sitting right in your dock" — a macOS-only concept sitting above
*both* cards, including the Windows one. "Sitting right where you left it" is
platform-neutral and keeps the same rhythm and meaning. Same constraint as
before: sourced from the desktop subproject's real behavior
(`desktop/PROGRESS.md` — a dedicated Tauri window loading the live,
cookie-authenticated `fellowscript.com/reader`, not an offline/bundled app).
Do not imply offline support, sync, or any capability beyond a dedicated
window to the same reading experience.

### 4.4 Two-card grid

```
display: grid
gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))'
gap: 'clamp(20px, 2.4vw, 32px)'
alignItems: 'stretch'
```
Exact pricing-grid recipe — free single-column stacking below ~660px, no new
breakpoint needed. Order is fixed: **macOS card first, Windows card second**,
always, in both DOM order and visual order (no OS auto-detection/reordering —
decided in style-brief).

Note: this card's internal `gap: 18` (§5/§6) is intentionally tighter than
the pricing card's `gap: 26` — pricing cards carry a feature-bullet list with
more items to separate; these cards carry a shorter, denser stack. This is a
deliberate deviation, not an inconsistency to fix at `/build` time.

**Shared card skeleton** (both cards use this exact vertical stack; only
surface treatment and the action/metadata slots differ — see §6 for why
Windows now carries a matching two-row bottom group):

```
padding: '38px 34px 40px'
borderRadius: 20
display: 'flex', flexDirection: 'column', gap: 18
```
Internal order: platform icon badge → platform name (uppercase, tracked) →
card title → one-line description → flexible spacer (`flex: 1`) → action
slot → metadata line. **Both cards now carry both trailing rows** (see §6)
so they land at the same vertical position — this is the fix for critique
Issue 6.

---

## 5. macOS card (primary path)

```jsx
<div style={{
  position: 'relative', display: 'flex', flexDirection: 'column', gap: 18,
  padding: '38px 34px 40px', borderRadius: 20,
  background: 'rgba(255,244,230,0.055)',
  border: '1px solid rgba(255,244,230,0.18)',
  boxShadow: '0 40px 90px -50px rgba(0,0,0,0.9)',
}} className="hm-dl-card hm-dl-mac">

  {/* 42×42 platform icon badge */}
  <span style={{
    display: 'grid', placeItems: 'center', width: 42, height: 42, borderRadius: 12,
    background: 'rgba(232,163,85,0.16)', border: '1px solid rgba(232,163,85,0.30)', color: AMBER,
  }}>
    <AppleMark size={20} />
  </span>

  {/* platform name */}
  <span style={{ fontFamily: HEAD_FONT, fontSize: 12, letterSpacing: '0.2em', textTransform: 'uppercase', color: '#F0C08A' }}>
    MACOS
  </span>

  {/* card title */}
  <h3 style={{ fontFamily: HEAD_FONT, fontSize: 21, fontWeight: 500, letterSpacing: '-0.02em', margin: 0, color: '#FFF9F0' }}>
    Signed, notarized, ready
  </h3>

  {/* description */}
  <p style={{ fontSize: 15, lineHeight: 1.6, color: 'rgba(255,243,228,0.7)', margin: 0 }}>
    One download, no gatekeeper warnings — just open it.
  </p>

  <div style={{ flex: 1 }} />

  {/* action — plain <a>, not <Link>: this points at a hosted file, not an internal route */}
  <a
    href={MACOS_DOWNLOAD_URL /* placeholder — see §8 */}
    download
    className="hm-btn-primary"
    style={{
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 9,
      padding: '16px 24px', borderRadius: 999,
      background: AMBER, color: '#21160F',
      fontFamily: BODY_FONT, fontSize: 14.5, fontWeight: 600, letterSpacing: '0.01em',
      textDecoration: 'none',
    }}
  >
    Download for Mac <span aria-hidden="true">↓</span>
  </a>

  {/* metadata — contrast raised, see critique Issue 8. MIN_MACOS_VERSION is
      Blocking/unsourced per §8 — render it as a visibly unresolved
      placeholder, not as a plausible number, until /build sources it from
      the actual signed build. */}
  <div style={{ fontFamily: BODY_FONT, fontSize: 12.5, letterSpacing: '0.04em', color: 'rgba(255,243,228,0.58)', textAlign: 'center' }}>
    Apple silicon &amp; Intel · 3 MB · macOS {MIN_MACOS_VERSION /* placeholder — see §8; preview must render "⟨MIN VERSION — TBC⟩", never a number */}
  </div>
</div>
```

Notes — four corrections, three carried from v1→v2 and one new in v3:

- **Surface hierarchy fix (v3 — critique pass 2, Issue 1, blocking).** v2's
  surface, `rgba(31,24,21,0.72)`, composited to a *measured* `rgb(28,22,19)`
  against `INK` — nearly indistinguishable from `INK` itself, because
  `rgba(31,24,21,…)` is a *subtractive* tint barely lighter than `INK`
  (`#17120F` = `rgb(23,18,15)`), so even 72% opacity of it lifts the surface
  almost not at all. Meanwhile v2's Windows card used an *additive* cream
  tint that composited brighter — `rgb(31,26,22)` — inverting the hierarchy
  style-brief calls non-negotiable ("macOS card is unambiguously the primary
  path: brighter surface"). Two tints on non-comparable scales silently
  invert; the fix is to put both cards' surfaces on **one shared additive
  scale** (`rgba(255,244,230, α)` on `INK`) with enough headroom between the
  three steps to read as a real hierarchy:

  | Surface | Value | Composite over `INK rgb(23,18,15)` | Relative luminance |
  |---|---|---|---|
  | Section (`INK`) | `#17120F` | `rgb(23, 18, 15)` | 0.00727 |
  | Windows (recessed) | `rgba(255,244,230,0.028)` | `rgb(30, 24, 21)` | ~0.00870 |
  | **macOS (primary)** | `rgba(255,244,230,0.055)` | `rgb(36, 30, 27)` | ~0.01050 |

  Arithmetic (per channel, `composite = base×(1−α) + overlay×α`, overlay =
  `(255,244,230)`): macOS red channel = `23×0.945 + 255×0.055 = 21.7 + 14.0
  = 35.8 ≈ 36`; green = `18×0.945 + 244×0.055 = 17.0 + 13.4 = 30.4 ≈ 30`;
  blue = `15×0.945 + 230×0.055 = 14.2 + 12.7 = 26.8 ≈ 27` → `rgb(36,30,27)`.
  Windows: red = `23×0.972 + 255×0.028 = 22.4 + 7.1 = 29.5 ≈ 30`; green =
  `18×0.972 + 244×0.028 = 17.5 + 6.8 = 24.3 ≈ 24`; blue = `15×0.972 +
  230×0.028 = 14.6 + 6.4 = 21.0 ≈ 21` → `rgb(30,24,21)`. macOS now sits
  **6/6/6 above Windows on every channel** and Windows sits 7/6/6 above
  `INK` — both steps roughly double the 3/255 delta that made v1's Windows
  card read as invisible, and the ordering is now provably correct rather
  than asserted. `/build`: never mix an additive tint on one card with a
  subtractive tint on the other — the two scales aren't comparable and the
  ordering can silently invert, which is exactly what happened here.
- **`backdrop-filter` dropped (v3 hygiene).** v2 carried
  `backdropFilter: blur(18px)` on the rationale that it would let the
  re-anchored orb's glow read faintly through the card. Pass-2 critique
  measured the render and found this isn't what happens: per §3, the orb
  clears the card row entirely by design, so the card sits over flat `INK`
  with nothing behind it to blur. The property costs a compositing layer for
  zero visible return. Dropped entirely rather than kept-but-inert.
- **Corrected claim (carried from v2).** v1 stated this "reuses the
  community chat-mock card's exact surface" — that's not accurate: the real
  card at `Home.jsx:304` has no `backdrop-filter`, a `0.16` border (not
  `0.18`), and `borderRadius: 22` (not `20`). This card is a **derived**
  surface treatment in the same family, sized to this section's pricing-card
  geometry (`borderRadius: 20`, matching §4.4's shared skeleton) — not a
  byte-for-byte reuse of the community card. `/build` should not go looking
  for an exact match.
- **Metadata contrast (carried from v2, critique Issue 8).** `rgba(255,243,228,0.58)`
  clears AA against both the v2 and v3 surfaces. Re-verified against the
  brightened v3 macOS surface `rgb(36,30,27)`: contrast measures **5.91:1**,
  still comfortably above the 4.5:1 AA floor (down slightly from v2's 6.07:1
  measured on the dimmer `rgb(28,22,19)` surface, because a brighter card
  surface narrows the gap to light text — expected and still well clear of
  the floor). No text value needs to change. Apply the same `0.58` to the
  Windows card's metadata line (§6); re-verified there too (see §6 notes).
- The button reuses `PillButton`'s primary visual spec byte-for-byte
  (padding, radius, font, colors) and its existing `.hm-btn-primary:hover`
  class for the lighten-to-`AMBER_LIGHT` hover — **do not** write a second
  hover rule. It cannot reuse the `PillButton` *component* itself because
  `PillButton` wraps React Router's `<Link>` for internal routes; this is an
  external/file download, so it must render as a plain `<a>` with the same
  style object (factor the shared style into a small constant if convenient,
  e.g. `pillButtonPrimaryStyle`, to avoid drift between the two).
- **Firm note, not a hedge (was a hedge in v1):** the `download` attribute is
  ignored by browsers when the file is cross-origin (a different host/CDN
  than the page). If the hosted `.dmg` lands on GitHub Releases or an
  external CDN, `download` will be a no-op there and the file will still open
  in a new tab/download per the browser's normal handling of that file type —
  which is an acceptable fallback (the browser still downloads a `.dmg`) but
  `/build` should not assume the `download`-triggered save-dialog behavior is
  guaranteed; confirm once the real hosted URL (§8) is known.

---

## 6. Windows card (recessed, present-but-not-live)

```jsx
<div style={{
  position: 'relative', display: 'flex', flexDirection: 'column', gap: 18,
  padding: '38px 34px 40px', borderRadius: 20,
  background: 'rgba(255,244,230,0.028)',
  border: '1px solid rgba(255,244,230,0.13)',
  cursor: 'default',
}} className="hm-dl-card">

  {/* "Coming soon" outline badge, top-right — pricing card's badge slot, outline variant */}
  <span style={{
    position: 'absolute', top: 22, right: 26, padding: '6px 12px', borderRadius: 999,
    background: 'rgba(232,163,85,0.14)', border: '1px solid rgba(232,163,85,0.28)',
    color: 'rgba(255,243,228,0.8)', fontSize: 10.5, fontWeight: 600, letterSpacing: '0.14em', textTransform: 'uppercase',
  }}>
    Coming soon
  </span>

  {/* 42×42 platform icon badge — same geometry as macOS, dimmer chrome only */}
  <span style={{
    display: 'grid', placeItems: 'center', width: 42, height: 42, borderRadius: 12,
    background: 'rgba(232,163,85,0.16)', border: '1px solid rgba(232,163,85,0.30)', color: AMBER,
  }}>
    <WinMark size={18} />
  </span>

  {/* platform name */}
  <span style={{ fontFamily: HEAD_FONT, fontSize: 12, letterSpacing: '0.2em', textTransform: 'uppercase', color: '#F0C08A' }}>
    WINDOWS
  </span>

  {/* card title — retitled, see critique Issue 7 */}
  <h3 style={{ fontFamily: HEAD_FONT, fontSize: 21, fontWeight: 500, letterSpacing: '-0.02em', margin: 0, color: '#FFF9F0' }}>
    Still in the workshop
  </h3>

  {/* description — the honest explanation, one sentence, no ETA */}
  <p style={{ fontSize: 15, lineHeight: 1.6, color: 'rgba(255,243,228,0.7)', margin: 0 }}>
    We started on macOS. The Windows build is on the way.
  </p>

  <div style={{ flex: 1 }} />

  {/* action slot — same vertical slot/height as the macOS button, but a genuinely new
      statement (platform coverage), not a fourth restatement of "coming soon".
      Left-aligned, body weight (not the button's 600/centered) so it reads as
      a plain statement, not a ghost button — see v3 note below. */}
  <div style={{
    display: 'flex', alignItems: 'center', justifyContent: 'flex-start',
    padding: '16px 24px',
    fontFamily: BODY_FONT, fontSize: 15, fontWeight: 400, letterSpacing: '0.01em',
    color: 'rgba(255,243,228,0.66)',
  }}>
    Windows 10 &amp; 11
  </div>

  {/* metadata — NEW row, matches macOS's metadata slot exactly (fixes critique Issues 6 & 7) */}
  <div style={{ fontFamily: BODY_FONT, fontSize: 12.5, letterSpacing: '0.04em', color: 'rgba(255,243,228,0.58)', textAlign: 'center' }}>
    We'll post it here first — no signup needed.
  </div>
</div>
```

What changed, v1 → v2 → v3:

- **Surface value corrected again (v3 — critique pass 2, Issue 1, blocking).**
  v1's `rgba(28,21,17,0.5)` composited to roughly `#1A1410`, ~3/255 above
  `INK` — invisible. v2 overcorrected to `rgba(255,244,230,0.035)`, which
  measured `rgb(31,26,22)` and came out **brighter than v2's own macOS
  surface** — the opposite of "recessed." v3 fixes this properly: rather than
  shaving this value again in isolation (there wasn't room to do that without
  landing back near invisible), §5's macOS surface was brightened first to
  open headroom, and this card's value was re-derived on the *same additive
  scale* as macOS so the two are directly comparable:

  `rgba(255,244,230,0.028)` on `INK rgb(23,18,15)` → red = `23×0.972 +
  255×0.028 ≈ 30`, green = `18×0.972 + 244×0.028 ≈ 24`, blue = `15×0.972 +
  230×0.028 ≈ 21` → **`rgb(30,24,21)`**, which is provably below macOS's
  `rgb(36,30,27)` (§5) on every channel and provably above `INK`'s
  `rgb(23,18,15)` on every channel — see §5's full table. Border stays at
  `0.13` (unchanged from v2; that fix already held up under measurement —
  the section's eyebrow rule at `0.14` is this system's established
  visibility floor for a hairline on `INK`, and `0.13` clears it).
- **Action-slot register fixed (v3 — critique pass 2, Issue 4, minor).** v2's
  "Windows 10 & 11" line was 14.5px/weight 600/centered — the macOS button's
  exact typographic weight, size, and box, minus the fill, which reads
  optically as a ghost/text button even though nothing about it is
  interactive (no hover, no focus target, no cursor change — that part was
  always correct). Changed to 15px/weight 400/left-aligned, matching the
  card's own title and description alignment above it. `padding: '16px 24px'`
  and the `0.66` color are unchanged, so the row still occupies the same
  height and both cards' bottom groups stay locked to the same baseline —
  only the macOS card's button is centered now, and that centering is earned
  there (a full-width pill), not here.
- **Bottom-group restructure (critique Issues 6 & 7, resolved together in v2, unchanged in v3).**
  v1 gave the Windows card only a single trailing line ("Nothing to click
  here yet"), so once `alignItems: 'stretch'` equalized both cards to the
  taller macOS card's height, that single line landed at the very bottom
  edge — about 35px below the macOS button's position, because macOS has
  *two* trailing rows (button + metadata) and Windows had one. This version
  gives the Windows card the same two-row trailing group, so both cards'
  action rows land at the same y-position and both metadata rows land at the
  same y-position. It also incidentally fixes Issue 7: v1 stated "coming
  soon" in some form four times ("Coming soon" badge, "On the way" title,
  "...is on the way" description, and the empty action line). This version
  states three genuinely distinct things — badge (status), title (no longer
  a status restatement), description (the one explanation) — and the two new
  bottom rows carry *new* information (platform coverage, and how you'll
  find out) rather than a repeat.
- **Text contrast, not chrome (critique Issue 8, secondary note).** The
  action-slot text is `rgba(255,243,228,0.66)` — the same body-copy value
  used everywhere else in this card, not a dimmed variant. v1's action text
  sat at `0.5`, which directly contradicted this card's own "dimming is
  confined to chrome, never text" rule. The metadata row matches macOS's
  corrected `0.58`, **re-verified against v3's Windows surface**: `rgb(30,24,21)`
  is dimmer than macOS's `rgb(36,30,27)`, and text contrast only improves as
  a surface gets darker relative to fixed light text — so if `0.58` clears
  AA at 5.91:1 on the brighter macOS surface (§5), it clears with more
  headroom here. No separate measurement changes this card's text values.

Notes — **this card's rules are still the single most important part of this
spec, unchanged from v1**:

- **No `<button>`, `<a>`, or focusable element anywhere in this card.** Its
  card wrapper is a plain `<div>` — not a `<button>`, not `tabIndex`-ed, no
  `role="button"`. It should not appear in the tab order at all, and a
  screen reader should encounter it as static content, not a disabled
  control (avoid `aria-disabled` theater — there's no control to disable).
- **No hover state, no transition, no `cursor: pointer` anywhere in this
  card.** `cursor: default` on the card root is the only interaction-adjacent
  style it carries. Its stillness next to the macOS card's lift *is* the
  "not yet" signal.
- **Contrast is held on text, dimming is confined to chrome.** Only the
  card's *surface* and *border* are dimmer than the macOS card's. Do not
  apply a blanket `opacity` to this card or any of its children — that is the
  exact anti-pattern the accessibility floor forbids here.
- **Do not build a "notify me" capture.** Explicitly out of scope (adds a
  backend endpoint + consent handling not part of a homepage section) —
  flagged forward as a separate future decision, not to be added here.

---

## 7. Iconography

Both marks render as **filled glyphs** (`fill="currentColor"`, no stroke),
sized inside the identical 42×42 amber badge used by both cards — **not**
redrawn as 1.6px-stroke `Ico` outlines. Brand marks read as counterfeit when
outlined in a line-icon style; the badge container (already established by
the feature-card pattern) is what carries this system's visual continuity,
not the glyph's rendering technique.

```jsx
function AppleMark({ size = 20 }) {
  return (
    <svg width={size} height={(size * 512) / 384} viewBox="0 0 384 512" fill="currentColor" aria-hidden="true">
      <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.8 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z" />
    </svg>
  );
}

function WinMark({ size = 18 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <rect x="2"  y="2"  width="9" height="9" />
      <rect x="13" y="2"  width="9" height="9" />
      <rect x="2"  y="13" width="9" height="9" />
      <rect x="13" y="13" width="9" height="9" />
    </svg>
  );
}
```

**Critique Issue 1 fix, explained.** v1's `AppleMark` path traveled to
`x = -58` and `y ≈ -17` against a `viewBox="0 0 244 300"` — outside its own
bounds, so it rendered as a clipped, unrecognizable box. That was a
hand-transcription error in a hand-authored path, which is exactly the kind
of mistake that shouldn't ship untested a second time. This version:

- Uses a widely-circulated, well-formed Apple-silhouette path on a
  `viewBox="0 0 384 512"` — every coordinate in the path string above falls
  within `[0, 384]` × `[0, 512]` (no negative values, nothing past either
  bound), so it cannot clip the way v1's did.
- **Still needs a rendered check before it ships** — this spec's own tooling
  cannot rasterize SVG to confirm pixel-perfect fidelity to Apple's current
  mark, and the honest thing to do is say so rather than assert certainty a
  second time. §12 requires a rendered preview specifically so this glyph
  gets looked at, not just token-checked, before Jacey reviews it.
- **Stronger alternative for `/build` to consider**: if the codebase adds (or
  already has access to) a maintained brand-icon source — e.g. the
  `simple-icons` npm package's `siApple` path data, or Apple's own official
  marketing-resources SVG — sourcing the glyph from there instead of the
  hand-authored path above removes this risk class entirely and is the safer
  long-term choice. Not required to unblock this spec (no new dependency is
  introduced here, per §1's constraint), but worth a five-minute swap at
  `/build` time.
- `WinMark` is unchanged from v1 — critique confirmed it renders correctly
  as-is. Deliberately uses four plain squares rather than tracing Microsoft's
  exact logotype curvature, which keeps it legally low-risk and reads
  correctly as "the Windows four-square mark" at 18px.
- Both are optically weight-matched by their differing `size` props
  (Windows' four-square mark reads heavier than Apple's mark at an equal
  bounding box, so Windows renders 2px smaller — 18px vs. 20px).

---

## 8. Open placeholders — must be filled at `/build` time, not invented here

**Rule, added in v3 after critique pass 2 caught a violation of it (Issue 2,
blocking): any placeholder marked Blocking below must render in every
preview/mockup as a visibly unresolved placeholder — e.g. `⟨MIN VERSION —
TBC⟩` — never as plausible, settled-looking copy.** v2's rendered preview
printed "macOS 12+" in the exact visual register as the verified facts next
to it ("Apple silicon & Intel", "3 MB"), which let an invented number pass
as fact in the artifact Jacey reviews for sign-off. `tauri.conf.json` sets
no `minimumSystemVersion` at all (confirmed by direct read, 2026-09-02) —
Tauri's own framework default is 10.13, so even that isn't a documented
product decision, just an unset value, and printing "12" specifically had no
source anywhere in this repo. §12's preview must show
`MIN_MACOS_VERSION` as the literal bracketed placeholder text, not a number,
until `/build` sources the real floor from the actual signed build.

| Placeholder | Status | Notes |
|---|---|---|
| `MACOS_DOWNLOAD_URL` | **Blocking** | The `.dmg` exists only at a local build path (`desktop/src-tauri/target/release/bundle/macos/FellowScript.dmg`, ~3 MB). Needs real hosting (GitHub Releases / CDN / backend route) before this button can function. |
| `MIN_MACOS_VERSION` | **Blocking (copy)** | `tauri.conf.json` sets no explicit `minimumSystemVersion` (confirmed by direct read — the key is absent from the file entirely). Tauri's framework default is 10.13, but that is not a verified product claim about this build — do not print it as one. Confirm the real floor against the actual signed/notarized build, then fill this in. Until then, every preview must render the bracketed placeholder text per the rule above, not a number. |
| Apple mark verification | Non-blocking, do before ship | See §7 — render and eyeball it, and consider sourcing from a maintained icon package instead of the hand-authored path. |
| Windows build itself | Known, not blocking this section | Section is designed to be honest about this; no action needed here. |
| "Notify me" capture | Explicitly deferred | Not specced; a future, separate feature if Jacey wants it. |
| Linux card | Explicitly out of scope | Grid absorbs a third card with no layout change if this ever changes. |

---

## 9. Motion

- **macOS card hover**: `translateY(-4px)`, border brightens to
  `rgba(255,244,230,0.30)`, shadow blooms warmer/larger. `220ms
  cubic-bezier(0.22, 0.61, 0.36, 1)`. Animate `transform`, `border-color`,
  `box-shadow` only — never layout properties. Always pair the reverse
  transition (same duration/easing) so a fast pointer-out can't strand the
  hover state.

  ```css
  .hm-dl-mac { transition: transform 220ms cubic-bezier(0.22,0.61,0.36,1), border-color 220ms cubic-bezier(0.22,0.61,0.36,1), box-shadow 220ms cubic-bezier(0.22,0.61,0.36,1); }
  .hm-dl-mac:hover { transform: translateY(-4px); border-color: rgba(255,244,230,0.30); box-shadow: 0 48px 100px -50px rgba(232,163,85,0.35), 0 40px 90px -50px rgba(0,0,0,0.9); }
  ```

- **Primary button hover**: reuse `.hm-btn-primary:hover` unchanged — no new
  button-hover rule.
- **Windows card**: no `.hm-dl-card` hover rule applies to it (its class list
  omits `hm-dl-mac`) — no lift, no transition, no cursor change. This is
  intentional per §6.
- **Reduced motion — fixed (critique Issue 9).** v1 set `transition: none
  !important` but left `.hm-dl-mac:hover { transform: translateY(-4px) }` in
  force, so a `prefers-reduced-motion: reduce` user got an *instantaneous*
  4px snap on hover instead of no motion at all — the opposite of the query's
  purpose. This version neutralizes the transform itself, and scopes the
  reset to `.hm-dl-mac` only rather than widening the shared
  `.hm-float, .hm-orbit-spin` selector's blast radius:

  ```css
  @media (prefers-reduced-motion: reduce) {
    .hm-float, .hm-orbit-spin { animation: none !important; }
    .hm-dl-mac { transition: none !important; }
    .hm-dl-mac:hover { transform: none !important; }
  }
  ```
  Border-color and shadow may still change instantly on hover under reduced
  motion (color/shadow changes aren't considered motion) — only the
  positional transform is suppressed. Add this to the existing block at
  `Home.jsx`'s `<style>` tag (~line 155); do not add a second
  `@media (prefers-reduced-motion: reduce)` block.

---

## 10. States (this is an interactive marketing component, not a data view — no loading/error/empty states apply; only interaction states below)

| State | Element | Spec |
|---|---|---|
| Default | macOS card | As specced in §5. |
| Hover | macOS card | `translateY(-4px)` + brighter border + amber shadow bloom, per §9. |
| Hover | macOS button | `.hm-btn-primary:hover` → background lightens to `AMBER_LIGHT` (existing global rule, unchanged). |
| Focus-visible | macOS button | Browser default focus ring is acceptable (no focus-ring-suppressing CSS exists anywhere in `Home.jsx`, so none is introduced here). If `/build` wants to match other primary CTAs' focus treatment site-wide, that's a global decision outside this section's scope — do not add a one-off focus style just for this button. |
| Default / only state | Windows card | Static — see §6. No hover, no focus target, no pressed state; there is nothing on this card that responds to interaction. |
| Reduced motion | macOS card | Hover lift transform is fully suppressed (`transform: none !important`), not merely un-transitioned — see §9's corrected fix. Border-color/shadow may still change instantly on hover. |

---

## 11. Accessibility checklist (Q14 — AA floor, AAA where practical)

- Body copy in both cards holds at `rgba(255,243,228,0.66)`–`0.7` against
  `INK`/card surfaces — comfortably clears AA for body text; do not let any
  implementer substitute a lower-opacity value "to make Windows read as more
  disabled."
- **Both metadata lines measure ≥5.9:1** (`rgba(255,243,228,0.58)` — macOS
  5.91:1 against v3's brightened `rgb(36,30,27)` surface, Windows higher
  still against its dimmer `rgb(30,24,21)` surface per §6) — up from v1's
  `0.45` (~4.2:1, which failed the 4.5:1 floor intake set as a success
  criterion). This is the one contrast value in the file that actually
  needed correcting; it's fixed identically in both cards (§5, §6).
- The Windows card's action-slot text is `0.66`, matching body copy exactly —
  not a separately dimmed value. This was inconsistent in v1 (§6 fix note).
- Primary button: `padding: 16px 24px` + ~14.5px font + line-height ≈ total
  hit height >44px — clears the 44×44 touch-target minimum on both axes at
  any reasonable card width (cards are ≥300px per the grid's `minmax`).
  Card-to-card gap is `clamp(20px, 2.4vw, 32px)` ≥ 20px, avoiding accidental
  adjacent-target taps on touch devices.
- Windows card carries **no interactive semantics at all** (§6) — this is
  itself the correct accessible treatment for "not available," per Q10/Q17:
  a real control that's disabled needs `aria-disabled`/`disabled` handling;
  a card with nothing clickable in it needs neither, and screen readers will
  correctly read it as plain descriptive content followed by silence rather
  than announcing a broken or disabled button.
- Both platform icon badges are decorative next to a text label ("MACOS" /
  "WINDOWS" already rendered as visible text) — `aria-hidden="true"` on both
  `<svg>`s is correct; no separate `alt`/`aria-label` needed on the badge.
- Headline two-tone treatment is a color/opacity distinction only, not the
  sole means of conveying information — both clauses are legible body text
  regardless of color perception.
- The atmosphere orb has `pointerEvents: 'none'` and now sits behind a
  `zIndex: 1` content wrapper — it cannot intercept clicks or visually
  obscure text at any viewport (§3 fix).

---

## 12. Generation-needed determination — **no image generation; updated preview requirements in v3**

**Still yes to a rendered/coded static preview** (unchanged since v2) — not
an openart-generated image, and not "no generation" as v1 concluded.

v1 argued no image generation was needed because every value here is a
precise token from a live codebase, and an AI-generated image would blur
those exact values — that reasoning about *openart specifically* still
holds; nothing here should go through openart. v2's critique pass
demonstrated the actual gap: it rebuilt v1's markup verbatim as static HTML
and found defects (broken glyph, inverted hierarchy, orb-over-type,
invisible Windows surface, misaligned action rows) that were **invisible in
the spec text and obvious within seconds of rendering it**. Intake's
deliverable explicitly includes "any generated visual reference," and its
final success criterion is Jacey approving a *finished design* in Discord —
not a markdown file.

**Isolated renders (unchanged from v2, keep these — they did their job):** a
static HTML/CSS page implementing this spec's exact tokens and structure,
screenshotted at ~390px, ~1024–1280px, and ~1440px, showing the section on
its own. v2's critique pass confirmed these correctly surface glyph fidelity,
card alignment, and orb-vs-card-row clearance. No change needed to this part.

**New requirement (v3 — critique pass 2, Issue 3, blocking): one additional
1440px render showing the section in its actual page neighborhood**, not in
isolation. v2's isolated-only preview could not show the two things the
style brief flagged as the design's central adjacency claims: that this
section's dark run *bookends* the page rather than breaking the light/dark
alternation, and that the reduced side-anchored orb (§3, `0.24`/`0.16`) reads
as a glow that *sets up* — rather than competes with — the Closing CTA's own
centered bloom directly below it ("Download glows, Closing CTA blooms").
Neither claim is testable in a crop that starts and ends at this section's
own edges.

Build this render with the last ~200px of the real Pricing section above and
the first ~400px of the real Closing CTA below, both lifted verbatim from
`Home.jsx` (confirmed by direct read, 2026-09-02) rather than approximated:

- **Pricing tail** (`Home.jsx:338`): `background: '#FBF7F1'` (`LIGHT_BG`),
  `color: '#1A1512'` (`LIGHT_INK`) — include enough of the pricing card grid's
  bottom edge that the light→dark seam at this section's top is visible in
  context, not just a flat light rectangle.
- **Closing CTA head** (`Home.jsx:381-385`): `position: relative, overflow:
  hidden, background: '#17120F'` (`INK`), with its real centered bloom —
  `position: absolute, width: '60vw', height: '60vw', minWidth: 480,
  minHeight: 480, left: '50%', top: '20%', transform: 'translateX(-50%)',
  borderRadius: '50%', background: 'radial-gradient(circle at 45% 40%,
  rgba(240,179,106,0.4) 0%, rgba(164,74,45,0.28) 42%, rgba(23,18,15,0) 74%)',
  filter: 'blur(10px)'` — plus enough of the opening `<blockquote>` heading
  beneath it that the bloom's own vertical extent is visible, not just its
  topmost sliver.

This answers the two open questions directly:

1. Does the light→dark edge at the Pricing boundary land cleanly, or does
   the Download section read as starting abruptly?
2. Do the Download orb and the Closing CTA bloom read as a considered
   glow-then-bloom sequence, or as two warm smudges stacked back to back?

If the doubled dark run reads wrong in this context, that is a style-brief-
level call to flag explicitly to Jacey at review — better to surface it here
than silently ship it. Keep the existing 390/1280/1440 isolated renders
alongside this one; this is one additional render, not a replacement.

---

## 13. Summary of what a `/build` pass needs to do

1. Add `AppleMark`/`WinMark` helper components near `Ico`/`Check` in
   `Home.jsx` (consider sourcing `AppleMark`'s path from a maintained icon
   package instead of the hand-authored one in §7, per that section's note).
2. Insert the new `{/* ══ On your desktop ══ */}` section between Pricing and
   Closing CTA, using the shell, orb, eyebrow, headline, sub copy, and
   two-card grid specified above — including the `position: relative;
   zIndex: 1` content-wrapper guard (§3).
3. Extend the existing reduced-motion media query with the `.hm-dl-mac`
   transform-suppression rule (§9) — do not just add `transition: none`.
4. Wire `MACOS_DOWNLOAD_URL` and `MIN_MACOS_VERSION` to real values once
   hosting and the actual minimum OS version are confirmed (§8) — do not
   ship placeholder/local-path values.
5. Leave the Windows card exactly as specced — no button, no hover, no
   backend call, both trailing rows present for alignment (§6).
6. Verify the orb's vertical clearance above the card grid, and the Apple
   glyph's fidelity, against a real render at 390/1280/1440/1920px (§3, §7)
   — this is what step 4's coded preview (§12) is for.
7. Use the exact §5/§6 surface values as given — do not re-tune either card's
   background in isolation. They were derived together as a shared additive
   scale specifically so the macOS card measures brighter than the Windows
   card on every channel (§5's arithmetic table); changing one without
   re-checking the other against that table risks reintroducing the v2
   inversion.
8. Render the new in-context 1440px preview required by §12 (Pricing tail
   above, real Closing CTA bloom below) alongside the existing isolated
   renders, and render any Blocking §8 placeholder as the literal bracketed
   placeholder text, never a number — both are new requirements in this
   version, not optional extras.
