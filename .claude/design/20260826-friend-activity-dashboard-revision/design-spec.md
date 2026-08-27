# Design Spec — 20260826-friend-activity-dashboard-revision

## Deliverable

A **direct code-level revision** of the existing single self-contained HTML/CSS artifact "Friend Activity Dashboard, Editorial Hero" (Variant C). Not a re-render or new visual asset — this is a targeted DOM + CSS edit applied to a copy of the source file.

- **Format:** single self-contained `.html` file (inline `<style>`, same two Google Fonts `<link>` tags: `Outfit:wght@400;500;600;700`, `Lora:ital,wght@0,500;0,600;1,500`, `Inter:wght@400;500;600`).
- **Source of truth:** `/Users/jaceysimpson/.claude/projects/-Users-jaceysimpson/ea90f968-0bb0-4369-9616-4d345baf4606/tool-results/artifact-c535906c-1787795237-b41d.html` — read in full; every line not called out below is copied forward unchanged (markup, copy, `.stage`/`.phone-shell`/`.screen` scaffold, phone chrome, color tokens, typography, all component structure).
- **Rendered frame:** iPhone-shell mockup, `.phone-shell` 458px wide, `.screen` 430×932px, `border-radius: 54px` — unchanged.
- **Output location:** since no naming convention was given, the generation step should write the revised file to `.claude/design/20260826-friend-activity-dashboard-revision/output/friend-activity-dashboard-editorial-hero-v2.html` (new file, does not overwrite the original artifact). Filename/location is the generation step's call to finalize if it has a differing convention, but this is the recommended default.

## Generation-needed?

**No.** This deliverable does not require OpenArt or any new image/asset generation. It is a scoped HTML/CSS edit of an already-finished mockup — remove two DOM elements, rebalance two flex/spacing rules, and replace two gradient value blocks. The generation step should perform the edit directly (or via a code-editing tool) and save the resulting HTML file; no rendering pipeline is needed beyond that.

## Layout (unchanged, for reference)

`.stage` (page eyebrow caption → phone shell → bottom caption) → `.phone-shell` → `.screen` containing, top to bottom: `.dynamic-island`, `.status-bar` (time + status icons), `.content` column (`.greeting`, `.hero-wrap` [`.hero-glow` + `.glass-card.hero-card`], `.checkin-row`, `.glass-card.standard.note-card`), `.tab-bar-zone`, `.home-indicator`. None of this structure changes.

## Components/elements — exact edits

### Edit 1 — Remove `.sec-label` in `.hero-card`, rebalance `.eyebrow-row`

**Remove** (line 553):
```html
<div class="sec-label">Friend Activity</div>
```
leaving `.eyebrow-row` with only the `.avatar-stack` as its single child.

**Change** the `.eyebrow-row` rule (currently lines 250–255):
```css
/* before */
.eyebrow-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}
```
```css
/* after */
.eyebrow-row {
  display: flex;
  align-items: center;
  justify-content: flex-end;
}
```
(`gap` can be dropped — there's only one child now — but leaving it is harmless; removing it is the cleaner choice since it no longer does anything.)

**Result:** the avatar stack keeps its original right-anchored position relative to the hero card's edge — the same visual read as before, just without the label occupying the left side of the row.

### Edit 2 — Remove `.sec-label` in `.note-card`, compensate `.note-headline` spacing

**Remove** (line 595):
```html
<div class="sec-label">Pick Up Where You Left Off</div>
```

**Change** `.note-headline`'s `margin-top` (currently line 425, `10px`):
```css
/* before */
.note-headline {
  margin-top: 10px;
  ...
}
```
```css
/* after */
.note-headline {
  margin-top: 16px;
  ...
}
```
**Rationale:** `.note-card` has `padding: 16px` at the top. With the label gone, `margin-top: 16px` on the headline creates a clean doubled 16px rhythm (card padding + headline margin) that reads as an intentional, generous top inset rather than a compensating patch — closer to how a headline-first card would have been spaced from scratch, satisfying the "must not look like it's missing a piece" requirement without trying to exactly reproduce the old label's footprint.

### No other DOM or CSS structure changes

Everything else — `.activity-primary`, `.hairline`, `.preview-panel.note`, `.checkin-row`, `.checkin-cta`, `.note-preview`, `.note-cta`, `.tab-bar-pill`, `.home-indicator`, the `.eyebrow-page` and `.caption` text (including the "Variant C — Editorial Hero" references at lines 518 and 620) — stays byte-identical to the source file.

## Styling — exact gradient value changes

### Edit 3 — `.screen` background wash (currently lines 106–116)

**Before:**
```css
background:
  linear-gradient(180deg,
    var(--grad-1) 0%,
    var(--grad-1) 12%,
    var(--grad-2) 20%,
    var(--grad-3) 30%,
    var(--grad-4) 40%,
    transparent 50%
  ),
  var(--bg-app);
```

**After:**
```css
background:
  linear-gradient(180deg,
    rgba(201, 132, 32, 0.14) 0%,
    rgba(201, 132, 32, 0.10) 10%,
    rgba(160, 100, 26, 0.07) 22%,
    rgba(107, 67, 21, 0.04) 34%,
    transparent 48%
  ),
  var(--bg-app);
```

**Rationale:**
- Replaces the two solid-hex `var(--grad-1)` stops (0%–12%, a fully opaque `#C98420` plateau) with `rgba()` equivalents of the same three token colors (`--grad-1` #C98420 → rgb(201,132,32), `--grad-2` #A0641A → rgb(160,100,26), `--grad-3` #6B4315 → rgb(107,67,21)) at low alpha — no stop ever reaches full opacity, eliminating the "hard-edged, fully-saturated plateau" the user flagged.
- Peak opacity (0.14 at 0%) sits inside the ui-ux-pro-max "Modern Dark / Cinema Mobile" ambient-glow convention (0.08–0.12) at its upper edge, and — more importantly — stays *below* the file's own `body::before` backdrop glow peak (`rgba(201,132,32,0.16)`), resolving the carried-forward gap about the outer page glow potentially reading as bolder than the in-phone wash after softening.
- Five gradual stops replace the old banded step-down, giving a smooth taper instead of visible banding.
- Falloff extends slightly further (transparent at 48% vs. 50% before, functionally the same reach) so the "warm light source at the top of the screen" signal stays legible per the success criteria — this is restraint, not removal.
- Stays strictly in the `--grad-1/2/3` gold/amber hue family — no new hue introduced, no token renamed or removed (the `--grad-*` custom properties themselves are untouched; the `.screen` rule now uses inline `rgba()` versions of those same colors because CSS gradients can't apply a separate opacity multiplier to a `var()` color stop without `color-mix()`, which isn't warranted here for a one-off restraint pass).

### Edit 4 — `.hero-glow` radial (currently lines 200–210)

**Before:**
```css
.hero-glow {
  position: absolute;
  top: -14px;
  left: -25px;
  right: -25px;
  bottom: -20px;
  background: radial-gradient(60% 60% at 50% 42%, rgba(212, 146, 42, 0.10), transparent 70%);
  filter: blur(50px);
  z-index: 0;
  pointer-events: none;
}
```

**After:**
```css
.hero-glow {
  position: absolute;
  top: -14px;
  left: -25px;
  right: -25px;
  bottom: -20px;
  background: radial-gradient(60% 60% at 50% 42%, rgba(212, 146, 42, 0.07), transparent 78%);
  filter: blur(50px);
  z-index: 0;
  pointer-events: none;
}
```

**Rationale:** opacity trimmed from 0.10 → 0.07 (a lighter pass, per the intake read that this element wasn't the primary complaint), and the falloff softened from `transparent 70%` to `transparent 78%` for a gentler edge. `blur(50px)` — already at the top of the validated 30–50px range — is left as-is. Position/size (`top/left/right/bottom` insets) unchanged. Net effect: settles as a quiet ambient bloom sitting under the now-softer `.screen` wash rather than competing with it (0.07 vs. the wash's 0.14 peak), satisfying the "not obviously stronger or more saturated than the screen wash" success criterion.

### Unaffected — `body::before` backdrop glow (lines 57–66)

Left completely unchanged, confirmed in scope per intake/style-brief. Its existing `radial-gradient(760px 560px at 50% 8%, rgba(201, 132, 32, 0.16), transparent 60%)` remains the file's most saturated gold ambient effect post-revision, which is correct: it sits *outside* the phone shell as the page-level backdrop, and 0.16 vs. the phone-screen wash's new 0.14 peak keeps it modestly, not dramatically, the boldest — no visual inconsistency introduced.

## Typography, color tokens, imagery

No changes. All `--grad-1..4`, `--gold*`, `--parchment*`, `--ink*`, `--hairline`, `--border-*`, `--caption` custom properties keep their existing hex/rgba values (the two gradient edits above use inline `rgba()` literals matching those same token colors rather than modifying the `:root` tokens themselves, since other rules — `.checkin-cta`, `.note-cta`, avatar text colors, etc. — still depend on the tokens' original full-strength values). Outfit/Lora/Inter font stack, the 36px `.activity-headline`, all font sizes/weights/letter-spacing unchanged.

## States

Not applicable — this is a single static screen state (no empty/loading/error variants exist in the source artifact or were requested). The mockup's existing implied interactive elements (`.checkin-cta`, `.note-cta`) keep their current single-state styling; no hover/press/disabled variants are in scope.

## Verification checklist for the generation step

1. Both `<div class="sec-label">...</div>` elements removed from markup (search confirms zero remaining `.sec-label` usages in markup; the `.sec-label` CSS rule itself, lines 236–242, can stay in the stylesheet unused or be removed — either is acceptable since it's dead code either way, but leaving it is lower-risk/lower-diff).
2. `.eyebrow-row` renders with the avatar stack right-aligned against the hero card's inner edge, matching the original's visual position.
3. `.note-card`'s headline sits with clean, non-crowded spacing below the card's top edge — no headline touching/overlapping the card border.
4. `.screen` gradient wash is visibly softer, un-banded, with no fully opaque gold at any point, still readable as a top-down warm light cue.
5. `.hero-glow` reads as a soft, low-contrast ambient bloom, visibly lighter than the `.screen` wash.
6. Diff the revised file against the original outside the four edits above — everything else must be byte-identical.
7. File remains valid, self-contained, single-file HTML (renders standalone with no external dependencies besides the two Google Fonts links already present).
