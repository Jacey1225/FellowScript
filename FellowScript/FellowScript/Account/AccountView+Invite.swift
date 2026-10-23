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
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                Button {
                    if reduceMotion { showInviteField.toggle() }
                    else { withAnimation(.easeInOut(duration: 0.2)) { showInviteField.toggle() } }
                } label: {
                    HStack(spacing: Theme.spacingSM) {
                        Image(systemName: "gift.fill").foregroundColor(Theme.gold)
                        Text("Have a friend's invite code?")
                            .font(.system(size: Theme.fontBody)).foregroundColor(Theme.parchment)
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
            FSField(label: "Invite code", text: $invite.codeInput,
                    helper: invite.redeemMsg == nil ? "Get 50% off your first month. New subscribers only." : nil,
                    state: invite.redeemMsg.map { FSFieldState.error($0) } ?? .normal,
                    accessibilityName: "Invite code", accessibilityId: "inviteCodeField", errorAccessibilityId: "inviteCodeError",
                    keyboard: .asciiCapable, capitalization: .characters, autocorrect: false,
                    submitLabel: .go, onSubmit: { startRedeem() })
                .disabled(invite.redeemBusy)
            if let info = invite.redeemInfo, invite.redeemMsg == nil {
                Text(info).font(.system(size: Theme.fontXS)).foregroundColor(Theme.textGoldMuted)
            }
            Button { startRedeem() } label: {
                HStack(spacing: 6) {
                    if invite.redeemBusy { ProgressView().tint(Theme.ink) }
                    Text(invite.redeemBusy ? "Checking…" : "Apply code")
                        .font(.system(size: Theme.fontSM, weight: .semibold))
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
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                if let fc = invite.friendCode {
                    Text("Friends get \(fc.percent_off)% off their first month. You earn a reward when they subscribe.")
                        .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary)
                    HStack(spacing: Theme.spacingSM) {
                        Text(fc.code)
                            .font(.system(size: Theme.fontBody, weight: .semibold)).tracking(2)
                            .foregroundColor(Theme.gold)
                            .textSelection(.enabled)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Your invite code, \(fc.code.map(String.init).joined(separator: " "))")
                            .accessibilityIdentifier("inviteCodeValue")
                        Button {
                            UIPasteboard.general.string = fc.code
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            codeCopied = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                codeCopied = false
                            }
                        } label: {
                            Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(codeCopied ? Theme.success : Theme.gold)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(codeCopied ? "Copied" : "Copy code")
                        .accessibilityIdentifier("copyInviteCodeButton")
                    }
                    .padding(.leading, Theme.spacingSM)
                    .background(Theme.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.fieldBorder, lineWidth: 1))
                    if invite.friendCodeFailed {
                        Text("Couldn't refresh. Showing your saved code.")
                            .font(.system(size: Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    }
                    if let link = URL(string: fc.link) {
                        ShareLink(item: link, message: Text("Join me on FellowScript, use my code \(fc.code)")) {
                            gradientPill("Share link").frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("shareInviteLinkButton")
                    }
                } else if invite.friendCodeLoading {
                    RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.fieldFill).frame(height: 44)
                        .accessibilityHidden(true)
                } else if invite.friendCodeFailed {
                    Text("Couldn't load your invite code.")
                        .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary)
                    Button {
                        Task { await invite.loadFriendCode(userId: appState.currentUser?.user_id ?? "") }
                    } label: { ghostPill("Try again", labelColor: Theme.gold) }
                }
            }
            .accessibilityIdentifier("shareInviteSection")
        }
    }

    // ── C. Card ─────────────────────────────────────────────────────────────

    /// Standalone "Invite a Friend" card, placed between Subscription and Plan
    /// Usage like every other Account section. Hidden when neither half applies.
    @ViewBuilder
    var inviteCard: some View {
        let showRedeem = vm.subscription == nil && !invite.redeemHidden
        let showShare = !invite.shareHidden
        if !vm.subLoading && (showRedeem || showShare) {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                sectionLabel("Invite a Friend")
                    .accessibilityAddTraits(.isHeader)
                if showShare { shareInviteSection }
                if showRedeem {
                    if showShare { Divider().background(Theme.borderGray) }
                    redeemInviteSection
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .glassCard(cornerRadius: 20)
        }
    }
}
