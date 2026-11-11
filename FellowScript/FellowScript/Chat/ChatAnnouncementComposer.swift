// ChatAnnouncementComposer.swift -- task 20261030-chat-announcements.
// Composer entry point: an "Announcement" chip in the "+" attach row of a group
// chat (shown only with the chat_announcements flag on) that opens the existing
// GroupAnnouncementFormView. The form's view model is flagged to also post the
// new announcement into the chat; content, scheduling, banner, polls, RSVP and
// the free-plan limit all behave exactly as in the Announcements list. A failed
// post leaves the form open with the user's content (the form owns that).

import SwiftUI

struct AttachAnnouncementChip {
    let action: () -> Void
}

struct AttachAnnouncementChipButton: View {
    let chip: AttachAnnouncementChip
    var compact: Bool = false

    var body: some View {
        Button(action: chip.action) { ChipIconLabel(title: "Announcement", systemIcon: "megaphone", compact: compact) }
            .buttonStyle(ChipButtonStyle(compact: compact, hasIcon: true))
            .accessibilityLabel("Announcement")
            .accessibilityHint("Write an announcement and post it in this chat")
    }
}

/// Presents the announcement form as a sheet. Owns its own view model so the
/// Announcements list's state is untouched.
private struct ChatAnnouncementSheet: ViewModifier {
    @Binding var isPresented: Bool
    @StateObject private var vm: GroupAnnouncementsViewModel

    init(isPresented: Binding<Bool>, service: DataServiceProtocol, groupId: String, userId: String) {
        _isPresented = isPresented
        let model = GroupAnnouncementsViewModel(service: service, groupId: groupId, userId: userId)
        model.postsToChat = true
        _vm = StateObject(wrappedValue: model)
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            GroupAnnouncementFormView(vm: vm, editing: nil) { _ in isPresented = false }
        }
    }
}

extension View {
    func chatAnnouncementSheet(isPresented: Binding<Bool>, service: DataServiceProtocol,
                               groupId: String, userId: String) -> some View {
        modifier(ChatAnnouncementSheet(isPresented: isPresented, service: service, groupId: groupId, userId: userId))
    }
}
