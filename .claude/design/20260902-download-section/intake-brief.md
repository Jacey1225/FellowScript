# Intake Brief — 20260902-download-section

## Request

> Design a new "Download" section for the FellowScript website homepage (https://fellowscript.com) that lets users download the desktop app's .dmg installer for both macOS and Windows. This is a static deliverable to be integrated into an existing homepage — a new section/component, not a full page or standalone asset.
>
> Context: FellowScript is a live product (see ~/Vscode/FellowScript/ repo, frontend at ~/Vscode/FellowScript/frontend/, React/Vite). A signed, notarized, stapled macOS .dmg installer already exists and works (built via Tauri, in the desktop/ subproject). Windows packaging has not been built yet, but the design should still include a Windows download option/button in anticipation of it.
>
> The user attached 5 reference screenshots of the CURRENT homepage, to be used as style/layout reference for how the new download section should visually integrate with the existing design language.
>
> The user wants the finished design reported back to them (in Discord) before any integration work happens — after this /design pipeline completes, a separate /build pipeline run will implement the approved design into the actual homepage codebase (~/Vscode/FellowScript/frontend/), so the deliverable from this pipeline should be a concrete, implementation-ready spec plus any generated visual reference, not the final coded component itself.

## Deliverable

A new homepage **section/component** (not a full page, not a standalone asset) for `fellowscript.com`: a "Download" section offering two platform download options — macOS (.dmg, live and working today) and Windows (anticipated, not yet built). The output of this `/design` pipeline run is an **implementation-ready design spec** (layout, copy, component states, interaction behavior, exact tokens) plus any generated visual reference (e.g. a mockup image) — not working code. A separate `/build` run will later implement it into `~/Vscode/FellowScript/frontend/`.

## References

- **5 attached screenshots of the current FellowScript homepage** (`/Users/jaceysimpson/.claude/channels/discord/inbox/1788383394101-1544816544599511060.png` through `.../1788383396062-1544816545979703377.png`), covering, in order: (1) hero section, (2) "how it feels day to day" steps + start of "everything you need" feature-grid section, (3) rest of feature-grid cards + start of "built for community" chat mockup section, (4) rest of community section + start of pricing section, (5) rest of pricing section + start of closing-CTA testimonial section. Together these give the complete visual language, section rhythm, and component patterns of the live homepage — the primary style/layout reference for how the new Download section should integrate.
- **`~/Vscode/FellowScript/frontend/src/pages/Home.jsx`** (read directly, not just the screenshots) — the actual source of the homepage referenced above. This is ground truth for the design system already in production use, more precise than the screenshots:
  - Palette: `INK #17120F` (dark section bg), `CREAM #F6EFE6`, `AMBER #E09A30` (primary accent, kept in-family with the in-app `--gold-light #E09A30` so the accent hue doesn't shift on a Home→Reader transition), `AMBER_LIGHT #F3C48B`, `LIGHT_BG #FBF7F1` (light section bg), `LIGHT_INK #1A1512` (text on light sections). Feature-card icon badges use `rgba(232,163,85,0.2)` bg / `#A9631F` icon color on light sections, `rgba(232,163,85,0.16)` bg / `AMBER` border+text on dark sections.
  - Fonts: `HEAD_FONT = 'Schibsted Grotesk', sans-serif` (headings, eyebrow labels), `BODY_FONT = 'Hanken Grotesk', system-ui, sans-serif` (body/buttons). Note this marketing-site pairing is deliberately distinct from the in-app Reader/Account theme (`theme.js`), which uses `'Lora'/'Playfair Display'` serif and a `colorPrimary #C8861A` amber-gold — the Home page keeps its own family in the amber hue but with grotesque sans typography.
  - Section rhythm: alternating dark (`INK`) / light (`LIGHT_BG`) full-width sections, `padding: clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px)`, content capped at `maxWidth: 1240` (hero uses 1400), centered.
  - Every section opens with an eyebrow label: `// SECTION NAME`, `HEAD_FONT`, `11.5px`, `letter-spacing 0.26em`, uppercase, colored `AMBER` on dark / `#B4712C` on light, `padding-bottom: 22px`, `border-bottom: 1px solid` (faint), `margin-bottom: 56px`.
  - Headings use `HEAD_FONT`, `font-weight: 400`, large `clamp()` sizes, `letter-spacing: -0.03em`, and consistently de-emphasize part of the phrase in a lower-opacity color (e.g. `rgba(255,249,240,0.42)` on dark, `rgba(26,21,18,0.38)` on light) — the two-tone-headline pattern repeats in every section.
  - Existing `PillButton` component (`to`, `primary` props): `border-radius: 999`, `padding: 15px 26px`, `Hanken Grotesk` 14px/600, primary = solid `AMBER` bg + `#21160F` text, secondary = `1px solid rgba(255,244,230,0.4)` outline + `#FFF8EE` text, `rgba(23,18,15,0.2)` bg. Hover states already defined via `.hm-btn-primary:hover` (lightens to `AMBER_LIGHT`) / `.hm-btn-outline:hover`.
  - Existing card patterns to reuse: light-section feature cards (`border: 1px solid rgba(26,21,18,0.13)`, `border-radius: 18`, `background: #FFFDFA`, icon badge + title + description); dark-section cards (`background: #1F1815` or `rgba(28,21,17,0.66–0.7)` with `backdrop-filter: blur`, `border: 1px solid rgba(255,244,230,0.16–0.18)`, `border-radius: 16–22`); pricing cards (`primary`/dark variant vs. `light` variant, with a pill "Most popular"-style badge absolutely positioned top-right).
  - `Blobs` component (radial-gradient warm orb + drifting dust) is reused across the Hero and Community sections for atmosphere on dark sections — available to reuse if the Download section lands on a dark background.
  - Motion: `prefers-reduced-motion: reduce` already respected globally (`@media` query disables `.hm-float`/`.hm-orbit-spin`); existing float/orbit keyframe patterns exist as reusable motion vocabulary.
  - No Tailwind — this codebase uses inline style objects + a few CSS-in-`<style>` classes, plus Ant Design (`antd`, `@ant-design/icons`) elsewhere in the app (not used on the Home marketing page itself).
- **`~/Vscode/FellowScript/desktop/`** (read directly) — confirms the deliverable's actual subject matter: `src-tauri/target/release/bundle/macos/FellowScript.dmg` exists and is built (Tauri, `productName: "FellowScript"`, `version: "0.1.0"` in `tauri.conf.json`). App icons are available at `src-tauri/icons/` (`icon.png`, `icon.icns`, and various sized PNGs) — usable as a source for an app-icon visual in the download section if desired. No Windows build/installer exists yet, and no `.exe`/`.msi` artifact or Windows-specific icon set was found.

No moodboard, external site, or brand-identity reference was attached beyond the homepage screenshots and live source — treat the existing homepage itself as the sole style authority.

## Desirables

- Visually integrate seamlessly with the existing homepage system above — not a bolted-on foreign component. Reuse the established eyebrow-label / two-tone-headline / pill-button / card vocabulary rather than inventing a new visual idiom.
- Two clear download options: **macOS (.dmg)** — live, functional, should read as the primary/ready path — and **Windows** — anticipated, not yet available, needs a way to be present without implying it works today (e.g. disabled state, "coming soon" treatment, waitlist/notify capture, or similar — left to the spec stage to decide from convention).
- Static deliverable — no video, no animated asset generation required, consistent with this being a section insert into an existing static marketing page (though the page's existing motion vocabulary, e.g. `hm-float`, subtle hovers, reduced-motion handling, may still apply to the finished component per the site's established rich-but-eased motion preference).
- Should read as an implementation-ready spec: specific enough (copy, layout, exact color/type tokens pulled from the existing system, button states, responsive behavior, icon choices) that a `/build` pass can implement it directly into `Home.jsx` without further interpretation.
- Platform icons (Apple logo, Windows logo) are expected — should use simple SVG line/brand icons consistent with the existing `Ico` line-icon convention already used for feature cards (`stroke="currentColor" strokeWidth="1.6"`), not photographic app-store badges.
- Should fit naturally into the existing section sequence (Hero → How it feels → Everything you need → Built for community → Pricing → Closing CTA → Footer) — exact placement is a synthesis-stage decision, but the natural candidate slots are directly after "Everything you need" (features) or right before/after "Pricing," since a download CTA logically follows "here's what it does" and pairs naturally with "here's how to get it."

## Preference profile

Relevant established answers from the UI/UX Design Philosophy module (`~/Downloads/ai_preference_survey_tracker.md`, Complete):

- **Q1 (creative synthesis vs. consistency):** Once a visual system is established (as it clearly is here, in live code), hold to it — this is squarely the "hold to the established system" case, not a fresh synthesis opportunity.
- **Q2 (originality vs. familiarity):** Screen-type dependent — a download/CTA section is a utility screen (like settings), so lean toward familiar, conventional download-section patterns rather than a novel layout, executed through the existing visual system.
- **Q7 (color):** Rich palette carrying brand/mood, not just function — the existing amber/ink/cream system already satisfies this; the Download section should carry the same warmth rather than defaulting to generic flat "download" iconography colors.
- **Q8 (spacing):** Systematic scale as default with deliberate deviations allowed; spacious/breathing-room both in outer and inner whitespace — matches the section padding already used throughout `Home.jsx`.
- **Q9 (motion):** Rich, expressive motion by default, each motion type tuned individually, always eased — never constant/linear (reads as robotic). Any hover/press states on the download buttons should follow this.
- **Q10 (interaction):** Minimal feedback by default, only where genuinely ambiguous — a disabled/"coming soon" Windows button is exactly the ambiguous case that *should* get explicit affordance (a visible reason it's not clickable), consistent with this exception.
- **Q12 (component philosophy):** Build custom to fit the synthesized system (already true — reuse `PillButton`, `Ico`, card patterns rather than a generic UI-kit download widget); fine to allow a similar-but-not-identical component rather than forcing full reuse.
- **Q14 (accessibility):** WCAG AA floor, AAA where practical; accessibility wins over mood by default. Download buttons are primary conversion targets — contrast and touch-target size matter here specifically.
- **Q15 (brand identity):** Hold to the established brand strictly — no sub-identity or divergent style for this new section.
- **Q17 (empty/loading/error states) — pet peeve:** Dislikes highly technical, messy, or redundant treatments. The "Windows not ready yet" state should stay warm and simple, not a technical placeholder.
- **Q22 (patterns to avoid):** Dislikes outdated-feeling systems generally; glassmorphism/neumorphism are liked, not avoided — the existing `backdrop-filter: blur` card treatment in `Home.jsx` is exactly this and is fair game to reuse for a download card.

## Gaps

- **Exact placement in the section sequence** — not specified by the user; two reasonable candidate slots identified above (after "Everything you need," or paired with "Pricing"), but not decided. Flag forward for synthesis/spec stage.
- **Windows button behavior when clicked** — no Windows build exists yet. Needs a decision: disabled/greyed with a "coming soon" label, an email-capture/notify-me micro-interaction, or a link to a waitlist — not specified by the user.
- **Version number / file size / release notes display** — common convention for download sections (e.g. "v0.1.0 · 42 MB"); not specified whether to show these, and the current Tauri version (`0.1.0`) may not be a version number intended for public display.
- **System requirements** — no minimum macOS/Windows OS version was specified for display copy.
- **Auto-detection of visitor's OS** — a very common convention for multi-platform download sections (highlighting/pre-selecting the button matching the visitor's platform); not requested explicitly, worth the synthesis/spec stage considering and flagging back rather than assuming.
- **Linux support** — not mentioned at all by the user; assumed out of scope, but not explicitly ruled out.
- **Exact download link/URL for the macOS .dmg** — the file exists locally at `desktop/src-tauri/target/release/bundle/macos/FellowScript.dmg`; how it will actually be hosted/served for a public download link (e.g. GitHub Releases, CDN, backend route) is a `/build`-stage concern, not fully specified here, and the spec stage should note the download must point at a real hosted artifact rather than a local build path.
- **Brand icon source for Apple/Windows logos** — no explicit brand icon assets for these were found in the repo; spec stage should specify simple official-shape SVGs consistent with the existing icon style rather than assume a specific icon library is available (no icon library beyond `@ant-design/icons`, which isn't used on the Home page, is present).
- **Deadline** — none given.

## Media type hint

**Static.** This is an explicit request for a homepage section/component insert (not a video, animation, or motion asset), consistent with the existing homepage being a conventional static React marketing page. The section may use the site's existing lightweight hover/float motion vocabulary, but the deliverable itself is a static UI spec, not a video/animation asset. Synthesis stage should confirm but no signal in the request points toward video.

## Success criteria

- The spec/mockup reads as a natural, on-brand extension of the current homepage — someone familiar with the live site should not be able to tell the Download section wasn't part of the original design pass.
- Both macOS and Windows options are clearly presented, with macOS reading as fully available/primary and Windows reading as honestly not-yet-available without looking broken or neglected.
- The spec is concrete enough (exact colors/type/spacing pulled from the real tokens above, copy, button states, responsive behavior) that a `/build` pass can implement it directly against `~/Vscode/FellowScript/frontend/src/pages/Home.jsx` with minimal further interpretation.
- Accessibility floor (AA contrast, adequate touch targets, clear disabled-state semantics for the Windows button) is met.
- The user, reviewing the finished design in Discord, would approve it as ready to build without needing another design pass.
