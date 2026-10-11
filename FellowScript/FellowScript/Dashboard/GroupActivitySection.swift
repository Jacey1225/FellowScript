// GroupActivitySection.swift -- Home "Group activity" row (task
// 20261011-home-group-activity-announcements). Replaces the latest-note resume
// card. A horizontally scrolling row of the most recently published
// announcements across the user's groups, newest first (capped). There is no
// event start date in the data model, so "upcoming" is defined as most recent
// published (user-confirmed; see architecture.json). Reuses the per-group
// GroupAnnouncementsService.fetchAnnouncements; no backend change.
//
// Failure behavior (throw-not-fabricate, preserve-cache-on-failed-refresh): a
// group whose fetch throws (flag off, 404, offline) keeps its previously cached
// cards and never gets invented ones; a refresh where every fetch fails keeps
// the whole cache. Cached cards for groups the user no longer has are dropped.
// With nothing to show and no successful fetch, the section hides quietly.

import SwiftUI
import Combine

// ── Pure logic (unit-testable) ───────────────────────────────────────────────

struct GroupActivityItem: Codable, Equatable, Identifiable {
    let groupId:      String
    let groupName:    String
    let announcement: FSGroupAnnouncement
    var id: String { "\(groupId):\(announcement.id)" }
}

enum GroupActivity {
    /// Max cards in the row.
    static let maxItems = 10
    /// Max announcements taken from any single group, so one busy group cannot
    /// crowd out the rest.
    static let perGroupLimit = 3
    /// Max groups fetched per refresh.
    static let maxGroups = 20
    /// Max simultaneous per-group requests.
    static let concurrency = 4

    static func cacheKey(userId: String) -> String { "groupActivity:\(userId)" }

    /// Sort key: publish time, falling back to creation time. Unparseable = oldest.
    static func date(of a: FSGroupAnnouncement) -> Date {
        FSAnnouncementDates.parse(a.publish_at)
            ?? FSAnnouncementDates.parse(a.created_at)
            ?? .distantPast
    }

    /// Published items only, restricted to `allowedGroupIds` (left/blocked groups
    /// never leak from cache), newest first, deduped, capped.
    static func select(_ items: [GroupActivityItem], allowedGroupIds: Set<String>) -> [GroupActivityItem] {
        var seen = Set<String>()
        let kept = items
            .filter { allowedGroupIds.contains($0.groupId) && $0.announcement.published }
            .filter { seen.insert($0.id).inserted }
        return Array(kept.sorted { l, r in
            let dl = date(of: l.announcement), dr = date(of: r.announcement)
            return dl != dr ? dl > dr : l.id < r.id
        }.prefix(maxItems))
    }

    /// Merge fresh per-group results over cache. `fresh` holds only the groups
    /// that fetched successfully (value may be empty = group has none); every
    /// other group keeps its cached items.
    static func merge(cached: [GroupActivityItem],
                      fresh: [String: [GroupActivityItem]],
                      allowedGroupIds: Set<String>) -> [GroupActivityItem] {
        let kept = cached.filter { fresh[$0.groupId] == nil }
        return select(kept + fresh.values.flatMap { $0 }, allowedGroupIds: allowedGroupIds)
    }

    /// Items for one group from a fetched page.
    static func items(from page: FSAnnouncementsPage, group: FSContact) -> [GroupActivityItem] {
        page.announcements
            .filter { $0.published }
            .sorted { date(of: $0) > date(of: $1) }
            .prefix(perGroupLimit)
            .map { GroupActivityItem(groupId: group.id, groupName: group.name, announcement: $0) }
    }

    static func dateLabel(_ a: FSGroupAnnouncement) -> String {
        let s = FSAnnouncementDates.display(a.publish_at)
        return s.isEmpty ? FSAnnouncementDates.display(a.created_at) : s
    }

    static func accessibilityLabel(_ item: GroupActivityItem) -> String {
        var parts = [item.groupName, item.announcement.title]
        let d = dateLabel(item.announcement)
        if !d.isEmpty { parts.append(d) }
        return parts.joined(separator: ", ")
    }

    enum State: Equatable { case loading, hidden, empty, content }

    static func state(items: [GroupActivityItem], hasSucceeded: Bool, isLoading: Bool) -> State {
        if !items.isEmpty { return .content }
        if hasSucceeded { return .empty }
        return isLoading ? .loading : .hidden
    }
}

// ── View model ───────────────────────────────────────────────────────────────

@MainActor
final class GroupActivityViewModel: ObservableObject {
    @Published private(set) var items: [GroupActivityItem] = []
    @Published private(set) var hasSucceeded = false
    @Published private(set) var isLoading = false

    var state: GroupActivity.State {
        GroupActivity.state(items: items, hasSucceeded: hasSucceeded, isLoading: isLoading)
    }

    func load(service: DataServiceProtocol, userId: String, groups: [FSContact]) async {
        guard !userId.isEmpty else { return }
        let groups = Array(groups.filter { $0.type == .group }.prefix(GroupActivity.maxGroups))
        let allowed = Set(groups.map(\.id))
        isLoading = true
        defer { isLoading = false }

        let key = GroupActivity.cacheKey(userId: userId)
        let cached = items.isEmpty
            ? (await DiskCache.shared.load([GroupActivityItem].self, forKey: key) ?? [])
            : items
        if items.isEmpty {
            items = GroupActivity.select(cached, allowedGroupIds: allowed)
        }
        guard let announcements = service as? GroupAnnouncementsService, !groups.isEmpty else {
            if groups.isEmpty { items = []; await DiskCache.shared.save([GroupActivityItem](), forKey: key) }
            return
        }

        var fresh: [String: [GroupActivityItem]] = [:]
        var index = 0
        while index < groups.count {
            let batch = groups[index..<min(index + GroupActivity.concurrency, groups.count)]
            index += GroupActivity.concurrency
            await withTaskGroup(of: (String, [GroupActivityItem]?).self) { tg in
                for g in batch {
                    tg.addTask {
                        guard let page = try? await announcements.fetchAnnouncements(userId: userId, groupId: g.id) else {
                            return (g.id, nil)
                        }
                        return (g.id, GroupActivity.items(from: page, group: g))
                    }
                }
                for await (gid, result) in tg { if let result { fresh[gid] = result } }
            }
            if Task.isCancelled { return }
        }

        guard !fresh.isEmpty else { return }   // every fetch failed: keep what is shown
        let merged = GroupActivity.merge(cached: cached, fresh: fresh, allowedGroupIds: allowed)
        items = merged
        hasSucceeded = true
        await DiskCache.shared.save(merged, forKey: key)
    }
}

// ── Views ────────────────────────────────────────────────────────────────────

private struct GroupActivityCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GroupActivityCard: View {
    let item: GroupActivityItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                Text(item.groupName)
                    .font(.interScaled(Theme.fontSM, weight: .semibold, relativeTo: .subheadline))
                    .foregroundColor(Theme.goldLight)
                    .lineLimit(1)
                Text(item.announcement.title)
                    .font(.interScaled(Theme.fontHeading, weight: .bold, relativeTo: .headline))
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.spacingXS)
                Text(GroupActivity.dateLabel(item.announcement))
                    .font(.interScaled(Theme.fontSM, relativeTo: .caption))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(Theme.spacingMD)
            .frame(width: 240, alignment: .leading)
            .frame(minHeight: 120, alignment: .topLeading)
            .glassCard(cornerRadius: Theme.radiusXL)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous))
        }
        .buttonStyle(GroupActivityCardStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GroupActivity.accessibilityLabel(item))
        .accessibilityHint("Opens this announcement in the group")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("group-activity-card-\(item.id)")
    }
}

struct GroupActivitySection: View {
    @ObservedObject var vm: GroupActivityViewModel
    let onOpen: (GroupActivityItem) -> Void

    var body: some View {
        let state = vm.state
        if state != .hidden {
            VStack(alignment: .leading, spacing: Theme.spacingMD) {
                Text("Group activity")
                    .font(.interScaled(Theme.fontDisplayMD, weight: .bold, relativeTo: .title2))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 20)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("group-activity-heading")

                switch state {
                case .content:
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Theme.spacingMD) {
                            ForEach(vm.items) { item in
                                GroupActivityCard(item: item) { onOpen(item) }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityLabel("Loading group activity")
                case .empty:
                    Text("No announcements from your groups yet.")
                        .font(.interScaled(Theme.fontSM, relativeTo: .subheadline))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 20)
                        .accessibilityIdentifier("group-activity-empty")
                case .hidden:
                    EmptyView()
                }
            }
            .padding(.top, Theme.spacingSM)
        }
    }
}
