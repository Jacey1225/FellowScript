// Guideline 1.2: blocking re-consent screen shown when AppState.termsReacceptRequired
// is set — the account predates a material Terms of Service change and must
// re-accept before continuing to use the app.

import SwiftUI

struct TermsReacceptView: View {
    @EnvironmentObject var appState: AppState
    @State private var agreeing = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            VStack(spacing: Theme.spacingLG) {
                Spacer()

                Text("Our Terms of Service have been updated")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment)
                    .multilineTextAlignment(.center)

                Text("We've clarified our zero-tolerance policy for objectionable content and abusive behavior, including new in-app reporting and blocking tools. Please review our updated Terms of Service before continuing.")
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingLG)

                Link("Read the updated Terms of Service",
                     destination: URL(string: "https://fellowscript.com/#/terms")!)
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.gold)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.lora(Theme.fontSM))
                        .foregroundColor(Theme.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.spacingLG)
                }

                Spacer()

                Button(action: {
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
                }) {
                    HStack {
                        if agreeing { ProgressView().tint(Theme.ink) }
                        Text("I Agree").font(.lora(Theme.fontSM)).bold()
                    }
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacingMD)
                    .background(Theme.gold)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                .disabled(agreeing)
                .padding(.horizontal, Theme.spacingLG)
                .padding(.bottom, Theme.spacingXL)
                .accessibilityLabel("I Agree to the updated Terms of Service")
            }
        }
    }
}
