// GroupAnnouncementDetailView.swift — read-only viewer for one announcement
// (task 20260929-group-announcements). Top-right "Edit" only for users the
// server marked `can_edit`. Delete is list-swipe only (onDelete kept for callers).

import SwiftUI

struct GroupAnnouncementDetailView: View {
    let item: FSGroupAnnouncement
    var onEdit: () -> Void
    var onDelete: () -> Void
    /// Part E: join (true) / leave (false) the RSVP. Nil = no RSVP action (count only).
    var onRSVP: ((Bool) async throws -> FSGroupAnnouncement)? = nil
    /// Poll voting (flag announcement_polls). Nil = results only.
    var pollActions: AnnouncementPollActions? = nil

    @EnvironmentObject private var appState: AppState
    @State private var sharePayload: SharePayload?
    @State private var sharing: SharePayload?

    private var theme: AnnouncementBgTheme { AnnouncementBgTheme.resolve(item.bg_theme) }

    var body: some View {
        ZStack(alignment: .top) {
            // Part D: the theme fills the page; the banner fades into it at the bottom.
            if theme != .none { theme.fill.ignoresSafeArea().accessibilityHidden(true) }
            if let s = item.banner_url, let url = URL(string: s) {
                bannerBackground(url)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    if item.banner_url.flatMap(URL.init(string:)) != nil {
                        Color.clear.frame(height: Self.bannerHeight * 0.45)
                    }
                    if !item.published {
                        Text("Scheduled for \(FSAnnouncementDates.display(item.publish_at))")
                            .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Theme.gold.opacity(0.12)).clipShape(Capsule())
                    }
                    Text(item.title)
                        .font(AnnouncementTitleFont.resolve(item.title_font).font(Theme.fontHeading, relativeTo: .title2))
                        .foregroundColor(AnnouncementTitleColor.surfaceColor(item.title_color, fallback: theme.readableText, surfaceHex: theme.surfaceHex))
                        .accessibilityAddTraits(.isHeader)
                    Text("By \(item.creator_username ?? "a member"), \(FSAnnouncementDates.display(item.publish_at))")
                        .font(.inter(Theme.fontXS)).foregroundColor(theme.readableText.opacity(theme == .none ? 0.6 : 0.75))
                    AnnouncementRepeatIndicator(item: item, color: theme.readableText.opacity(theme == .none ? 0.75 : 0.85), font: .inter(Theme.fontXS))
                    Text(item.description)
                        .font(.inter(Theme.fontSM)).foregroundColor(theme.readableText.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    AnnouncementExtrasDetail(item: item, textColor: theme.readableText, onRSVP: onRSVP, pollActions: pollActions)
                        .padding(.top, Theme.spacingSM)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.spacingMD)
            }
        }
        .background { if theme == .none { Color.clear.warmBloomBackground() } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .shareSheet(item: $sharing)
        .task(id: "\(item.id)|\(item.published)|\(item.title)|\(item.publish_at)") {
            sharePayload = nil
            sharePayload = await AnnouncementShare.payload(for: item, appState: appState)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Task 20261011-ios-share-notes-highlights: group name + title + date +
                // a request-to-join link. Hidden unless the group has a published
                // Explorer listing (never falls back to a group invite link).
                if let payload = sharePayload {
                    Button { sharing = payload } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.gold)
                            .frame(minWidth: 60, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Share announcement \(item.title)")
                    .accessibilityHint("Shares the group name, title, date and a link to ask to join.")
                }
                if item.can_edit {
                    // Same minimum width as the share button so each half of the glass
                    // pill centers its content (a bare text label sat off-center).
                    Button(action: onEdit) {
                        Text("Edit")
                            .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold)
                            .frame(minWidth: 60, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    /// Legacy plain-text body (title, date, location). No longer used by the Share
    /// button, which now goes through SharePayloads.announcement (never includes
    /// the location). Kept for its existing unit tests.
    static func shareText(for item: FSGroupAnnouncement) -> String {
        var lines = [item.title]
        let when = FSAnnouncementDates.display(item.publish_at)
        if !when.isEmpty { lines.append(item.published ? when : "Scheduled for \(when)") }
        let place = (item.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty { lines.append(place) }
        return lines.joined(separator: "\n")
    }

    private static let bannerHeight: CGFloat = 380

    /// Full-bleed decorative banner behind the page, extended under the nav bar,
    /// faded out at the bottom so no edge shows; a light scrim keeps text legible.
    private func bannerBackground(_ url: URL) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.bannerHeight)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            }
            .clipped()
            .overlay(Color.black.opacity(0.25))
            .mask(
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.45),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .ignoresSafeArea(edges: .top)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
