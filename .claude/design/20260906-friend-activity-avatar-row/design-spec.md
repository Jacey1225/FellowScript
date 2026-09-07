# Design Spec — Friend Activity avatar row

Task: `20260906-friend-activity-avatar-row`
Stage: 3 (static spec), **revision 3** — bounce from critique (pass 2 of 3, second and final bounce budget; this revision must pass)

---

## Revision changelog (against the version critique reviewed)

Every numbered issue in `critique.md` is addressed below; item numbers match that document.

**Pass-1 findings (1–10): untouched in this revision.** Critique's second pass independently verified all ten against the real source and confirmed none regressed. This revision does not re-open, restate, or re-derive any of them — the changelog entries below are left exactly as pass 2 read them. Everything in this revision is scoped to the new nudge-trigger control (issues 11–20, all raised for the first time in pass 2, since the control did not exist in pass 1).

1. **Tile elevation inverted** → tile fill replaced (`Theme.cardBg` was darker than the page itself; parent glass is lighter than the page). New fill is a flat white-wash overlay drawn on top of whatever the parent renders, guaranteeing a relative lift regardless of runtime `.ultraThinMaterial` compositing. Hairline raised `0.10 → 0.14`.
2. **Hollow badge fails WCAG 1.4.11** → stroke opacity `0.28 → 0.45`, width `1.5 → 2pt` (3.94:1 against the old tile value; must be reverified against the new tile fill, floor stated explicitly as a build-time check).
3. **Badge 48% oversized** → `16pt → 11pt` badge, `21pt → 16pt` cutout ring, restoring the stated 0.27×-avatar derivation.
4. **Four illegible 7pt glyphs** → dropped entirely. Badge is now a pure two-state shape (filled gold dot / hollow ring); activity type is spoken only via the accessibility label and the 28pt headline below, never a mark that shrinks under Issue 3's fix.
5. **Caption overflow contradiction** → `.frame(width:)` moved onto the `Text` itself; the "allow overflow" permission is deleted.
6. **Three internal contradictions** → (a) `activityRow` moved from "unchanged" to "modified — one padding value"; (b) **both** the populated-state padding (L353) and the no-activity-branch padding (L292) go `14 → 16`; (c) the accessibility label no longer composes with a duplicate username — fixed on the new tile **and** on `activityRow`'s existing label (L356), since both compose `headline(_:)`, which already includes the name. *(Line numbers shown here reflect the file's current state — see the Deliverable section's note on why they shifted by 14 from what pass 1/2 originally cited; the fix itself is untouched.)*
7. **Random "selected" ring** → the row no longer reorders `friends_active`. The gold ring is applied in place, wherever the (randomly-picked) primary friend naturally falls; presence is guaranteed via union-after-cap instead of a destructive reorder.
8. **Silent truncation + eager HStack** → `HStack` → `LazyHStack`; cap raised `12 → 50` (a LazyHStack makes the perf argument for a low cap moot, and 50 covers essentially every real friend count without inventing a new "See all" screen).
9. **Sub-12pt caption via `minimumScaleFactor`** → deleted. Caption font now scales with Dynamic Type via `@ScaledMetric` through the standard range; overflow is absorbed by Issue 5's fixed-width truncation, not shrinkage. (Deviates slightly from the critique's suggestion to also `@ScaledMetric` the *tile*: growing the squircle would perturb the locked "4 full + peek" visible-width math for no correctness gain, since truncation alone already prevents collision — reasoned below under Styling.)
10. **Redundant accessibility traits** → dropped; tile uses plain `Button` + `.accessibilityLabel` only, matching `activityRow`/`notePreviewRow`'s existing house style.

**New in this revision (fixes 11–20, all against the nudge-trigger control added last pass):**

11. **Ambiguous/broken layering (critical)** → the control's `ZStack` position is now stated once, unambiguously, as a **sibling** of the tile's chat `Button` — never nested inside its label. Added a belt-and-braces `.accessibilityAction(named: "Nudge")` on the tile itself.
12. **Hollow-badge contrast eroded back toward the floor by the Issue-1 tile-lightening fix** → stroke raised again, `0.45 → 0.70` (2pt unchanged), recomputed against the tile's actual current fill value at **≈5.49:1** (see Styling), and the acceptance criterion restated as "≥4:1 with headroom" rather than "≥3:1, verify later."
13. **Nudge control overlapped the avatar with no cutout ring** → given the identical tile-fill cutout treatment the status badge already gets (23pt cutout behind the now-18pt control, same 2.5pt-per-side ring proportion as the badge's own 16pt/11pt pair).
14. **No implementation contract for the callback/state** → clarified that `onNudge` **already exists** on `FriendActivityHeroCard` (added by the sibling `/build` task since pass 1, defaulted per the file's own `onOpenNote` convention) and added the missing per-friend state input, `nudgeStates: [String: NudgeUIState] = [:]`, reusing the file's **existing** shared `NudgeUIState` enum (already driving `CheckInRow`) instead of inventing a parallel one.
15. **Undefined "tapped, then rate-limited" path** → resolved by adopting `NudgeUIState` wholesale: `.rateLimited` renders identically to `.sent` (disabled, `checkmark`, no red pulse); `Theme.error` is reserved for `.failed` alone, matching `CheckInRow`'s own existing distinction exactly.
16. **Hierarchy inversion + sub-legible glyph (moderate)** → control `22pt → 18pt`, glyph `9pt → 11pt`, corner inset `6pt → 8pt` (lands on the file's 4/8pt rhythm); 32×32pt hit area unchanged.
17. **No undo on an irreversible action (moderate)** → removed this spec's own invented "≈1.2s full-gold peak" transient (not part of the shared `NudgeUIState` visual language `CheckInRow` already established) in favor of transitioning straight `.sending → .sent`, matching `CheckInRow` exactly. This removes the undo problem at its root — there is no longer a window where a tap has fired but not visually committed. The residual exposure (no confirm-before-send at all) is inherent to the existing fire-and-forget `onNudge` contract this control deliberately matches, not something a visual spec can close alone — flagged forward.
18. **Stale "14pt above" figure (minor)** → deleted; restated as the card's existing 20pt outer padding, which the row adds nothing on top of.
19. **Cold-neutral wash vs. the brief's warm-hearth mood (minor)** → the confirmed Issue-1 fix's *mechanism and magnitude* are untouched; only its hue is swapped, `Color.white.opacity(0.06) → Theme.goldLight.opacity(0.06)`, matching `glassCard`'s own white-plus-gold precedent.
20. **>50-friend union appends to the tail (minor)** → changed to insert `resolvedPrimary` at the **head** instead, so the presence guarantee is actually visible rather than landing off-screen behind fifty other tiles.

The nudge network call itself still belongs entirely to the sibling `/build` task `20260906-friend-nudges` — nothing here calls an endpoint; this revision only tightens the visual/state contract that task's frontend step implements against.

---

## Deliverable

**Not a generated visual asset.** This is a SwiftUI implementation spec for an in-place code revision to an existing native iOS screen. Output format: this markdown document, precise enough to hand directly to `frontend-agent` (or a human) as an implementation brief — no image/mockup rendering is required or useful here, since the target is real, already-running UI code, not a picture of one.

- **File touched:** `FellowScript/FellowScript/FellowScript/Dashboard/DashboardComponents.swift`
- **Component replaced:** `FriendActivityHeroCard.avatarStackRow` (current lines 310–328)
- **Component modified — one padding value, in two places:** `activityRow` (function at L330-357: its own `.padding(.top, 14)` at L353) **and** the sibling no-activity branch (L288-293: `.padding(.top, 14)` at L292). Both become `16`. Also modified: `activityRow`'s `.accessibilityLabel` at L356 (duplicate-username fix, Issue 6c — see Components §1).
  - **Line numbers re-verified this revision:** the sibling `/build` task's forward-compatible `onNudge` plumbing (comment + declaration, L238-251) landed in the file between pass 1 and pass 2 and shifted every line below it down by 14. Every line citation in this document (including this one) has been checked against the file's current state, not the version pass 1 or pass 2 originally cited.
- **Component reused unchanged:** `AvatarView` (lines 91–129) — composed, not modified, except that its existing 40pt-capable `diameter` param and photo-crossfade behavior are used as-is. Also unchanged: `notePreviewRow`, `highlightPreviewRow`, `headline(_:)`, `dayWord(_:)`, `noFriendsState`.
- **Callback already exists, not newly added:** `var onNudge: (FSFriendActivityEntry) -> Void = { _ in }` is already declared on `FriendActivityHeroCard` at **L251**, added forward-compatibly by the sibling `/build` task since pass 1, defaulted for exactly the reason its own comment (L238-250) and the pre-existing `onOpenNote` precedent (L231-236) both state. This spec does not add that parameter — see Components §2 for the one parameter it does add (`nudgeStates`) and Issue 14 below.
- **New token needed:** none. The tile fill is a flat opacity overlay expressed inline (`Theme.goldLight.opacity(...)`, Issue 19), matching this file's existing convention of inline opacity values for one-off overlays (e.g. `glassCard`'s own `border: [Color.white.opacity(0.20), ...]`) rather than a new absolute-hex `Theme` entry — see Styling for the reasoning on why an overlay, not a new hex token, is the correct fix for Issue 1.
- **New enum needed:** none, either. The nudge control's states reuse the file's existing `NudgeUIState` (`idle`/`sending`/`sent`/`rateLimited`/`failed`, **L472-478**) — already shared with `CheckInRow` — rather than a parallel type (Issue 14).
- **Platform:** iOS, SwiftUI, dark-only (no light-mode variant exists on this surface)

---

## Layout

`FriendActivityHeroCard.body`'s structure stays: `VStack(alignment: .leading, spacing: 0)` inside the existing `.glassCard(cornerRadius: 24, tint: #2A1B0B @0.14, blurBoost: 6)` parent, inside the existing 20pt outer padding. Only the **first child** of that VStack changes.

Named regions, top to bottom, inside the card:

1. **Friend tile row** (replaces `avatarStackRow`) — full-width horizontally-scrolling strip, `ScrollView(.horizontal, showsIndicators: false)`. Left-aligned (not right-aligned like the current facepile — dropping the current `HStack { Spacer(); ... }` right-alignment entirely).
2. **Headline block** (`activityRow`, modified — one padding value, see above) — sits directly below.
3. **Preview block** (`highlightPreviewRow` or `notePreviewRow`, unchanged) — below that, behind its existing `Divider()`.

Vertical rhythm around the new row 1: **top gap is the card's existing 20pt outer padding** (`.padding(20)` on the card's outer `VStack`, L296) — the row adds no top padding of its own (Issue 18: the prior draft's "14pt above" figure was carried over from `style-brief.md` before the padding source was traced back to the card, and was simply wrong, not a design choice — deleted here rather than restated). **16pt below** before `activityRow`/the no-activity text begins. This is supplied entirely by raising `activityRow`'s own top padding (L353) **and** the no-activity branch's own top padding (L292) from `14` to `16` — the row itself carries **no** bottom padding of its own, so the gap is never doubled and never state-dependent (fixes Issues 6a/6b together).

Row content layout (per tile, left to right): tiles laid out in a `LazyHStack(spacing: 10)` inside the `ScrollView` (Issue 8 — was a plain `HStack`), each tile a `VStack(spacing: 6)` of [squircle container with inset avatar + badge + nudge control] then [name caption]. Row height is **not** a fixed constant — let the `VStack` size itself from its children, since the caption's `@ScaledMetric` font (Issue 9) makes the caption's own height vary slightly with Dynamic Type; do not hardcode "≈88pt" anywhere in the implementation.

Visible-width target: 4 full tiles + ~11pt peek of a 5th, computed against a 313pt usable width (20pt dashboard margin + 20pt card padding on each side, iPhone-15-class device) — 4×68 + 3×10(gaps) = 302pt of 313pt, leaving the peek. This is a **target for typical devices**, not a hard-coded width: the row must remain a true `ScrollView`, not a fixed-width clipped `HStack`, so it degrades gracefully on smaller/larger devices rather than the peek amount being exact everywhere. (The 68pt tile square itself stays fixed-size at every standard Dynamic Type step — see Styling's Issue 9 note for why only the caption, not the tile, scales.)

---

## Components / elements

### 1. Friend tile (per friend, replaces one avatar in the old facepile)

- **Container:** `RoundedRectangle(cornerRadius: 20, style: .continuous)`, **68×68pt**, filled per the corrected elevation treatment below (Styling §Tile fill). Hairline stroke: `Color.white.opacity(0.14)`, 1pt (raised from 0.10 — Issue 1).
- **Selected state (headline friend only, "ring in place"):** additional ring `RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.gold.opacity(0.55), lineWidth: 1.5)`, inset so it doesn't clip against the hairline. Applied to whichever tile matches `entry.id == resolvedPrimary?.id` — the row is **never reordered** to move this tile to a particular position (Issue 7). See §3 (Row container) for how presence is guaranteed without reordering.
- **Avatar inset:** `AvatarView(initial:, photoURL:, diameter: 40)`, centered both axes within the tile (so ~14pt of tile fill visible on all sides around the circle before the badge overlaps it).
- **Status badge** *(two-state only — Issue 4, per-type glyphs dropped entirely)*:
  - Structure (outer to inner, "cut out of the avatar" look): a same-tile-fill "cutout" circle **16pt diameter** (no stroke) directly behind the badge, then the **11pt** badge circle on top of that — restoring the style brief's own 0.27×-avatar derivation (0.275 × 40 ≈ 11) that the prior draft silently doubled (Issue 3).
  - Position: both circles centered at the point `avatarCenter + (avatarRadius·cos45°, avatarRadius·sin45°)` = `avatarCenter + (14.1, 14.1)pt` (avatar radius 20pt) — i.e. exactly on the avatar's own bottom-right edge, matching the reference's "badge overlaps the photo, not the tile corner" placement precisely rather than an approximated bounding-box offset.
  - **Has recent activity** (`last_active_at` within 24h — see threshold note below, unchanged from prior draft): filled `Theme.gold` (`#D4922A`) circle, **no glyph**. This state no longer distinguishes `activity_type` visually at all — that distinction is fully carried by the tile's accessibility label and by `activityRow`'s 28pt headline text for whichever friend is expanded below.
  - **No recent activity:** hollow — `Circle().stroke(Theme.parchment.opacity(0.70), lineWidth: 2)`, no fill (opacity `0.28→0.45` at pass 1, raised again `0.45→0.70` this pass — Issue 12; width stays `2pt`). Pass 1's 0.45 figure was computed against the tile fill *before* Issue 1's elevation fix landed; recomputed against the tile's real current fill (Issue 19's warmed value, §Styling) it lands at **≈3.13:1** — a pass by 0.13 under one plausible model of a material nobody has measured, i.e. not a safe floor for a state indicator. **0.70 recomputes to ≈5.49:1** against that same real current fill (full derivation in Styling). Acceptance criterion restated as **"≥4:1 against the final composited tile, with headroom"** rather than "≥3:1, verify later" — a device check should be confirming a comfortable value, not adjudicating a marginal one.
  - Filled-vs-hollow remains a **shape/fill** distinction (not a hue distinction), so the state still reads under WCAG 1.4.1 for anyone who can't distinguish gold from a parchment stroke.
  - "Recent activity" threshold, unchanged from prior draft: **`last_active_at` within the last 24 hours**, computed client-side via the file's existing `parseActivityDate(_:)` helper compared against `Date()`. Client-side derivation, no backend field. `last_active_at == nil` always renders the hollow state.
- **Name caption:** `Text(f.username)`. Font size via `@ScaledMetric(relativeTo: .caption2) private var captionSize: CGFloat = 11` (semibold) — **not** a fixed `.system(size: 11)` — so it grows with Dynamic Type through the standard range instead of the deleted `minimumScaleFactor` shrinking it below the 12pt floor (Issue 9). Color `Theme.parchment.opacity(0.85)`. `.frame(width: 68)` applied directly to the `Text` (not the tile or the `VStack`) so a long name truncates within its own column rather than widening it (Issue 5 — the overflow permission from the prior draft is deleted outright). `.lineLimit(1).truncationMode(.tail)`, centered under the tile, 6pt gap below.
- **Nudge-trigger control** *(new — user amendment)*: see Component §2 below.
- **Tap target (open chat):** the tile — squircle + avatar + badge + caption — wrapped in a single `Button(action: { onOpenFriend(entry) })`, `.buttonStyle(.plain)`. Reuses the exact same `onOpenFriend` callback `activityRow` already calls — no new callback plumbing needed on `FriendActivityHeroCard`'s public interface.
  - Hit area: the 68×68pt tile alone clears the 44×44pt minimum touch target with margin; the caption extends the visual footprint further without needing to be separately tappable.
  - Adjacent-tile spacing: 10pt gap clears the 8pt minimum adjacent-target spacing floor.
  - **Interaction with the nudge control, stated unambiguously as sibling views (Issue 11 — the prior draft described this layering two different, contradictory ways, one of which does not work):**

    ```swift
    ZStack(alignment: .topTrailing) {
        Button(action: { onOpenFriend(entry) }) {
            tileContent   // squircle fill + hairline + selected-ring + avatar + status badge + caption — NOT the nudge control
        }
        .buttonStyle(.plain)

        nudgeControl(for: entry)   // sibling, declared second, so it draws — and hit-tests — in front
            .padding(8)            // corner inset, Issue 16
    }
    ```

    The nudge `Button` is a **sibling of the tile's chat `Button` inside the outer `ZStack`, declared after it. It must never be placed inside the chat button's own label.** This is a structural requirement, not a hit-testing nicety: SwiftUI collapses a `Button`'s label subtree into a single accessibility element, so a `Button` nested inside another `Button`'s label is not exposed to VoiceOver as an independent element — regardless of what tap-routing does — which would silently defeat the two independent accessibility labels specified in §2 below. As two sibling views, both hit-test correctly front-to-back (the nudge control's own front-most, expanded `.contentShape(Circle())` wins inside its own bounds; every other tap on the tile falls through to the chat `Button` beneath it) and both are exposed to VoiceOver as separate elements.
    - **Belt-and-braces:** also mirror the nudge action as `.accessibilityAction(named: Text("Nudge")) { onNudge(entry) }` on the tile's own chat `Button`. This gives VoiceOver users (via the rotor) a second, always-reachable path to the same action that keeps working even if a future refactor accidentally re-nests the views — a safety net, not a substitute for keeping the structure correct.
- **Accessibility:** plain `Button` + `.accessibilityLabel(...)` only — `.accessibilityElement(children: .combine)` and `.accessibilityAddTraits(.isButton)` are both dropped (Issue 10; `Button` already supplies its own element boundary and `.isButton` trait, matching how `activityRow`/`notePreviewRow` already do it in this file). Label: **`"\(headline(entry)). Opens chat."`** — not `"<username>, <headline>..."` (Issue 6c: `headline(_:)` already begins with the username, so the old phrasing produced "Maria, Maria wrote a note today. Opens chat." in VoiceOver). The row's current `.accessibilityHidden(true)` (L327) is **removed entirely**.
  - **Apply the identical fix to the existing, already-shipping `activityRow` label at L356** (task instruction, not just a nice-to-have): replace `.accessibilityLabel("\(entry.username): \(headline(entry)). Tap to open chat.")` with `.accessibilityLabel("\(headline(entry)). Opens chat.")`. Same bug, same fix, same file — no reason to leave the pre-existing instance uncorrected while fixing the new one.

### 2. Nudge-trigger control (new — top-right corner of each tile)

**Contract (Issue 14):** the callback already exists — `var onNudge: (FSFriendActivityEntry) -> Void = { _ in }`, declared on `FriendActivityHeroCard` at **L251**, added forward-compatibly by the sibling `/build` task `20260906-friend-nudges` between pass 1 and pass 2, defaulted for exactly the reason its own comment (L238-250) and the pre-existing `onOpenNote` precedent (L231-236) both state: every pre-existing call site, preview, and the two named test files (`DashboardEmptyStateTests.swift`, `DashboardFriendRandomizationTests.swift`) keep compiling and rendering unchanged. This spec adds the one thing that's still missing — the per-friend **state input** the tile needs to render from:

```swift
var nudgeStates: [String: NudgeUIState] = [:]   // keyed by friend id; a missing key renders .idle
```

Declared alongside the existing `onNudge`, defaulted to `[:]` for the same compiling-unchanged reason. It's a dictionary, not a scalar, because this row — unlike `CheckInRow`'s single candidate — renders many friends at once, each independently nudgeable and independently rate-limited.

This reuses the file's **existing** shared `NudgeUIState` enum (`idle` / `sending` / `sent` / `rateLimited` / `failed`, **L472-478**) — already driving `CheckInRow` (L481-577) — rather than a parallel `NudgeControlState` type. One state machine for "what does a nudge attempt look like," shared across both surfaces, per this row's own "compose existing, no one-off" desirable. The actual nudge network call, and how `nudgeStates` gets populated (a real send, or a rate-limit already known from an earlier session), still belong entirely to the sibling `/build` task — this control only renders whatever the map says.

- **Icon:** `Image(systemName: "paperplane.fill")` in the interactive states, `checkmark` in `.sent`/`.rateLimited` — this exactly mirrors `CheckInRow`'s own `iconName` (L514-519) and `nudgeState == .sending` → `ProgressView()` swap (L550-559), rather than a second glyph vocabulary for the same concept.
- **Circle size (Issue 16):** **18pt** diameter (down from a prior 22pt) — the tile's *tertiary* affordance should not out-diameter the tile's actual information, the 11pt status badge; 18pt narrows that gap from 2.0× to 1.6×. Glyph **11pt** (up from 9pt), clearing the sub-legible-glyph floor and matching the reasoning that made Issue 4 drop the tile's other small glyphs.
- **Corner inset (Issue 16):** **8pt** from the tile's top edge and 8pt from its trailing edge (up from 6pt, landing on the file's 4/8pt spacing rhythm instead of sitting outside it), measured to the circle's own edge. Center point: `(tileWidth − inset − radius, inset + radius)` = `(68 − 8 − 9, 8 + 9)` = **(51, 17)** in tile-local coordinates — unchanged in absolute position from the prior draft, since `inset + radius` (17) lands on the same sum either way; only the circle's own diameter shrank around that same center, so none of the collision-clearance geometry below needed re-deriving from scratch.
- **Position:** the control sits in the `ZStack(alignment: .topTrailing)` shown in §1's "Interaction with the nudge control" — a **sibling** of the tile's chat `Button`, never nested inside it (Issue 11). By construction it is diagonally opposite the 11pt status badge, so the two never collide; the corner inset plus the caption's own 6pt gap below the tile keep it clear of the caption too.
- **Cutout ring, matching the status badge's own treatment (Issue 13):** a same-tile-fill circle, no stroke, **23pt diameter**, centered at the same point as the nudge control (2.5pt of ring per side around the 18pt control — the identical ring-to-control ratio as the badge's own 16pt cutout around its 11pt badge). Drawn *before* the nudge control in the `ZStack`, same layering order as the badge's cutout-then-badge pattern in §1. Previously a `Theme.gold.opacity(0.16)` fill sat directly on the friend's photo with nothing behind it — a translucent gold wash over a face, and a background the contrast math in Issue 12 couldn't actually assume. With the cutout, both corner tokens use the same "cut out of the avatar" construction the style brief names as the specific Discord detail worth carrying over, and the control's background is once again the known tile fill.
  - Geometry check: cutout radius 11.5pt, avatar radius 20pt, avatar-to-nudge-center distance ≈24.04pt (`√(17² + 17²)`, unchanged from the prior draft's position) → sum of radii 31.5pt > 24.04pt, so the cutout penetrates ≈7.5pt into the avatar circle — comparable to the badge's own ≈8pt penetration into the avatar (§1). That penetration is the intended look, not a defect; it's what "cut out of" means. The cutout stays clear of the tile's own hairline (11.5pt radius vs. 17pt to the nearest edge) and 31.2pt from the status badge's own cutout center at the opposite corner — no collision.
- **State → visual mapping (Issues 14 & 15), mirroring `CheckInRow`'s own `badgeText`/`iconName`/`isDisabled`/`accessibilityText` computed properties (L491-526) so the two surfaces stay in lockstep instead of drifting apart:**

  | `NudgeUIState` | Interactive? | Circle | Icon |
  |---|---|---|---|
  | `.idle` | yes | fill `Theme.gold.opacity(0.16)`, stroke `Theme.gold.opacity(0.35)` 1pt | `paperplane.fill`, `Theme.goldLight` |
  | `.sending` | no | same fill/stroke as `.idle` | `ProgressView()` in place of the glyph, `Theme.goldLight` tint — matches `CheckInRow` L550-559 |
  | `.sent` | no | hollow, stroke `Theme.parchment.opacity(0.35)` | `checkmark`, `Theme.parchment.opacity(0.55)` |
  | `.rateLimited` | no | **identical to `.sent`** | **identical to `.sent`** |
  | `.failed` | yes | `.idle` appearance plus a one-time ≈0.3s `.easeOut` tint pulse of `Theme.error.opacity(0.4)` (mirrors `CheckInRow`'s own error-pulse overlay, L565-568) | `paperplane.fill`, `Theme.goldLight` |

  This is the resolution to Issue 15: a rate-limit rejection and a genuine send failure are no longer the same visual. `.rateLimited` settles into the same non-interactive "already handled" look as `.sent` — tapping a disabled control is already a no-op in SwiftUI, so no separate rejection feedback is needed — while `Theme.error`'s "that didn't land, try again" pulse is reserved for `.failed`, the one state where retrying is actually correct advice. `.failed` is also, per `CheckInRow`'s own `isDisabled` (L507-512), the only state besides `.idle` that stays tappable. None of this is a new design decision — it's this control adopting exactly the distinction `CheckInRow` already draws in the same file, rather than inventing its own.
- **Sizing note (deliberate exception, stated plainly):** the 18pt visual circle sits below the 44×44pt touch-target floor. Expand the tappable area via `.contentShape(Circle())` sized to **32×32pt**, centered on the same visual circle, rather than the full 44×44pt: the tile's own top-right corner geometry (68pt tile, 40pt centered avatar, 20pt corner radius) does not have 44pt of clear room in that corner without the hit area bleeding meaningfully into the adjacent tile's 10pt gap or the row's own top whitespace. 32pt is the largest expansion that stays visually contained to *this* tile's own corner (hit area spans x 35→67, y 1→33 against the 68×68pt tile — fully contained). The tile's own primary tap target (open chat, 68×68pt) already clears the 44pt floor with margin, so the floor is met by the row's primary interaction; this secondary control's reduced hit area is a considered, stated trade-off for a tertiary affordance, not an oversight.
- **Pressed state (`.idle`/`.failed` only, since `.sending`/`.sent`/`.rateLimited` are non-interactive):** scale **0.90** (more pronounced than the tile's own 0.96, since this is a smaller, more precision-dependent target and benefits from a clearer "I felt that" confirmation), `.easeOut(duration: 0.12)`; fill brightens to `Theme.gold.opacity(0.28)`. Reduced motion: drop the scale transform, keep only the fill-brighten as the state cue (mirrors this file's existing `ContinueIslandButtonStyle` reduced-motion fallback: opacity/brightness step survives, transform doesn't).
- **No separate "sent peak" transient (Issue 17, resolved by removal rather than by adding an undo):** the prior draft invented an ≈1.2s "full `Theme.gold` fill" flash between `.sending` and `.sent`'s disabled resting look — a moment this control's own reasoning is not part of the shared `NudgeUIState` visual language `CheckInRow` already established (`CheckInRow` transitions `.sending → .sent`'s disabled `checkmark` look directly, no separate peak, L508-519). That invented transient is what created the accidental-tap/no-undo problem critique raised: a window during which a tap had already fired but not yet visually committed, with no way to take it back. Removing it removes the problem at its root — with `.sending → .sent` direct, there's no committed-but-unconfirmed window left to protect. The remaining exposure — a genuine mis-tap dispatching a real nudge with **no** confirm-before-send step at all — is inherent to the existing fire-and-forget `onNudge`/`CheckInRow` contract this control is deliberately matching, not something a visual-only spec can close without changing that contract. Flagged forward below for the sibling `/build` task, rather than papered over with a UI mechanism (a delayed dispatch, a re-tap-to-cancel) this spec has no server-side cancel counterpart to actually back up.
- **Accessibility:** a separate `.accessibilityLabel` from the tile's own chat-opening label (a second, independent interactive element in the same tile, not folded into the tile's combined label — echoes Issue 10's reasoning, and is exactly why Issue 11's sibling-not-nested structure matters). Mirrors `CheckInRow`'s own `accessibilityText` switch (L521-526) exactly:
  - `.idle` / `.sending` / `.failed`: `"Nudge \(entry.username) to study"`.
  - `.sent` / `.rateLimited`: `"Nudge sent to \(entry.username)"`.
  - No `.accessibilityHint` needed beyond the label itself — consistent with this row's otherwise unfussy accessibility posture.

### 3. Row container

- `ScrollView(.horizontal, showsIndicators: false)` wrapping the `LazyHStack(spacing: 10)` of tiles described above (Issue 8 — `HStack` → `LazyHStack` so tiles build on demand rather than all-at-once). No `+N` overflow indicator (removed — scrolling supersedes it).
- Rendered friend set: `feed.friends_active`, **not reordered** (Issue 7). Take `Array(feed.friends_active.prefix(50))` (cap raised `12 → 50`, Issue 8 — a `LazyHStack` removes the perf justification for a low cap, and 50 covers essentially every real friend count without inventing a new "See all" screen this app doesn't otherwise have), then, if `resolvedPrimary` isn't already present in that first-50 slice, **insert it at the head** of the rendered array rather than appending it to the tail (Issue 20 — appending would place the presence guarantee past the visible/peek window for anyone with more than 50 friends, i.e. exactly the case the guarantee exists for, defeating its own purpose). In the ordinary case (≤50 friends, which is effectively all real users) this union step is a no-op — recency order from `friends_active` is preserved exactly as the data provides it for everyone else.
- If `feed.friends_active.isEmpty`, this entire region does not render — already guaranteed today by `FriendActivityHeroCard.body`'s existing `if feed.friends_active.isEmpty { noFriendsState } else { ... }` branch; no new empty-state code needed for the row itself.

---

## Styling

All values are existing `Theme` tokens or values directly derived from them — no new brand colors introduced (Q3: system is locked).

| Element | Value | Source |
|---|---|---|
| Tile fill | flat overlay, see below | corrected in this revision (Issue 1); hue warmed this pass (Issue 19) |
| Tile hairline | `Color.white.opacity(0.14)` | raised from 0.10 (Issue 1) |
| Selected-tile ring | `Theme.gold.opacity(0.55)`, 1.5pt | existing token, applied in place (Issue 7) |
| Avatar fallback fill / initials | `AvatarView` defaults (`#24170A` fill, `Theme.goldLight` text) | unchanged, existing |
| Badge — has activity | fill `Theme.gold` (`#D4922A`), no glyph | glyph dropped (Issue 4) |
| Badge — no activity | stroke `Theme.parchment.opacity(0.70)`, 2pt, no fill | raised again this pass, `0.45 → 0.70` (Issue 12) — recomputes to ≈5.49:1 against the tile's real current fill |
| Badge cutout ring | same fill as tile (16pt) | resized (Issue 3) |
| Name caption | `Theme.parchment.opacity(0.85)`, `@ScaledMetric` ~11pt semibold | scaling replaces `minimumScaleFactor` (Issue 9) |
| Nudge control cutout ring | same fill as tile (23pt) | new, this pass (Issue 13) |
| Nudge control `.idle`/`.failed` | fill `Theme.gold.opacity(0.16)`, stroke `Theme.gold.opacity(0.35)` | new prior pass, unchanged |
| Nudge control `.sending` | same fill/stroke as `.idle`, `ProgressView` in place of glyph | new prior pass, unchanged |
| Nudge control `.sent`/`.rateLimited` | stroke `Theme.parchment.opacity(0.35)`, glyph `Theme.parchment.opacity(0.55)` | new prior pass, unchanged; `.rateLimited` unified onto this row this pass (Issue 15) |

**Tile fill — corrected elevation (Issue 1, unchanged this pass — confirmed fixed, see changelog note above):** `Theme.cardBg` is dropped as the tile fill. It measures *darker* than `Theme.bgPage` itself (0.00894 vs. 0.00973 relative luminance — both computed by critique from the real hex values), while the parent `glassCard` — built from `.ultraThinMaterial` (a lightening vibrancy material in dark mode) plus its tint — renders *lighter* than the page. Filling the tile with `Theme.cardBg` therefore produces a tile that is darker than a parent that is lighter than the page: a recessed hole, not an elevated tile, inverting both the style brief's "sits a clear step above the parent glass" claim and its "row of small lit windows" mood.

Fix: fill the tile with a **flat, non-material wash drawn directly over whatever the parent already renders behind it** — `RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.goldLight.opacity(0.06))`. Because the tile is a sibling view drawn on top of the parent card's own already-composited background (not a separately-backdrop-sampled layer), this guarantees the tile is *relatively* lighter than the parent no matter how `.ultraThinMaterial` actually resolves against live content at runtime — it does not depend on knowing the parent's exact composited value in advance, which the prior draft's absolute-hex approach did (and got backwards). It stays flat/no-material, which is the one part of the original reasoning that was already correct and should survive unchanged (stacking a second blurred layer inside an already-`blurBoost: 6` parent would compound into visual mud, exactly as previously reasoned).

**Fallback direction, stated explicitly (correcting the prior draft's inverted fallback):** if this reads too subtly ("dead") once seen live on device, the fix is to **raise** the opacity value (e.g. `0.06 → 0.09`–`0.10`) — never to swap to a second material layer, and never to move toward darkening. The prior draft's fallback ("blended toward parchment," implicitly a lightening move framed as a hedge) pointed the right direction but for the wrong reason (starting from an already-inverted base); this version starts from a base that is correct by construction, so the fallback is a pure magnitude dial, not a direction fix.

**Warm-hue refinement (Issue 19, minor — layered onto the confirmed fix above, not reopening it):** the fix above previously used `Color.white.opacity(0.06)`, a hue-neutral lift that drifts slightly cold against the brief's warm-hearth mood, and against this file's own precedent for lightening a warm-dark surface — `glassCard`'s own border gradient pairs white with `Theme.gold.opacity(0.12)`, never white alone. Swapped to `Theme.goldLight.opacity(0.06)` above: same relative-overlay mechanism, same fallback dial (raise toward `0.09`–`0.10` if too subtle, exactly as stated above), same non-material construction — only the hue changed, from neutral to warm-lit. This does not touch Issue 1's fix direction or magnitude reasoning.

**Recomputed contrast against the tile's real current fill (Issue 12), independently verified against the real `Theme.swift` hex values, not just critique's model:** modeling the parent glass at ≈`#3A322A` (`bgPage` + two `.ultraThinMaterial` passes + the `#2A1B0B`@0.14 tint — a model, not a measurement, same starting point critique used) and blending `Theme.goldLight.opacity(0.06)` over it:

| Surface | Modeled value | Relative luminance |
|---|---|---|
| Tile fill (`goldLight` @0.06 over parent) | ≈`#45392B` | 0.0442 |
| Hollow badge stroke (`parchment` @0.70 on tile) | ≈`#C0B49E` | 0.4677 |
| **Contrast** | | **≈5.49:1** |

That clears the restated "≥4:1 with headroom" criterion with real margin — enough to survive both an imperfect parent-glass model and the Issue-1 fallback dial's `0.06 → 0.10` range without landing anywhere near the floor again. (The warmed tile fill actually computes to a *lower* luminance than the previous white-based wash — 0.0442 vs. 0.0504 — so the contrast improvement here comes from both the badge-stroke increase and the hue change working in the same direction, not fighting each other.)

Two contrast notes carried forward unchanged from critique, since both were already checked and don't need rework:
- The **nudge glyph** (`goldLight` on `gold`@0.16 over the tile) computes to ≈4.27:1 against the prior tile value and is not meaningfully affected by this pass's small tile-hue change — clears the 3:1 glyph floor comfortably.
- The **disabled/rate-limited ring** (`parchment`@0.35) computes to ≈2.48:1, but WCAG 1.4.11 explicitly exempts inactive components, so this is not a violation; its `checkmark` glyph at `parchment`@0.55 (≈3.88:1) remains the state's real carrier.

**Caption scaling (Issue 9), and why the tile itself does not also scale:** the critique's proposed fix suggested `@ScaledMetric`-ing both the caption and the tile "so it grows in proportion rather than colliding." This spec scales only the caption font, for a specific reason: the caption's `.frame(width: 68)` (Issue 5) already absorbs any width growth via truncation, not overflow, so there is no width collision to solve by growing the tile. The only remaining risk was the deleted `minimumScaleFactor` pushing text below the 12pt floor, which `@ScaledMetric` on the font alone fully resolves. Growing the 68pt tile itself would ripple into the Layout section's locked "4 full + ~11pt peek" visible-width math and the badge/avatar geometry above, for no corresponding correctness gain — so it's deliberately left fixed-size at every standard Dynamic Type step, exactly as the prior draft already specified. At accessibility Dynamic Type sizes (`.accessibility1`+), the existing behavior is unchanged: the caption drops from layout entirely (see States) rather than either wrapping or forcing tile growth.

Typography: system SF only (`Font.system`), matching every other size in this file — no `.inter`/`.playfair` custom font introduced for this row.

Corner radius: `20pt, .continuous` — proportionally matches the Discord reference (~0.11 of tile width) and uses the same `.continuous` style as every other rounded shape in this file.

---

## States

- **Populated (normal):** as specified above — natural recency order, capped-and-unioned, scrollable tile row, ring in place on the primary friend's tile wherever it falls.
- **Empty (`feed.friends_active.isEmpty`):** row does not render at all; existing `noFriendsState` text takes over the whole card, unchanged. No skeleton, no shimmer (per Q17, minimal/unfussy default).
- **Loading:** out of scope for this row specifically — no dedicated loading skeleton is being added; whatever loading treatment `DashboardView` already applies to the card as a whole (if any) continues to cover this case. Do not invent a new per-row loading state.
- **Reduced motion:** `@Environment(\.accessibilityReduceMotion)` (same pattern `AvatarView` already uses) drops the tile's press-scale animation entirely; the tap's resulting navigation still fires instantly. The nudge control's own reduced-motion handling is specified in Component §2 (drops scale, keeps the fill-brighten cue). First-class, not an afterthought.
- **Tile press feedback (interaction, not a persistent state):** on tap-down, scale to **0.96** with `.easeOut(duration: 0.18)`; on release, ease back with `.easeOut(duration: 0.12)` (exit faster than enter, no spring/overshoot). No staggered entrance animation for the row, no badge pulse, no shimmer — Q10's "minimal feedback by default" governs; this row is meant to be glanceable, not performative.
- **Nudge control states:** `idle` / `sending` / `sent` / `rateLimited` / `failed`, driven by the shared `NudgeUIState` enum via the new `nudgeStates: [String: NudgeUIState]` input, plus its own separate `pressed` interaction state (an animation, not a `NudgeUIState` case) — fully specified in Component §2 above, not repeated here.
- **Dynamic Type / accessibility text sizes:** the 68pt tile is a **fixed-size icon-first control** and does not grow with Dynamic Type (see Styling's Issue 9 note for why). The name caption's font scales with Dynamic Type through the **standard** range via `@ScaledMetric` (Issue 9) with truncation, not shrinkage, absorbing overflow. At **accessibility Dynamic Type sizes** (`.accessibility1` and larger, checked via `@Environment(\.dynamicTypeSize)`), the name caption is **dropped from layout entirely** (tile + badge + nudge control only, row height shrinks accordingly, no reserved caption space) rather than wrapping or forcing the tile to grow — the friend's full name remains available via the tile's `accessibilityLabel` regardless of whether the caption is visually shown. This keeps the row's touch targets and glanceable proportions stable at every text size while still meeting the Q14 AA-floor commitment (no information is lost, only a visual convenience is hidden).

---

## Generation-needed?

**No.** This deliverable is a scoped SwiftUI implementation spec for existing, already-running app UI, not a new visual asset. Step 4 (`design-generation-agent`) should record a skip for this task rather than calling OpenArt — there is nothing here that benefits from a rendered mockup; the spec above is precise enough to hand directly to implementation (`frontend-agent` in `/build`, or a human) against the real `DashboardComponents.swift` file.

---

## Flagged forward (not blocking, but worth surfacing at critique)

- The five behavior-altering decisions made at synthesis (badge semantics, interactivity/tappability, true horizontal scroll, row placement, added name caption) are synthesis-made, not user-confirmed — the interactivity change in particular alters the widget's actual behavior (previously fully decorative), not just its appearance. Unchanged from the prior draft; still worth an explicit user yes.
- The "24-hour recent-activity window" is this spec's own concrete pick to close an otherwise-undefined threshold; it's reasonable but arbitrary and easy to change if the user has a different window in mind.
- The tile fill's corrected direction (Issue 1) is reasoned from first principles (relative overlay over whatever the parent renders, rather than an absolute hex guess) and should be more robust than the prior draft's inverted absolute value — but it is still not visually verified on a live device against real backdrop content, and this pass's contrast math (Issue 12/19) is likewise modeled, not measured. Flag for a device look once built.
- The nudge control's 32×32pt (not 44×44pt) hit area is a stated, deliberate exception to the touch-target floor for this one secondary/tertiary affordance, justified by the tile's tight corner geometry — surfaced explicitly here rather than left as a silent gap, per this pipeline's own accessibility-deliberately-decided standard.
- **Reconciliation progress, updated this pass:** the sibling `/build` task `20260906-friend-nudges` has already landed the forward-compatible `onNudge` callback and the shared `NudgeUIState` enum on `FriendActivityHeroCard`/`CheckInRow` since pass 1 — real evidence the two tasks are converging on one contract, not two. What's still needed from that task: actually driving the new `nudgeStates` map this spec adds (a real send, and knowing "already rate-limited" on first render vs. only after a local attempt), and wiring the tile-row control this spec describes to `onNudge` once the tile restyle itself lands. This spec only guarantees the visual/state contract; the sibling task's own architecture step should confirm it against this document directly rather than re-deriving it.
- **New this pass (Issue 17's residual):** removing the invented "sent peak" transient closes the accidental-tap/no-undo gap that transient created, but does **not** add any confirm-before-send or cancel-after-send step to nudging itself — a mis-tap on the 32×32pt control still dispatches a real push notification to another person with no recovery path, exactly as `CheckInRow`'s existing 56pt button already behaves today. If that's an acceptable risk for a low-stakes social nudge (as `CheckInRow`'s shipped behavior suggests it already is), no further action is needed; if not, adding a cancel window is a product/backend decision for the sibling `/build` task, not something this visual spec can resolve unilaterally.
- Issue 20's gold "selected" ring still needs a device look to settle whether it reads as "selected" or as "this is who's shown below" — carried forward unchanged from pass 2, since it's a device-verification item, not a spec-level gap.
