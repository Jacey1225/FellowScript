// GroupAnnouncementDetailView.swift — read-only viewer for one announcement
// (task 20260929-group-announcements). Top-right "Edit" only for users the
// server marked `can_edit`. Delete is list-swipe only (onDelete kept for callers).

import SwiftUI

struct GroupAnnouncementDetailView: View {
    let item: FSGroupAnnouncement
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
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
                        .font(.inter(Theme.fontHeading, weight: .semibold))
                        .foregroundColor(AnnouncementTitleColor.surfaceColor(item.title_color, fallback: Theme.parchment))
                        .accessibilityAddTraits(.isHeader)
                    Text("By \(item.creator_username ?? "a member"), \(FSAnnouncementDates.display(item.publish_at))")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
                    Text(item.description)
                        .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.spacingMD)
            }
        }
        .warmBloomBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if item.can_edit {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Edit", action: onEdit)
                        .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold)
                }
            }
        }
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
