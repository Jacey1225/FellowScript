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

    // The `shape:`/split-stroke `glassCard` overloads that used to live here
    // (added for `NoteResumeCard`'s notched card body, task
    // 20260827-continue-island-shape-refinement) were removed by task
    // 20260828-continue-button-circle-implementation: the circular Continue
    // button's card join is a plain overlap with no notch (design-spec.md's
    // Option 2, "THE NOTCH" fix in generation.json), so every call site now
    // uses the plain `cornerRadius:` overload above. Confirmed via repo-wide
    // grep that nothing else ever called the `shape:` overloads.
}

// ── Shared avatar (task 20260905-profile-photo) ─────────────────────────────
// A small photo-with-initials-fallback circle, reused by every Dashboard/
// Chat/Notes surface that shows a user's identity via a plain initial
// circle today: HeroHeader/FriendActivityHeroCard below, MessageGroupRow's
// bubble avatars, and NoteDetailView's reply monogram. Deliberately NOT
// used by AccountView+Profile.swift's own profile-header avatar -- that one
// has its own bespoke gradient/Playfair-display treatment plus an upload
// affordance, and per this task's UI/UX preference profile (Q12: no forced
// cross-platform/cross-surface abstraction), a shared small-avatar
// component doesn't need to also cover that larger, editable, differently-
// styled case.
//
// Falls back to (and stays showing, underneath) the initials circle
// whenever `photoURL` is nil/empty, still loading, or fails to load --
// never a broken-image icon or blank space. The photo crossfades in via
// `AsyncImage`'s own `transaction:` (applied automatically on every phase
// change, including the initial load), respecting `prefers-reduced-motion`
// (UI/UX Q14/Q18) by dropping the animation entirely rather than skipping
// the photo.
struct AvatarView: View {
    let initial:     String
    var photoURL:    String? = nil
    var diameter:    CGFloat = 32
    var fillColor:   Color   = Color(hex: "#24170A")
    var textColor:   Color   = Theme.goldLight

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var resolvedURL: URL? {
        guard let photoURL, !photoURL.isEmpty else { return nil }
        return URL(string: photoURL)
    }

    var body: some View {
        ZStack {
            Circle().fill(fillColor)
            Text(initial)
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundColor(textColor)
            if let resolvedURL {
                AsyncImage(
                    url: resolvedURL,
                    transaction: Transaction(animation: reduceMotion ? nil : .easeIn(duration: 0.25))
                ) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: diameter, height: diameter)
                            .clipShape(Circle())
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// ── Home wordmark header ──────────────────────────────────────────────────────
// Task 20261008-home-wordmark-header: a small "FellowScript" wordmark (same
// Schibsted Grotesk SemiBold the website homepage nav uses) replaces the old
// announcement / "Welcome Back" headline. Text only -- the backdrop is
// provided by DashboardView so it can fade smoothly past this header. Lives
// inside the page's scroll content, so it scrolls with the page.
struct HomeWordmarkHeader: View {
    static let baseSize: CGFloat = 17

    var body: some View {
        WordmarkText(size: Self.baseSize, relativeTo: .headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }
}

// Mirrors activity.py's closed activity-type string set (NOTE_CREATED/
// NOTE_EDITED/NOTE_REPLIED/VERSE_HIGHLIGHTED) -- plain string constants, not
// a Swift enum, so `FSFriendActivityEntry.activity_type` (a plain optional
// String) can carry an unrecognized/future value without failing to decode
// the whole feed; unmatched values fall through to `headline`'s existing
// generic fallback below instead.
private enum FriendActivityType {
    static let created     = "note_created"
    static let edited      = "note_edited"
    static let replied     = "note_replied"
    static let highlighted = "verse_highlighted"
}

// Task 20260906-friend-activity-avatar-row (critique residual R4): a small,
// reusable conditional so an `.accessibilityAction` can be omitted entirely
// -- not merely turned into a no-op -- when its underlying control isn't
// currently interactive. A closure-guarded action would still appear on
// VoiceOver's rotor and silently do nothing; this keeps the rotor itself in
// sync with what the visible control can actually do.
private extension View {
    @ViewBuilder
    func accessibilityActionIfEnabled(_ enabled: Bool, named name: Text, _ action: @escaping () -> Void) -> some View {
        if enabled {
            accessibilityAction(named: name, action)
        } else {
            self
        }
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
    // Task 20260902-dashboard-friend-randomization: the headline friend used
    // to always be `feed.friends_active.first` (most-recently-active). It's
    // now a random pick from that same list, re-rolled by the caller once
    // per `DashboardViewModel.load()` call and threaded in here rather than
    // derived as a computed property in this view -- a computed property
    // read from `body` would re-roll on every unrelated SwiftUI re-render
    // (e.g. `notes`/`isLoading` changing elsewhere on the dashboard), not
    // just on an actual refresh. Defaults to nil (falling back to `.first`
    // below) so call sites/previews/tests that don't thread a pick through
    // keep the prior deterministic behavior.
    var primary: FSFriendActivityEntry? = nil
    let onOpenFriend: (FSFriendActivityEntry) -> Void
    // Task 20260903-friend-activity-note-navigation: distinct tap target on
    // the note-preview text block below, separate from activityRow's own
    // Button (which stays wired to onOpenFriend/chat, unchanged). Defaulted
    // (not required) so every pre-existing call site/preview/test that only
    // supplies onOpenFriend (all of DashboardEmptyStateTests.swift and
    // DashboardFriendRandomizationTests.swift) keeps compiling unchanged.
    var onOpenNote: (FSFriendNotePreview) -> Void = { _ in }
    // True while DashboardView has an in-flight fetch for the tapped
    // preview's full note -- shows a small inline spinner next to the
    // preview text and disables re-tapping mid-fetch, per the UI/UX
    // preference profile's "minimal feedback, only where genuinely
    // ambiguous" guidance (this is a real network round-trip with a
    // plausible failure mode, so *some* feedback is warranted, just not
    // more than this).
    var isLoadingNotePreview: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Caption font scales with Dynamic Type through the standard range
    // instead of being fixed/shrunk via minimumScaleFactor -- overflow is
    // absorbed by the caption's own fixed-width truncation instead
    // (friendTile below), per design-spec.md Components §1.
    @ScaledMetric(relativeTo: .caption2) private var captionSize: CGFloat = 11

    // nil `last_active_at` here means *no* friend has any tracked activity,
    // which is a distinct empty state from "no friends".
    private var resolvedPrimary: FSFriendActivityEntry? { primary ?? feed.friends_active.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if feed.friends_active.isEmpty {
                noFriendsState
            } else {
                avatarStackRow
                if let resolvedPrimary, resolvedPrimary.last_active_at != nil {
                    activityRow(resolvedPrimary)
                    // Task 20260904-friend-activity-push-triggers: a
                    // verse_highlighted entry shows the new highlight_preview
                    // (real verse content, per Round 2) instead of the note
                    // preview -- a highlight and a group-note preview are
                    // never both present for the same entry today, but this
                    // ordering keeps note_preview as the fallback body
                    // content for every other activity type unchanged.
                    if resolvedPrimary.activity_type == FriendActivityType.highlighted,
                       let highlight = resolvedPrimary.highlight_preview {
                        Divider().background(Color.white.opacity(0.08)).padding(.top, 16)
                        highlightPreviewRow(highlight, friendUsername: resolvedPrimary.username)
                    } else if let preview = resolvedPrimary.note_preview {
                        Divider().background(Color.white.opacity(0.08)).padding(.top, 16)
                        notePreviewRow(preview, friendUsername: resolvedPrimary.username)
                    }
                } else {
                    Text("No recent activity from your friends yet.")
                        .font(.system(size: 14.5))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.top, 16)
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

    // ── Friend tile row (task 20260906-friend-activity-avatar-row) ─────────
    // Replaces the old right-aligned overlapping facepile with a
    // horizontally-scrolling row of Discord-inspired squircle tiles, per
    // design-spec.md Layout/Components §1-3. `showsIndicators: false` and
    // `LazyHStack` (not `HStack`) so tiles build on demand rather than
    // all-at-once, matching the row container spec below.
    private var avatarStackRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(rowFriends) { entry in
                    friendTile(entry)
                }
            }
        }
    }

    // Rendered friend set: `feed.friends_active`, never reordered
    // (design-spec.md §3, Issue 7/20). Take the first 50 (LazyHStack removes
    // the perf justification for a lower cap), then, if `resolvedPrimary`
    // isn't already present in that slice, insert it at the *head* rather
    // than appending it -- appending would place the presence guarantee
    // past the visible/peek window for anyone with more than 50 friends,
    // exactly the case the guarantee exists for. In the ordinary case
    // (<=50 friends) this union step is a no-op.
    private var rowFriends: [FSFriendActivityEntry] {
        var friends = Array(feed.friends_active.prefix(50))
        if let resolvedPrimary, !friends.contains(where: { $0.id == resolvedPrimary.id }) {
            friends.insert(resolvedPrimary, at: 0)
        }
        return friends
    }

    // One friend tile: squircle container (fill + hairline + selected-ring
    // in place + avatar + status badge) as the chat tap target, plus a name
    // caption below. Row height is not a fixed constant -- the VStack sizes
    // itself from its children, since the caption's @ScaledMetric font
    // makes its own height vary slightly with Dynamic Type.
    private func friendTile(_ entry: FSFriendActivityEntry) -> some View {
        VStack(spacing: 6) {
            Button(action: { onOpenFriend(entry) }) {
                tileContent(entry)
            }
            .buttonStyle(FriendTileButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel("\(headline(entry)). Opens chat.")
            .frame(width: 68, height: 68)

            // At accessibility Dynamic Type sizes the caption is dropped
            // from layout entirely rather than wrapping or forcing the
            // tile to grow -- the friend's full name remains available via
            // the tile's own accessibilityLabel regardless.
            if dynamicTypeSize < .accessibility1 {
                Text(entry.username)
                    .font(.system(size: captionSize, weight: .semibold))
                    .foregroundColor(Theme.parchment.opacity(0.85))
                    .frame(width: 68)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    // The tile's chat-button content: squircle fill/hairline, the
    // in-place selected ring, the avatar (cut out for the status badge
    // corner), and the status badge itself.
    private func tileContent(_ entry: FSFriendActivityEntry) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.goldLight.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
            if resolvedPrimary?.id == entry.id {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.gold.opacity(0.55), lineWidth: 1.5)
                    .padding(1.5)
            }
            avatarWithCutouts(entry)
            statusBadge(for: entry)
        }
        .frame(width: 68, height: 68)
    }

    // A true cutout, masking the status badge out of the avatar itself via
    // `.blendMode(.destinationOut)` inside a `.compositingGroup()`, rather
    // than a same-tile-fill overprint circle drawn on top of the photo
    // (which only tints the photo by 6%, since the tile fill is a
    // translucent wash -- it does not occlude anything). Offset matches the
    // status badge's own centering below (avatarCenter + (14.1, 14.1)).
    private func avatarWithCutouts(_ entry: FSFriendActivityEntry) -> some View {
        AvatarView(initial: entry.initial, photoURL: entry.profile_photo_url, diameter: 40)
            .mask(
                ZStack {
                    Circle()
                    Circle().frame(width: 16, height: 16)
                        .offset(x: 14.1, y: 14.1)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            )
    }

    // Two-state only (Issue 4) -- filled gold dot / hollow ring, no
    // per-type glyphs. Activity type is carried by the accessibility
    // label and the 28pt headline below, not a mark that shrinks under
    // this badge's 11pt size.
    private func statusBadge(for entry: FSFriendActivityEntry) -> some View {
        Group {
            if hasRecentActivity(entry) {
                Circle().fill(Theme.gold)
            } else {
                Circle().stroke(Theme.parchment.opacity(0.70), lineWidth: 2)
            }
        }
        .frame(width: 11, height: 11)
        .offset(x: 14.1, y: 14.1)
    }

    // "Recent activity" threshold: last_active_at within the last 24
    // hours, computed client-side against the existing parseActivityDate
    // helper. No backend field; `last_active_at == nil` always renders
    // hollow.
    private func hasRecentActivity(_ entry: FSFriendActivityEntry) -> Bool {
        guard let d = parseActivityDate(entry.last_active_at) else { return false }
        return Date().timeIntervalSince(d) <= 24 * 60 * 60
    }

    private func activityRow(_ entry: FSFriendActivityEntry) -> some View {
        Button(action: { onOpenFriend(entry) }) {
            HStack(alignment: .top, spacing: 14) {
                AvatarView(initial: entry.initial, photoURL: entry.profile_photo_url, diameter: 32)
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
            .padding(.top, 16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(headline(entry)). Opens chat.")
    }

    // Distinct tap target from activityRow's headline Button above (task
    // 20260903-friend-activity-note-navigation) -- taps the note preview
    // itself, not the friend's avatar/name, and opens the full note rather
    // than the friend's chat thread. Own sibling accessibilityLabel, per
    // the spec's callout that activityRow's existing "...Tap to open chat."
    // label needs a distinguishable counterpart here.
    private func notePreviewRow(_ preview: FSFriendNotePreview, friendUsername: String) -> some View {
        Button(action: { onOpenNote(preview) }) {
            HStack(alignment: .top, spacing: 8) {
                Text(preview.previewText)
                    .font(.system(size: 17))
                    .foregroundColor(Theme.parchment.opacity(0.85))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                if isLoadingNotePreview {
                    ProgressView()
                        .tint(Theme.gold)
                        .padding(.top, 3)
                }
            }
            .padding(.top, 16)
            .padding(.leading, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoadingNotePreview)
        .accessibilityLabel("\(friendUsername)'s note preview. Tap to open note.")
    }

    private func headline(_ entry: FSFriendActivityEntry) -> String {
        let when = dayWord(entry.last_active_at)
        switch entry.activity_type {
        case FriendActivityType.created:
            return "\(entry.username) wrote a note \(when)"
        case FriendActivityType.edited:
            return "\(entry.username) edited a note \(when)"
        case FriendActivityType.replied:
            return "\(entry.username) replied to a note \(when)"
        case FriendActivityType.highlighted:
            return "\(entry.username) highlighted a verse \(when)"
        default:
            // nil (no tracked activity_type yet) or an unrecognized future
            // value this build doesn't know about -- same safe-generic-
            // fallback posture as the backend's own missing-type handling,
            // keyed off whether a note preview is present at all (matches
            // this headline's pre-Round-1 behavior exactly).
            return entry.note_preview != nil
                ? "\(entry.username) wrote a note \(when)"
                : "\(entry.username) was active \(when)"
        }
    }

    // Distinct read-only preview for a verse_highlighted entry (task
    // 20260904-friend-activity-push-triggers, Round 2): shown instead of
    // notePreviewRow when the headline friend's most recent activity is a
    // highlight. No tap action -- unlike notePreviewRow there's no "open
    // full note" equivalent in scope here, just a body snippet plus a
    // subtle attribution affordance for whose highlight it is, reusing
    // HighlightRow's existing color-circle + username-capsule visual
    // language (NotesListView.swift) rather than inventing a new pattern.
    private func highlightPreviewRow(_ preview: FSFriendHighlightPreview, friendUsername: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(hex: preview.color))
                .frame(width: 10, height: 10)
                .shadow(color: .black.opacity(0.30), radius: 2)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                // verse_text is nil on a backend bible-text lookup miss --
                // fall back to reference-only content rather than blanking
                // the row (same posture as the push body's own fallback).
                Text(preview.verse_text ?? "\(preview.book) \(preview.chapter):\(preview.verse)")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.parchment.opacity(0.85))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text("\(preview.book) \(preview.chapter):\(preview.verse)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.parchment.opacity(0.55))
                    Text(friendUsername)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Theme.gold.opacity(0.65))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.gold.opacity(0.10))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.top, 16)
        .padding(.leading, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(friendUsername) highlighted \(preview.book) \(preview.chapter):\(preview.verse)"
            + (preview.verse_text.map { ": \($0)" } ?? "") + "."
        )
    }

    private func dayWord(_ iso: String?) -> String {
        guard let d = parseActivityDate(iso) else { return "recently" }
        return activityDayLabel(d).lowercased()
    }
}

// Tile press feedback (design-spec.md States): scale to 0.96 on tap-down,
// ease back on release faster than it entered (0.18s in / 0.12s out, no
// spring/overshoot). Reduce Motion drops the scale transform entirely; the
// tap's resulting navigation still fires instantly.
private struct FriendTileButtonStyle: ButtonStyle {
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: configuration.isPressed ? 0.18 : 0.12), value: configuration.isPressed)
    }
}

// Task 20260906-friend-nudges: drives CheckInRow's send-action visuals below
// (idle/sending/sent/rateLimited/failed). Previously also shared with the
// friend-activity avatar row's own nudge control; that control (and its
// dedicated NudgeControlButtonStyle) was retired by task
// 20260907-dashboard-nudge-icon-cleanup -- CheckInRow is this enum's only
// remaining consumer.
enum NudgeUIState: Equatable {
    case idle
    case sending
    case sent
    case rateLimited
    case failed

    // Task 20260922-chat-friend-nudge-button: extracted so Dashboard's
    // CheckInRow and Chat's per-friend nudge control (ChatRootView.swift)
    // both derive their post-send display state from the exact same
    // NudgeResult mapping instead of each view model re-switching over
    // NudgeResult independently -- the intake spec's Architecture/
    // Implementation preference (Q3) defaults to abstracting logic that's
    // shared between the two rather than duplicating it. Only covers the
    // outcome states -- `.idle`/`.sending` stay driven directly by each call
    // site's own pre-send/mid-flight assignments, since those never come
    // from a NudgeResult.
    static func from(_ result: NudgeResult) -> NudgeUIState {
        switch result {
        case .sent:        return .sent
        case .rateLimited: return .rateLimited
        case .failed:      return .failed
        }
    }
}

// ── Check-in nudge row (flush, no container — matches `.checkin-row`) ──────────
struct CheckInRow: View {
    let checkIn: FSCheckInCandidate
    // Task 20260906-friend-nudges: owned by DashboardViewModel (mirrors
    // isLoadingNotePreview on FriendActivityHeroCard above -- external state,
    // not local @State, so a parent reload/re-pick can reset it) and driven
    // by the shared sendNudge/NudgeResult contract. `onTap` itself no longer
    // opens chat -- see the call site's comment for why.
    var nudgeState: NudgeUIState = .idle
    let onTap:   () -> Void

    private var badgeText: String {
        switch nudgeState {
        case .rateLimited: return "Already nudged recently"
        case .sent:         return "Nudge sent"
        default:
            guard let days = checkIn.days_since_contact else { return "Never messaged" }
            if days <= 0 { return "Talked today" }
            return days == 1 ? "It's been 1 day" : "It's been \(days) days"
        }
    }

    // Disabled once a send has actually landed somewhere (sent, or
    // rate-limited from this or an earlier attempt) -- re-tapping either
    // would just bounce off the same rate limit a moment later. Not
    // disabled while merely `.failed`, since that's the one outcome meant to
    // invite an immediate retry.
    private var isDisabled: Bool {
        switch nudgeState {
        case .sending, .sent, .rateLimited: return true
        case .idle, .failed:                return false
        }
    }

    // Task 20260907-dashboard-nudge-icon-cleanup: swapped from
    // "paperplane.fill" (reads as "send a message," which this action no
    // longer does -- it nudges, per task 20260906-friend-nudges) to
    // "bell.fill", a minimalistic, deliberately-filled glyph that keeps the
    // same weight/fill-style language as this row's other icon states
    // (the "checkmark" below, and the avatar row's own now-retired
    // "bell.and.waves.left.and.right.fill" nudge glyph).
    private var iconName: String {
        switch nudgeState {
        case .sent, .rateLimited: return "checkmark"
        default:                  return "checkmark"
        }
    }

    private var accessibilityText: String {
        switch nudgeState {
        case .sent, .rateLimited: return "Nudge sent to \(checkIn.username)"
        default:                  return "Check in with \(checkIn.username)"
        }
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
                            .overlay(
                                Group {
                                    if nudgeState == .sending {
                                        ProgressView().tint(Theme.goldLight)
                                    } else if nudgeState == .sent || nudgeState == .rateLimited {
                                        Image(systemName: iconName)
                                            .font(.system(size: 17))
                                            .foregroundColor(Theme.goldLight)
                                    } else {
                                        KnockGlyph(size: 40)
                                            .accessibilityHidden(true)
                                    }
                                }
                            )
                    )
                    // A quick, transient tint pulse on a failed send -- same
                    // "that didn't land, try again" language as the sibling
                    // /design task's tile-control error state -- rather than
                    // a toast/alert for a low-stakes social action.
                    .overlay(
                        Circle().fill(Theme.error.opacity(nudgeState == .failed ? 0.4 : 0))
                    )
                    .animation(.easeOut(duration: 0.3), value: nudgeState)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(accessibilityText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 2)
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


// ── Knock glyph ─────────────────────────────────────────────────────────────────
// SQUIDWARD's gold "Knock" nudge icon (design 20261013-fellowscript-checkin-
// button-icon-concepts, revision-knock-gold), drawn natively in a 96-unit
// space so it stays crisp at every size and needs no asset-format workaround
// for the original SVG's gradients/blur. `flat: true` is the bare-button
// variant (single `flatColor` silhouette, no glow/highlight/ticks tint), so
// callers can drive the failed-state tint through `flatColor` exactly like
// the old SF Symbol's foregroundColor. Dark-ground colors only: both current
// nudge sites sit on dark surfaces, so the light-ground deeper-gold variant
// is intentionally not shipped.
struct KnockGlyph: View {
    let size: CGFloat
    var flat: Bool = false
    var flatColor: Color = Theme.goldLight

    var body: some View {
        let u = size / 96
        let pillW = 36 * u, pillH = 68 * u
        ZStack(alignment: .topLeading) {
            if !flat {
                RoundedRectangle(cornerRadius: 18 * u)
                    .fill(Color(hex: "#EDAB3C"))
                    .frame(width: pillW, height: pillH)
                    .blur(radius: 9 * u)
                    .opacity(0.15)
                    .offset(x: 24 * u, y: 14 * u)
            }
            // Highlight circle (centre (58,38) r12) pokes out past the pill's
            // right edge (x=60): a translucent copy sits behind the pill so the
            // overhang is see-through over the background, per the design SVG.
            Circle()
                .fill(flat
                    ? AnyShapeStyle(flatColor.opacity(0.6))
                    : AnyShapeStyle(LinearGradient(
                        colors: [Color(hex: "#F0AE40"), Color(hex: "#B07820")],
                        startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.6)))
                .frame(width: 24 * u, height: 24 * u)
                .offset(x: 46 * u, y: 26 * u)
            // Pill with the highlight circle clipped to it (circle centre
            // (58,38) r12 in the 96-unit space, i.e. local (34,24) in the pill).
            ZStack(alignment: .topLeading) {
                Rectangle().fill(flat
                    ? AnyShapeStyle(flatColor)
                    : AnyShapeStyle(LinearGradient(
                        colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .opacity(flat ? 1 : 0.88)
                Circle()
                    .fill(flat ? Color.white.opacity(0.28) : Color(hex: "#F5C060").opacity(0.9))
                    .frame(width: 24 * u, height: 24 * u)
                    .offset(x: 22 * u, y: 12 * u)
            }
            .frame(width: pillW, height: pillH, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 18 * u))
            .offset(x: 24 * u, y: 14 * u)
            KnockTicks()
                .stroke(flat ? flatColor : Color(hex: "#F5EAD0").opacity(0.9),
                        style: StrokeStyle(lineWidth: 3 * u, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }
}

private struct KnockTicks: Shape {
    func path(in rect: CGRect) -> Path {
        let u = rect.width / 96
        var p = Path()
        p.move(to: CGPoint(x: 62 * u, y: 22 * u)); p.addLine(to: CGPoint(x: 64 * u, y: 16 * u))
        p.move(to: CGPoint(x: 70 * u, y: 26 * u)); p.addLine(to: CGPoint(x: 74 * u, y: 21 * u))
        return p
    }
}
