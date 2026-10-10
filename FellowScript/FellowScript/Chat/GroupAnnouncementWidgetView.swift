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

    /// RSVP join / leave from the detail sheet; refreshes the widget's cached item too.
    func rsvp(_ item: FSGroupAnnouncement, join: Bool) async throws -> FSGroupAnnouncement {
        guard let service else { throw AppError.networkError("Announcements aren't available right now.") }
        let updated = try await service.rsvpAnnouncement(userId: userId, groupId: groupId, announcementId: item.id, join: join)
        if self.item?.id == updated.id {
            self.item = updated
            await DiskCache.shared.save(FSLatestAnnouncement(announcement: updated), forKey: cacheKey)
        }
        return updated
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
    @StateObject private var vm: GroupAnnouncementWidgetViewModel
    @State private var viewing: FSGroupAnnouncement?

    init(service: DataServiceProtocol, groupId: String, userId: String) {
        _vm = StateObject(wrappedValue: GroupAnnouncementWidgetViewModel(service: service, groupId: groupId, userId: userId))
    }

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
                GroupAnnouncementDetailView(item: readOnly(item), onEdit: {}, onDelete: {},
                                            onRSVP: { join in try await vm.rsvp(item, join: join) })
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
            Button { viewing = item } label: { AnnouncementWidgetCardBody(item: item) }
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
}

/// The 3:1 banner card face (title, eyebrow, View chip over a scrim).
struct AnnouncementWidgetCardBody: View {
    let item: FSGroupAnnouncement
    /// Form live preview: a locally cropped photo shown instead of `banner_url`.
    var previewImage: UIImage? = nil

    /// Layering (regression fix): the card's size comes ONLY from the 3:1 clear
    /// base. The banner is an `.overlay`, so an oversized aspect-fill photo can
    /// never grow the card and push the scrim/text out of the clipped frame.
    var body: some View {
        let url = item.banner_url.flatMap(URL.init(string:))
        return Color.clear
            .aspectRatio(AnnouncementLimits.bannerAspect, contentMode: .fit)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background(
                // Fallback gradient sits under the banner so a missing/failed image needs no error UI.
                LinearGradient(colors: [Color(hex: "#2a2110"), Color(hex: "#5a4210"), Color(hex: "#C99A10")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay {
                if let previewImage {
                    Image(uiImage: previewImage).resizable().scaledToFill().accessibilityHidden(true)
                } else if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                    .accessibilityHidden(true)
                }
            }
            .overlay {
                // Scrim: white text stays ~9:1 (AA) even over a pure white photo.
                LinearGradient(stops: [.init(color: .black.opacity(0.78), location: 0),
                                       .init(color: .black.opacity(0.72), location: 0.4),
                                       .init(color: .black.opacity(0), location: 0.85)],
                               startPoint: .bottom, endPoint: .top)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) { cardText }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldFaint, lineWidth: 1))
    }

    private var cardText: some View {
        HStack(alignment: .center, spacing: Theme.spacingSM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(AnnouncementTitleFont.resolve(item.title_font).font(17)).foregroundColor(AnnouncementTitleColor.bannerColor(item.title_color))
                    .lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
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

#if DEBUG
/// Regression previews: a tall 3000x6000 portrait and a pure-white photo must
/// still show the title and "View" inside the 3:1 frame.
private func previewBannerURL(tall: Bool, white: Bool) -> String {
    let size = tall ? CGSize(width: 3000, height: 6000) : CGSize(width: 3000, height: 1000)
    let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
    let data = UIGraphicsImageRenderer(size: size, format: fmt).jpegData(withCompressionQuality: 0.6) { ctx in
        (white ? UIColor.white : UIColor.systemTeal).setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-banner-\(tall)-\(white).jpg")
    try? data.write(to: url)
    return url.absoluteString
}

private func previewItem(_ title: String, _ banner: String) -> FSGroupAnnouncement {
    FSGroupAnnouncement(id: "p", group_id: "g", creator_id: nil, creator_username: "sam", title: title, description: "",
                        banner_url: banner, publish_at: "2026-09-29T12:00:00Z", created_at: "2026-09-29T12:00:00Z",
                        updated_at: "2026-09-29T12:00:00Z", published: true, can_edit: false)
}
#Preview("Tall photo") {
    AnnouncementWidgetCardBody(item: previewItem("Youth night moved to Friday", previewBannerURL(tall: true, white: false)))
        .padding().background(Color.black)
}
#Preview("White photo") {
    AnnouncementWidgetCardBody(item: previewItem("Potluck this Sunday after service", previewBannerURL(tall: false, white: true)))
        .padding().background(Color.black)
}
#endif
