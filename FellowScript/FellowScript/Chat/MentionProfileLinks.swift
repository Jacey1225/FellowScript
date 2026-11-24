// MentionProfileLinks.swift (task 20261030-profile-everywhere)
// Makes a rendered @mention open that user's profile. Mention runs carry a
// private-scheme link (fsprofile://<uuid>) that this file's opener turns into
// the shared profile sheet. Fail closed: a mention without a well-formed UUID
// (or with a placeholder name) gets no link at all, so it stays plain bold text.

import SwiftUI
import UIKit

enum MentionProfileLink {
    static let scheme = "fsprofile"

    /// The link URL for one mention, or nil when it must not be tappable.
    static func url(for mention: FSMention, shownName: String) -> URL? {
        let name = shownName.hasPrefix("@") ? String(shownName.dropFirst()) : shownName
        guard ProfileTapGuard.isTappable(userId: mention.userId, username: name) else { return nil }
        return URL(string: "\(scheme)://\(mention.userId.lowercased())")
    }

    /// The user id carried by one of our links, nil for any other URL.
    static func userId(from url: URL) -> String? {
        guard url.scheme == scheme, let host = url.host, UUID(uuidString: host) != nil else { return nil }
        return host
    }
}

private struct MentionProfileOpener: ViewModifier {
    @EnvironmentObject var appState: AppState
    @State private var target: String?
    @State private var pendingLink: PendingExternalLink?

    func body(content: Content) -> some View {
        content
            .tint(Theme.parchment)   // link runs keep the bubble text colour; bold is the cue
            .environment(\.openURL, OpenURLAction { url in
                if let id = MentionProfileLink.userId(from: url) {
                    target = id
                    return .handled
                }
                // Task 20261124-clickable-message-links: only http/https leave the
                // app, always to the system browser (never a web view). Suspicious
                // links (userinfo, raw IP, odd port, IDN host) ask first.
                switch MessageLinkPolicy.decide(url) {
                case .open(let safe): return .systemAction(safe)
                case .confirm(let safe, let host):
                    pendingLink = PendingExternalLink(url: safe, host: host)
                    return .handled
                case .reject: return .discarded
                }
            })
            .externalLinkConfirmation($pendingLink)
            .sheet(item: Binding(get: { target.map(MentionProfileTarget.init) },
                                 set: { target = $0?.id })) { t in
                ProfileView(viewerId: appState.currentUser?.user_id ?? "", targetId: t.id,
                            service: appState.service)
            }
    }
}

private struct MentionProfileTarget: Identifiable { let id: String }

extension View {
    func mentionProfileOpener() -> some View { modifier(MentionProfileOpener()) }
}

/// A link waiting for the user's "Open" in the leaving-FellowScript dialog.
struct PendingExternalLink: Identifiable {
    let url: URL
    let host: String
    var id: String { url.absoluteString }
}

private struct ExternalLinkConfirmation: ViewModifier {
    @Binding var pending: PendingExternalLink?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "You're leaving FellowScript",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { link in
            Button("Open \(link.host)") { UIApplication.shared.open(link.url) }
            Button("Cancel", role: .cancel) {}
        } message: { link in
            Text(link.url.absoluteString)
        }
    }
}

extension View {
    /// Shows the confirm dialog for a suspicious link; Open hands it to the system.
    func externalLinkConfirmation(_ pending: Binding<PendingExternalLink?>) -> some View {
        modifier(ExternalLinkConfirmation(pending: pending))
    }

    /// Link handling for text that has no @mentions (agent chat bodies).
    func messageLinkOpener() -> some View { modifier(MessageLinkOpener()) }
}

private struct MessageLinkOpener: ViewModifier {
    @State private var pendingLink: PendingExternalLink?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                switch MessageLinkPolicy.decide(url) {
                case .open(let safe): return .systemAction(safe)
                case .confirm(let safe, let host):
                    pendingLink = PendingExternalLink(url: safe, host: host)
                    return .handled
                case .reject: return .discarded
                }
            })
            .externalLinkConfirmation($pendingLink)
    }
}
