// GroupAnnouncementDetailView.swift — read-only viewer for one announcement
// (task 20260929-group-announcements). Top-right "Edit" (and a Delete menu, the
// accessible alternative to swipe) only for users the server marked `can_edit`.

import SwiftUI

struct GroupAnnouncementDetailView: View {
    let item: FSGroupAnnouncement
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    if let s = item.banner_url, let url = URL(string: s) {
                        Color.white.opacity(0.06)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .overlay {
                                AsyncImage(url: url) { phase in
                                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                            .accessibilityHidden(true)
                    }
                    if !item.published {
                        Text("Scheduled for \(FSAnnouncementDates.display(item.publish_at))")
                            .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Theme.gold.opacity(0.12)).clipShape(Capsule())
                    }
                    Text(item.title)
                        .font(.inter(Theme.fontHeading, weight: .semibold)).foregroundColor(Theme.parchment)
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
                    Menu {
                        Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundColor(Theme.gold).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("More actions")
                    Button("Edit", action: onEdit)
                        .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold)
                }
            }
        }
    }
}
