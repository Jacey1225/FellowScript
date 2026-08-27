# Intake Brief — 20260826-friend-activity-dashboard-revision

## Request

> revise an existing design mockup (a finished static deliverable, not new-from-scratch), for the FellowScript project.
>
> Existing reference (the current version to revise — full HTML saved locally, read it directly): /Users/jaceysimpson/.claude/projects/-Users-jaceysimpson/ea90f968-0bb0-4369-9616-4d345baf4606/tool-results/artifact-c535906c-1787795237-b41d.html
>
> This is "Friend Activity Dashboard, Editorial Hero" (Variant C), a warm gold/parchment iPhone-shell UI mockup showing a home dashboard with: a "Friend Activity" hero card ("Sarah wrote a note today", note preview, avatar stack), a "Check in with Sarah" nudge row, and a "Pick Up Where You Left Off" note-resume card. It also has a radial gold glow effect behind the hero card and a gradient wash at the top of the phone screen.
>
> Requested changes (verbatim):
> 1. Remove the small section header labels inside the widgets — specifically "Friend Activity" and "Pick Up Where You Left Off" (these are the `.sec-label` elements at the top of each glass card).
> 2. Make the background gold glow more natural and subtle (currently a fairly saturated radial gradient wash down the top of the phone screen, `linear-gradient(180deg, var(--grad-1)...)` plus a `.hero-glow` radial blur behind the hero card).

## Deliverable

A **revision** of an existing finished static mockup — a single self-contained HTML/CSS artifact rendering an iPhone-shell home-dashboard screen ("Friend Activity Dashboard, Editorial Hero" / Variant C) for the FellowScript app. Not a from-scratch design: the base layout, component structure, typography, color tokens, and content are to be preserved. Two targeted edits only:

1. Remove two `.sec-label` elements (the "Friend Activity" eyebrow label inside `.hero-card` at line 553, and the "Pick Up Where You Left Off" eyebrow label inside `.note-card` at line 595) and adjust the resulting spacing so removal doesn't leave dead whitespace or misaligned layout.
2. Reduce saturation/intensity of two gradient effects:
   - The `.screen` background wash — the `linear-gradient(180deg, var(--grad-1) 0%, var(--grad-1) 12%, var(--grad-2) 20%, var(--grad-3) 30%, var(--grad-4) 40%, transparent 50%)` layered over `var(--bg-app)` (lines 106-116).
   - The `.hero-glow` radial blur behind the hero card — currently `radial-gradient(60% 60% at 50% 42%, rgba(212, 146, 42, 0.10), transparent 70%)` with `filter: blur(50px)` (lines 200-210).

## References

- `/Users/jaceysimpson/.claude/projects/-Users-jaceysimpson/ea90f968-0bb0-4369-9616-4d345baf4606/tool-results/artifact-c535906c-1787795237-b41d.html` — the base/current version to revise. Full self-contained HTML file (fonts: Outfit/Lora/Inter via Google Fonts; all styling inline `<style>`). Contributes: complete layout structure, all copy/content, color token system (`--grad-1..4`, `--gold*`, `--parchment*`, `--ink*`), component styling (glass-card, hero-card, checkin-row, note-card), and the exact two elements/effects targeted for change. This file was read directly (not treated as opaque) — its full CSS and markup are captured above with line references for the two change targets.

No other references (moodboard, brand guide, competing variant screenshots, Miro board) were provided or pointed to in the request.

## Desirables

- Preserve everything not explicitly called out: overall layout/composition, phone-shell chrome (dynamic island, status bar, home indicator, tab-bar pill), typography choices and scale (Outfit/Lora/Inter, the 36px editorial headline that defines "Variant C"), copy/content, avatar stack, check-in nudge row, note-resume CTA, glass-card blur/border treatment, color token names and values not tied to the two flagged effects.
- **Change 1 (remove sec-labels):** Both `.sec-label` divs (`Friend Activity`, `Pick Up Where You Left Off`) removed cleanly, with the affected containers' internal spacing rebalanced — `.eyebrow-row` in the hero card currently uses the label as one flex child opposite the avatar stack (removing it will leave the avatar stack alone in a `justify-content: space-between` row, likely needing `flex-end` or a repositioned/resized top margin); `.note-card`'s label currently sits directly above `.note-headline` with no other spacer, so headline top-spacing will need to absorb the label's implicit gap. Card must not look like it's missing a piece — no orphaned empty flex rows, no headline crammed against the card's top edge/border.
- **Change 2 (soften the glow):** Result should read as "natural and subtle," not just "less opacity for its own sake." Per the ui-ux-pro-max style-intelligence database, dark-mode ambient-glow conventions in comparable premium mobile UI keep glow effects to roughly opacity 0.08–0.12 with soft large-radius blur (30–50px) rather than a banded, saturated linear wash — the current `.screen` gradient (lines 106-116) is a hard 5-stop banded wash hitting full `--grad-1` (#C98420, fully opaque) for its first 12% before stepping down, which is the "fairly saturated" quality the user flagged. A more natural treatment likely means: fewer/softer stops, no fully-opaque gold at any stop, a wider/gentler falloff (echoing the existing `body::before` page-level radial glow, which already uses a restrained `rgba(201,132,32,0.16)` — that's a plausible reference point for "natural" within this same file). The `.hero-glow` radial (already fairly restrained at 0.10 opacity/50px blur) should get a comparable but even lighter pass — lower opacity, and/or a softer edge falloff — rather than a total overhaul, since the user's complaint was more clearly aimed at the phone-screen wash than at this element specifically.
- Both effects live on gold/amber (`--grad-1..4`, `--gold*` tokens) and should stay in that hue family — "natural" means restraint in saturation/opacity/banding, not a hue or theme change.
- Output should remain a single self-contained HTML file matching the existing file's structure/conventions (inline `<style>`, same Google Fonts links, same `.stage`/`.phone-shell`/`.screen` scaffold) so it stands as a drop-in revision of the same artifact.

## Gaps

- No explicit numeric target for the new gradient opacity/stop values — the user described the desired *quality* ("more natural and subtle") but not exact numbers. Synthesis/spec stage should propose specific values (informed by the "Desirables" reasoning above) rather than treating this as blocking.
- No confirmation on whether the `body::before` page-level backdrop glow (outside the phone shell, lines 57-66) is in scope — the request named only the `.screen` gradient and `.hero-glow`, so this is presumed out of scope, but should be flagged if the revised phone-screen glow ends up looking inconsistent next to it.
- No file naming / output location convention given for the revised HTML (e.g., save as a new "Variant C v2," overwrite in place, filename pattern for the design pipeline's generated asset). Downstream generation step will need to decide/confirm.
- No confirmation whether other captions/labels referencing "Variant C — Editorial Hero" in the page eyebrow/caption text (lines 518, 620) should be updated to reflect the revision — presumed unchanged since request only names the two `.sec-label` elements and the glow effects.
- No Miro board or other design-tool reference was cited in the request, so no board-lookup was needed for this task.

## Media type hint

**static**. The deliverable is a single static HTML/CSS mockup screen (a phone-shell UI frame), no motion, animation, or duration specified either in the original artifact or in the revision request. Both requested changes are static-property edits (removing DOM elements, adjusting gradient/color values).

## Success criteria

- Both `.sec-label` elements ("Friend Activity" and "Pick Up Where You Left Off") are absent from the revised markup, and neither card shows a layout artifact (empty gap, misaligned avatar stack, headline crowding the card edge) from their removal.
- The `.screen` top-of-phone gradient wash reads as visibly softer/less saturated than the original — no hard-edged fully-opaque gold band — while still legibly signaling "warm gold light source at the top of the screen" consistent with the mockup's overall gold/parchment editorial identity.
- The `.hero-glow` radial behind the hero card reads as a soft ambient bloom rather than a discrete gradient outline; not obviously stronger or more saturated than the toned-down `.screen` wash.
- All other elements, copy, layout, and color tokens unrelated to the two flagged changes remain identical to the original file.
- The revised file remains a valid, self-contained, renderable single HTML file in the same structural pattern as the original.
