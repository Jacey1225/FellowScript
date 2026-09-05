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
    // Task 20260905-profile-photo: the viewer's own photo -- defaulted nil
    // so any pre-existing preview/test call site that only supplies
    // `username` keeps compiling and rendering the initials-only avatar
    // unchanged.
    var photoURL: String? = nil

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    var body: some View {
        // Text only — the backdrop is provided by DashboardView so it can
        // fade smoothly past this header rather than ending on a hard edge.
        //
        // Task 20260901-dashboard-background-consistency: this greeting text
        // used to be a dark ink (#2A1B0B), which relied on the bespoke,
        // strong top-anchored linear "hero" gradient's bright warm fill for
        // contrast. That gradient is gone (replaced with the same subtle
        // two-RadialGradient bloom over Theme.bgPage every other screen
        // uses), so dark-on-dark here would fail WCAG AA. Per the spec's
        // explicit allowance ("adjust text color/weight only if needed to
        // preserve [legibility], without reintroducing a bespoke background
        // treatment"), swapping to Theme.parchment — the same token every
        // other headline sitting directly on this exact bgPage+bloom
        // background already uses (AccountView's profile name,
        // FriendActivityHeroCard's activity headline, NoteResumeCard's
        // title) — restores contrast (>14:1 against bare bgPage, >10:1 at
        // the bloom's brightest point) without inventing a new treatment.
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(greeting), \(username)")
                    .font(.system(size: 27, weight: .heavy))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(2)
            }
            Spacer()
            // Identity avatar (decorative — not a control, so no dead button).
            AvatarView(
                initial:   String(username.prefix(1)).uppercased(),
                photoURL:  photoURL,
                diameter:  44,
                fillColor: Color(hex: "#2A1B0B"),
                textColor: Color(hex: "#F0AE40")
            )
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
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
                    AvatarView(initial: f.initial, photoURL: f.profile_photo_url, diameter: 28)
                        .overlay(Circle().stroke(Theme.bgPage, lineWidth: 2))
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
            .padding(.top, 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.username): \(headline(entry)). Tap to open chat.")
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
                Text(preview.text)
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

// ── Continue circle button geometry (superseded pill/chamfer/notch system) ────
// Task 20260828-continue-button-circle-implementation replaced the "Continue"
// island's pill/chamfer silhouette and the card's matching bottom-right notch
// with a plain circular icon button (design-spec.md's Option 2, in
// .claude/design/20260828-continue-button-circle-icon-options/): the card
// always uses the plain `glassCard(cornerRadius:)` overload (no notch), and
// the button's own silhouette is a plain `Circle()` (no chamfer). The entire
// depth-off-the-arc chamfer/notch geometry system this section used to hold
// (`chamferEdgeIntersections`, `chamferGeometryIsValid`,
// `chamferTreatmentFitsIslandRadius`, `ContinueIslandShape`,
// `NoteResumeCardNotch`, `NoteResumeCardShape`, `NotchedCardMaterial`) was
// removed along with it — confirmed via repo-wide grep that nothing besides
// this file and its own test file ever referenced any of it. See
// NoteResumeCard's `continueCircleButton`/`rimGradient` below for the new
// construction.

/// Press-state styling for the "Continue" circular button (design-spec.md's
/// Option 2, carried unchanged from the retired pill/island's own press
/// state): scale to 0.96 with a one-step fill darkening, 150ms ease-out.
/// Reduce Motion drops the scale transform entirely and substitutes a brief
/// opacity dip alongside the same darkening. Name kept as-is even though the
/// "island" it originally styled is gone — this is still the one shared
/// `ButtonStyle` for the Continue affordance, and renaming it is out of
/// scope for a pure visual-construction swap.
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
// that empty state keeps its original pill exactly as-is: the circular
// Continue-button treatment only ever applies to the populated
// (`note != nil`) branch.
struct NoteResumeCard: View {
    let note:   FSNote?
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Task 20260828-continue-button-circle-implementation: sizing is now
    // @ScaledMetric-driven, not the old labelSize-measurement-driven
    // approach (the "Continue" text label this used to measure is gone —
    // the new button is icon-only). `@ScaledMetric(relativeTo: .subheadline)`
    // scales the 52pt base value by the same Dynamic-Type text style the old
    // island's own label used, so this stays behaviorally consistent with
    // the prior sizing's growth curve without needing a live label
    // measurement. `resolvedDiameter` below clamps the scaled result to
    // design-spec.md's locked 52...72 range.
    @ScaledMetric(relativeTo: .subheadline) private var diameter: CGFloat = 52

    // Live-measured card width, kept only as a verification/regression hook
    // now that there is no §4 fallback state to switch into: design-spec.md
    // states that the clamped 52...72 diameter can never exceed 45% of card
    // width at any accessibility text size, retiring the old fallback
    // capsule entirely (open question 3 in intake-spec.md). This still
    // measures the real card width live (mirroring the prior `cardWidth`/
    // `didAppear` convention) so a regression test can pin
    // `resolvedDiameter <= 0.45 * cardWidth` against the actually-laid-out
    // view rather than taking the claim on faith — it no longer drives any
    // rendering branch itself.
    // Not `private` -- read directly by NoteResumeCardContinueIslandTests via
    // the `didAppear` hook below (mirrors NoteDetailView's `showEditor`/
    // `didAppear` convention in NotesListView.swift).
    @State var cardWidth: CGFloat = 0

    // Testing-only hook (default nil, zero runtime cost otherwise) — see
    // NoteDetailView's identical pattern in NotesListView.swift.
    internal var didAppear: ((Self) -> Void)?

    // ── design-spec.md tokens (component-internal) ──────────────────────────
    private let gutter: CGFloat           = 12
    private let cardCornerRadius: CGFloat = 20   // unchanged from the existing card

    // design-spec.md's locked clamp: the @ScaledMetric-scaled diameter can
    // grow past 72pt at the largest accessibility categories; clamping here
    // keeps the button within the approved 52...72 range at every size.
    //
    // Not `private` -- read directly by NoteResumeCardContinueIslandTests via
    // the `didAppear` hook, mirroring `cardWidth`'s identical testability
    // convention above: ViewInspector has no support for @ScaledMetric (it
    // can't thread a `.environment(\.sizeCategory, ...)` override through
    // that property wrapper without a real host), so the regression sweep
    // proving this clamps to 52...72 and never exceeds 45% of the live
    // `cardWidth` reads this off the actual, live-hosted view instead.
    var resolvedDiameter: CGFloat {
        min(max(diameter, 52), 72)
    }
    // Icon size is a fixed 38% of the *resolved* (post-clamp,
    // post-@ScaledMetric) diameter, not a static 20pt -- 20pt is simply what
    // 38%-of-52 evaluates to at the default size.
    private var iconSize: CGFloat { resolvedDiameter * 0.38 }

    // Overhang/placement (unchanged mechanic, re-derived from diameter
    // instead of island height): trailing edge of the circle flush with the
    // card's trailing edge; 42% of the diameter sits above the card's bottom
    // edge, 58% overhangs below it.
    private var derivedBottomPadding: CGFloat {
        ((0.42 * resolvedDiameter + gutter + 4) / 4).rounded(.up) * 4
    }
    private var belowCardReserve: CGFloat { 0.58 * resolvedDiameter }

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

    // MARK: - Populated state — the circular "Continue" button

    @ViewBuilder
    private func populatedCard(_ note: FSNote) -> some View {
        VStack(spacing: 0) {
            cardBody(note)
                .overlay(alignment: .bottomTrailing) {
                    // Bottom-trailing-aligned to the card's own frame, then
                    // shifted down by 58% of the circle's diameter — the
                    // circle's trailing edge lands flush with the card's
                    // trailing edge (both share the same outer 20pt margin
                    // below), and its top/bottom edges land exactly at
                    // `cardBottomY − 0.42×diameter` /
                    // `cardBottomY + 0.58×diameter` as specified.
                    continueCircleButton.offset(y: belowCardReserve)
                }
            // Reserve the overhang as real layout space in this component's
            // own container (rather than assuming the parent stack's
            // incidental spacing covers it). Verified against the live view
            // hierarchy (ContentView → TabView → DashboardView's
            // ScrollView/LazyVStack → this card): none of those ancestors
            // clip, and the ScrollView/LazyVStack's existing 150pt bottom
            // padding for the floating tab bar comfortably clears the
            // ≥16pt button-to-tab-bar gap on top of this reservation.
            Color.clear.frame(height: belowCardReserve)
        }
        .padding(.horizontal, 20)
        // Testing-only: see the `didAppear`/`cardWidth` comments above.
        .onAppear { didAppear?(self) }
        .onChange(of: cardWidth) { _, _ in didAppear?(self) }
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
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, derivedBottomPadding)
        // Card join: plain overlap, no notch (design-spec.md's Option 2,
        // generation.json's "THE NOTCH" fix) -- always the plain
        // `glassCard(cornerRadius:)` overload, matching variants 1/2/3/3b's
        // construction from the design pass, never the retired
        // `glassCard(shape:)` notch-cutting overloads.
        .glassCard(cornerRadius: cardCornerRadius, tint: Color(hex: "#2A1B0B").opacity(0.14), blurBoost: 4)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { cardWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in cardWidth = new }
            }
        )
    }

    // The gold arc rim (design-spec.md's Option 2, the one rim exception to
    // the standard #F5D392@0.35 top-fade rim every other option uses):
    // `#FBE8C0 @ 0.8`, 2pt, drawn `.strokeBorder` so the stroke sits fully
    // inside the circle's own silhouette (never bleeding past the fill
    // edge — a fix generation.json's own pass made after the first
    // `.stroke()` attempt bled outside it).
    //
    // SwiftUI's `AngularGradient` places its 0° stop at the circle's
    // 3-o'clock (right), sweeping clockwise -- NOT 0°-at-top as a naive
    // reading might assume. The generation pass's own disclosed false start
    // got this wrong on the first attempt (assumed 0°-at-top, rendered a
    // band centered on the right instead) and had to shift every stop by
    // −90° to actually center the bright band on top; top is therefore 270°
    // in AngularGradient's own coordinate system. The window must read as
    // full bright ±45° from top, fading to clear by ±70° (a ~25° ramp at
    // each end) -- so the stop locations below are 270° ± {45, 70},
    // expressed as `location = degrees / 360` across an explicit 0°...360°
    // sweep.
    private var rimGradient: AngularGradient {
        let rimColor = Color(hex: "#FBE8C0").opacity(0.8)
        return AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 200.0 / 360.0),    // 270 - 70
                .init(color: rimColor, location: 225.0 / 360.0),  // 270 - 45
                .init(color: rimColor, location: 315.0 / 360.0),  // 270 + 45
                .init(color: .clear, location: 340.0 / 360.0),    // 270 + 70
                .init(color: .clear, location: 1.0),
            ]),
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)
        )
    }

    // The circular "Continue" button itself (design-spec.md's Option 2).
    private var continueCircleButton: some View {
        Button(action: onOpen) {
            Circle()
                .fill(
                    // Direction is `.topLeading → .bottomTrailing` (a
                    // deliberate change from the pill's horizontal
                    // `.leading → .trailing`), so the light direction agrees
                    // with the top rim highlight and the downward ambient
                    // shadow.
                    LinearGradient(colors: [Color(hex: "#EEAC3F"), Color(hex: "#C88C2C")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: resolvedDiameter, height: resolvedDiameter)
                .overlay(
                    Image(systemName: "chevron.right")
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundColor(Color(hex: "#24170A"))
                        // Optical offset: -1pt on the x-axis, nudging the
                        // glyph toward the circle's leading edge.
                        .offset(x: -1)
                )
                .overlay(
                    Circle().strokeBorder(rimGradient, lineWidth: 2)
                )
                // Shadow stack (unchanged from the pill, all three layers,
                // same values): separation (zero-offset, carves the gutter —
                // blur tied to `gutter + 2pt`), ambient, and contact.
                .shadow(color: .black.opacity(0.40), radius: gutter + 2, x: 0, y: 0)
                .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 4)
                .shadow(color: .black.opacity(0.40), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(ContinueIslandButtonStyle(reduceMotion: reduceMotion))
        // Hit target: always ≥ 44×44pt regardless of the 52-72pt visual
        // diameter (the clamp floor of 52pt already clears 44pt, but this
        // must still be explicit -- hit-testing must not be limited to the
        // visually-reduced silhouette, matching the pill's own
        // `.contentShape` convention for the same reason).
        .contentShape(Circle())
        .accessibilityLabel("Continue reading \(noteTitle)")
    }

    // MARK: - Empty state (`note == nil`)
    //
    // Unchanged, pixel-for-pixel, per design step 1's decision
    // (design-notes.md) and this task's own explicit scope (design-spec.md's
    // "Empty-state reconciliation" note): the populated state's new
    // light-fill/dark-glyph circular button is a stated intentional
    // distinction from this branch's dark-fill/light-glyph look, not an
    // inconsistency to fix. This branch is exactly the original
    // implementation, preserved so `NoteResumeCardTests`'s existing
    // empty-state assertions keep passing.
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
