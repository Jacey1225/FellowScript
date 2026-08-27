// DashboardComponents.swift
// Subviews for the redesigned Dashboard (DashboardView.swift). Each takes only
// real model data; design-specific gradient colors are inline hex, content
// colors use Theme tokens. No fabricated data — callers hide a card when its
// source is empty.
//
// SOURCE MAPPING: reference DashboardRedesign.swift, Theme/Theme.swift

import SwiftUI

// ── Glassmorphism card background ─────────────────────────────────────────────
// Frosted translucent glass: a dark material (the app is forced dark, so it
// renders dark) + a warm tint so the gold backdrop bleeds through the upper
// cards + a soft light hairline edge. Replaces the old opaque Theme.cardBg fill.
extension View {
    // `tint`/`border` default to the exact values every pre-existing call site
    // relied on implicitly, so Dashboard/Chat/Notes/Note-Editor call sites that
    // only ever pass `cornerRadius:` render identically. The Danger Zone card
    // (AccountView.swift) is the only caller that overrides them, swapping in
    // Theme.dangerBg/Theme.borderDanger for the same glass shape/material.
    // `blurBoost` (default 0, no-op) is the real-code equivalent of the mockup's
    // backdrop-filter blur bump (hero 22→26px, standard 18→22px). SwiftUI's
    // Material tiers have no numeric blur-radius knob, so when > 0 this
    // composites a second, reduced-opacity `.ultraThinMaterial` sample under
    // the tint and blurs only that layer — a second material pass stacked and
    // blurred reads measurably softer/hazier than one pass. Only the new
    // Editorial Hero call sites pass this; every other caller renders
    // byte-identical since the default preserves prior behavior exactly.
    func glassCard(
        cornerRadius: CGFloat = 20,
        tint: Color = Color(hex: "#2A1B0B").opacity(0.20),
        border: [Color] = [Color.white.opacity(0.20), Color(hex: "#D4922A").opacity(0.12)],
        blurBoost: CGFloat = 0
    ) -> some View {
        self
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    if blurBoost > 0 {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(0.6)
                            .blur(radius: blurBoost)
                    }
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: border,
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }

    // Shape-parameterized variant of `glassCard` above — identical material/
    // tint/border treatment, but composed over an arbitrary `Shape` instead
    // of a `RoundedRectangle`. Added for `NoteResumeCard`'s notched card body
    // (design-spec.md §3 steps 3-4: the card's fill AND its 1pt hairline
    // stroke must both follow the bottom-right notch/chamfer cut), which a
    // plain `cornerRadius:` can't express. `eoFill` lets a shape that
    // combines a boolean-subtraction (even-odd) path — like
    // `NoteResumeCardShape` — fill correctly. Uses `.stroke` rather than the
    // `.strokeBorder` the `cornerRadius:` overload uses above, since
    // `strokeBorder` requires `InsettableShape` conformance (which a
    // boolean-subtraction shape can't meaningfully provide) — at this 1pt
    // hairline weight the outward-vs-inset difference is imperceptible.
    // Every existing call site keeps using the `cornerRadius:` overload
    // above, completely unchanged.
    func glassCard<S: Shape>(
        shape: S,
        eoFill: Bool = false,
        tint: Color = Color(hex: "#2A1B0B").opacity(0.20),
        border: [Color] = [Color.white.opacity(0.20), Color(hex: "#D4922A").opacity(0.12)],
        blurBoost: CGFloat = 0
    ) -> some View {
        let fillStyle = FillStyle(eoFill: eoFill)
        return self
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial, style: fillStyle)
                    if blurBoost > 0 {
                        shape.fill(.ultraThinMaterial, style: fillStyle)
                            .opacity(0.6)
                            .blur(radius: blurBoost)
                    }
                    shape.fill(tint, style: fillStyle)
                }
            )
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: border,
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
    }
}

// ── Hero header + warm gradient ───────────────────────────────────────────────
// Matches the approved mockup's header treatment: a single greeting line,
// nothing above or below it (no "YOUR RHYTHM" eyebrow, no "Last read..."
// subtitle — both existed pre-redesign and leaked through as stale internal
// jargon). Keeps the existing time-of-day + live-username greeting logic
// (arguably better product behavior than the mockup's hardcoded "Good
// morning, friend" copy) since the mockup's actual requirement is the
// *structure* (single line, no eyebrow/subtitle), not literal static text.
struct HeroHeader: View {
    let username: String

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    var body: some View {
        // Text only — the warm backdrop is provided by DashboardView so it can
        // fade smoothly past this header rather than ending on a hard edge.
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(greeting), \(username)")
                    .font(.system(size: 27, weight: .heavy))
                    .foregroundColor(Color(hex: "#2A1B0B"))
                    .lineLimit(2)
            }
            Spacer()
            // Identity avatar (decorative — not a control, so no dead button).
            Circle()
                .fill(Color(hex: "#2A1B0B"))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(String(username.prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "#F0AE40"))
                )
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }
}

// ── Friend Activity hero card ("Editorial Hero" mockup) ────────────────────────
// Ports `.hero-card` from friend-activity-dashboard-revised.html: an avatar
// stack of active friends, the most-recently-active friend's headline +
// timestamp (tap → open their chat), and (if they have one) a preview of
// their most recent public note. Superseding GroupActivityWidget — this is
// the community/friend-activity emphasis the redesign is built around.
struct FriendActivityHeroCard: View {
    let feed: FSFriendActivityFeed
    let onOpenFriend: (FSFriendActivityEntry) -> Void

    // Most-recently-active friend (feed is already ordered by last_active_at
    // desc, nulls last) — nil `last_active_at` here means *no* friend has any
    // tracked activity, which is a distinct empty state from "no friends".
    private var primary: FSFriendActivityEntry? { feed.friends_active.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if feed.friends_active.isEmpty {
                noFriendsState
            } else {
                avatarStackRow
                if let primary, primary.last_active_at != nil {
                    activityRow(primary)
                    if let preview = primary.note_preview {
                        Divider().background(Color.white.opacity(0.08)).padding(.top, 16)
                        Text(preview.text)
                            .font(.system(size: 17))
                            .foregroundColor(Theme.parchment.opacity(0.85))
                            .lineLimit(4)
                            .padding(.top, 16)
                            .padding(.leading, 32)
                    }
                } else {
                    Text("No recent activity from your friends yet.")
                        .font(.system(size: 14.5))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.top, 14)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 24, tint: Color(hex: "#2A1B0B").opacity(0.14), blurBoost: 6)
        .padding(.horizontal, 20)
    }

    private var noFriendsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a friend to see their notes and highlights here.")
                .font(.system(size: 14.5))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var avatarStackRow: some View {
        HStack {
            Spacer()
            HStack(spacing: -9) {
                ForEach(Array(feed.friends_active.prefix(4))) { f in
                    Circle().fill(Color(hex: "#24170A"))
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Theme.bgPage, lineWidth: 2))
                        .overlay(Text(f.initial).font(.system(size: 12, weight: .bold)).foregroundColor(Theme.goldLight))
                }
                if feed.friends_active.count > 4 {
                    Circle().fill(Color(hex: "#24170A"))
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Theme.bgPage, lineWidth: 2))
                        .overlay(Text("+\(feed.friends_active.count - 4)")
                            .font(.system(size: 10.5, weight: .bold)).foregroundColor(Theme.goldLight))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func activityRow(_ entry: FSFriendActivityEntry) -> some View {
        Button(action: { onOpenFriend(entry) }) {
            HStack(alignment: .top, spacing: 14) {
                Circle().fill(Color(hex: "#24170A"))
                    .frame(width: 32, height: 32)
                    .overlay(Text(entry.initial).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.goldLight))
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline(entry))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(Theme.parchment)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let d = parseActivityDate(entry.last_active_at) {
                        Text(activityTimeLabel(d))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.parchment.opacity(0.55))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.gold.opacity(0.75))
                    .padding(.top, 8)
            }
            .padding(.top, 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.username): \(headline(entry)). Tap to open chat.")
    }

    private func headline(_ entry: FSFriendActivityEntry) -> String {
        let when = dayWord(entry.last_active_at)
        return entry.note_preview != nil
            ? "\(entry.username) wrote a note \(when)"
            : "\(entry.username) was active \(when)"
    }

    private func dayWord(_ iso: String?) -> String {
        guard let d = parseActivityDate(iso) else { return "recently" }
        return activityDayLabel(d).lowercased()
    }
}

// ── Check-in nudge row (flush, no container — matches `.checkin-row`) ──────────
struct CheckInRow: View {
    let checkIn: FSCheckInCandidate
    let onTap:   () -> Void

    private var badgeText: String {
        guard let days = checkIn.days_since_contact else { return "Never messaged" }
        if days <= 0 { return "Talked today" }
        return days == 1 ? "It's been 1 day" : "It's been \(days) days"
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Check in with \(checkIn.username)")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(Theme.parchment)
                Text(badgeText)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Theme.goldLight.opacity(0.85))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .overlay(Capsule().stroke(Theme.gold.opacity(0.35), lineWidth: 1))
            }
            Spacer(minLength: 0)
            Button(action: onTap) {
                Circle()
                    .fill(LinearGradient(colors: [Theme.goldLight, Theme.goldDim],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Circle().fill(Color(hex: "#24170A")).frame(width: 50, height: 50)
                            .overlay(Image(systemName: "paperplane.fill")
                                .font(.system(size: 17))
                                .foregroundColor(Theme.goldLight))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Check in with \(checkIn.username)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 2)
    }
}

// ── Continue island geometry (design-spec.md §1/§2.3/§3) ───────────────────────
// The card's bottom-right corner has a notch subtracted from it, and the new
// "Continue" island's own top-left corner is chamfered to match — both built
// from the same depth-off-the-arc construction so the 12pt gutter between
// them stays constant-width through the diagonal, by construction, with no
// extra reconciliation step (§3 step 3).

/// Depth-off-the-arc chamfer geometry per design-spec.md §2.3/§3 step 2:
/// given a corner of `radius` whose two flat edges meet at
/// `(center.x - radius, center.y - radius)`, returns where a chamfer facet
/// cut `depth` into the arc at `angleDegrees` off horizontal actually
/// crosses those two flat edges (the facet's angular span on the circle
/// necessarily overruns the corner's own 90° quarter-arc — see §2.3 — so
/// these crossing points, not the plain tangent points, are what the facet
/// actually connects to). Shared by the island's own top-left corner and the
/// card's derived notch (built at the notch's own inflated radius) so both
/// facets stay parallel.
private func chamferEdgeIntersections(
    center: CGPoint, radius: CGFloat, depth: CGFloat, angleDegrees: Double
) -> (onLeftEdge: CGPoint, onTopEdge: CGPoint) {
    let h = Double(max(0, radius - depth))                 // sagitta: perpendicular distance from center
    let psi = (270 - angleDegrees) * .pi / 180              // facet's perpendicular direction from center
    let lineDir = psi - .pi / 2                             // facet's own line direction
    let footX = Double(center.x) + h * cos(psi)
    let footY = Double(center.y) + h * sin(psi)
    let dx = cos(lineDir), dy = sin(lineDir)

    let topY = Double(center.y - radius)
    let tTop = dy != 0 ? (topY - footY) / dy : 0
    let onTop = CGPoint(x: footX + tTop * dx, y: topY)

    let leftX = Double(center.x - radius)
    let tLeft = dx != 0 ? (leftX - footX) / dx : 0
    let onLeft = CGPoint(x: leftX, y: footY + tLeft * dy)

    return (onLeft, onTop)
}

/// The "Continue" island's own silhouette (design-spec.md §2.2): a capsule
/// (full round on the right end and the bottom-left quarter) with the
/// top-left corner replaced by the 8pt-depth, ~52°, 4pt-rounded-join
/// chamfer from §1/§2.3/§3 step 2 — never an angle-and-run cut off the
/// bounding box, which §2.3/§3 step 2 explicitly rules out as invisible at
/// this corner radius.
struct ContinueIslandShape: Shape {
    var chamferDepth: CGFloat
    var chamferAngle: Double
    var joinRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.height / 2
        guard r > chamferDepth, rect.width > 2 * r else {
            return Path(roundedRect: rect, cornerRadius: max(0, min(r, rect.width / 2)), style: .continuous)
        }
        let center = CGPoint(x: rect.minX + r, y: rect.minY + r)
        let (onLeft, onTop) = chamferEdgeIntersections(center: center, radius: r, depth: chamferDepth, angleDegrees: chamferAngle)

        // Built via CGMutablePath (not SwiftUI's Path directly) because the
        // two chamfer-corner fillets need `addArc(tangent1End:tangent2End:
        // radius:)`, which only exists on CGMutablePath/UIBezierPath, not on
        // SwiftUI's own Path type. Path(_ cgPath:) bridges the result back.
        let cgPath = CGMutablePath()
        cgPath.move(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        cgPath.addArc(tangent1End: onLeft, tangent2End: onTop, radius: joinRadius)
        cgPath.addArc(tangent1End: onTop, tangent2End: CGPoint(x: rect.maxX - r, y: rect.minY), radius: joinRadius)
        cgPath.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        cgPath.addArc(center: CGPoint(x: rect.maxX - r, y: rect.midY), radius: r,
                      startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        cgPath.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        cgPath.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                      startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        cgPath.closeSubpath()
        return Path(cgPath)
    }
}

/// The card's bottom-right notch (design-spec.md §2.3/§3 step 3): the
/// island's own top-left silhouette (top edge, chamfered corner, left edge)
/// inflated outward by `gutter` on the sides facing the card interior. The
/// notch's right/bottom sides deliberately extend past the card's own
/// edges — the island sits flush with the card's trailing edge and
/// overhangs its bottom edge, so no gutter is needed on those two sides,
/// only where the notch's cut faces card material (top and left).
struct NoteResumeCardNotch: Shape {
    var islandWidth: CGFloat
    var islandHeight: CGFloat
    var gutter: CGFloat
    var chamferDepth: CGFloat
    var chamferAngle: Double
    var joinRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let notchRadius = islandHeight / 2 + gutter   // §2.3: island radius inflated by the gutter
        let islandTopInset = 0.42 * islandHeight        // §2.3: island's top edge, measured up from the card's bottom edge
        let notchLeft = rect.maxX - islandWidth - gutter
        let notchTop  = rect.maxY - islandTopInset - gutter
        // Extend generously past the card's own bottom-right edge so the cut
        // fully reaches the boundary regardless of the card's own corner
        // radius there — this whole region is being subtracted anyway.
        let overrun = max(rect.width, rect.height) + notchRadius
        let notchRect = CGRect(
            x: notchLeft, y: notchTop,
            width: (rect.maxX - notchLeft) + overrun,
            height: (rect.maxY - notchTop) + overrun
        )

        guard notchRadius > chamferDepth, notchRect.width > notchRadius, notchRect.height > notchRadius else {
            return Path(notchRect)
        }

        let center = CGPoint(x: notchRect.minX + notchRadius, y: notchRect.minY + notchRadius)
        let (onLeft, onTop) = chamferEdgeIntersections(center: center, radius: notchRadius, depth: chamferDepth, angleDegrees: chamferAngle)

        // See ContinueIslandShape above: built via CGMutablePath for the
        // same tangent-arc-fillet reason.
        let cgPath = CGMutablePath()
        cgPath.move(to: CGPoint(x: notchRect.minX, y: notchRect.maxY))
        cgPath.addLine(to: CGPoint(x: notchRect.minX, y: onLeft.y))
        cgPath.addArc(tangent1End: onLeft, tangent2End: onTop, radius: joinRadius)
        cgPath.addArc(tangent1End: onTop, tangent2End: CGPoint(x: notchRect.maxX, y: notchRect.minY), radius: joinRadius)
        cgPath.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.minY))
        cgPath.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.maxY))
        cgPath.closeSubpath()
        return Path(cgPath)
    }
}

/// The notched card body's fill/stroke shape: the existing rounded rect,
/// boolean-subtracting the notch above (design-spec.md §3 step 4) — draw
/// with an even-odd fill rule (`glassCard(shape:eoFill:...)`) so the notch
/// actually cuts a hole rather than adding a second overlapping fill.
struct NoteResumeCardShape: Shape {
    var cornerRadius: CGFloat
    var islandWidth: CGFloat
    var islandHeight: CGFloat
    var gutter: CGFloat
    var chamferDepth: CGFloat
    var chamferAngle: Double
    var joinRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        path.addPath(NoteResumeCardNotch(
            islandWidth: islandWidth, islandHeight: islandHeight, gutter: gutter,
            chamferDepth: chamferDepth, chamferAngle: chamferAngle, joinRadius: joinRadius
        ).path(in: rect))
        return path
    }
}

/// Wraps the card's title/preview content in the glass material, switching
/// between the notched shape (island/notch treatment active) and the
/// original plain rounded rect (§4 Dynamic Type fallback engaged) — the only
/// two card-background states this component ever renders.
private struct NotchedCardMaterial: ViewModifier {
    var useNotch: Bool
    var cornerRadius: CGFloat
    var islandWidth: CGFloat
    var islandHeight: CGFloat
    var gutter: CGFloat
    var chamferDepth: CGFloat
    var chamferAngle: Double
    var joinRadius: CGFloat

    func body(content: Content) -> some View {
        if useNotch {
            content.glassCard(
                shape: NoteResumeCardShape(
                    cornerRadius: cornerRadius,
                    islandWidth: islandWidth, islandHeight: islandHeight,
                    gutter: gutter, chamferDepth: chamferDepth,
                    chamferAngle: chamferAngle, joinRadius: joinRadius
                ),
                eoFill: true,
                tint: Color(hex: "#2A1B0B").opacity(0.14),
                blurBoost: 4
            )
        } else {
            content.glassCard(cornerRadius: cornerRadius, tint: Color(hex: "#2A1B0B").opacity(0.14), blurBoost: 4)
        }
    }
}

/// Press-state styling for the "Continue" island / its fallback capsule
/// (design-spec.md §2.4): scale to 0.96 with a one-step fill darkening,
/// 150ms ease-out. Reduce Motion drops the scale transform entirely and
/// substitutes a brief opacity dip alongside the same darkening.
private struct ContinueIslandButtonStyle: ButtonStyle {
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1.0)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(reduceMotion && configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// ── Note-resume card (ports `.glass-card.standard.note-card`) ──────────────────
// Adapts the existing "continue reading" affordance to the redesign's
// note-resume concept: the user's own most recent note (`vm.recentNote`), not
// a friend's. `note == nil` (no notes written yet) renders a defined empty
// state that opens a fresh note instead of silently vanishing — and, per
// design-spec.md §2.4 and this task's own design step 1 (design-notes.md),
// that empty state keeps its original pill exactly as-is: the island/notch
// treatment only ever applies to the populated (`note != nil`) branch.
struct NoteResumeCard: View {
    let note:   FSNote?
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var labelSize: CGSize = .zero
    @State private var cardWidth: CGFloat = 0

    // ── design-spec.md §5 tokens (component-internal — Bucket 2, fixed
    // across every device width per §6) ─────────────────────────────────────
    private let gutter: CGFloat           = 12
    private let chamferDepth: CGFloat     = 8
    private let chamferAngle: Double      = 52
    private let chamferJoin: CGFloat      = 4
    private let cardCornerRadius: CGFloat = 20   // unchanged from the existing card

    // §2.2: height is a floor, width is intrinsic to the rendered label —
    // both recompute live from `labelSize`, which itself is re-measured at
    // every Dynamic Type change (see `measuringLabel` below), never a value
    // computed once at design time.
    private var islandHeight: CGFloat { max(44, labelSize.height + 22) }
    private var islandWidth:  CGFloat { labelSize.width + 36 }

    // §2.1: card bottom padding, rounded up to the nearest 4pt.
    private var derivedBottomPadding: CGFloat {
        ((0.42 * islandHeight + gutter + 4) / 4).rounded(.up) * 4
    }
    // §2.3/§3 step 8: 58% of the island's height sits below the card's own frame.
    private var belowCardReserve: CGFloat { 0.58 * islandHeight }

    // §4 fallback thresholds. The proportional width check (45% of
    // `cardWidth`) is the operative trigger; the 48pt padding-cap check is a
    // dead-code safety net under `.subheadline`, kept for completeness in
    // case the label style ever changes.
    private var notchTreatmentFits: Bool {
        guard cardWidth > 0 else { return true }
        return islandWidth <= 0.45 * cardWidth && derivedBottomPadding <= 48
    }

    private var noteTitle: String {
        guard let note else { return "" }
        return note.title.isEmpty ? "Untitled note" : note.title
    }

    var body: some View {
        if let note {
            populatedCard(note)
        } else {
            emptyStateCard
        }
    }

    // MARK: - Populated state — the new "Continue" island

    @ViewBuilder
    private func populatedCard(_ note: FSNote) -> some View {
        VStack(spacing: 0) {
            cardBody(note)
                .overlay(alignment: .bottomTrailing) {
                    // Bottom-trailing-aligned to the card's own frame, then
                    // shifted down by 58% of the island's height (§2.3) — the
                    // island's trailing edge lands flush with the card's
                    // trailing edge (both share the same outer 20pt margin
                    // below), and its top/bottom edges land exactly at
                    // `cardBottomY − 0.42×islandHeight` /
                    // `cardBottomY + 0.58×islandHeight` as specified.
                    if notchTreatmentFits {
                        continueIsland.offset(y: belowCardReserve)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !notchTreatmentFits {
                        fallbackContinueCapsule
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                }
            // §2.3/§3 step 8: reserve the overhang as real layout space in
            // this component's own container (rather than assuming the
            // parent stack's incidental spacing covers it) — collapsed
            // entirely once the fallback removes the overhang. Verified
            // against the live view hierarchy (ContentView → TabView →
            // DashboardView's ScrollView/LazyVStack → this card): none of
            // those ancestors clip, and the ScrollView/LazyVStack's existing
            // 150pt bottom padding for the floating tab bar comfortably
            // clears the ≥16pt island-to-tab-bar gap on top of this
            // reservation at every Dynamic Type size up to the point the
            // §4 fallback engages.
            if notchTreatmentFits {
                Color.clear.frame(height: belowCardReserve)
            }
        }
        .padding(.horizontal, 20)
        .background(measuringLabel)
    }

    private func cardBody(_ note: FSNote) -> some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                Text(note.title.isEmpty ? "Untitled note" : note.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(2)
                Text(note.preview)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.parchment.opacity(0.70))
                    .lineLimit(3)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume note: \(noteTitle)")
        // §2.1: top/left/right padding unchanged (16pt); bottom padding is
        // the derived value while the notch is active, or the original 16pt
        // once the §4 fallback takes over (no notch to clear in that case).
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, notchTreatmentFits ? derivedBottomPadding : 16)
        .modifier(NotchedCardMaterial(
            useNotch: notchTreatmentFits,
            cornerRadius: cardCornerRadius,
            islandWidth: islandWidth, islandHeight: islandHeight,
            gutter: gutter, chamferDepth: chamferDepth,
            chamferAngle: chamferAngle, joinRadius: chamferJoin
        ))
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { cardWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in cardWidth = new }
            }
        )
    }

    // Hidden, zero-footprint "Continue" label solely for measuring
    // `labelSize` at the live Dynamic Type size (§3 step 1/§4: island
    // width/height and every derived notch/padding/reserve value must
    // recompute from the *rendered* label, not a value computed once at
    // design time). `.fixedSize()` makes this Text report its true
    // intrinsic size regardless of the space proposed to it.
    private var measuringLabel: some View {
        Text("Continue")
            .font(.subheadline.weight(.semibold))
            .tracking(0.2)
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { labelSize = geo.size }
                        .onChange(of: geo.size) { _, new in labelSize = new }
                }
            )
            .hidden()
    }

    // The "Continue" island itself (design-spec.md §2.2/§2.3/§3).
    private var continueIsland: some View {
        let shape = ContinueIslandShape(chamferDepth: chamferDepth, chamferAngle: chamferAngle, joinRadius: chamferJoin)
        return Button(action: onOpen) {
            Text("Continue")
                .font(.subheadline.weight(.semibold))
                .tracking(0.2)
                .foregroundColor(Color(hex: "#24170A"))
                .frame(width: islandWidth, height: islandHeight)
                .background(
                    LinearGradient(colors: [Color(hex: "#EEAC3F"), Color(hex: "#C88C2C")],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(shape)
                .overlay(
                    // Top rim (§2.2): a 1pt inner stroke meant to read on the
                    // top edge only. Approximated here as a full-perimeter
                    // stroke faded out via a top-to-bottom mask, rather than
                    // a hand-trimmed top-only path — visually equivalent at
                    // this shape's proportions and far simpler to keep in
                    // sync with the live chamfer geometry above.
                    shape
                        .stroke(Color(hex: "#F5D392"), lineWidth: 1)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.35), location: 0.0),
                                    .init(color: .white.opacity(0.35), location: 0.45),
                                    .init(color: .clear, location: 0.6),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                )
                // Three shadows (§2.2): separation (zero-offset, carves the
                // top/left gutter — blur tied to `gutter + 2pt`), ambient,
                // and contact, all layered on the same view.
                .shadow(color: .black.opacity(0.40), radius: gutter + 2, x: 0, y: 0)
                .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 4)
                .shadow(color: .black.opacity(0.40), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(ContinueIslandButtonStyle(reduceMotion: reduceMotion))
        // §3 step 9: the chamfer removes real material from the fill near
        // the top-left corner; without this, SwiftUI would hit-test against
        // that reduced fill instead of the nominal bounding rect.
        .contentShape(Rectangle())
        .accessibilityLabel("Continue reading \(noteTitle)")
    }

    // §4 fallback: full-width capsule fully inside the card's padding box,
    // no notch/overhang, standard 16pt bottom padding restored above.
    private var fallbackContinueCapsule: some View {
        Button(action: onOpen) {
            Text("Continue")
                .font(.subheadline.weight(.semibold))
                .tracking(0.2)
                .foregroundColor(Color(hex: "#24170A"))
                .frame(maxWidth: .infinity)
                .frame(height: islandHeight)
                .background(
                    LinearGradient(colors: [Color(hex: "#EEAC3F"), Color(hex: "#C88C2C")],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(ContinueIslandButtonStyle(reduceMotion: reduceMotion))
        .contentShape(Rectangle())
        .accessibilityLabel("Continue reading \(noteTitle)")
    }

    // MARK: - Empty state (`note == nil`)
    //
    // Unchanged, pixel-for-pixel, per design step 1's decision
    // (design-notes.md): the island/notch treatment and the card's derived
    // height/padding apply only to the populated branch above. This branch
    // is exactly the original implementation, preserved so
    // `NoteResumeCardTests`'s existing empty-state assertions keep passing.
    private var emptyStateCard: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                Text("You haven't written a note yet.")
                    .font(.system(size: 14.5))
                    .foregroundColor(Theme.textSecondary)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Start a note").font(.system(size: 14.5, weight: .heavy))
                        Text("capture a reflection").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(Color(hex: "#24170A"))
                    Spacer()
                    Circle().fill(Color(hex: "#24170A")).frame(width: 38, height: 38)
                        .overlay(Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.goldLight))
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(LinearGradient(colors: [Theme.goldLight, Theme.goldDim],
                                           startPoint: .leading, endPoint: .trailing))
                .clipShape(Capsule())
                .padding(.top, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(16)
        .glassCard(cornerRadius: 20, tint: Color(hex: "#2A1B0B").opacity(0.14), blurBoost: 4)
        .padding(.horizontal, 20)
        .accessibilityLabel("Start a new note")
    }
}

// ── Friend-activity timestamp helpers ───────────────────────────────────────────
// Small, local ISO-date parser/formatter for the hero card's activity
// timestamps — mirrors the parsing this file's other dashboard-only pieces
// already do locally (e.g. CommunityActivityItem.timeLabel before it) rather
// than reaching into DashboardViewModel's private static parseDate.
private func parseActivityDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return d }
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) { return d }
    let df = DateFormatter()
    for fmt in ["yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
        df.dateFormat = fmt
        if let d = df.date(from: s) { return d }
    }
    return nil
}

private func activityDayLabel(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date)     { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f.string(from: date)
}

private func activityTimeLabel(_ date: Date) -> String {
    let f = DateFormatter()
    f.timeStyle = .short
    return "\(activityDayLabel(date)) · \(f.string(from: date))"
}
