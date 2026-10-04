// AccountView+Rewards.swift — owner reward claim row (task 20261001-promo-owner-rewards).
// Shown only when the backend reports a reward summary (flag on) AND the user
// has an earned reward on an Apple subscription. Stripe owners get the discount
// automatically on the web, so nothing is shown for them here. Invitees who are
// brand-new subscribers on iOS cannot get a promotional-offer discount from a
// code (Apple restriction); when IOS_OFFER_CODES_ENABLED is on they redeem a
// one-time Apple offer code instead (AccountView+Invite.swift).

import SwiftUI

extension AccountView {

    @ViewBuilder
    var ownerRewardRow: some View {
        if let reward = vm.rewardSummary, reward.provider == "apple", reward.earned > 0 || vm.rewardMsg != nil {
            Divider().background(Theme.borderGoldFaint)
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                HStack(spacing: Theme.spacingSM) {
                    Image(systemName: "gift.fill").foregroundColor(Theme.gold)
                    Text(reward.earned > 0
                         ? "You earned \(reward.percent_off)% off your next month"
                           + (reward.earned > 1 ? " (\(reward.earned) rewards)" : "")
                         : "Invite reward")
                        .font(.inter(Theme.fontBody)).foregroundColor(Theme.parchment)
                }
                if reward.earned > 0 {
                    Text("Thanks for sharing FellowScript. Claim it to apply the discount to your next renewal.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textMuted)
                    Button { Task { await vm.claimReward() } } label: {
                        ghostPill(vm.rewardBusy ? "Claiming…" : "Claim reward", labelColor: Theme.gold)
                    }
                    .disabled(vm.rewardBusy || vm.subBusy || !reward.can_claim_apple)
                    .accessibilityIdentifier("claimRewardButton")
                }
                if let msg = vm.rewardMsg {
                    Text(msg).font(.inter(Theme.fontSM)).foregroundColor(Theme.textGoldMuted)
                        .accessibilityIdentifier("rewardMessage")
                }
            }
        }
    }
}
