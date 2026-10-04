// AccountView+Invite.swift — friend invite code surfaces (task
// 20261003-ios-friend-offer-code-redeem, design-notes.md).
//   redeemInviteSection  "Have a friend's invite code?" (new subscribers)
//   shareInviteSection   "Share your invite code" (owner)
// Both hide entirely on the backend's uniform 404 (flag off). The Apple offer
// code is never displayed; see InviteCodeViewModel.

import SwiftUI

extension AccountView {

    // ── A. Redeem ───────────────────────────────────────────────────────────

    @ViewBuilder
    var redeemInviteSection: some View {
        if !invite.redeemHidden {
            Divider().background(Theme.borderGoldFaint)
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                Button {
                    if reduceMotion { showInviteField.toggle() }
                    else { withAnimation(.easeInOut(duration: 0.2)) { showInviteField.toggle() } }
                } label: {
                    HStack(spacing: Theme.spacingSM) {
                        Image(systemName: "gift.fill").foregroundColor(Theme.gold)
                        Text("Have a friend's invite code?")
                            .font(.inter(Theme.fontBody)).foregroundColor(Theme.parchment)
                        Spacer()
                        Image(systemName: showInviteField ? "chevron.up" : "chevron.down")
                            .foregroundColor(Theme.textMuted)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("inviteCodeDisclosure")

                if showInviteField { redeemFields }
            }
        }
    }

    @ViewBuilder
    private var redeemFields: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            Text("Invite code").font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
            TextField("", text: $invite.codeInput)
                .font(.inter(Theme.fontBody, weight: .semibold))
                .foregroundColor(Theme.parchment)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .textContentType(.none)
                .keyboardType(.asciiCapable)
                .submitLabel(.go)
                .onSubmit { startRedeem() }
                .disabled(invite.redeemBusy)
                .padding(Theme.spacingSM)
                .background(Theme.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                    .stroke(invite.redeemMsg == nil ? Theme.borderGoldDim : Theme.error, lineWidth: 1))
                .accessibilityLabel("Invite code")
                .accessibilityIdentifier("inviteCodeField")
            Text("Get 50% off your first month. New subscribers only.")
                .font(.interScaled(Theme.fontXS)).foregroundColor(Theme.textSecondary)
            if let info = invite.redeemInfo, invite.redeemMsg == nil {
                Text(info).font(.interScaled(Theme.fontXS)).foregroundColor(Theme.textGoldMuted)
            }
            if let msg = invite.redeemMsg {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(msg)
                }
                .font(.interScaled(Theme.fontSM)).foregroundColor(Theme.error)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("inviteCodeError")
            }
            Button { startRedeem() } label: {
                HStack(spacing: 6) {
                    if invite.redeemBusy { ProgressView().tint(Theme.ink) }
                    Text(invite.redeemBusy ? "Checking…" : "Apply code")
                        .font(.inter(Theme.fontSM, weight: .semibold))
                }
                .foregroundColor(Theme.ink)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .background(Capsule().fill(Theme.gold))
            }
            .disabled(invite.redeemBusy || InviteCodeViewModel.normalize(invite.codeInput).isEmpty)
            .opacity(InviteCodeViewModel.normalize(invite.codeInput).isEmpty ? 0.5 : 1)
            .accessibilityIdentifier("applyInviteCodeButton")
        }
    }

    private func startRedeem() {
        guard let uid = appState.currentUser?.user_id else { return }
        invite.service = appState.service
        Task {
            await invite.redeem(userId: uid) {
                // Resync entitlements once so a completed redemption shows up.
                await store.syncEntitlements(userId: uid, service: appState.service)
                await vm.loadSubscription(userId: uid)
            }
        }
    }

    // ── B. Share ────────────────────────────────────────────────────────────

    @ViewBuilder
    var shareInviteSection: some View {
        if !invite.shareHidden {
            Divider().background(Theme.borderGoldFaint)
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                Text("Share your invite code")
                    .font(.playfair(18)).foregroundColor(Theme.parchment)
                    .accessibilityAddTraits(.isHeader)
                if let fc = invite.friendCode {
                    Text("Friends get \(fc.percent_off)% off their first month. When they subscribe you earn a reward.")
                        .font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
                    Text(fc.code)
                        .font(.playfair(Theme.fontDisplayMD)).tracking(2)
                        .foregroundColor(Theme.gold)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity).padding(Theme.spacingSM)
                        .background(Theme.inputBg)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGold, lineWidth: 1))
                        .accessibilityLabel("Your invite code, \(fc.code.map(String.init).joined(separator: " "))")
                        .accessibilityIdentifier("inviteCodeValue")
                    if invite.friendCodeFailed {
                        Text("Couldn't refresh. Showing your saved code.")
                            .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    }
                    HStack(spacing: Theme.spacingSM) {
                        Button {
                            UIPasteboard.general.string = fc.code
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            codeCopied = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                codeCopied = false
                            }
                        } label: {
                            ghostPill(codeCopied ? "Copied" : "Copy code",
                                      labelColor: codeCopied ? Theme.success : Theme.gold)
                        }
                        .accessibilityIdentifier("copyInviteCodeButton")
                        if let link = URL(string: fc.link) {
                            ShareLink(item: link, message: Text("Join me on FellowScript, use my code \(fc.code)")) {
                                gradientPill("Share link")
                            }
                            .accessibilityIdentifier("shareInviteLinkButton")
                        }
                    }
                } else if invite.friendCodeLoading {
                    RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.inputBg).frame(height: 56)
                        .accessibilityHidden(true)
                } else if invite.friendCodeFailed {
                    Text("Couldn't load your invite code.")
                        .font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
                    Button {
                        Task { await invite.loadFriendCode(userId: appState.currentUser?.user_id ?? "") }
                    } label: { ghostPill("Try again", labelColor: Theme.gold) }
                }
            }
            .accessibilityIdentifier("shareInviteSection")
        }
    }
}
