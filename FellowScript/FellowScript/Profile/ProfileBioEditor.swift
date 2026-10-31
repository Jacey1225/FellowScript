// ProfileBioEditor.swift (task 20261030-user-profiles)
// Inline own-bio editor (design E1). The draft is never cleared on failure;
// errors render inline under the field in text (not color alone).

import SwiftUI

struct ProfileBioEditor: View {
    @ObservedObject var vm: ProfileViewModel
    @FocusState private var focused: Bool

    private var counterText: String {
        let remaining = vm.draftRemaining
        if remaining < 0 { return "Over by \(-remaining)" }
        if remaining <= 20 { return "\(remaining) left" }
        return "\(vm.draftLength)/\(ProfileViewModel.bioMaxLength)"
    }
    private var counterColor: Color {
        let remaining = vm.draftRemaining
        if remaining < 0 { return Theme.error }
        if remaining <= 20 { return Theme.gold }
        return Theme.textSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            TextField("Add a short bio", text: $vm.draft, axis: .vertical)
                .lineLimit(3...6)
                .focused($focused)
                .font(.inter(Theme.fontBody))
                .foregroundColor(Theme.parchment)
                .tint(Theme.gold)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSM).fill(Theme.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSM)
                    .stroke(vm.draftRemaining < 0 ? Theme.error : (focused ? Theme.gold : Theme.fieldBorder), lineWidth: 1))
                .textInputAutocapitalization(.sentences)
                .accessibilityLabel("Bio")
                .disabled(vm.isSavingBio)

            HStack {
                Text("Plain text, up to \(ProfileViewModel.bioMaxLength) characters. No links.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                Spacer(minLength: 8)
                Text(counterText)
                    .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(counterColor)
                    .accessibilityLabel(vm.draftRemaining < 0
                        ? "Over the limit by \(-vm.draftRemaining) characters"
                        : "\(vm.draftRemaining) characters left")
            }

            if let error = vm.bioError {
                Text(error)
                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.error)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(spacing: 12) {
                Button("Cancel") { vm.cancelEditingBio() }
                    .font(.inter(Theme.fontBody, weight: .semibold))
                    .foregroundColor(Theme.parchment)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(vm.isSavingBio)
                Spacer()
                Button {
                    Task { await vm.saveBio() }
                } label: {
                    Group {
                        if vm.isSavingBio { ProgressView().tint(Theme.ink) } else { Text("Save") }
                    }
                    .font(.inter(Theme.fontBody, weight: .bold))
                    .foregroundColor(Theme.ink)
                    .frame(minWidth: 88, minHeight: 44)
                    .background(Capsule().fill(Theme.goldGradient))
                    .opacity(vm.canSaveBio ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSaveBio)
                .accessibilityLabel("Save bio")
            }
        }
        .onAppear { focused = true }
    }
}
