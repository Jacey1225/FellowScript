// AnnouncementTimelineRow.swift -- task 20261030-chat-announcements.
// The in-timeline row for an announcement a member posted into the group chat
// (system_kind "announcement"). Renders the SAME banner card face as the chat
// header widget (AnnouncementWidgetCardBody) under a small "Announcement" label
// with the poster and an "edited" marker. Tap fetches the full announcement and
// opens the existing read-only GroupAnnouncementDetailView (RSVP and polls work
// as in the widget). A failed fetch shows a warm error; nothing is fabricated
// from the line's card. Rows only render while the server sends the card, which
// it does only with the chat_announcements flag on; otherwise the caller falls
// back to the plain system line.

import SwiftUI
import Combine

enum AnnouncementTimelineCopy {
    static func label(poster: String, edited: Bool) -> String {
        let who = poster.isEmpty ? "A member" : poster
        return edited ? "Announcement by \(who) \u{00B7} edited" : "Announcement by \(who)"
    }
    static let openError = "Couldn't open that announcement. Please try again."
    static let goneError = "That announcement is no longer available."

    static func errorMessage(for error: Error) -> String {
        if case AppError.networkError(let m) = error, m.localizedCaseInsensitiveContains("not found") { return goneError }
        return openError
    }
}

struct AnnouncementTimelineRow: View {
    let message: FSMessage
    let card: FSMessageAnnouncement
    /// Poster display name (from the grouped row; "You" for the viewer's own).
    let posterName: String

    @EnvironmentObject private var appState: AppState
    @Environment(\.chatAnnouncementGroupId) private var groupId
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewing: FSGroupAnnouncement?
    @State private var opening = false
    @State private var errorText: String?
    @StateObject private var actions = AnnouncementTimelineActions()

    private var posterLabel: String { card.creator_username ?? posterName }
    private var edited: Bool { card.edited == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if groupId != nil {
            HStack(spacing: 6) {
                Image(systemName: "megaphone.fill").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
                Text(AnnouncementTimelineCopy.label(poster: posterLabel, edited: edited))
                    .font(.inter(Theme.fontXXS, weight: .semibold))
                Spacer(minLength: 0)
                if opening { ProgressView().controlSize(.mini).tint(Theme.gold) }
            }
            .foregroundColor(Theme.textSecondary)
            }
            if let groupId {
                Button { Task { await open(groupId: groupId) } } label: {
                    AnnouncementWidgetCardBody(item: card.cardItem(groupId: groupId))
                }
                .buttonStyle(.plain)
                .disabled(opening)
                .accessibilityLabel("\(AnnouncementTimelineCopy.label(poster: posterLabel, edited: edited)): \(card.title)")
                .accessibilityHint("Opens the announcement")
                .accessibilityAddTraits(.isButton)
            }
            if groupId == nil {
                // Feature off for this viewer: plain system line, no card.
                Text("\(posterName) posted an announcement")
                    .font(.inter(Theme.fontXXS)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
            }
            if let errorText {
                Text(errorText).font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    .accessibilityLabel(errorText)
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingXS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(MessageGroupRow.anchorId(for: message.id))
        .sheet(item: $viewing) { item in
            NavigationStack {
                GroupAnnouncementDetailView(
                    item: item, onEdit: {}, onDelete: {},
                    onRSVP: { join in try await actions.rsvp(item, join: join, appState: appState, groupId: item.group_id) },
                    pollActions: actions.pollActions(for: item, appState: appState))
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

    private func open(groupId: String) async {
        guard let uid = appState.currentUser?.user_id, let svc = appState.service as? GroupAnnouncementsService else {
            errorText = AnnouncementTimelineCopy.openError
            return
        }
        opening = true
        errorText = nil
        defer { opening = false }
        do {
            var full = try await svc.fetchAnnouncement(userId: uid, groupId: groupId, announcementId: card.id)
            full.can_edit = false   // read-only here; edit/delete stay in the group info panel
            viewing = full
        } catch {
            errorText = AnnouncementTimelineCopy.errorMessage(for: error)
        }
    }
}

/// RSVP and poll calls for the detail sheet. Stateless apart from the services it
/// resolves per call; it only returns fresh server results to the sheet.
@MainActor
final class AnnouncementTimelineActions: ObservableObject {
    func rsvp(_ item: FSGroupAnnouncement, join: Bool, appState: AppState, groupId: String) async throws -> FSGroupAnnouncement {
        guard let uid = appState.currentUser?.user_id, let svc = appState.service as? GroupAnnouncementsService else {
            throw AppError.networkError("Announcements aren't available right now.")
        }
        var updated = try await svc.rsvpAnnouncement(userId: uid, groupId: groupId, announcementId: item.id, join: join)
        updated.can_edit = false
        return updated
    }

    func pollActions(for item: FSGroupAnnouncement, appState: AppState) -> AnnouncementPollActions? {
        guard let uid = appState.currentUser?.user_id else { return nil }
        return AnnouncementPollActions.make(service: appState.service as? AnnouncementPollsService,
                                            userId: uid, groupId: item.group_id, item: item) { _ in }
    }
}
