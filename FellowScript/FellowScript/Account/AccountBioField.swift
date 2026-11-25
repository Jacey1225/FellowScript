// AccountBioField.swift (task 20261125-account-page-cleanup)
// Own-bio editor inside the Account "Edit Profile" card. Reuses ProfileViewModel
// (bioMaxLength, normalization, counter, saveBio, bioErrorMessage) and
// ProfileBioEditor, so validation and save behavior match ProfileView exactly.
//
// Rules honored here:
//  * throw-not-fabricate: the editor (and so Save) only exists once a profile
//    was loaded or cached. A failed first load shows an error with Retry, never
//    an empty field a Save could use to wipe the stored bio.
//  * preserve-cache-on-failed-refresh: a failed refresh keeps the cached bio
//    (ProfileViewModel.load does not clear `profile` on network errors).

import SwiftUI

struct AccountBioField: View {
    @StateObject private var vm: ProfileViewModel
    /// The bio text the draft was last seeded with; lets a later refresh replace
    /// the draft only while the user has not typed anything.
    @State private var seededBio: String?

    init(userId: String, service: DataServiceProtocol) {
        _vm = StateObject(wrappedValue: ProfileViewModel(viewerId: userId, targetId: userId, service: service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Bio").font(.fsLabel).foregroundColor(Theme.textPrimary)

            if vm.profile != nil {
                ProfileBioEditor(vm: vm, autoFocus: false, showsCancel: false)
                if vm.bioJustSaved {
                    Label("Bio saved", systemImage: "checkmark")
                        .font(.inter(Theme.fontSM)).foregroundColor(Theme.success)
                }
                if let note = vm.statusMessage {
                    Text(note).font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                }
            } else if vm.phase == .failed || vm.phase == .unavailable {
                Text("Couldn't load your bio.")
                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.error)
                Button("Retry") { Task { await vm.load() } }
                    .font(.inter(Theme.fontBody, weight: .semibold))
                    .foregroundColor(Theme.parchment)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Retry loading bio")
            } else {
                ProgressView().tint(Theme.gold)
                    .accessibilityLabel("Loading bio")
            }
        }
        .task { await vm.load() }
        .onChange(of: vm.profile?.bio) { _, newBio in
            guard vm.profile != nil else { return }
            let incoming = newBio ?? ""
            if seededBio == nil || vm.draft == seededBio {
                vm.draft = incoming
                seededBio = incoming
            }
        }
        .onChange(of: vm.profile == nil) { _, isNil in
            // First profile arrival (cache hit or fetch) with a nil bio does not
            // change `profile?.bio`, so seed the empty draft here too.
            if !isNil, seededBio == nil {
                let incoming = vm.profile?.bio ?? ""
                vm.draft = incoming
                seededBio = incoming
            }
        }
        .onChange(of: vm.bioJustSaved) { _, saved in
            // Show the server-normalized text that was stored.
            if saved { let stored = vm.profile?.bio ?? ""; vm.draft = stored; seededBio = stored }
        }
    }
}
