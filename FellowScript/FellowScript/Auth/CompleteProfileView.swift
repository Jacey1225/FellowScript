// Shown when AppState.needsProfileCompletion is set — an Apple sign-in created
// this account without a real name/email. Apple only ever supplies those on the
// very first authorization for a given Apple ID + app, so if that grant was
// missed there is no way to ask Apple for it again; the user sets them here
// instead.

import SwiftUI

struct CompleteProfileView: View {
    @EnvironmentObject var appState: AppState
    @State private var username = ""
    @State private var email    = ""
    @State private var errorMsg: String?
    @State private var saving   = false

    private var formValid: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@")
    }

    var body: some View {
        FSAuthScaffold(
            title: "Finish setting up your account",
            subtitle: "Apple didn't share a name or email for this sign-in, so we couldn't set them up for you. Please choose a username and email to continue — this only needs to happen once.",
            errorMessage: errorMsg,
            primaryTitle: "Continue",
            primaryDimmed: !formValid,
            saving: saving,
            onPrimary: { if formValid && !saving { submit() } }
        ) {
            VStack(spacing: Theme.spacingMD) {
                FSField(label: "Username", required: true, text: $username, leadingSymbol: "person",
                        contentType: .username, capitalization: .never, autocorrect: false)
                FSField(label: "Email", required: true, text: $email, leadingSymbol: "envelope",
                        contentType: .emailAddress, keyboard: .emailAddress,
                        capitalization: .never, autocorrect: false)
            }
        }
        // Shared keyboard-dismiss convention (task 20260831-interaction-polish-conventions).
        .dismissesKeyboardOnScrollAndTap()
    }

    private func submit() {
        errorMsg = nil
        Task {
            saving = true
            defer { saving = false }
            do {
                try await appState.completeProfile(
                    username: username.trimmingCharacters(in: .whitespaces),
                    email: email.trimmingCharacters(in: .whitespaces)
                )
            } catch {
                errorMsg = error.localizedDescription
            }
        }
    }
}
