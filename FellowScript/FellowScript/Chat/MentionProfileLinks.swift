// MentionProfileLinks.swift (task 20261030-profile-everywhere)
// Makes a rendered @mention open that user's profile. Mention runs carry a
// private-scheme link (fsprofile://<uuid>) that this file's opener turns into
// the shared profile sheet. Fail closed: a mention without a well-formed UUID
// (or with a placeholder name) gets no link at all, so it stays plain bold text.

import SwiftUI

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

    func body(content: Content) -> some View {
        content
            .tint(Theme.parchment)   // link runs keep the bubble text colour; bold is the cue
            .environment(\.openURL, OpenURLAction { url in
                guard let id = MentionProfileLink.userId(from: url) else { return .systemAction }
                target = id
                return .handled
            })
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
