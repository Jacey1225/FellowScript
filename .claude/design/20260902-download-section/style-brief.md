# Style Brief — 20260902-download-section

## Media type

**`static`.**

Reasoning: the deliverable is a React marketing-page section to be inserted into `Home.jsx` — a layout/copy/token spec plus a still visual reference. Intake's hint said static and nothing in the request, references, or deliverable points to a timeline-based asset. The section *will* carry motion (hover states, reduced-motion handling), but motion here is a property of the specced component, not the deliverable itself — it gets written as CSS/transition specs in step 3, not choreographed as a video timeline. Routes step 3 to `design-static-spec-agent`.

---

## Unified style direction

### Mood

**Warm, quiet, and settled — the "of course it's here too" moment, not a sales pitch.** The download section is a utility moment inside an emotionally warm page. It should feel like the calm exhale after pricing: the product stepping off the web and onto the reader's own desk. Confident, unhurried, dimly lit, amber-glowed. Explicitly *not*: a tech-download-page tone (no monospace version strings, no checksum energy, no bright "GET IT NOW" urgency), and not a fake-enthusiasm treatment of the unfinished Windows build.

### Placement in the section sequence — **decided**

**Insert as a dark (`INK #17120F`) section between Pricing and the Closing CTA.**

Resolves intake's first gap. Rationale:

1. **Narrative** — pricing answers "what does it cost," download answers "how do I get it." A get-it moment directly before the closing scripture CTA compounds the page's conversion arc rather than interrupting the features→community→pricing story mid-flow. Placing it after "Everything you need" would sever the features→community handoff.
2. **Rhythm** — the page's light/dark alternation cannot survive *any* single insertion without a same-color adjacency somewhere. But the page already contains one continuous dark run (Hero → How it feels day to day). Putting Download adjacent to the Closing CTA creates a **second dark run that bookends the page**, so the doubled-dark reads as deliberate symmetry rather than a broken rhythm. Light run (Everything you need → … → Pricing) stays intact.
3. **Palette headroom** — dark sections are where this system's amber accent, `Blobs` atmosphere, and glass-card treatment carry the most weight. The download CTA is the section that most deserves them.

**Atmosphere restraint (important):** do **not** drop the full `Blobs` component here. The Closing CTA immediately below already runs a centered radial glow, and two full orb fields back to back would flatten its climax. Use a **single, side-anchored, low-opacity warm orb** (the Closing CTA's own `radial-gradient(circle at 45% 40%, rgba(240,179,106,0.4) …)` recipe, dropped to roughly `0.22–0.26` alpha and anchored off one edge rather than centered). The Download section glows; the Closing CTA blooms.

### Palette

Pulled verbatim from `Home.jsx` — no new colors are introduced.

| Role | Token | Notes |
|---|---|---|
| Section background | `INK #17120F` | Full-bleed |
| Section eyebrow | `AMBER #E09A30` | Dark-section eyebrow color |
| Eyebrow rule | `1px solid rgba(255,244,230,0.14)` | |
| Headline (lead clause) | `#FFF9F0` | |
| Headline (de-emphasized clause) | `rgba(255,249,240,0.42)` | The repeating two-tone pattern |
| Body / sub copy | `rgba(255,243,228,0.66)` | |
| macOS card surface | `#1F1815` + `backdrop-filter: blur(…)` | Matches the community chat-mock card |
| macOS card border | `1px solid rgba(255,244,230,0.18)` | |
| macOS card shadow | `0 40px 90px -50px rgba(0,0,0,0.9)` | Reused from community card |
| Windows card surface | `rgba(28,21,17,0.5)` | Recessed variant of the same family |
| Windows card border | `1px solid rgba(255,244,230,0.10)` | Deliberately dimmer *chrome* |
| Platform icon badge | `42×42`, `border-radius 12`, bg `rgba(232,163,85,0.16)`, `1px solid rgba(232,163,85,0.30)`, glyph `AMBER` | Dark-section variant of the feature-card badge |
| Primary button | `background AMBER`, `color #21160F` | Existing `PillButton primary` |
| "Coming soon" badge | outline pill: `rgba(232,163,85,0.14)` bg, `1px solid rgba(232,163,85,0.28)`, text `rgba(255,243,228,0.8)` | The reaction-pill recipe, *not* the solid-amber "Most popular" badge — it must not compete with the live macOS path |
| Metadata line | `rgba(255,243,228,0.45)` at 12.5px | The "Jacey highlighted Romans 8:28 · just now" footnote treatment |

**Contrast rule (non-negotiable, from Q14):** the Windows card is de-emphasized by dimming its **chrome** (border, surface, badge fill) — never by dimming its **text**. All body copy in both cards holds at `rgba(255,243,228,0.66)` or above against `INK`, which clears AA. Do not reach for a blanket `opacity: 0.5` on the Windows card; that is the exact anti-pattern the accessibility floor forbids here.

### Typography

Unchanged from the established system.

- **Eyebrow** — `HEAD_FONT` (Schibsted Grotesk), `11.5px`, `letter-spacing 0.26em`, uppercase, `AMBER`, `padding-bottom 22px`, bottom rule, `margin-bottom 56px`. Copy: `// ON YOUR DESKTOP` (preferred — matches the plain, phrase-like register of `// HOW IT FEELS DAY TO DAY` and `// BUILT FOR COMMUNITY` far better than a bare `// DOWNLOAD`). Alternate: `// GET THE APP`.
- **Section headline** — `HEAD_FONT`, `font-weight 400`, `clamp(32px, 4.2vw, 62px)`, `line-height 1.03`, `letter-spacing -0.03em`, `#FFF9F0`, with the trailing clause in `rgba(255,249,240,0.42)`. **Must follow the two-tone pattern** — it appears in every single section and its absence would immediately read as foreign. Lead candidate: *"Read on your desktop, `wherever the browser isn't.`"* Spec stage locks final copy; the pattern is the constraint, not the words.
- **Sub copy** — `BODY_FONT` (Hanken Grotesk), `16.5px`, `line-height 1.7`, `rgba(255,243,228,0.66)`, `max-width 34em`.
- **Card platform name** — `HEAD_FONT`, `12px`, `letter-spacing 0.2em`, uppercase, `#F0C08A` — the pricing card's plan-name treatment ("FREE", "GROUP") applied as "MACOS" / "WINDOWS".
- **Card title** — `HEAD_FONT`, `21px`, `font-weight 500`, `letter-spacing -0.02em` — the feature-card title treatment.
- **Metadata / requirements line** — `BODY_FONT`, `12.5px`, `letter-spacing 0.04em`, `rgba(255,243,228,0.45)`.

### Composition & layout

- Section padding `clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px)`; inner `maxWidth: 1240; margin: 0 auto` — identical to every non-hero section.
- **Two-card pair**, `display: grid`, `grid-template-columns: repeat(auto-fit, minmax(300px, 1fr))`, `gap: clamp(20px, 2.4vw, 32px)`, `align-items: stretch` — the exact pricing-grid recipe, which gives free single-column stacking below ~660px with no new breakpoint.
- **Card internals**, top to bottom: platform icon badge → platform name (uppercase, tracked) → card title → one-line description → flexible spacer (`flex: 1`) → action slot pinned with `margin-top: auto` → metadata line. Both cards use the same skeleton so they stack as a matched pair; only their surface treatment and action slot differ. Padding `38px 34px 40px`, `border-radius 20` — pricing-card geometry.
- **macOS card is unambiguously the primary path**: brighter surface, brighter border, real shadow, solid amber pill button. **Windows card is present and complete but visually recessed** — dimmer surface and border, outline "Coming soon" badge pinned top-right (the pricing card's absolutely-positioned badge slot, `top: 22, right: 26`).
- Touch targets: primary download pill at `padding: 16px 24px` minimum → comfortably over 44px tall. Card gap ≥ 20px.

### Windows "not yet available" treatment — **decided**

Resolves intake's second gap, and it is the single most design-sensitive decision in this section.

**Do not render a disabled button.** A greyed-out button that looks pressable but isn't is the classic anti-pattern, and it is also exactly what Q17 flags as a messy placeholder. Instead:

- Windows card carries a **"Coming soon" outline pill badge** top-right.
- Its description does the honest explaining, warmly and in one sentence — e.g. *"We started on macOS. The Windows build is on the way."* No technical framing, no ETA it can't keep, no apology.
- The action slot holds a **static status line, not a button** — same vertical position and height as the macOS button so the cards stay optically matched, but rendered as plain text/inline mark rather than a pill. Nothing on this card invites a click, so nothing needs to reject one.
- The whole card is **`cursor: default`, non-focusable, and carries no hover state at all.** Its stillness while the macOS card lifts under the pointer is itself the affordance — it communicates "not yet" through behavior, not through a stop sign.

Optional upgrade (a "notify me" email capture) is deliberately **not** specced: it adds a backend endpoint, storage, and consent scope well beyond a homepage section insert. Flagged forward as a user decision, not assumed.

### Iconography

Apple and Windows brand marks sit inside the standard `42×42` amber badge, at ~20px optical size, matching the feature-card badge geometry exactly.

**One deliberate departure from intake's assumption:** these are rendered as **filled glyphs (`fill="currentColor"`), not 1.6px-stroke `Ico` outlines.** Brand marks redrawn as thin outlines look off-brand and slightly counterfeit, and Apple's mark specifically is not meant to be outlined or restyled. The badge container is what carries the system's visual continuity here; the glyph inside it stays the official silhouette. Both marks must be optically weight-matched to each other (the Windows four-square mark reads heavier than the Apple mark at equal bounding box — size to optical balance, not to a shared box).

### Motion language

Per Q9 — rich, individually tuned, always eased, never linear.

- **macOS card hover:** `translateY(-4px)` + border brightens to `rgba(255,244,230,0.30)` + a soft amber shadow bloom. `220ms`, `cubic-bezier(0.22, 0.61, 0.36, 1)` (power2.out equivalent — the "Standard" hover tier). Transform/opacity/shadow only; never animate layout properties. Always pair a matching reverse transition so a fast pointer-out can't strand the state.
- **Primary button hover:** reuse the existing `.hm-btn-primary:hover` (lightens to `AMBER_LIGHT`) unchanged — do not invent a second button hover behavior.
- **Windows card:** no hover, no lift, no transition. Intentional.
- **Reduced motion:** the new card class must be added to the existing `@media (prefers-reduced-motion: reduce)` block in `Home.jsx`'s inline `<style>`, alongside `.hm-float` / `.hm-orbit-spin`. Do not add a second, separate media query.

### Copy metadata slot — **decided**

A single quiet footnote line under the macOS action, in the `rgba(255,243,228,0.45)` / 12.5px treatment.

- **Show:** file size and minimum macOS version — e.g. `Apple silicon & Intel · 3 MB · macOS 11 or later`.
- **Omit the version number in v1.** The Tauri config reads `0.1.0`, which undersells a signed, notarized, shipping build to a first-time visitor. The slot exists; the version string doesn't go in it yet.
- Real values must be sourced at `/build` time — the current `.dmg` measures ~3 MB and `tauri.conf.json` sets no explicit `minimumSystemVersion`, so the minimum-OS string is still unfilled (carried forward below).

### OS auto-detection — **decided: no**

Both cards always render, always in the same order (macOS first). No platform sniffing, no reordering, no pre-selection in v1. With only one platform actually shipping, auto-detection has no upside and one real downside: a Windows visitor would be auto-steered onto the card that can't help them. Revisit when the Windows build lands.

---

## Synthesis rationale

This is a **single-reference-plus-curated-matches** case, and the preference profile (Q1, Q15) points hard at fidelity over invention: an established system in live production code is the authority, and this section's job is to be indistinguishable from an original design pass. So the work here was **specific improvement and faithful extension**, not a new style.

**Primary reference — the live homepage** (5 attached screenshots, all viewed, plus `Home.jsx` read as ground truth). The screenshots confirmed what the source describes and added the things source alone doesn't convey: how heavy the hero's warm orb actually reads, how much air sits between the eyebrow rule and the headline, how the two-tone headline lands optically (the de-emphasized clause reads as a genuine second voice, not just faded text), and how much quieter the light sections are than the dark ones. Every token in this brief traces to a line in `Home.jsx`. The extensions I made rather than copied — the dark-run bookend argument for placement, the recessed-card variant, the dim-the-chrome-not-the-text contrast rule, the no-hover-as-affordance move on the Windows card, the outline badge chosen over the solid amber one — are all *derivations from* patterns already present, not additions to the vocabulary.

**Curated library — `.claude/visual-preferences/`.** Globbed all five categories; `web-hero-landing` and `widgets-dashboard-ui` were the plausible fits for a marketing-page card module and both were opened and reviewed rather than pulled wholesale. Two files genuinely match and contributed:

- **`widgets-dashboard-ui/original-c9bb392bb08dee4d5b031c6fc9df2cf8.webp`** — two side-by-side dark rounded cards, each representing one entity, each with a **platform brand mark badged in the top-right corner**, differentiated by a subtle surface tint rather than by layout. This is structurally the download-card-pair problem already solved, and it independently corroborates the badge-top-right placement that `Home.jsx`'s pricing card already uses. It reinforced the decision to differentiate the two cards by *surface treatment* while keeping their skeletons identical.
- **`widgets-dashboard-ui/original-82b43302403ccdd24262aad5e612ea80.webp`** — translucent frosted-glass cards floating over a warm desert-dusk amber gradient with soft glow orbs. Mood-wise this is nearly the FellowScript dark section already, and it confirms (per Q22, where glassmorphism is explicitly liked) that the `backdrop-filter: blur` + warm-orb-behind-card treatment is the right register for the download moment rather than a flat solid card.

The rest of `web-hero-landing` (monochrome editorial, blue-tech, food-brand red, hero-image-driven full pages) was reviewed and **deliberately not pulled** — those are hero compositions in unrelated palettes, and importing anything from them would violate the hold-to-the-established-system directive. `mobile-app-screens`, `before-after-comparisons`, and the empty `motion-references` folder have no bearing on a desktop web section and were not used.

**`ui-ux-pro-max`** grounded three specifics: the disabled-state guideline (which pushed me toward *not rendering a button at all* rather than the database's default `opacity-50 cursor-not-allowed`, since the stronger move is to remove the false affordance entirely); the "App Store Style Landing" pattern, which confirms platform-specific CTAs and download-CTA-near-the-end as convention (satisfying Q2's lean toward familiar patterns for a utility screen); and the Standard-tier hover preset (200–300ms, power2.out, ≤4px displacement, transform-only, always reverse-paired), which set the exact card hover numbers above.

---

## Carried-forward gaps

**Resolved at this stage** (no longer open): section placement, Windows-not-ready treatment, OS auto-detection, version-display policy.

**Still open — needs a real value before or during `/build`:**

1. **Minimum macOS version string.** `tauri.conf.json` sets no `minimumSystemVersion`, so the layout slot is specced but its text is unknown. Tauri's default floor is macOS 10.13, but that should be confirmed against the actual build rather than printed on a marketing page from a framework default.
2. **Hosted download URL.** The `.dmg` exists only at a local build path (`desktop/src-tauri/target/release/bundle/macos/FellowScript.dmg`, ~3 MB). The button must point at a real hosted artifact — GitHub Releases, CDN, or a backend route. This is a `/build` decision but blocks the section actually functioning.
3. **Windows "notify me" capture** — explicitly out of scope for this design, but it's the natural follow-up. If Jacey wants email capture on the Windows card, that's a backend endpoint plus consent handling and should go through `/build` as its own item, not be smuggled into this section.
4. **Linux** — still unmentioned by the user. The two-card `auto-fit` grid would absorb a third card without a layout change if it ever matters; assumed out of scope.

**Newly surfaced by synthesis:**

5. **Apple / Microsoft brand-mark usage.** No brand icon assets exist in the repo, and both marks carry usage guidelines (Apple's in particular restricts redrawing/outlining and constrains how the mark may appear in download contexts). The spec should hand `/build` inline SVG paths for the official silhouettes as filled glyphs. Low practical risk at this scale, but worth naming rather than discovering later.
6. **The doubled dark run (Download → Closing CTA) is the one rhythm compromise in this design.** It's argued for above as intentional bookending, and the reduced-orb treatment is specced to protect the Closing CTA's climax — but it is a judgment call, and it's the thing most likely to draw a reaction when Jacey reviews the mockup. Worth surfacing explicitly at review rather than letting it pass silently.
7. **Desktop-app value proposition copy.** The brief covers *how* the section looks but not *why* someone should want the desktop app over the web reader (offline? focus? menubar presence?). The section needs one honest reason in its sub copy, and nobody has stated one yet. The spec stage should either draw it from the desktop subproject's actual behavior or flag it back rather than inventing a benefit the app doesn't deliver.
