// Guideline 1.2: blocking re-consent screen shown when AppState.termsReacceptRequired
// is set — the account predates a material Terms of Service change and must
// re-accept before continuing to use the app.

import SwiftUI

struct TermsReacceptView: View {
    @EnvironmentObject var appState: AppState
    @State private var agreeing = false
    @State private var errorMessage: String?

    var body: some View {
        FSAuthScaffold(
            title: "Our Terms of Service have been updated",
            subtitle: "We've clarified our zero-tolerance policy for objectionable content and abusive behavior, including new in-app reporting and blocking tools. Please review our updated Terms of Service before continuing.",
            errorMessage: errorMessage,
            primaryTitle: "I Agree",
            saving: agreeing,
            onPrimary: { if !agreeing { accept() } }
        ) {
            Link("Read the updated Terms of Service",
                 destination: URL(string: "https://fellowscript.com/#/terms")!)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.gold)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func accept() {
        Task {
            agreeing = true
            errorMessage = nil
            do {
                try await appState.acceptTerms()
            } catch {
                // Keep the blocking gate up — don't let a failed
                // acceptance silently look like it succeeded.
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't save your acceptance. Please try again."
            }
            agreeing = false
        }
    }
}
