# Critique — Friend Activity avatar row

Task: `20260906-friend-activity-avatar-row`
Stage: 5 (critique)
Pass: **3 of 3 — final.** The bounce budget (2) is spent. Per this pipeline's own cap, this pass **passes regardless of residuals** and documents them honestly instead of looping. `escalate: true` is set in `loop-count.json` so the orchestrator surfaces the residuals to the user rather than silently accepting them.

---

## What was reviewed

- `intake-brief.md` (desirables + the mid-pipeline nudge amendment), `style-brief.md` (style direction + its amendment), `design-spec.md` **revision 3**, `generation.json`, plus pass 2's own `critique.md` to verify each of its findings.
- **No generated asset and no reachable webpage.** The deliverable is a native SwiftUI implementation spec, so `openart_creation_show` and the browser tools do not apply; `generation.json` correctly records the OpenArt skip. As in passes 1 and 2, the spec was reviewed **against the real source it targets** — the strongest available substitute for loading a live artifact:
  - `FellowScript/FellowScript/Dashboard/DashboardComponents.swift` (925 lines) — `glassCard` L29, `AvatarView` L91-129, `FriendActivityHeroCard` L217-, `NudgeUIState` L472-478, `CheckInRow` L481-577, `ContinueIslandButtonStyle` L603-613
  - `FellowScript/FellowScript/Theme/Theme.swift` — token hex values
  - `FSFriendActivityEntry` (`Identifiable`, `id == friend_id: String`)
- Grounded in `ui-ux-pro-max` (`--stack swiftui`; `references/pro-rules.md` → touch target ≥44×44 with hit-slop when smaller, gesture-conflict prevention / no nested tap conflicts, icon contrast ≥3:1, consistent icon sizing, dark-mode state-contrast parity) and `design-system` (no raw hex in components; component tokens reference semantic tokens).
- Every contrast figure below was **independently recomputed** from the real `Theme.swift` hex values with the WCAG relative-luminance formula, not taken from the spec. Where `.ultraThinMaterial` compositing is involved the parent value is a stated model, not a measurement — same caveat as prior passes.

---

## Verdict

**Pass — with residuals, escalated.**

Revision 3 fixes all ten of pass 2's findings (Issues 11–20). I verified each against the revised spec **and** against the source, including every line number, token value, and geometric and contrast claim it makes. Nothing was restated-but-not-applied, nothing regressed from passes 1–2, and the two places where the spec argued back (declining to `@ScaledMetric` the tile; resolving Issue 17 by deleting the invented "sent peak" rather than bolting an undo onto it) are both better calls than the fixes I proposed. The spec is implementable, internally consistent, faithful to the style brief, and meets every intake desirable including the mid-pipeline nudge amendment.

It is not defect-free. One residual is genuinely visual and would show on device: the "cut out of the avatar" technique — the single detail the style brief names as *the* thing that makes the row read as Discord — is specified with a fill that is 94% transparent, so it will not cut anything out. That fault is an emergent interaction between two correct fixes (Issue 1 changed the tile fill from near-opaque to a 6% wash; Issues 3/13 specify the cutouts as "same fill as tile"), which is exactly the class of thing that survives three passes. It is a one-line implementation change, documented below with a concrete fix, and it is not worth a fourth loop the cap does not allow.

Style direction is right. Generation skip is right. Nothing here calls for reopening synthesis or intake.

---

## Verification of pass 2's ten findings

| # | Finding | Status | Evidence checked |
|---|---|---|---|
| 11 | Ambiguous/nested `Button` composition *(critical)* | **Fixed** | Stated once, with a code snippet, as a `ZStack(alignment: .topTrailing)` **sibling** of the chat `Button`, plus an explicit "must never be placed inside the chat button's own label" and the correct *reason* (SwiftUI collapses a `Button`'s label subtree into one accessibility element — not merely a hit-testing nicety). `.accessibilityAction(named: "Nudge")` added as the belt-and-braces second path. Layout re-derived: the caption's `.frame(width: 68)` keeps the outer `ZStack` 68pt wide, so `.topTrailing` really does land on the tile's own top-right corner and not somewhere else. Residual at R2/R4. |
| 12 | Hollow-badge contrast eroded to ≈3.13:1 *(major)* | **Fixed** | Stroke `0.45 → 0.70`, 2pt. I recomputed from scratch: tile = `goldLight #F0AE40 @0.06` over the modelled parent `#3A322A` → **≈#45392B, L 0.0436**; stroke = `parchment #F5EAD0 @0.70` over that → **≈#C0B59E, L 0.4672**; contrast **≈5.53:1** (spec claims 5.49 — same figure within hex rounding). Clears the restated "≥4:1 with headroom" criterion, and survives the Issue-1 fallback dial to `0.10`. |
| 13 | Nudge control washed over a face, no cutout *(major)* | **Fixed in structure, broken in fill** | The cutout is added at the right size (23pt behind an 18pt control = 2.5pt of ring per side, identical to the badge's 16pt/11pt pair) and drawn in the right order. But its specified *fill* no longer occludes — see **R1**, the one substantive residual. |
| 14 | No implementation contract *(major)* | **Fixed, and better than proposed** | I verified in source: `var onNudge: (FSFriendActivityEntry) -> Void = { _ in }` really is at **L251**, already defaulted, with a 13-line comment (L238-250) that names this very design task. `NudgeUIState` (`idle/sending/sent/rateLimited/failed`) really is at **L472-478** and really is shared with `CheckInRow`. The spec discovered this mid-revision and reused it instead of inventing the parallel `NudgeControlState` I proposed — the right call. The one genuinely missing piece, `nudgeStates: [String: NudgeUIState] = [:]`, is added and defaulted per the file's own convention. Keying by `entry.id` is valid: `FSFriendActivityEntry` is `Identifiable` with `var id: String { friend_id }`. |
| 15 | Undefined tap-then-rate-limited path *(major)* | **Fixed** | `.rateLimited` now renders identically to `.sent`; `Theme.error` reserved for `.failed`. I checked this against `CheckInRow`'s real `isDisabled` (L507-512: `.failed` is the one non-idle state that stays tappable), `iconName` (L514-519: `checkmark` for `.sent`/`.rateLimited`), and its `Theme.error.opacity(0.4)` pulse overlay (L565-568). The two surfaces are now in lockstep rather than drifting. |
| 16 | Hierarchy inversion + 9pt glyph *(moderate)* | **Fixed** | Control 22 → **18pt**, glyph 9 → **11pt**, inset 6 → **8pt** (on the file's 4/8 rhythm). Control-to-badge diameter ratio 2.0× → 1.64×. Center stays at (51, 17) because `inset + radius` is unchanged — that arithmetic checks out and correctly saved re-deriving the collision geometry. |
| 17 | Irreversible action with no undo *(moderate)* | **Fixed by removal — better than my fix** | The invented ≈1.2s "sent peak" is deleted; `.sending → .sent` direct, matching `CheckInRow`. That removes the committed-but-unconfirmed window at its root rather than patching an undo onto a transient that shouldn't have existed. The residual (no confirm-before-send at all) is correctly identified as inherent to the existing fire-and-forget contract and flagged forward, not papered over. Carried at R3/R7. |
| 18 | Stale "14pt above" *(minor)* | **Fixed** | Deleted, restated as the card's existing padding. Verified `.padding(20)` really is at **L296** on the card's outer `VStack`, and that the row is its first child inside `VStack(spacing: 0)` — so 20pt is the true top gap. |
| 19 | Cold-neutral wash vs. warm-hearth mood *(minor)* | **Fixed** | `Color.white.opacity(0.06) → Theme.goldLight.opacity(0.06)`; mechanism and magnitude untouched, only hue. Matches `glassCard`'s own white-plus-gold border precedent rather than white alone. |
| 20 | >50-friend union appends to the tail *(minor)* | **Fixed** | Insert at head. Ring re-roll carried forward as a device-look item, correctly labelled as such rather than "fixed." |

**Ten of ten addressed. None regressed. Pass 1's ten remain fixed** — I re-spot-checked the load-bearing ones: `.padding(.top, 14)` really is at **L292** (no-activity branch) and **L353** (`activityRow`), the shipped duplicate-username label really is at **L356** (`"\(entry.username): \(headline(entry)). Tap to open chat."`), `avatarStackRow`'s `.accessibilityHidden(true)` really is at **L327**, and `AvatarView` really does take a `diameter` param (L94) with a reduce-motion-gated crossfade (L112).

---

## What works

- **The line-number re-verification was real, not claimed.** Revision 3 says every citation was re-checked because the sibling `/build` task shifted the file by 14 lines. I checked all of them independently and they are all correct against the file's current 925-line state — including the ones that moved. This is the third consecutive revision whose codebase claims hold up under spot-check; that is unusual and worth saying plainly.
- **Reusing `NudgeUIState` instead of inventing a state enum is the single best decision in this revision.** It closes the design/build split at the level of a shared type rather than a shared description, and it means the rate-limit-vs-failure distinction can't drift between `CheckInRow` and this row later. It also converted my Issue-14 fix into a smaller change than I proposed.
- **Resolving Issue 17 by deleting the offending transient.** Removing an invented mechanism that this spec had no business inventing is a better answer than adding an undo timer to defend it. The residual risk is then stated accurately, at the right altitude (a backend/product contract decision), rather than absorbed.
- **The contrast work is now done, not deferred.** Pass 2's complaint was that the spec deferred the one check it exists to settle. Revision 3 computes it, shows the intermediate composited hex values, and restates the acceptance criterion as a floor with headroom. My independent recomputation lands within rounding of theirs.
- **Geometry is internally consistent and checks out.** Badge cutout and nudge cutout centers are 31.2pt apart against a 19.5pt radius sum (no collision); the 32pt hit circle spans x 35→67, y 1→33 and is fully contained in the 68pt tile (so it can't breach the 8pt adjacent-target floor); the badge sits exactly on the avatar's edge at avatar-center + (14.1, 14.1).
- **Every intake desirable is met, including the amendment.** See the traceability table below. The amendment's two named collision risks (status badge, name caption) are avoided structurally — diagonally opposite corner, caption below the tile — not coincidentally.
- **The five synthesis-made behavior decisions and the arbitrary 24h window are still flagged forward** rather than quietly hardening into fact across three revisions. That discipline held.

---

## Residual issues (not fixed — documented, not looped)

### R1. The cutout circles are specified with a 94%-transparent fill, so they will not cut anything out *(major — the one that will actually show)*

Both corner tokens are specified as sitting on **"a same-tile-fill circle, no stroke"** — 16pt behind the 11pt status badge (§1), 23pt behind the 18pt nudge control (§2), restated in the Styling table as "same fill as tile."

The tile fill, after Issue 1's fix, is **`Theme.goldLight.opacity(0.06)`** — a 6% relative overlay, deliberately chosen because the parent's composited value is unknowable in advance. Drawing that same 6% wash on top of the friend's photo does not occlude the photo; it tints it by 6%. So:

- The badge and nudge control will read as floating **on** the avatar, not cut out of it — precisely the fault Issue 13 was raised to fix, reintroduced through the other end.
- The style brief names this technique as *the* detail that makes the row read as Discord ("the badge is cut out of the avatar"). It is the one signature move, and as specified it doesn't happen.
- Issue 12's contrast math assumes both tokens sit on the known tile fill. Over an arbitrary photo tinted 6%, the hollow badge's 5.53:1 and the nudge glyph's ≈4.5:1 are not predictable at all — so the one number this revision worked hardest to nail down is unverifiable in the ~40% of each token's area that overlaps the avatar.

This is an emergent interaction between two individually-correct fixes (Issue 1 replaced a near-opaque `Theme.cardBg` with a translucent wash; Issues 3/13 inherited "same fill as tile" from the pre-fix draft). Neither pass caught it because each was reviewed on its own terms.

**Proposed fix (implementation, one change):** make the cutouts a *true* cutout rather than a same-color overprint — punch the two circles out of the avatar so the tile surface genuinely shows through:

```swift
AvatarView(initial: f.initial, photoURL: f.profile_photo_url, diameter: 40)
    .mask(
        ZStack {
            Circle()                                   // the avatar
            Circle().frame(width: 16, height: 16)      // status-badge cutout
                .offset(x: 14.1, y: 14.1)
                .blendMode(.destinationOut)
            Circle().frame(width: 23, height: 23)      // nudge cutout
                .offset(x: 17, y: -17)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    )
```

This is robust to the unknown parent material for the same reason Issue 1's overlay is — it never has to name the composited color. The alternative (an opaque hex approximating the composited tile) would reintroduce exactly the absolute-value guess Issue 1 removed, and should not be taken. Whichever is chosen, delete the phrase "same fill as tile" from §1, §2, and the Styling table, since it is the specific wording that produces the wrong build.

### R2. `.padding(8)` and the 32pt hit frame are ambiguous about which view they measure from *(moderate)*

§2 defines the corner inset as 8pt "measured to the circle's own edge," giving center **(51, 17)** — all the collision and cutout geometry depends on that. But §1's snippet applies `.padding(8)` to `nudgeControl(for: entry)`, and §2 also asks that view to carry a **32×32pt** `.contentShape`. If the returned view's frame is the 32pt hit area (the natural reading), `.padding(8)` insets *that* frame, landing the visual circle at **(44, 24)** — ~10pt further into the tile, shifting the avatar overlap, moving the cutout off its stated position, and invalidating the corner-clearance derivation.

**Proposed fix:** state the composition explicitly so padding measures the 18pt visual circle and the hit area expands outward without affecting layout:

```swift
nudgeGlyph
    .frame(width: 18, height: 18)
    .contentShape(Circle().inset(by: -7))   // 32pt hit area, does not change layout bounds
    .padding(8)
```

### R3. The 32pt hit circle creates ~7pt of invisible nudge zone over a 68pt target with a different, irreversible action *(moderate — device look, not necessarily a fix)*

As a front-most sibling, the control's 32pt `.contentShape` wins every tap inside it — including the ~7pt annulus around the 18pt visible circle, which looks like plain tile and avatar. A tap there sends a real push notification to another person, with no confirm and no undo (Issue 17's correctly-flagged residual). `pro-rules.md` names both halves: expand hit area when the icon is smaller **and** avoid overlapping gestures causing accidental actions. The spec resolves the first and honestly flags the second, but the two pull against each other and the resolution was never tested against a thumb.

**Proposed fix:** nothing to change on paper — this needs the device look the spec already asks for. If mis-taps show up, the dial is the hit-area size (32 → 26–28pt trades touch-target generosity for fewer accidental sends), not the visual size.

### R4. The belt-and-braces `.accessibilityAction(named: "Nudge")` is unconditional *(minor)*

The mirrored rotor action fires `onNudge(entry)` regardless of `nudgeStates[entry.id]`. So a VoiceOver user can dispatch a nudge while the visible control is disabled (`.sending`, `.sent`, `.rateLimited`) — the accessibility path and the visual path disagree about what is possible, which is the sort of divergence the split labels were added to prevent.

**Proposed fix:** expose the action only for `.idle`/`.failed` (matching `CheckInRow`'s `isDisabled` at L507-512), and word it with the same label the control uses in that state.

### R5. The cutout's corner clearance is argued against the wrong constraint *(minor, conclusion still holds)*

§2 justifies clearance as "11.5pt radius vs. 17pt to the nearest edge" — a straight-edge measure. At a 20pt-radius top-right corner the binding constraint is the corner arc, not the edge. I re-derived it: the cutout center is 4.24pt from the corner arc center, +11.5pt radius = 15.7pt against a 20pt corner radius, so it clears with ~4pt to spare. The conclusion is right; the derivation shown is not the one that decides it.

### R6. The row scrolls inside the card's 20pt padding, so the peek tile is clipped 20pt from the card edge *(minor)*

The 313pt usable-width math is correct, but it means the scrolling strip is inset on both sides rather than bleeding to the card's edge. The "4 full + ~11pt peek" scroll affordance still reads; it just sits in a margin rather than running off the card. Conventional and defensible — but it is a visual the spec never states a position on, and the style brief's reference does bleed. Worth a glance on device alongside the other two device items.

### R7. Carried forward unchanged, correctly flagged by the spec, not resolvable in a visual spec

- Nudging is **fire-and-forget with no confirm or cancel** — a mis-tap sends a real push. Inherent to the existing `CheckInRow` contract this control deliberately matches; changing it is a product/backend decision for the sibling `/build` task.
- **Five behavior-altering decisions remain pipeline-made, not user-confirmed**: badge semantics, making the row tappable, true horizontal scroll, keeping the row in its slot, adding name captions. The **tappability** change is still the significant one — the user asked for a look and is getting a row of live navigation targets.
- The **24-hour "recent activity" window** is the pipeline's own pick; no such threshold exists in app or backend.
- **Two things need a device look, not more arithmetic**: the tile's composited lift against real `.ultraThinMaterial` output (every contrast figure here rests on a modelled parent value), and whether the gold ring reads as "selected" or as "this is who's shown below."
- **Sibling-task reconciliation.** `onNudge` and `NudgeUIState` have landed, which is real convergence; still outstanding is driving `nudgeStates` (including knowing "already rate-limited" on first render) and wiring the control once the tile restyle lands.

---

## Desirables traceability

| Desirable (intake) | Status |
|---|---|
| Horizontal row of individually-bounded cards, not the facepile | **Met** |
| Rounded-square container, circular photo inset, generous rounding | **Met** — 68pt tile, 20pt `.continuous`, 40pt centered avatar; geometry re-verified this pass |
| Dark/glass treatment consistent with dashboard glassmorphism | **Met** — flat relative lift, warm-hued, no second material inside an already-blurred parent |
| Small circular badge overlapping the photo's bottom-right | **Met on placement, size and contrast** (11pt at 0.275× avatar, correct anchor, filled/hollow shape distinction, ≈5.53:1) — **R1 undermines its cutout construction** |
| Legible and thumb-scannable at a glance | **Met** — remaining pressure is R3's invisible hit zone, an interaction risk rather than a legibility one |
| Compose existing `AvatarView` and existing styling, no one-off | **Met, and exceeded** — reuses `AvatarView`, `CheckInRow`'s `paperplane.fill`, and the shared `NudgeUIState` rather than inventing parallels |
| Accessibility deliberately decided, not carried over | **Met** — `.accessibilityHidden` removed, two independent elements with distinct labels, the composition that makes that work is now stated unambiguously, Dynamic Type and reduced motion both specified. R4 is a small inconsistency, not a gap |
| Scoped revision, not a Dashboard rewrite | **Met** — one component replaced, two padding values and one existing label touched |
| Real data drives the row; graceful fallback | **Met** — no placeholder friends; `AvatarView` initials fallback and `noFriendsState` preserved |
| **Amendment:** small nudge interaction in each tile's top-right corner | **Met** — placement, sizing, cutout, five states, contract, and accessibility all specified; R1/R2/R4 are refinements to a control that is now fundamentally sound |

**Style-direction fidelity:** the brief's structure (discrete non-overlapping squircles, corner-badged, warm re-tone, spacious gaps, name captions, press feedback eased and exit-faster-than-enter) is carried faithfully. Three places where the spec **deviates from the style brief deliberately and correctly**: the tile fill (brief said `Theme.cardBg`, which is darker than the page — corrected), the per-activity-type badge glyphs (brief specified four; they were sub-legible at the corrected badge size — dropped, with meaning carried by the accessibility label and the 28pt headline), and the "14pt above" figure (brief's number, traced to the card's real 20pt padding — corrected). Each is argued, not silently dropped. The one remaining drift is R1: the brief's named cutout technique is specified but, as written, won't render.

---

## Summary of residual fixes

| # | Severity | Fix |
|---|---|---|
| R1 | Major | Cutouts must actually cut out — mask the badge/nudge circles out of `AvatarView` with `.blendMode(.destinationOut)` in a `.compositingGroup()`; delete "same fill as tile" from §1, §2 and the Styling table |
| R2 | Moderate | Apply `.padding(8)` to the 18pt visual frame and expand the hit area with `.contentShape(Circle().inset(by: -7))`, so the stated (51, 17) center survives implementation |
| R3 | Moderate | Device look for mis-taps on the ~7pt invisible nudge annulus; dial is the hit area (32 → 26–28pt), not the visual size |
| R4 | Minor | Gate the mirrored `.accessibilityAction(named: "Nudge")` on `.idle`/`.failed`, matching `CheckInRow.isDisabled` |
| R5 | Minor | Re-argue the nudge cutout's corner clearance against the 20pt corner arc (15.7 < 20), not the straight edge |
| R6 | Minor | Confirm on device that the scroll strip inset inside the card's 20pt padding reads as intended rather than as a clipped row |
