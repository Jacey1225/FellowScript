// ChatProfileHookins.swift (task 20261030-profile-everywhere)
// Thin chat-side adapters that attach the shared `.profileTap(...)` modifier
// (Profile/ProfileTapTarget.swift) to chat surfaces. Kept out of
// ChatThreadView.swift / MessageGroupRow.swift so those files only gain
// one-line hook-ins. Every adapter fails closed: no real user id means the
// content is returned untouched (plain text, no button trait).

import SwiftUI

// ── Id lookup context ─────────────────────────────────────────────────────────

/// The ids a thread can offer for its received-message senders. `dmPeerId` is
/// the contact id of a DM (every received DM row is from that peer);
/// `idByUsername` maps the group's already-resolved members (built from real
/// member ids by ChatThreadViewModel.resolveGroupMemberPhotos) so rows that
/// only carry a display name (paged history) can still be matched to a member.
struct ChatProfileLookup {
    var dmPeerId: String? = nil
    var idByUsername: [String: String] = [:]
    static let none = ChatProfileLookup()
}

private struct MemberIdByUsernameKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    /// Resolved group members, username -> user id (group info member chips).
    var fsMemberIdByUsername: [String: String] {
        get { self[MemberIdByUsernameKey.self] }
        set { self[MemberIdByUsernameKey.self] = newValue }
    }
}

// ── Pure resolution (unit-testable) ───────────────────────────────────────────

enum ChatProfileResolver {
    /// The profile id of a received-message group's sender, or nil (untappable).
    /// Never fabricated: a DM peer id, an id carried on the message itself, or
    /// a username that matches a resolved group member. Own and system groups
    /// are never tappable.
    static func senderProfileId(group: MessageDisplayGroup, lookup: ChatProfileLookup) -> String? {
        guard !group.isOutgoing, !group.isSystem else { return nil }
        if let dm = lookup.dmPeerId { return UUID(uuidString: dm) != nil ? dm : nil }
        if let id = group.messages.compactMap(\.senderId).first(where: { UUID(uuidString: $0) != nil }) {
            return id
        }
        if let id = lookup.idByUsername[group.senderName], UUID(uuidString: id) != nil { return id }
        return nil
    }
}

// ── Layout-neutral tap ────────────────────────────────────────────────────────

extension View {
    /// `.profileTap` with its 44pt hit area, but with negative padding so the
    /// layout footprint stays `insetH`/`insetV` smaller on each side (the
    /// existing visual size). The hit area still extends past the visual.
    func profileTapKeepingLayout(userId: String?, username: String, photoURL: String? = nil,
                                 insetH: CGFloat, insetV: CGFloat) -> some View {
        modifier(KeepLayoutProfileTap(userId: userId, username: username, photoURL: photoURL,
                                      insetH: insetH, insetV: insetV))
    }

    /// Square avatar convenience: `diameter` is the drawn size.
    func profileTapAvatar(userId: String?, username: String, photoURL: String? = nil,
                          diameter: CGFloat) -> some View {
        let inset = max(0, (44 - diameter) / 2)
        return profileTapKeepingLayout(userId: userId, username: username, photoURL: photoURL,
                                       insetH: inset, insetV: inset)
    }
}

private struct KeepLayoutProfileTap: ViewModifier {
    let userId: String?
    let username: String
    let photoURL: String?
    let insetH: CGFloat
    let insetV: CGFloat

    func body(content: Content) -> some View {
        if ProfileTapGuard.isTappable(userId: userId, username: username) {
            content
                .profileTap(userId: userId, username: username, photoURL: photoURL)
                .padding(.horizontal, -insetH)
                .padding(.vertical, -insetV)
        } else {
            content
        }
    }
}

// ── Message sender avatar / name ──────────────────────────────────────────────

private struct SenderProfileTap: ViewModifier {
    let group: MessageDisplayGroup
    let lookup: ChatProfileLookup
    let isAvatar: Bool

    func body(content: Content) -> some View {
        let id = ChatProfileResolver.senderProfileId(group: group, lookup: lookup)
        if isAvatar {
            if ProfileTapGuard.isTappable(userId: id, username: group.senderName) {
                content.profileTapAvatar(userId: id, username: group.senderName,
                                         photoURL: group.senderPhotoURL, diameter: 32)
            } else {
                content.accessibilityHidden(true)   // decorative, as before
            }
        } else {
            content.profileTap(userId: id, username: group.senderName,
                               photoURL: group.senderPhotoURL, expandHitArea: false)
        }
    }
}

extension View {
    /// Sender avatar (`expandHitArea` true) or name (false) of a received group.
    func senderProfileTap(group: MessageDisplayGroup, lookup: ChatProfileLookup,
                          expandHitArea: Bool = true) -> some View {
        modifier(SenderProfileTap(group: group, lookup: lookup, isAvatar: expandHitArea))
    }

    /// One member chip (avatar + name) in group info.
    func groupMemberProfileTap(name: String, userId: String?, photoURL: String?) -> some View {
        // Chip is 26pt tall; the 44pt hit area grows only vertically in effect.
        profileTapKeepingLayout(userId: userId, username: name, photoURL: photoURL,
                                insetH: 0, insetV: 9)
    }
}

// ── DM header ─────────────────────────────────────────────────────────────────

private struct DMHeaderProfileTap: ViewModifier {
    let contact: FSContact

    func body(content: Content) -> some View {
        if contact.type == .friend,
           ProfileTapGuard.isTappable(userId: contact.id, username: contact.name) {
            // The header button is a no-op for a DM; the profile target sits on
            // top of it and the underlying button is hidden from VoiceOver.
            content
                .accessibilityHidden(true)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .profileTap(userId: contact.id, username: contact.name,
                                    photoURL: contact.photoUrl, expandHitArea: false)
                }
        } else {
            content
        }
    }
}

extension View {
    /// DM thread header: avatar and name open the peer's profile. Groups are
    /// untouched (the header keeps opening group info).
    func dmHeaderProfileTap(contact: FSContact) -> some View {
        modifier(DMHeaderProfileTap(contact: contact))
    }
}

// ── Group join-request applicant ──────────────────────────────────────────────

extension View {
    /// Applicant avatar in the host's join-request list. `applicantUserId` is
    /// optional on the wire; absent means untappable.
    func joinRequestProfileTap(_ req: FSJoinRequest) -> some View {
        // Decorative unless tappable (the avatar itself no longer hides itself).
        Group {
            if ProfileTapGuard.isTappable(userId: req.applicantUserId, username: req.displayName) {
                profileTapAvatar(userId: req.applicantUserId, username: req.displayName,
                                 photoURL: req.profilePhotoUrl, diameter: 40)
            } else {
                accessibilityHidden(true)
            }
        }
    }
}
