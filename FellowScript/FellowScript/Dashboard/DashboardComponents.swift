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
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(hex: "#2A1B0B").opacity(0.20))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color(hex: "#D4922A").opacity(0.12)],
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

// ── Group activity widget (reuses CommunityActivityItem) ───────────────────────
struct GroupActivityWidget: View {
    let items: [CommunityActivityItem]
    let onTapItem: (CommunityActivityItem) -> Void
    let onContinueReading: (() -> Void)?   // nil → no saved reading position yet

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Group activity")

            if items.isEmpty {
                Text("No recent activity yet. Add friends or join a group to see it here.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15))
                            .foregroundColor(Theme.gold.opacity(0.65))
                            .frame(width: 26, height: 26)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(Theme.parchment)
                                .lineLimit(1)
                            Text(item.preview.isEmpty ? "—" : item.preview)
                                .font(.system(size: 11.5))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(item.timeLabel)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onTapItem(item) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.name): \(item.preview), \(item.timeLabel). Tap to open.")
                    .accessibilityAddTraits(item.contact != nil ? .isButton : [])
                }
            }

            if let onContinueReading {
                Button(action: onContinueReading) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Continue reading").font(.system(size: 14.5, weight: .heavy))
                            Text("where you left off").font(.system(size: 11.5))
                        }
                        .foregroundColor(Color(hex: "#24170A"))
                        Spacer()
                        Circle().fill(Color(hex: "#24170A")).frame(width: 38, height: 38)
                            .overlay(Image(systemName: "arrow.right").foregroundColor(Color(hex: "#F0AE40")))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(LinearGradient(colors: [Theme.gold, Color(hex: "#EDAB3C")],
                                               startPoint: .leading, endPoint: .trailing))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .glassCard(cornerRadius: 20)
        .padding(.horizontal, 20)
    }
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
