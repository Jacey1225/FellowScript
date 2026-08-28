# Intake Brief — Circular "Continue" button icon options (note-resume widget, Home dashboard)

Task: `20260828-continue-button-circle-icon-options`

## Request (verbatim)

> Redesign the "Continue" button on FellowScript's note-resume widget (Home dashboard). This button has been through several rounds of an in-app-implementation-only /build process already (as a pill-shaped, chamfered "island" with the text "Continue") — the user has now decided they want a different visual direction and wants to see a few real options before committing, via a proper /design pipeline pass this time.
>
> **New direction:**
> - Change the button from a pill/capsule shape with the text label "Continue" to a **circle** containing a **"continue" icon** (e.g. a play triangle, forward chevron, or forward arrow — propose appropriate icon options) instead of text.
> - Keep the same general placement: bottom-right corner of the note-resume widget card, on FellowScript's Home dashboard.
> - Keep the same general interaction/visual relationship to the card as it currently has: the button should slightly overlay/overlap the widget card (detached "island" effect, breaking past the card's own boundary at the corner), matching the current behavior — this part should NOT change, only the button's own shape (circle vs. pill) and content (icon vs. text) are in question.
> - The user explicitly wants **a few different design options**, wants **screenshots of each** to compare, and will pick their favorite to bring into a follow-up /build pass. So this pass's deliverable is genuinely a multi-option comparison, not a single finalized spec.
>
> [Reference materials and prior-context pointers as supplied — see References and notes below.]

## Deliverable

A small set (a "few," exact count left to the synthesis/spec stage) of distinct, real, rendered **screenshot comparison options** for a redesigned circular "Continue" affordance on the note-resume widget's bottom-right corner — each option pairing the circle shape with a specific candidate "continue" icon (play triangle, forward chevron, forward arrow, or another appropriate icon) and a specific fill/highlight/shadow treatment consistent with the app's existing visual language. This is explicitly a **multi-option comparison deliverable**, not a single finalized design spec — the user will pick a favorite from the rendered set to carry into a separate, later `/build` implementation pass. Placement and the card-overlay/breach mechanic are carried forward unchanged from the current shipped button; only the button's own shape and content are being explored.

**Flag for downstream stages (synthesis, spec, generation):** Because the deliverable is inherently multi-option, `design-reference-synthesis-agent` and whichever spec agent follows should treat "produce N distinct rendered options, not one locked design" as a first-class requirement, and `design-generation-agent` should expect to render multiple candidate images rather than a single asset.

## References

1. **`/tmp/fellowscript-screenshots4/2CF030F5-4CCD-432A-A7AC-FDD8206F6F8E.png`** (viewed directly) — Current shipped Home dashboard, real device/simulator screenshot. Shows the current pill-shaped, amber-gradient "Continue" button with dark-brown text, positioned at the bottom-right of the note-resume card and visibly overlapping/breaking past the card's own bottom-right corner (the "island" effect). Also shows the app's overall warm amber-on-dark visual language: an amber-to-dark vertical gradient behind the greeting header, dark glass/frosted cards below, gold accent text and badge outlines, a pill-shaped bottom tab bar. **Contributes:** current-state baseline, the exact placement/overlay behavior to preserve, and the color/material language new options should stay consistent with.

2. **`/Users/jaceysimpson/Vscode/FellowScript/.claude/pipeline/20260827-continue-island-shape-refinement/intake-spec.md`** and **`design-notes.md`** (both read directly). *Correction to the request's pointer:* the request named `.claude/design/20260827-note-widget-continue-island/design-spec.md` ("original design spec, revision 4") as a reference — that exact file does not exist on disk in this checkout (confirmed by direct search; the shape-refinement task's own design-notes.md independently notes "the original design-spec.md file itself is no longer present on disk in this checkout"). Its substance was recovered via direct quotes preserved in `intake-spec.md` (§2.2/§2.3/§4/§6) and via extensive comments citing it in the live source file. **Contributes:** the placement/overlay mechanic to preserve (island's trailing edge flush with the card's trailing edge, top edge inset 42% of island height above the card's bottom edge, 58% of island height overhangs below the card's own frame, 12pt gutter separation, chamfered top-left corner keyed to a matching card notch — this chamfer/notch mechanic is pill-specific and won't directly carry to a circle, per the request's own framing); color/gradient tokens (`#EEAC3F`→`#C88C2C` linear gradient fill, `#24170A` dark-brown content color, `#F5D392` top-rim highlight stroke faded via gradient mask, a three-shadow stack — zero-offset separation shadow blurred at gutter+2pt, ambient shadow, contact shadow); the 4/8/16/20pt spacing grid; the 44×44pt minimum touch-target convention (`islandHeight = max(44, labelSize.height + 22)`); Dynamic Type handling (all island geometry re-measured live from the rendered label, with a §4 fallback to a full-width plain capsule when the island would exceed 45% of card width).

3. **`/Users/jaceysimpson/Vscode/FellowScript/.claude/pipeline/20260827-continue-island-shape-refinement/design-notes.md`** (most recent shape-refinement pass, read directly — same file as above, cited separately per the request's own framing). **Contributes:** the app's general spacing/gutter/separation conventions (zero-offset separation shadow as the primary structural separation cue, a de-emphasized flat hairline as a secondary accent, 1pt canonical hairline weight app-wide) and shadow-vs-hairline elevation layering approach — these carry forward as general conventions even though the specific corner-radius/chamfer-join numeric decisions in this file are pill/chamfer-construction-specific and don't directly apply to a circle.

4. **`/Users/jaceysimpson/Vscode/FellowScript/FellowScript/FellowScript/Dashboard/DashboardComponents.swift`** (read directly, full `NoteResumeCard`/`ContinueIslandShape`/`NoteResumeCardNotch`/`glassCard` implementation). **Contributes:** ground truth for real implementability — confirms a plain `Circle()` clip shape is a strictly simpler SwiftUI construction than the current custom `CGMutablePath` chamfer-fillet geometry (the request's own framing is correct: this is a genuine implementation-complexity benefit worth surfacing in the options); confirms the current button's exact sizing mechanism (height floors at 44pt, width is driven by measured label text — a mechanism that doesn't transfer to an icon-only circle, since there's no label to measure width from, so circle diameter needs its own resolved sizing logic); surfaces two **existing circular-icon-button precedents already on this same screen** worth drawing stylistic kinship with — `CheckInRow`'s two-tone nested-circle paper-plane "send" button (56pt outer gradient ring, 50pt inner dark circle, icon centered) and the empty-state card's 38pt dark circle with a white arrow-right icon; confirms the existing accessibility pattern (`.accessibilityLabel("Continue reading \(noteTitle)")` on the button itself, decoupled from visible content) that an icon-only circle should keep using.

No Miro board or other reference was supplied.

## Desirables

- Circle shape, replacing the current pill/capsule.
- An icon inside the circle (not text) — candidate icons explicitly invited: a play triangle, a forward chevron, a forward arrow, or another appropriate "continue" icon; propose more than one candidate as part of the option set.
- Same general placement: bottom-right corner of the note-resume widget card.
- Same overlay/overlap mechanic: the button should still slightly breach the card's own boundary at that corner (detached "island" effect) — this specific behavior is explicitly called out as **not** to change, only the button's shape and content are in question.
- Visual/material continuity with the app's existing warm amber-on-dark language: gold gradient fill, dark-brown icon color, subtle top-rim highlight, layered shadow treatment — nothing in the request asks to change the color story.
- Carry forward the 44×44pt minimum touch-target constraint from the prior pill spec as a hard floor.
- Carry forward Dynamic Type awareness as a design consideration, with the explicit caveat that the *old* label-driven sizing mechanism doesn't transfer to an icon-only circle and needs its own resolution (see Gaps).
- Realistic SwiftUI implementability, informed directly by the actual component source — the request explicitly notes a circle is "generally simpler" than the current chamfered-capsule construction and wants that benefit reflected in the options.
- A genuinely multi-option, comparison-oriented deliverable (real screenshots per option) rather than one finalized spec — the user picks a favorite afterward, to be handed to a separate follow-up `/build` pass.

## Gaps

(Flagged forward for synthesis/spec to resolve or re-flag — not blocking this intake pass.)

- **Exact icon choice** among the candidates (play triangle / forward chevron / forward arrow / other) — intentionally unresolved; the multi-option format is itself the mechanism meant to resolve this, not a gap to close now.
- **Exact number of options** — the request says "a few" with no specific count; synthesis/spec should pick a reasonable number (e.g., 3–4) that meaningfully varies icon choice and/or secondary treatment (filled vs. outlined icon, solid vs. gradient fill, two-tone nested-circle vs. single-tone, with/without top-rim highlight) rather than treating this as blocking.
- **Circle diameter / sizing logic.** The old pill's width was driven by measured label text width (`labelSize.width + 36`) and height floored at 44pt; an icon-only circle has no label to size against, so a fixed diameter (or a small set of Dynamic-Type-aware size steps) needs to be chosen at the spec stage — informed by the 44pt minimum touch target and by the two existing circular precedents already on this screen (56pt outer / 50pt inner CheckInRow button, 38pt empty-state button).
- **Icon size/weight and fill treatment within the circle** — solid gradient fill vs. a two-tone nested-circle treatment (like `CheckInRow`'s), icon stroke weight, whether the top-rim highlight and three-shadow stack carry over unchanged — open per-option decisions.
- **How the circle should meet the card's corner.** The request says the overlay/overlap behavior should not change, but the *mechanism* by which the old pill met the card (a chamfered top-left corner keyed to a matching diagonal notch cut into the card) is geometrically specific to a rounded-rect-with-one-cut-corner silhouette and has no direct equivalent against a circle (there's no shared diagonal to key a notch to). Whether the card keeps a notch at all, uses a plain overlap with no notch, or some other treatment for a circular button is a real open design question for the spec stage, not something directly inheritable from the pill precedent.
- **Dynamic Type / accessibility-text-size scaling behavior for an icon-only circular button** — unresolved, since the mechanism that scaled the old pill (measuring rendered label text) doesn't apply to a fixed icon.
- **Whether the empty-state card's own existing 38pt circular arrow-right affordance should visually reconcile** with a newly-circular populated-state Continue button, now that both would be circles on the same widget in different states — not raised by the user, worth flagging to synthesis.
- No explicit dimensions/aspect ratio were given for the *screenshots themselves* (e.g. device frame, resolution) — reasonable to default to the same device framing as the supplied reference screenshot unless synthesis decides otherwise.
- No explicit deadline or variant count constraint (e.g. light/dark mode — app is forced dark already per source comments, so this is likely moot) was given.
- Platform is implicitly iOS/SwiftUI only (matches the existing codebase and screenshot) — no multi-platform ask.
- The prior "revision 4" design-spec.md file referenced by the request is missing from disk (see References §2) — a documentation-completeness gap, not a blocker, since its substance was recovered via quotes and code comments.

## Media type hint

**Static.** The explicit deliverable is "a few different design options" with "screenshots of each... to compare" — a set of static UI mockup images, no animation, transition, or video requested anywhere in the request. High confidence; synthesis makes the final call.

## Success criteria

- Multiple genuinely distinct circular "Continue" button options are produced, each as an actual rendered screenshot (not just a verbal description) — the user needs to visually compare, not read about, the differences.
- Each option clearly shows: the circle shape, one specific candidate icon (play triangle / forward chevron / forward arrow / other), and the same bottom-right card-corner overlay/breach placement the current button uses.
- Every option stays visually consistent with FellowScript's existing warm amber-on-dark, glass-card visual language shown in the reference screenshot (gold gradient fill, dark-brown content color, layered shadow treatment) — no option should read as an off-brand departure.
- Each option is grounded in what's realistically buildable in this SwiftUI codebase (informed by the actual `DashboardComponents.swift` structure), so that whichever option the user picks can go directly into a follow-up `/build` implementation pass without a redesign detour.
- The user can look at the finished set and clearly identify a favorite — the deliverable succeeds if it enables a confident choice, not if it prematurely narrows to one answer.
- Downstream pipeline stages carry forward the multi-option requirement explicitly (per the flag above) rather than collapsing this into a single-answer spec or single generated asset.
