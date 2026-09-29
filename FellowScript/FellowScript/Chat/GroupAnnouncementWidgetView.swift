// GroupAnnouncementWidgetView.swift — banner card directly under the group chat
// header (task 20260929-announcement-push-widget, design-notes.md). Groups only
// (the caller decides). Opens the existing GroupAnnouncementDetailView.
//
// Failure behavior (throw-not-fabricate, preserve-cache-on-failed-refresh): the
// fetch throws; a failed refresh keeps the previously shown item (in memory and
// in DiskCache) with no error UI. If nothing was ever loaded, renders nothing.

import SwiftUI
import Combine

@MainActor
final class GroupAnnouncementWidgetViewModel: ObservableObject {
    let groupId: String
    let userId:  String
    private let service: GroupAnnouncementsService?

    @Published var item: FSGroupAnnouncement?
    @Published var dismissedId: String?

    init(service: DataServiceProtocol, groupId: String, userId: String) {
        self.service = service as? GroupAnnouncementsService
        self.groupId = groupId
        self.userId  = userId
        self.dismissedId = UserDefaults.standard.string(forKey: dismissKey)
    }

    private var cacheKey: String { "announcementLatest:\(userId):\(groupId)" }
    private var dismissKey: String { "fs.announcementDismissed.\(userId).\(groupId)" }

    /// Visible = a published item that was not dismissed on this device.
    var visibleItem: FSGroupAnnouncement? {
        guard let item, item.published, item.id != dismissedId else { return nil }
        return item
    }

    func load() async {
        if item == nil, let cached = await DiskCache.shared.load(FSLatestAnnouncement.self, forKey: cacheKey) {
            item = cached.announcement
        }
        guard let service else { return }
        do {
            let fresh = try await service.fetchLatestAnnouncement(userId: userId, groupId: groupId)
            item = fresh
            await DiskCache.shared.save(FSLatestAnnouncement(announcement: fresh), forKey: cacheKey)
        } catch {
            // Keep whatever is shown; no error UI.
        }
    }

    func dismiss() {
        guard let id = item?.id else { return }
        UserDefaults.standard.set(id, forKey: dismissKey)
        dismissedId = id
    }

    /// Push deep link: the announcement by id, or nil when it is gone.
    func fetch(id: String) async -> FSGroupAnnouncement? {
        guard let service else { return nil }
        return try? await service.fetchAnnouncement(userId: userId, groupId: groupId, announcementId: id)
    }
}

struct GroupAnnouncementWidgetView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var vm: GroupAnnouncementWidgetViewModel
    @State private var viewing: FSGroupAnnouncement?

    init(service: DataServiceProtocol, groupId: String, userId: String) {
        _vm = StateObject(wrappedValue: GroupAnnouncementWidgetViewModel(service: service, groupId: groupId, userId: userId))
    }

    private var height: CGFloat { typeSize.isAccessibilitySize ? 88 : 72 }

    var body: some View {
        VStack(spacing: 0) {
            if let item = vm.visibleItem {
                card(item)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.top, Theme.spacingSM)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        // Modifiers live on the container so the push deep link works even when
        // the card itself is hidden (dismissed / nothing to show).
        .task { await vm.load(); await consumePendingOpen() }
        .onChange(of: appState.pendingAnnouncementOpen) { _, _ in Task { await consumePendingOpen() } }
        .sheet(item: $viewing) { item in
            NavigationStack {
                // Read-only here; edit/delete stay in the group info panel.
                GroupAnnouncementDetailView(item: readOnly(item), onEdit: {}, onDelete: {})
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { viewing = nil }
                                .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold)
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func readOnly(_ item: FSGroupAnnouncement) -> FSGroupAnnouncement {
        var copy = item
        copy.can_edit = false
        return copy
    }

    private func consumePendingOpen() async {
        guard let pending = appState.pendingAnnouncementOpen, pending.groupId == vm.groupId else { return }
        appState.pendingAnnouncementOpen = nil
        // Falls back to just the chat (no dialog) if the announcement is gone.
        if let item = await vm.fetch(id: pending.announcementId) { viewing = item }
    }

    private func card(_ item: FSGroupAnnouncement) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { viewing = item } label: { cardBody(item) }
                .buttonStyle(AnnouncementCardPressStyle(reduceMotion: reduceMotion))
                .accessibilityLabel("Announcement: \(item.title)")
                .accessibilityHint("Opens the announcement")
                .accessibilityAddTraits(.isButton)

            Button {
                withMotionAwareAnimation(.easeIn(duration: 0.16), reduceMotion: reduceMotion) { vm.dismiss() }
                UIAccessibility.post(notification: .announcement, argument: "Announcement dismissed")
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(Theme.parchment)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .offset(x: 10, y: -10)
            .accessibilityLabel("Dismiss announcement")
        }
    }

    private func cardBody(_ item: FSGroupAnnouncement) -> some View {
        let url = item.banner_url.flatMap(URL.init(string:))
        return ZStack(alignment: .bottomLeading) {
            // Fallback gradient sits under the banner so a missing/failed image needs no error UI.
            LinearGradient(colors: [Color(hex: "#2a2110"), Color(hex: "#5a4210"), Color(hex: "#C99A10")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                }
                .accessibilityHidden(true)
                // Scrim: text always parchment on dark, AA over any banner.
                LinearGradient(colors: [Color(red: 10/255, green: 10/255, blue: 10/255).opacity(0.35),
                                        Color(red: 10/255, green: 10/255, blue: 10/255).opacity(0.78)],
                               startPoint: .top, endPoint: .bottom)
            }
            HStack(alignment: .center, spacing: Theme.spacingSM) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ANNOUNCEMENT")
                        .font(.inter(11, weight: .semibold)).tracking(0.66).foregroundColor(Theme.goldLight)
                    Text(item.title)
                        .font(.inter(15, weight: .semibold)).foregroundColor(Color(hex: "#F2F2F2"))
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Text("View").font(.inter(Theme.fontXS, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(Theme.goldLight)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .overlay(Capsule().stroke(Theme.goldLight.opacity(0.4), lineWidth: 1))
                .padding(.trailing, 28)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldFaint, lineWidth: 1))
    }
}

private struct AnnouncementCardPressStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
    }
}
