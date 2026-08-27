// DashboardComponents.swift
// Subviews for the redesigned Dashboard (DashboardView.swift). Each takes only
// real model data; design-specific gradient colors are inline hex, content
// colors use Theme tokens. No fabricated data — callers hide a card when its
// source is empty.
//
// SOURCE MAPPING: reference DashboardRedesign.swift, Theme/Theme.swift

import SwiftUI

// ── View-model structs (dashboard-only, not domain models) ────────────────────
struct GroupSummary: Identifiable {
    let id:             String
    let title:          String
    let subtitle:       String
    let memberInitials: [String]
}

struct QuickAction: Identifiable {
    let id = UUID()
    let label:  String
    let symbol: String
    let tint:   Color
    let run:    () -> Void
}

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
}

// ── Hero header + warm gradient ───────────────────────────────────────────────
struct HeroHeader: View {
    let username: String
    let subtitle: String

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
                Text("YOUR RHYTHM")
                    .font(.system(size: 10, weight: .semibold)).tracking(4)
                    .foregroundColor(Color(hex: "#1E140A").opacity(0.66))
                Text("\(greeting), \(username)")
                    .font(.system(size: 27, weight: .heavy))
                    .foregroundColor(Color(hex: "#2A1B0B"))
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13.5))
                        .foregroundColor(Color(hex: "#26190C").opacity(0.78))
                }
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

// ── Revisit a Verse card (reauthored "insight" card) ──────────────────────────
// Shows one of the user's own highlights/bookmarks. The dashboard doesn't load
// Bible text, so we show the reference + a "tap to open" affordance rather than
// fabricate verse copy. Tapping opens it in the reader.
struct RevisitVerseCard: View {
    let verse: FSHighlight
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                Text("REVISIT A VERSE")
                    .font(.system(size: 10, weight: .semibold)).tracking(3)
                    .foregroundColor(Color(hex: "#241708").opacity(0.66))

                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: verse.color))
                        .frame(width: 4, height: 30)
                    Text("\(verse.book) \(verse.chapter):\(verse.verse)")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(Color(hex: "#24170A"))
                }

                HStack(spacing: 6) {
                    Text("Open in the reader")
                        .font(.system(size: 13, weight: .bold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(Color(hex: "#24170A").opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                LinearGradient(colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Revisit \(verse.book) \(verse.chapter):\(verse.verse). Opens in the reader.")
    }
}

// ── Friend Activity hero card ("Editorial Hero" mockup) ────────────────────────
// Ports `.hero-card` from friend-activity-dashboard-revised.html: an avatar
// stack of active friends, the most-recently-active friend's headline +
// timestamp (tap → open their chat), and (if they have one) a preview of
// their most recent public note. Superseding GroupActivityWidget — this is
// the community/friend-activity emphasis the redesign is built around; the
// "Continue reading" affordance it used to carry lives on in QuickActionsRow's
// existing "Read" action, unchanged.
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
            sectionLabel("Friend activity")
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

// ── Note-resume card (ports `.glass-card.standard.note-card`) ──────────────────
// Adapts the existing "continue reading" affordance to the redesign's
// note-resume concept: the user's own most recent note (`vm.recentNote`), not
// a friend's. `note == nil` (no notes written yet) renders a defined empty
// state that opens a fresh note instead of silently vanishing.
struct NoteResumeCard: View {
    let note:   FSNote?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Pick up where you left off")
                if let note {
                    Text(note.title.isEmpty ? "Untitled note" : note.title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(Theme.parchment)
                        .lineLimit(2)
                        .padding(.top, 6)
                    Text(note.preview)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.parchment.opacity(0.70))
                        .lineLimit(3)
                        .padding(.top, 2)
                } else {
                    Text("You haven't written a note yet.")
                        .font(.system(size: 14.5))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.top, 6)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(note == nil ? "Start a note" : "Open note").font(.system(size: 14.5, weight: .heavy))
                        Text(note == nil ? "capture a reflection" : "where you left off").font(.system(size: 11.5, weight: .medium))
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
        .accessibilityLabel(note.map { "Resume note: \($0.title)" } ?? "Start a new note")
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

// ── Bookmarks widget ──────────────────────────────────────────────────────────
struct BookmarksWidget: View {
    let bookmarks: [FSBookmark]
    let onTap: (FSBookmark) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Bookmarks")
            ForEach(Array(bookmarks.prefix(4).enumerated()), id: \.element.id) { idx, mark in
                if idx > 0 { Divider().background(Theme.borderGoldFaint) }
                Button(action: { onTap(mark) }) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10).fill(Theme.gold.opacity(0.14))
                            .frame(width: 34, height: 34)
                            .overlay(Image(systemName: "bookmark.fill").font(.system(size: 14)).foregroundColor(Theme.goldLight))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(mark.book) \(mark.chapter)")
                                .font(.system(size: 13.5, weight: .bold)).foregroundColor(Theme.parchment)
                            if !mark.label.isEmpty {
                                Text(mark.label).font(.system(size: 11.5)).foregroundColor(Theme.textSecondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textMuted)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassCard(cornerRadius: 20)
        .padding(.horizontal, 20)
    }
}

// ── Compact stat cards ────────────────────────────────────────────────────────
struct NotesSparklineCard: View {
    let counts: [Int]   // 7 chronological daily counts
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes this week").font(.system(size: 11.5)).foregroundColor(Theme.textSecondary)
            Text("\(counts.reduce(0, +))").font(.system(size: 28, weight: .heavy)).foregroundColor(Theme.parchment)
            HStack(alignment: .bottom, spacing: 5) {
                let maxVal = max(counts.max() ?? 1, 1)
                ForEach(Array(counts.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(v == maxVal && v > 0 ? Theme.goldLight : Theme.parchment.opacity(0.16))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, 40 * CGFloat(v) / CGFloat(maxVal)))
                }
            }
            .frame(height: 40, alignment: .bottom)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .glassCard(cornerRadius: 20)
    }
}

struct HighlightsCountCard: View {
    let highlights: [FSHighlight]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Highlights added").font(.system(size: 11.5)).foregroundColor(Theme.textSecondary)
            Text("\(highlights.count)").font(.system(size: 28, weight: .heavy)).foregroundColor(Theme.parchment)
            HStack(spacing: 5) {
                ForEach(highlights.prefix(7)) { h in
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: h.color)).frame(width: 14, height: 14)
                }
            }
            .frame(height: 14, alignment: .leading)
            .padding(.top, 14)
            if let latest = highlights.last {
                Text("Latest: \(latest.book) \(latest.chapter):\(latest.verse)")
                    .font(.system(size: 11)).foregroundColor(Theme.textMuted).lineLimit(1).padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .glassCard(cornerRadius: 20)
    }
}

// ── My Groups row ─────────────────────────────────────────────────────────────
struct MyGroupsRow: View {
    let groups: [GroupSummary]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My groups").font(.system(size: 16, weight: .heavy)).foregroundColor(Theme.parchment)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(g.title).font(.system(size: 15, weight: .heavy)).foregroundColor(Theme.parchment).lineLimit(1)
                            Text(g.subtitle).font(.system(size: 11.5)).foregroundColor(Theme.textSecondary)
                            HStack(spacing: -9) {
                                ForEach(Array(g.memberInitials.prefix(3).enumerated()), id: \.offset) { i, initial in
                                    Circle().fill(i == 0 ? Theme.gold : Theme.cardBg)
                                        .frame(width: 28, height: 28)
                                        .overlay(Circle().stroke(Theme.bgPage, lineWidth: 2))
                                        .overlay(Text(initial).font(.system(size: 11, weight: .heavy))
                                            .foregroundColor(i == 0 ? Color(hex: "#24170A") : Theme.parchment))
                                }
                            }
                        }
                        .padding(15)
                        .frame(width: 172, alignment: .leading)
                        .glassCard(cornerRadius: 18)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

// ── Quick actions ─────────────────────────────────────────────────────────────
struct QuickActionsRow: View {
    let actions: [QuickAction]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(actions) { a in
                Button(action: a.run) {
                    VStack(spacing: 8) {
                        Circle().fill(a.tint.opacity(0.16)).frame(width: 40, height: 40)
                            .overlay(Image(systemName: a.symbol).foregroundColor(a.tint))
                        Text(a.label).font(.system(size: 11, weight: .bold)).foregroundColor(Theme.parchment.opacity(0.82))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .glassCard(cornerRadius: 18)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }
}
