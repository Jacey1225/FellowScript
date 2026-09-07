# Intake Brief

## Request

> "There are some profile pics aligned horizontally like this Discord UI, and I would like the same idea to show up in the friend activity widget of the homepage in the iOS app here."

(Via Discord Development channel, jacey1006. A reference screenshot arrived slightly after the initial request — see References.)

## Deliverable

A layout revision to the **existing** Friend Activity widget (`FriendActivityHeroCard`, in `FellowScript/FellowScript/FellowScript/Dashboard/DashboardComponents.swift`) on the FellowScript iOS app's home dashboard — specifically its horizontal row of friends' profile photos — restyled to match the Discord reference pattern described below. This is a static SwiftUI UI layout deliverable (not video/animation), scoped to an existing widget inside an existing app, not a net-new standalone asset.

## References

1. **`/Users/jaceysimpson/.claude/channels/discord-development/inbox/1788741666599-1546319343984443452.png`** — the user's actual attached reference (arrived after the initial text request). Screenshot of Discord's **mobile "Messages" tab**. Contributes the **exact layout pattern** to emulate:
   - Below the header ("Messages"), a search field, an "Add Friends" pill, and a blue circular "+" button.
   - A **horizontally-scrollable row of rounded-square ("squircle") cards** — an "active friends" strip. Cards are dark, roughly square, generously rounded corners (~24px), with visible gaps between them (not overlapping/stacked).
   - Each card contains a **circular profile photo inset**, roughly centered/lower within the card, with padding around it (the photo does not fill the card edge-to-edge).
   - Each card has a **small circular status/activity badge** overlapping the **bottom-right corner of the circular photo** (not the card) — a distinct ring/fill color from the card background, containing either an icon (e.g. a moon/crescent glyph seen on one card, suggesting a "do not disturb"/night-activity state) or a plain neutral ring (seen on two other cards, suggesting a generic "active"/unspecified-activity state).
   - This is Discord's **"active friends" horizontal strip**, distinct from Discord's other well-known avatar pattern (a tightly-overlapping circular facepile used in voice-channel participant lists) — the attached reference confirms the card-based, non-overlapping, corner-badged variant is the one the user means, not the overlapping-circle facepile initially assumed before the image arrived.

2. **Live web/browser lookup of the general Discord avatar-row pattern** — attempted via the `agent-browser` skill, but the underlying `belt` CLI is not installed/authenticated in this environment. No live corroborating source was retrieved; the attached screenshot above is the sole and authoritative visual reference for this task. Noted here rather than silently falling back to unverified assumption.

3. **Existing widget source** — `/Users/jaceysimpson/Vscode/FellowScript/FellowScript/FellowScript/Dashboard/DashboardComponents.swift`, `FriendActivityHeroCard` (lines ~211-451). Contributes the **current state to revise**:
   - It already has an `avatarStackRow` (lines 296-314): a right-aligned `HStack(spacing: -9)` of up to 4 tightly-**overlapping** 28pt circular `AvatarView`s (photo-with-initials-fallback), each with a 2pt stroke in `Theme.bgPage` for separation, plus a "+N" overflow circle beyond 4 friends. This row is currently **purely decorative** (`.accessibilityHidden(true)`, no tap target).
   - This existing pattern is the *overlapping facepile* style, not the *card strip with corner badge* style shown in reference 1 — the requested change is a real restyle, not confirmation of already-matching work.
   - `activityRow` (lines 316-343) below it shows one enlarged avatar (32pt) for the single most-recently-active friend, with headline text and a chat-navigation tap target — this stays relevant context for how avatar identity/tap-navigation already works elsewhere in the same card, even though it's a separate sub-component from the avatar row itself.
   - `AvatarView` (lines 91-129) is the shared circular photo/initials-fallback component already used everywhere avatars appear in the app (Dashboard, Chat, Notes) — the new card treatment should compose this existing primitive (photo, initials fallback, crossfade-in behavior) rather than reinventing avatar rendering from scratch.
   - `FSFriendActivityEntry` (referenced via `Models.swift`, not fully read this pass) already carries `activity_type` (`note_created`/`note_edited`/`note_replied`/`verse_highlighted`) and `last_active_at` per friend — a plausible real data source for the reference's per-card status badge, though the reference's badge glyphs (moon/plain ring) don't map cleanly onto FellowScript's activity-type set and that mapping is not yet defined (see Gaps).
   - `DashboardViewModel` (`DashboardView.swift`) fetches/holds `friendActivity: FSFriendActivityFeed`, feeding `FriendActivityHeroCard(feed: vm.friendActivity, ...)` from `DashboardView.swift` (~line 216).

## Desirables

- Friends' profile photos should be **aligned horizontally** in a **row of individually-bounded cards**, not the app's current tightly-overlapping circular facepile.
- Each card: **rounded-square container**, circular photo inset within it (not edge-to-edge), generous rounding, dark/glass treatment consistent with the rest of the dashboard's existing glassmorphism language (`glassCard` extension already used throughout this file).
- Each card carries a **small circular badge overlapping the avatar photo's bottom-right corner**, distinct in color/fill from the surrounding card, to indicate some form of per-friend status or activity — mirroring the reference's badge, adapted to whatever status/activity concept the widget actually has data for.
- Row should be legible and thumb-scannable at a glance on the home dashboard, matching the general "friend activity" purpose the widget already serves (surfacing what friends have been up to).
- Should compose the app's existing `AvatarView` primitive and `glassCard` styling rather than introducing a visually inconsistent one-off treatment.

## Preference profile

From `~/Downloads/ai_preference_survey_tracker.md`, UI/UX Design Philosophy module (Complete, 23/23) — answers bearing on this deliverable:

- **Q3 (visual system depth):** A comprehensive visual system (palette, typography, iconography, shape language, elevation, stroke/texture, personality) should already be treated as established/locked for an existing app like FellowScript, not reopened — the new avatar-card treatment should sit inside the current system, not introduce a new one.
- **Q12 (component philosophy):** Build components custom-fit to the synthesized visual system rather than skinning a generic primitive library; similar-but-not-identical per-screen components are fine until reuse is actually needed — supports adapting/extending `AvatarView`/`glassCard` in place rather than forcing full reuse across every avatar context in the app. Also: "dislikes stale, boring, minimally-functional dashboard widgets" and wants dashboards to use unique, highly-functional widgets tailored to the project — relevant since this widget's avatar row is currently purely decorative (`accessibilityHidden`, no tap target) and the redesign is a chance to make it more functional, not just re-skinned.
- **Q9 (motion):** Rich, expressive motion/micro-interactions by default, but every motion type individually tuned, and always eased — never constant/linear ("robotic") speed. Any new tap/press feedback on these cards (if made interactive) should follow this.
- **Q18 (micro-interactions):** Look for opportunities to add small functional delight moments by default (not purely decorative ones) — relevant if the avatar row becomes tappable.
- **Q10 (interaction feedback):** Minimal feedback by default, only where genuinely ambiguous — don't over-animate confirmation of a simple tap.
- **Q14 (accessibility):** WCAG AA floor, AAA where practical; reduced-motion support first-class from the start. The current row is `accessibilityHidden` — if it becomes a real interactive element (not just decorative), it needs a real accessibility treatment instead of staying hidden.
- **Q17 (empty/loading/error states):** Keep any empty/loading fallback for this row minimal and unfussy (plain, no invented expressive animation) per the established default.
- **Q4 (layout, follow-up):** Spacious/breathing-room as the general default, in both outer and inner whitespace — argues for the reference's generously-gapped, non-overlapping card row over the app's current tightly-packed overlap.

## Gaps

- **Status/activity badge semantics**: the reference shows a moon glyph on one card and plain neutral rings on two others — unclear whether these map to a real Discord concept (do-not-disturb / online / idle) that should be reinterpreted for FellowScript's own activity model (`note_created`/`note_edited`/`note_replied`/`verse_highlighted`, or simply "recently active" vs. not), or whether the badge should just be a generic "has new activity" indicator. Needs a decision at the synthesis/spec stage.
- **Interactivity**: current avatar row is purely decorative (no tap target, `accessibilityHidden`). Unclear whether the new card row should become tappable per-friend (e.g. opening that friend's chat, as `activityRow` already does for the single headline friend) or remain decorative like today.
- **Scroll vs. fixed count**: the reference row scrolls horizontally with presumably many friends; the current widget caps at 4 visible + a "+N" overflow circle. Unclear whether the redesign should adopt true horizontal scrolling or keep the fixed-count-plus-overflow approach adapted into card form.
- **Placement relative to `activityRow`**: today the avatar row sits above a single expanded "headline friend" activity block in the same card. Unclear whether the new card row replaces that pairing, sits alongside it unchanged, or the whole card's structure should be reconsidered.
- **Exact card/photo/badge sizing, corner radius, and color values**: not specified by the user; to be derived from the reference screenshot's proportions and the app's existing token values (`Theme.bgPage`, `Theme.gold*`, existing `glassCard` corner radii of 20-24pt) at the spec stage.
- **Quantity/variant**: no explicit variant count requested (e.g., light/dark, or multiple layout options) — single deliverable assumed.
- **Deadline**: none stated.

## Media type hint

**Static.** This is a UI layout/component design change to an existing SwiftUI screen (no motion/video requested); the user's own framing ("show up in the friend activity widget") and the reference (a static screenshot) both point to a static layout deliverable. Final call belongs to the synthesis stage.

## Success criteria

- The Friend Activity widget's row of friend avatars reads, at a glance, as the same *idea* as the Discord reference: individually-bounded rounded-square cards laid out horizontally, each with an inset circular profile photo and a small corner status/activity badge — not the app's current overlapping-circle facepile.
- The new treatment is visually consistent with FellowScript's existing dashboard design system (glassmorphism cards, existing color tokens, existing `AvatarView` avatar rendering with initials fallback and photo crossfade).
- Real data continues to drive the row (no fabricated placeholder friends/photos) — falls back gracefully (per `AvatarView`'s existing initials-fallback and the widget's existing `noFriendsState`) when data is sparse or absent.
- Accessibility is deliberately decided rather than left as an accidental carry-over: if the row becomes interactive, it gets real labels/hit targets; if it stays decorative, that's an explicit choice, not an oversight.
- The change lands as a scoped revision to `FriendActivityHeroCard`/`avatarStackRow` (and `AvatarView` if extended), not a rewrite of the whole Dashboard.

## User amendment (2026-09-06, after static-spec/critique already started)

The user added a new requirement mid-pipeline:

> Remember there must be a small nudge interaction that should ideally be placed on the top right corner of the profile

This ties directly into the separate, parallel `/build` task `20260906-friend-nudges` (a feature letting a user send a friend a push-notification "nudge"). That task's architecture had decided the nudge trigger would live ONLY on the existing `CheckInRow` CTA, with no second entry point. This new instruction asks for a small nudge-trigger affordance placed in the top-right corner of each friend tile in THIS widget (the new avatar row being designed here) — a second, additional entry point the sibling task's architecture explicitly ruled out. The two tasks now need to be reconciled: this design spec should carry a small tappable nudge icon/control in each tile's top-right corner (sized/positioned to not collide with the existing bottom-right status badge), and the sibling build task's architecture needs to be revisited to wire that control to the nudge endpoint as a second, now-required entry point.

This amendment supersedes the design-spec's current top-right corner treatment (previously undecorated) and is being fed back to the static-spec step for a revision before critique's findings are finalized.
