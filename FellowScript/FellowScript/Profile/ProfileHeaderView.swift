// ProfileHeaderView.swift (task 20261030-user-profiles)
// Identity block: avatar, name, relationship chip, and the bio region whose
// content depends on the viewer's tier (design D1: strangers get one quiet line).

import SwiftUI

struct ProfileHeaderView: View {
    @ObservedObject var vm: ProfileViewModel
    let profile: FSProfile

    private var effectiveState: FSProfileRelationship {
        // While the undo window is open the bio and friend-only affordances are already gone.
        vm.unfriendPending && profile.relationship == .friends ? .none : profile.relationship
    }

    var body: some View {
        VStack(spacing: Theme.spacingMD) {
            AvatarView(initial: String(profile.username.prefix(1)).uppercased(),
                       photoURL: profile.profile_photo_url, diameter: 96,
                       fillColor: Theme.gold.opacity(0.18), textColor: Theme.gold)
                .overlay(Circle().stroke(Theme.borderGoldDim, lineWidth: 1))
                .accessibilityHidden(true)

            VStack(spacing: Theme.spacingSM) {
                Text(profile.username)
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                chip
            }
            .accessibilityElement(children: .combine)

            bioRegion
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.spacingSM)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.spacingLG)
        .widgetCard()
    }

    // MARK: Chip

    private var chipLabel: String? {
        switch effectiveState {
        case .friends:         return "Friends"
        case .requestSent:     return "Request sent"
        case .requestReceived: return "Wants to be friends"
        case .selfUser, .none: return nil
        }
    }
    private var chipIcon: String {
        switch effectiveState {
        case .friends:         return "checkmark.circle"
        case .requestSent:     return "clock"
        default:               return "person.crop.circle.badge.plus"
        }
    }

    @ViewBuilder private var chip: some View {
        if let label = chipLabel {
            Label(label, systemImage: chipIcon)
                .font(.inter(Theme.fontSM, weight: .semibold))
                .foregroundColor(Theme.gold)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Theme.gold.opacity(0.12)))
        }
    }

    // MARK: Bio

    @ViewBuilder private var bioRegion: some View {
        if profile.relationship == .selfUser {
            if vm.isEditingBio {
                ProfileBioEditor(vm: vm)
            } else {
                selfBio
            }
        } else if !profile.bioVisible || vm.unfriendPending {
            quietLine("Bio is shared with friends.")
        } else if let bio = profile.bio, !bio.isEmpty {
            bioText(bio)
        } else {
            quietLine("No bio yet.")
        }
    }

    private var selfBio: some View {
        VStack(spacing: Theme.spacingSM) {
            if let bio = profile.bio, !bio.isEmpty {
                bioText(bio)
            } else {
                quietLine("Add a short bio so friends know who you are.")
            }
            if vm.bioJustSaved {
                Label("Bio saved", systemImage: "checkmark")
                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
            }
            if profile.editable {
                Button(profile.bio?.isEmpty == false ? "Edit bio" : "Add bio") { vm.beginEditingBio() }
                    .font(.inter(Theme.fontBody, weight: .semibold))
                    .foregroundColor(Theme.gold)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
    }

    /// Plain text only: `Text(verbatim:)` so nothing is parsed as markdown or auto-linked.
    private func bioText(_ bio: String) -> some View {
        Text(verbatim: bio)
            .font(.inter(Theme.fontBody))
            .foregroundColor(Theme.parchment)
            .lineSpacing(3)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Bio: \(bio)")
    }

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .font(.inter(Theme.fontBody))
            .foregroundColor(Theme.textSecondary)
            .multilineTextAlignment(.center)
    }
}
