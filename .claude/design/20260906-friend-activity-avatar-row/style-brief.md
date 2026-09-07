# Style Brief — Friend Activity avatar row

Task: `20260906-friend-activity-avatar-row`
Stage: 2 (reference synthesis)

---

## Media type

**`static`.**

Reasoning: the deliverable is a SwiftUI layout revision to an existing on-screen component (`FriendActivityHeroCard.avatarStackRow`), not a rendered motion asset. The user's own framing ("show up in the friend activity widget") describes a persistent UI state; the sole attached reference is a static screenshot; no animation, transition, or video artifact was requested. Motion still appears in this brief, but only as *press-feedback specification for a static component* — that does not make the deliverable a video. Step 3 routes to `design-static-spec-agent`.

---

## Unified style direction

### Mood

**Warm-lit hearth, quiet presence.** Discord's reference row reads cold-neutral and utilitarian — a device-status strip. FellowScript's dashboard reads candlelit and communal. The synthesized row keeps Discord's *structure* (discrete, individually-bounded, non-overlapping squircle tiles, corner-badged) and re-tones it entirely into FellowScript's warm dark: the strip should feel like a row of small lit windows showing who's been in scripture lately, not a presence-indicator array.

The row is a **nested surface inside an already-glass card**. That is the single hardest constraint in this brief: `FriendActivityHeroCard` is already `.glassCard(cornerRadius: 24, tint: #2A1B0B @0.14, blurBoost: 6)`. Stacking a second `.ultraThinMaterial` layer inside it compounds into visual mud. Discord's reference itself resolves this the right way — its cards are a **flat, slightly-lighter-than-background fill**, not a second blur. Follow Discord here, not the app's own `glassCard` habit.

### Palette

All values are existing locked `Theme` tokens (Preference Q3: the visual system is established, not reopened). No new brand colors.

| Role | Token / value | Notes |
|---|---|---|
| Page beneath | `Theme.bgPage` `#1E1812` | unchanged |
| Parent card | `glassCard(24, tint #2A1B0B @0.14, blurBoost 6)` | unchanged, already in place |
| **Friend tile fill** | `Theme.cardBg` `#221508 @0.90` — **flat, no material** | the one new surface; sits a clear step above the parent glass |
| Tile hairline | `Color.white.opacity(0.10)` | ~half of `glassCard`'s `0.20` white stop, so nested tiles never out-shout the parent |
| Selected tile ring | `Theme.gold.opacity(0.55)`, 1.5pt | marks the friend expanded in `activityRow` below |
| Avatar fallback fill | `#24170A` + `Theme.goldLight` `#F0AE40` initials | `AvatarView` defaults — unchanged |
| Badge — has activity | fill `Theme.gold` `#D4922A`, glyph `Theme.ink` `#1A100A` | ~8:1 glyph-on-fill |
| Badge — no recent activity | hollow, stroke `Theme.parchment.opacity(0.28)`, no fill | Discord's neutral ring |
| Badge separator ring | stroke in the **tile fill color**, 2.5pt | Discord's exact technique: the badge is cut out of the avatar |
| Name caption | `Theme.parchment.opacity(0.85)` | ~12:1 on tile fill |

Contrast: gold on `#221508` measures ≈7:1 (AA comfortably, near AAA); parchment caption ≈12:1. Meets the Q14 AA floor. The badge glyph sits below the 12px text floor — it is an **icon, not text**, so its meaning must also be carried by the accessibility label (below), never by color or glyph alone.

### Typography

System SF only, existing dashboard scale. No new families, no new weights.

- Name caption: **11pt semibold**, one line, `.truncationMode(.tail)`, centered under its tile.
- Badge glyph: SF Symbol at ~7pt, `.bold` — sized to the badge, not to a text scale.
- Everything else in the widget (headline 28pt bold, timestamp 11pt) is untouched.

### Composition / layout

Proportions derived from the attached Discord screenshot and re-scaled to FellowScript's iOS metrics (dashboard 20pt outer margin + hero card 20pt inner padding → ~313pt usable on iPhone 15).

| Property | Value | Derivation |
|---|---|---|
| Tile | **68 × 68pt**, square | Discord's card measures ~1.03:1 |
| Corner radius | **20pt, `.continuous`** | Discord's ≈0.11 of card width; `.continuous` matches every other radius in this file |
| Gap between tiles | **10pt** | Discord's ≈0.094 of card width |
| Avatar diameter | **40pt** (0.59 of tile) | Discord's is 0.62; trimmed slightly to protect the badge's breathing room |
| Avatar position | horizontally centered, vertically centered | matches reference |
| Badge outer | **16pt** diameter, 2.5pt ring of tile fill | Discord's ≈0.27 of avatar diameter |
| Badge anchor | avatar's bottom-right, ~45° | overlaps the **photo**, not the tile corner — this is the detail that makes it read as Discord |
| Name caption gap | 6pt below tile | from the curated F1 "Cast" row |
| Row height | ~88pt total | 68 + 6 + 14 |
| Visible tiles | 4 full + ~11pt peek of the 5th | 4×68 + 3×10 = 302 of 313 |

**Horizontal scroll, not fixed-count.** `ScrollView(.horizontal, showsIndicators: false)`, with the trailing tile deliberately half-visible to signal scrollability. The existing `+N` overflow circle is **removed** — scrolling makes it redundant. Cap the rendered set (~12 friends) for list perf.

Note on the `ui-ux-pro-max` "avoid horizontal scroll" guideline (severity: High): that rule is scoped to *web page-level* horizontal overflow. An intentional, bounded, in-card carousel on a native mobile surface is the opposite case, and is exactly what both the attached reference and the curated `b3f90ded…` "Day tasks" row do. Deviation is deliberate and stated.

Whitespace follows Q4 (spacious): 14pt above the row, 16pt below. Watch for double-padding against `activityRow`'s existing `.padding(.top, 14)` — reconcile at spec stage rather than stacking both.

### Motion language (press feedback only — this is a static deliverable)

Per Q9 (always eased, never linear) and Q10 (minimal feedback by default):

- Press: scale **0.96**, `.easeOut` **0.18s in / 0.12s out** — exit faster than enter, no spring overshoot.
- Photo load: reuse `AvatarView`'s existing 0.25s `.easeIn` crossfade. Nothing new.
- **No** staggered row-entrance choreography, no badge pulse, no shimmer. Q10's minimal-by-default governs; the row is glanceable, not a stage.
- `@Environment(\.accessibilityReduceMotion)` drops the press animation entirely (state change still applies instantly) — first-class, per Q14, matching how `AvatarView` already handles it.

### Resolved decisions (intake gaps closed here)

These were open at intake. Synthesis makes an explicit call on each rather than passing ambiguity forward; each is a stated choice the user can veto at critique.

1. **Badge semantics** → a **two-state, activity-derived** badge, not a Discord presence clone. FellowScript has no online/idle/DND concept, so cloning Discord's would mean inventing data.
   - *Has recent activity* → filled gold dot with an SF Symbol matching `activity_type`: `square.and.pencil` (note_created), `pencil` (note_edited), `bubble.left.fill` (note_replied), `highlighter` (verse_highlighted).
   - *Unrecognized / future `activity_type`* → filled gold dot, **no glyph** — mirrors the reference's plain-ring cards and matches the codebase's deliberate "unmatched values fall through to a generic fallback" decoding stance.
   - *No recent activity* → hollow parchment ring, no fill.
   - Filled-vs-hollow is a **shape** difference, not just a color one, so WCAG 1.4.1 holds without relying on hue.
2. **Interactivity** → **tappable, per friend**, invoking the existing `onOpenFriend(entry)` callback `activityRow` already uses. Q12 explicitly dislikes decorative, minimally-functional dashboard widgets, and the navigation path already exists — leaving the row inert would be the weaker choice. Consequently `.accessibilityHidden(true)` is **removed**; each tile becomes a real button with `.isButton` and a label of the form `"<username>, <activity headline>. Opens chat."`. The 68pt tile clears the 44×44 minimum with room to spare, and the 10pt gap clears the 8pt adjacent-target minimum.
3. **Scroll vs. fixed count** → true horizontal scroll with edge peek; `+N` overflow removed (above).
4. **Placement** → the card row **replaces `avatarStackRow` in its existing slot** (under the header, above `activityRow`). `activityRow` and the note/highlight preview stay exactly as they are — this is a scoped restyle, not a card rewrite. To resolve the resulting duplication (the headline friend appears both in the row and expanded below), **order the headline friend first and give their tile the gold selected ring** — this ties row to detail block and is the small functional delight Q18 asks for, at zero motion cost.
5. **Empty / loading** → per Q17, minimal and unfussy: if `friends_active` is empty the row simply doesn't render; the existing `noFriendsState` copy already covers the no-friends case. No skeleton, no shimmer, no invented empty-state illustration.

---

## Synthesis rationale

This is a **multi-reference** synthesis: one attached reference plus five confirmed matches from the curated library. The library matches were weighted equally with the attached screenshot, per the taste-baseline rule.

**From the attached Discord screenshot** (`~/.claude/channels/discord-development/inbox/1788741666599-1546319343984443452.png`) — the *skeleton*, and the only source for it: discrete non-overlapping squircle tiles; circular photo inset with real padding rather than edge-to-edge; badge overlapping the **photo's** bottom-right rather than the tile's corner; the badge's ring-of-card-color cutout technique; a filled-glyph card sitting beside plain-ring cards; and the measured proportions (1.03:1 tile, radius ≈0.11w, gap ≈0.094w, avatar ≈0.6w, badge ≈0.27× avatar) that drive the whole metrics table above. It is also the reference that *rules out* the overlapping facepile the app currently ships.

**From `widgets-dashboard-ui/original-a1de8333c29ebbcc147961ea8fd8ab86.webp`** — the closest thing in the library to this exact problem: circular avatar tokens carrying small colored corner accents, sitting on dark rounded cards with warm orange/amber accenting on near-black. Confirms that a gold-accented badge on a warm-dark tile is on-taste rather than a stretch, and that small avatar-plus-accent tokens stay legible at chip scale in Jacey's baseline.

**From `widgets-dashboard-ui/827660df4f4cdd6dab949cdcf48ed3e9.webp`** (and its crop, `f3cd6ba56b8772f3fd12eb5fd059850f.webp`) — generous ~24pt squircle radii, heavy inner padding, and avatar chips inset within a card rather than floating. This is where the "spacious inner whitespace" instinct (Q4) gets its concrete proportion, and it corroborates the decision to give the avatar real margin inside the tile instead of filling it.

**From `widgets-dashboard-ui/9edf8e02799223e3ab3b3000f69fc257.webp`** — uniformly-sized squircle tiles read as a set, including a person-as-tile treatment with live status. Supports treating each friend as a first-class tile rather than as decoration inside a larger block.

**From `mobile-app-screens/still-5c7c5e64ca7336c0f06fa0af0c789f55.webp`** (F1 "Cast" row) — a horizontal row of people on near-black with **name captions beneath**. This is the one place the synthesis deliberately *adds* to Discord: Discord's tiles are photo-only and anonymous until tapped. The library's own people-row consistently names them. Adding an 11pt caption below the tile keeps the tile itself faithful to Discord while making the row functionally better (you know who you're tapping) and giving the accessibility label a visible counterpart.

**From `mobile-app-screens/b3f90ded92c8fb6791d7352a11b33354.webp`** ("Day tasks" row) — a horizontally-scrolling card row with an intentionally peeking edge card. Directly resolves the scroll-affordance gap and supplies the "4 full + peek" fit target.

**From `mobile-app-screens/9710930a3a46fb30000cf826307fd7a2.webp`** — warm amber-on-dark mobile UI with circular avatars on dark cards; palette-adjacency confirmation that FellowScript's `#D4922A`-on-`#1E1812` register is already represented in the baseline, so re-toning Discord's cold neutrals into it is a move toward the taste profile, not away from it.

**What is genuinely shared across all of these**, and therefore what the synthesis keeps: discrete rounded-square tiles at a consistent size; real inner padding around a circular subject; a small high-contrast accent token at a corner; dark warm-neutral surfaces with hairline rather than solid borders; and a strong preference for one accent hue carrying all the signal. **What was not averaged in**: Discord's blurple/cold-grey palette, its anonymity, and its presence-state vocabulary — all three conflict with FellowScript's locked system or its actual data model, so structure was taken and tone was replaced rather than blended.

**Grounding:** `ui-ux-pro-max` (touch target ≥44×44, adjacent spacing ≥8pt, reduced-motion, dark-mode contrast, exit-faster-than-enter easing) and `design-system` (component tokens must reference existing semantic tokens — no raw hex introduced beyond what `Theme` already defines). `brand` was **not** loaded: Q3 treats FellowScript's identity as established and locked, and this task consumes tokens rather than defining them.

---

## Carried-forward gaps

**Unresolved from intake:**

- **"Recently active" has no definition.** The badge's filled-vs-hollow split depends on a threshold over `last_active_at`, but no such window exists anywhere in the app or backend. Spec stage must pick one concretely (24h is the obvious candidate) and state that it is a client-side derivation, not a server-provided flag. This is the most likely thing to need the user's input.
- **Quantity / variants** — still no variant count requested; single deliverable assumed. Dark-only (the app has no light mode on this surface).
- **Deadline** — still none stated.

**New, surfaced by synthesis:**

- **Nested-surface risk.** A tile inside `glassCard` is the one genuinely novel surface here, and the flat-`cardBg` resolution is reasoned but **not visually verified on device**. If `#221508 @0.90` over a `blurBoost: 6` parent reads flat/dead rather than layered, the fallback is a marginally lighter fill (not a second material). Needs a live look.
- **No token exists for "nested surface inside a glassCard."** Spec stage should either reuse `Theme.cardBg` as-is or add one named token to `Theme.swift` — but not scatter a raw hex into `DashboardComponents.swift`.
- **Headline-friend duplication is mitigated, not eliminated.** The same friend appears in the row and in `activityRow` below. The gold selected ring is the proposed tie, but whether that reads as intentional linkage or as redundancy is a judgement call best made against a rendered comp.
- **Dynamic Type at accessibility sizes.** An 11pt caption under a fixed 68pt tile will collide at XXL+. Spec stage must decide: does the tile grow, does the caption wrap to two lines, or does the caption drop entirely above a size threshold? Q14's AA-floor commitment makes "ignore it" not an option.
- **Five decisions above are synthesis-made, not user-confirmed.** Badge semantics, interactivity, scroll behavior, placement, and the added name caption were all resolved here by explicit choice. Each is defensible and grounded, but the interactivity change in particular alters the widget's behavior rather than just its appearance — worth surfacing to the user at critique.

## User amendment (2026-09-06) — read intake-brief.md's own amendment section for full context

New requirement added mid-pipeline: each tile needs a small, tappable nudge-trigger affordance in its **top-right corner** (a small icon button, e.g. a bell/hand-wave glyph on a subtle filled circle, sized modestly enough not to compete with the tile's existing bottom-right status badge or collide with the name caption below). This is the visual/interaction half of the sibling `/build` task `20260906-friend-nudges` — the nudge endpoint itself is being implemented there; this design task only needs to spec the control's placement, sizing, and tap state (default / pressed / sent-confirmation / rate-limited) within the tile. Revise the static spec to include this before critique finalizes.
