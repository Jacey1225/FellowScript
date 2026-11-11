// ProfileTapTarget.swift (task 20261030-profile-everywhere)
// The single shared "open this user's profile" tap target. Every spot that shows
// another user's avatar or username attaches `.profileTap(...)` instead of
// owning its own sheet state. Deny-by-default: without a real user id the
// modifier returns the content untouched (no button, no trait, no sheet).

import SwiftUI

/// Pure guard deciding whether a (userId, username) pair may open a profile.
/// Fail closed: only a well-formed UUID plus a real display name qualifies.
enum ProfileTapGuard {
    /// Labels the app shows for entities that are not a profile-able user.
    private static let nonUserLabels: Set<String> = [
        "", "someone", "a member", "them", "you", "system", "announcement",
    ]

    static func isTappable(userId: String?, username: String?) -> Bool {
        guard let userId, UUID(uuidString: userId) != nil else { return false }
        let name = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !nonUserLabels.contains(name)
    }
}

struct ProfileTapModifier: ViewModifier {
    @EnvironmentObject var appState: AppState
    let userId: String?
    let username: String
    let photoURL: String?
    let expandHitArea: Bool
    @State private var show = false

    func body(content: Content) -> some View {
        if ProfileTapGuard.isTappable(userId: userId, username: username), let userId {
            Button { show = true } label: {
                content
                    .frame(minWidth: expandHitArea ? 44 : nil, minHeight: expandHitArea ? 44 : nil)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(username)'s profile")
            .accessibilityAddTraits(.isButton)
            .sheet(isPresented: $show) {
                // The profile view owns fetch, 404 and cache behavior; nothing is
                // pre-fetched here and the tap site learns nothing about the target.
                ProfileView(viewerId: appState.currentUser?.user_id ?? "", targetId: userId,
                            service: appState.service)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Makes this view open `userId`'s profile when tapped. No-op when the id
    /// is missing, malformed, or the name is a placeholder. `photoURL` is
    /// accepted for call-site symmetry; the profile view loads its own data.
    func profileTap(userId: String?, username: String, photoURL: String? = nil,
                    expandHitArea: Bool = true) -> some View {
        modifier(ProfileTapModifier(userId: userId, username: username, photoURL: photoURL,
                                    expandHitArea: expandHitArea))
    }
}

/// A tappable avatar that opens that user's profile (design A1). Absorbed from
/// ProfileEntryViews; now routed through the shared modifier.
struct ProfileLinkedAvatar: View {
    let userId: String
    let username: String
    var photoURL: String? = nil
    var diameter: CGFloat = 36

    var body: some View {
        AvatarView(initial: String(username.prefix(1)).uppercased(), photoURL: photoURL,
                   diameter: diameter, fillColor: Theme.gold.opacity(0.15), textColor: Theme.gold)
            .profileTap(userId: userId, username: username, photoURL: photoURL)
    }
}
