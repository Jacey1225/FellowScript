// GroupInfoAnnouncementsList.swift -- task 20261023-group-info-row. Read-only
// announcement cards (newest first) for the group info submenu. Reuses
// GroupAnnouncementsViewModel (cache first, preserve-cache-on-failed-refresh).

import SwiftUI

/// Pure ordering/formatting for the cards.
enum GroupInfoAnnouncementsPolicy {
    /// Published items only, newest publish time first. Unparseable dates sort last.
    static func ordered(_ items: [FSGroupAnnouncement]) -> [FSGroupAnnouncement] {
        items.filter { $0.published }.sorted { a, b in
            let da = FSAnnouncementDates.parse(a.publish_at), db = FSAnnouncementDates.parse(b.publish_at)
            switch (da, db) {
            case let (x?, y?): return x > y
            case (_?, nil):    return true
            default:           return false
            }
        }
    }
}

struct GroupInfoAnnouncementsList: View {
    @ObservedObject var vm: GroupAnnouncementsViewModel
    let groupName: String
    let onSelect: (FSGroupAnnouncement) -> Void

    private var shown: [FSGroupAnnouncement] { GroupInfoAnnouncementsPolicy.ordered(vm.items) }

    var body: some View {
        Group {
            if !vm.loaded {
                if vm.loadError != nil {
                    GroupInfoErrorView(category: .announcements) { Task { await vm.load() } }
                } else {
                    GroupInfoLoadingView(category: .announcements)
                }
            } else if shown.isEmpty {
                GroupInfoEmptyView(category: .announcements)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if vm.refreshFailed { GroupInfoRefreshNote { Task { await vm.load() } } }
                        ForEach(shown) { item in card(item) }
                    }
                    .padding(Theme.spacingMD)
                }
            }
        }
        .task { await vm.load() }
    }

    private func card(_ item: FSGroupAnnouncement) -> some View {
        Button { onSelect(item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let s = item.banner_url, let url = URL(string: s) {
                    // Optional banner: 16:9 top crop inside the card.
                    Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                            }
                            .accessibilityHidden(true)
                        }
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(groupName)
                        .font(.inter(13, weight: .semibold)).foregroundColor(Theme.gold)
                        .lineLimit(1)
                    Text(item.title)
                        .font(.inter(17, weight: .bold)).foregroundColor(Theme.parchment)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    let date = FSAnnouncementDates.display(item.publish_at)
                    if !date.isEmpty {
                        Text(date).font(.inter(13)).foregroundColor(Theme.parchment.opacity(0.55))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.parchment.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.parchment.opacity(0.14), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the announcement")
        .accessibilityAddTraits(.isButton)
    }
}
