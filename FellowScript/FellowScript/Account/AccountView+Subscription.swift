// AccountView+Subscription.swift — subscription card (active plan, seat
// management, join requests, member-count picker for a new plan, joinable
// friend plans). Split out of AccountView.swift (readability #6, 20260904-
// frontend-arch-sweep) -- same type, same behavior, just this section's own
// file. See AccountView.swift's header comment for the full split rationale
// and the list of sibling section files.

import SwiftUI

extension AccountView {

    /// Scrolls to the subscription card, then clears the one-shot signal.
    func scrollToSubscriptionSection(_ proxy: ScrollViewProxy) {
        upgradeCenter.scrollToSubscription = false
        // Next runloop turn so a just-mounted Account tab has laid out its sections.
        DispatchQueue.main.async {
            if reduceMotion {
                proxy.scrollTo("subscriptionSection", anchor: .top)
            } else {
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("subscriptionSection", anchor: .top) }
            }
        }
    }

    /// "Free plan includes" list, rendered only from the usage payload. Paid-only
    /// rows carry a lock glyph plus text (not colour alone).
    @ViewBuilder
    var freePlanLimitsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FREE PLAN INCLUDES")
                .font(.system(size: Theme.fontXS, weight: .semibold)).tracking(2)
                .foregroundColor(Theme.textGoldMuted)
                .padding(.bottom, Theme.spacingXS)
                .accessibilityAddTraits(.isHeader)
            if let usage = vm.usage {
                ForEach(Array(usage.freePlanRows.enumerated()), id: \.offset) { _, row in
                    freeLimitRow(row)
                    Divider().background(Theme.borderGray)
                }
            } else {
                Text("Loading limits")
                    .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary)
            }
        }
        .accessibilityIdentifier("freePlanLimitsList")
    }

    func freeLimitRow(_ row: FreePlanLimitRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.spacingSM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(.system(size: Theme.fontSM)).foregroundColor(Theme.parchment)
                if let caption = row.caption {
                    Text(caption).font(.system(size: Theme.fontXS)).foregroundColor(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.spacingSM)
            HStack(spacing: 4) {
                if row.locked { Image(systemName: "lock.fill").font(.system(size: 11)).accessibilityHidden(true) }
                Text(row.value).font(.system(size: Theme.fontSM)).multilineTextAlignment(.trailing)
            }
            .foregroundColor(Theme.gold)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Subscription")

            if vm.subLoading {
                HStack { Spacer(); ProgressView().tint(Theme.gold); Spacer() }
            } else if let plan = vm.subscription {
                activePlanRow(plan)
                benefitsDisclosure(memberCount: plan.max_members, isExpanded: $showBenefits)

                if vm.isSubHost && plan.plan_type == "group" {
                    seatManagementRow(plan)

                    if !vm.subMembers.isEmpty {
                        rowCaption("Members (\(vm.subMembers.count)/\(plan.max_members))")
                    }
                    ForEach(vm.subMembers) { memberRow($0) }

                    // Task 20260930-subscription-seat-invites: owner-only link that files
                    // a join request (never membership). Hides itself when the backend
                    // flag is off (uniform 404 from list).
                    if plan.max_members > 1 {
                        Divider().background(Theme.borderGray)
                        InviteLinkSection(
                            service: appState.service, subscriptionId: plan.id,
                            userId: appState.currentUser?.user_id ?? ""
                        )
                        .id(plan.id)
                        Button { Task { await vm.refreshSubRequests() } } label: {
                            Text("Refresh join requests")
                                .font(.system(size: Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold)
                                .frame(minHeight: 44)
                        }
                    }

                    if !vm.subRequests.isEmpty {
                        rowCaption("Join Requests")
                        ForEach(vm.subRequests) { requestRow($0) }
                    }
                }
                ownerRewardRow
                Divider().background(Theme.borderGray)
                managePlanRow(plan)
            } else {
                freePlanLimitsList
                purchaseSurface
                if !vm.joinablePlans.isEmpty {
                    Divider().background(Theme.borderGray)
                    rowCaption("Join a Friend's Group Plan")
                    ForEach(vm.joinablePlans) { joinableRow($0) }
                }
            }

            // Outstanding requests this user has sent.
            if !vm.mySubRequests.isEmpty {
                Divider().background(Theme.borderGray)
                rowCaption("Your Pending Requests")
                ForEach(vm.mySubRequests) { myRequestRow($0) }
            }

            Divider().background(Theme.borderGray)

            // Restore a subscription bought on another device / after reinstall.
            Button { Task { await vm.restorePurchases() } } label: {
                ghostPill("Restore Purchases", labelColor: Theme.textGoldMuted)
            }
            .disabled(vm.subBusy)

            if let msg = vm.subMsg {
                Text(msg)
                    .font(.system(size: Theme.fontSM)).foregroundColor(Theme.error)
                    .padding(.horizontal, Theme.spacingSM).padding(.vertical, Theme.spacingXS + 2)
                    .background(Theme.error.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    // ── Subscription row builders ────────────────────────────────────────────────

    func rowCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.fontSM))
            .foregroundColor(Theme.textMuted)
    }

    func activePlanRow(_ plan: FSSubscription) -> some View {
        HStack(spacing: Theme.spacingMD) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.12)).frame(width: 40, height: 40)
                Image(systemName: vm.isSubHost ? "crown.fill" : "person.3.fill")
                    .foregroundColor(Theme.gold)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Group Plan")
                        .font(.system(size: Theme.fontBody)).foregroundColor(Theme.parchment)
                    let badge = plan.is_trial ? "Free trial" : (vm.autoRenewOff ? "Cancelling" : plan.status.capitalized)
                    Text(badge)
                        .font(.system(size: Theme.fontXXS)).tracking(1)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((vm.autoRenewOff ? Theme.error : Theme.gold).opacity(0.15))
                        .foregroundColor(vm.autoRenewOff ? Theme.error : Theme.gold)
                        .clipShape(Capsule())
                }
                Text("\(plan.priceLabel)/mo · \(vm.isSubHost ? "You are the host" : "Member")"
                     + (plan.plan_type == "group" ? " · up to \(plan.max_members)" : ""))
                    .font(.system(size: Theme.fontXS)).foregroundColor(Theme.textMuted)
                // Trial / next-billing line (host only — they own billing).
                if vm.isSubHost {
                    if vm.autoRenewOff {
                        Text("Auto-renew off · cancels \(Self.mediumDate(vm.planEndDate) ?? plan.nextBillingLabel) · access until then")
                            .font(.system(size: Theme.fontXS)).foregroundColor(Theme.error)
                    } else if !plan.nextBillingLabel.isEmpty {
                        Text(plan.is_trial
                             ? "🎁 \(plan.trial_days_remaining) day\(plan.trial_days_remaining == 1 ? "" : "s") left · first billing \(plan.nextBillingLabel)"
                             : "Next billing \(plan.nextBillingLabel)"
                             + (plan.card_last4.isEmpty ? "" : " · \(plan.card_brand.capitalized) •••• \(plan.card_last4)"))
                            .font(.system(size: Theme.fontXS)).foregroundColor(Theme.textGoldMuted)
                    }
                }
            }
            Spacer()
        }
    }

    func memberRow(_ m: FSSubMember) -> some View {
        HStack(spacing: Theme.spacingSM) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.15)).frame(width: 30, height: 30)
                Text(String(m.username.prefix(1)).uppercased()).font(.system(size: Theme.fontXS, weight: .heavy)).foregroundColor(Theme.gold)
            }
            Text(m.username + (m.user_id == vm.profileData?.user_id ? " (you)" : ""))
                .font(.system(size: Theme.fontSM)).foregroundColor(Theme.parchment)
            Spacer()
            if m.user_id != vm.profileData?.user_id {
                Button { Task { await vm.removeMember(m.user_id) } } label: {
                    Image(systemName: "minus.circle").foregroundColor(Theme.error)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(m.username)")
            }
        }
    }

    // Mirrors the "Label + trailing chevron, plain row" idiom already used by the
    // Blocked Users row (privacySafetySection, AccountView+Misc.swift), swapping
    // chevron.right (navigate) for chevron.down/up (expand/collapse in place): this
    // toggles content inline rather than navigating to another screen.
    func benefitsDisclosure(memberCount: Int, isExpanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS + 2) {
            Button {
                withMotionAwareAnimation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack {
                    Label("What's included", systemImage: "info.circle")
                        .font(.system(size: Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)   // touch-target-size: 44x44pt minimum (Apple HIG)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("whatsIncludedToggle")
            .accessibilityLabel("What's included")
            .accessibilityHint(isExpanded.wrappedValue
                ? "Double tap to collapse the list of plan benefits"
                : "Double tap to expand the list of plan benefits")

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: Theme.spacingXS + 2) {
                    // Numbers come only from the usage payload (never hardcoded);
                    // until it loads the captions stay neutral.
                    benefitRow("Unlimited notes",
                                vm.usage.map { "Free plan: \($0.notes.limit) \($0.windowPhrase)" } ?? "Loading limits")
                    benefitRow("Unlimited scheduled devotions",
                                vm.usage.map { ($0.scheduledDevotionsLocked || $0.agentEvents.limit == 0)
                                    ? "Not included in the Free plan. Subscribers can schedule as many as they like, such as one for morning and one for bedtime."
                                    : "Free plan includes \($0.agentEvents.limit) in total. Paid plans have as many as you like, such as one for morning and one for bedtime." } ?? "Loading limits")
                    if let hosting = vm.usage?.sessions {
                        benefitRow("Unlimited hosted sessions",
                                    "Free plan: \(hosting.limit) at a time. Join as many as you like.")
                    }
                    benefitRow("Session summaries and Explorer publishing",
                                "Included with your plan. Free plan members can still browse and join Explorer.")
                    benefitRow("Shared group access for up to \(memberCount) member\(memberCount == 1 ? "" : "s")",
                                "Unlimited usage is shared across everyone on the plan")
                }
                .padding(.leading, Theme.spacingSM)
                .padding(.top, Theme.spacingXS)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .contain)
            }
        }
    }

    // Reuses the checkmark.circle.fill / Theme.gold pairing already used as an
    // affirmative marker in requestRow's accept button, repurposed here as a
    // static bullet rather than a tappable action.
    func benefitRow(_ title: String, _ caption: String) -> some View {
        HStack(alignment: .top, spacing: Theme.spacingSM) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(Theme.gold)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: Theme.fontSM)).foregroundColor(Theme.parchment)
                Text(caption).font(.system(size: Theme.fontXXS)).foregroundColor(Theme.textMuted)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    func requestRow(_ r: FSSubMember) -> some View {
        HStack(spacing: Theme.spacingSM) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.15)).frame(width: 30, height: 30)
                Text(String(r.username.prefix(1)).uppercased()).font(.system(size: Theme.fontXS, weight: .heavy)).foregroundColor(Theme.gold)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(r.username).font(.system(size: Theme.fontSM)).foregroundColor(Theme.parchment)
                Text("Wants to join").font(.system(size: Theme.fontXS)).foregroundColor(Theme.textMuted)
            }
            Spacer()
            Button { Task { await vm.acceptRequest(r.user_id) } } label: {
                Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.gold)
            }
            .buttonStyle(.borderless).accessibilityLabel("Accept \(r.username)")
            Button { Task { await vm.declineRequest(r.user_id) } } label: {
                Image(systemName: "xmark.circle").foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.borderless).accessibilityLabel("Decline \(r.username)")
        }
    }

    @ViewBuilder
    func managePlanRow(_ plan: FSSubscription) -> some View {
        if vm.isSubHost && plan.provider == "apple" {
            // Apple subscriptions can only be canceled through the App Store.
            Button { Task { await store.showManageSubscriptions() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                    Text("Manage Subscription").font(.system(size: Theme.fontSM))
                }
                .foregroundColor(Theme.gold)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
            }
        } else {
            Button {
                Task { if vm.isSubHost { await vm.cancelPlan() } else { await vm.leavePlan() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: vm.isSubHost ? "trash" : "rectangle.portrait.and.arrow.right")
                    Text(vm.isSubHost ? "Cancel Plan" : "Leave Plan").font(.system(size: Theme.fontSM))
                }
                .foregroundColor(Theme.error)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(Capsule().stroke(Theme.error.opacity(0.4), lineWidth: 1))
            }
            .disabled(vm.subBusy)
        }
    }

    /// Which purchase UI the free-user card shows (task 20261117-web-only-payments).
    /// US storefront: the web checkout button. Everything else, including an unknown
    /// storefront: the StoreKit picker exactly as before. An active Apple plan never
    /// gets an upsell.
    @ViewBuilder
    var purchaseSurface: some View {
        switch WebCheckoutPolicy.surface(gate: webGate.state, hasActiveApplePlan: false, quoteBlockedByApple: false) {
        case .resolving:
            HStack { Spacer(); ProgressView().tint(Theme.gold); Spacer() }
                .frame(minHeight: 120)
                .accessibilityLabel("Loading")
        case .storeKit:
            rowCaption("Start with a free 1-month trial — you won't be billed until it ends.")
            memberCountPickerRow()
        case .web, .appleManaged:
            // The section itself swaps to the Apple-managed notice when the server
            // quote says an Apple plan is active.
            WebCheckoutSection()
        }
    }

    func memberCountPickerRow() -> some View {
        // StoreKit's localized price only; until products load the title carries no price.
        let priceSuffix = store.displayPrice(for: selectedMemberCount).map { " — \($0)/mo" } ?? ""
        return VStack(alignment: .leading, spacing: Theme.spacingSM) {
            HStack(spacing: Theme.spacingMD) {
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.12)).frame(width: 36, height: 36)
                    Image(systemName: "person.3.fill").foregroundColor(Theme.gold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group\(priceSuffix)")
                        .font(.system(size: Theme.fontBody)).foregroundColor(Theme.parchment)
                    Text("Free for 1 month · choose 1-8 members")
                        .font(.system(size: Theme.fontXS)).foregroundColor(Theme.textMuted)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Members").font(.fsLabel).foregroundColor(Theme.textPrimary)
                FSNumberStepper(value: $selectedMemberCount, range: 1...8, unit: selectedMemberCount == 1 ? "member" : "members")
            }
            benefitsDisclosure(memberCount: selectedMemberCount, isExpanded: $showBenefits)
            Button {
                Task { await vm.purchasePlan(memberCount: selectedMemberCount) }
            } label: {
                gradientPill("Start", compact: true)
            }
            // Stay tappable even if products haven't loaded — purchasePlan
            // surfaces a clear message instead of the button silently failing.
            .disabled(vm.subBusy || store.purchasing)

            // Guideline 3.1.2: the purchase surface itself must clearly and
            // conspicuously link to the Privacy Policy / Terms of Use, not
            // only from privacySafetySection/legalSection further down this
            // same scrollable screen (ios-guidelines High #3 / intake H14).
            HStack(spacing: 6) {
                Link("Privacy Policy", destination: URL(string: "https://fellowscript.com/#/privacy")!)
                Text("·").foregroundColor(Theme.textMuted)
                Link("Terms of Use", destination: URL(string: "https://fellowscript.com/#/terms")!)
            }
            .font(.system(size: Theme.fontXXS))
            .foregroundColor(Theme.textGoldMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .contain)
        }
    }

    /// Seat changes are billed where the plan was bought, never in the app
    /// (task 20261117-web-only-payments). Apple plans: manage in Apple Settings.
    /// Stripe plans: a web link in the US storefront only; elsewhere nothing.
    @ViewBuilder
    func seatManagementRow(_ plan: FSSubscription) -> some View {
        if plan.provider == "apple" {
            Text("To change seats, manage your plan in Apple Settings. Your plan renews through Apple.")
                .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textMuted)
                .accessibilityIdentifier("appleManagedNotice")
        } else if plan.provider == "stripe" && webGate.isEnabled {
            Link(destination: WebCheckoutPolicy.manageURL) {
                HStack(spacing: 6) {
                    Text("Manage plan on the web").font(.system(size: Theme.fontSM, weight: .semibold))
                    Image(systemName: "arrow.up.right.square").accessibilityHidden(true)
                }
                .foregroundColor(Theme.gold)
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("webCheckoutManage")
        }
    }

    func joinableRow(_ j: FSJoinablePlan) -> some View {
        let pending = vm.mySubRequests.contains { $0.subscription_id == j.plan.id }
        return HStack(spacing: Theme.spacingSM) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.15)).frame(width: 30, height: 30)
                Text(String(j.hostName.prefix(1)).uppercased()).font(.system(size: Theme.fontXS, weight: .heavy)).foregroundColor(Theme.gold)
            }
            Text("\(j.hostName)'s Group · \(j.memberCount)/\(j.plan.max_members)")
                .font(.system(size: Theme.fontSM)).foregroundColor(Theme.parchment)
            Spacer()
            Button(pending ? "Requested" : "Request") { Task { await vm.requestJoin(j.plan.id) } }
                .font(.system(size: Theme.fontXS)).foregroundColor(pending ? Theme.textMuted : Theme.gold)
                .buttonStyle(.borderless).disabled(pending || vm.subBusy)
        }
    }

    func myRequestRow(_ r: FSSubRequest) -> some View {
        HStack {
            Image(systemName: "clock").foregroundColor(Theme.textGoldMuted)
            Text("Pending group plan request").font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary)
            Spacer()
            Button("Cancel") { Task { await vm.cancelMyRequest(r.subscription_id) } }
                .font(.system(size: Theme.fontXS)).foregroundColor(Theme.textMuted).buttonStyle(.borderless)
        }
    }

    /// "Aug 15, 2026" for a Date, or nil. Used for the Apple auto-renew-off line.
    static func mediumDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: date)
    }
}
