// SOURCE: frontend/src/pages/Account.jsx
// KEY STATE: profileData, agents, events, requests, editLoading, deleteConfirm, agentModal
// INTERACTIONS: edit profile (username/email/password), accept friend requests,
//               create/toggle/delete agents, create/delete events, sign out, delete account
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift

import SwiftUI
import Combine

// A friend's group plan that still has room, surfaced so the user can request to join.
struct FSJoinablePlan: Identifiable {
    let plan: FSSubscription
    let hostName: String
    let memberCount: Int
    var id: String { plan.id }
}

@MainActor
final class AccountViewModel: ObservableObject {
    var service: DataServiceProtocol = MockDataService.shared

    @Published var profileData:     FSUser?          = nil
    @Published var agents:          [FSAgent]         = []
    @Published var events:          [FSHeartbeat]     = []
    // Task 20260902-group-tagged-devotions: the user's own groups, keyed by
    // id, for EventSetupSheet's gold group-picker button. Sourced from the
    // existing NetworkService.fetchContacts(userId:) call in load() below
    // rather than a second fetch path.
    @Published var groups:          [String: FSGroup] = [:]
    @Published var friendRequests:  [(id: String, username: String)] = []
    @Published var isLoading       = true
    @Published var editMsg:        (type: AlertType, text: String)? = nil

    enum AlertType { case success, error, warning }

    var friendCount: Int { profileData?.friends.count ?? 0 }
    var groupCount:  Int { profileData?.groups.count  ?? 0 }
    @Published var noteCount:      Int = 0
    @Published var highlightCount: Int = 0

    // Free-tier usage (nil = not loaded / unavailable)
    @Published var usage:    FSUsage? = nil
    @Published var limitMsg: String?  = nil   // shown when a create hits the free-tier cap
    // Shown when an agent create/toggle/rename/event-update is rejected by the
    // backend — these used to apply an optimistic local mutation via bare
    // `try?` and never surface the failure, silently drifting the UI from
    // server state. Separate from limitMsg (which is titled "Free Plan Limit"
    // specifically) since these failures aren't always cap-related.
    @Published var agentMsg:  String?  = nil
    // Same idea, for the friend-request accept flow (compile-errors #2) — a
    // failed accept must surface something rather than silently vanishing
    // the request from the UI.
    @Published var friendMsg: String?  = nil
    // Shown when the notes-count/highlights/agents fetch genuinely fails
    // (network/HTTP error or decode failure) on the *current* load() call —
    // task 20260903-account-stats-not-loading. Previously these three
    // silently collapsed to 0/empty on any failure, which looked visually
    // identical to the account genuinely having no notes/highlights/agents.
    @Published var statsMsg: String?  = nil

    // Bumped at the start of every load() call; a call only commits its
    // results if it's still the most recent one when it finishes. See
    // load()'s own comment for why this is needed.
    private var loadGeneration = 0

    // Manual "execute now" heartbeat trigger (task
    // 20260901-heartbeat-manual-trigger-button). Heartbeat ids currently
    // mid-fire, so the per-row button can disable itself and show a spinner
    // instead of allowing a double-tap to race two requests for the same
    // heartbeat.
    @Published var firingHeartbeatIds: Set<String> = []
    // Non-error, self-dismissing confirmation shown in the Events section
    // for a manual fire's success/already-fired-today outcome — distinct
    // from limitMsg/agentMsg, which are reserved (per this screen's existing
    // convention) for the free-tier cap and genuine failures respectively.
    @Published var eventFireMsg: (type: AlertType, text: String)? = nil

    // Subscription
    @Published var subscription:   FSSubscription? = nil
    @Published var subMembers:     [FSSubMember]   = []   // group members (host view)
    @Published var subRequests:    [FSSubMember]   = []   // incoming join requests (host view)
    @Published var mySubRequests:  [FSSubRequest]  = []   // this user's outstanding requests
    @Published var joinablePlans:  [FSJoinablePlan] = []  // friends' group plans with room
    @Published var subLoading      = true
    @Published var subBusy         = false
    @Published var subMsg: String? = nil
    // Apple plan that was cancelled (auto-renew off) but still in its paid period.
    @Published var autoRenewOff    = false
    @Published var planEndDate: Date? = nil

    var isSubHost: Bool { subscription?.isHost(profileData?.user_id ?? "") ?? false }

    /// Authoritative "has an unlimited (paid) plan" for the UI. Matches the
    /// server's enforcement criterion exactly (a plan in `trialing`/`active`
    /// status grants unlimited; `past_due`/other do not, and the server still
    /// caps them). The subscription record — loaded *after* StoreKit entitlement
    /// sync — is the source of truth; the usage payload's `subscribed` flag is a
    /// fallback because it can be fetched before that sync and momentarily read
    /// "free" on a cold launch.
    var hasUnlimitedPlan: Bool {
        if let s = subscription?.status, s == "trialing" || s == "active" { return true }
        return usage?.subscribed ?? false
    }

    func load(service: DataServiceProtocol, user: FSUser) async {
        self.service = service
        isLoading = true
        defer { isLoading = false }
        profileData = user
        let uid = user.user_id

        // Re-entrancy guard (task 20260903-account-stats-not-loading):
        // load() can run more than once concurrently -- the initial `.task`
        // on AccountView's mount plus a `.refreshable` pull (or a `.task`
        // re-fire), with no de-duplication between them. Previously every
        // invocation unconditionally overwrote noteCount/highlightCount/
        // agents/events (and their DiskCache entries) with whatever ITS OWN
        // fetch produced -- including the `?? 0`/`?? []` fallback of a call
        // that failed or got cancelled mid-flight. Whichever call happened
        // to *finish* last won, even if it was the failing one, so a
        // slower/cancelled call could silently clobber a faster, fully
        // correct call's results. And because the clobbered (zeroed) result
        // was also the one written to the cache, the bad zero then
        // persisted into the very next load's cache-first read too.
        // `generation` makes each call check, right before it commits
        // anything, whether a newer call has since started; if so it
        // discards its own now-stale result instead of writing it anywhere.
        loadGeneration += 1
        let generation = loadGeneration

        // ── Cache-first: show last-known account data instantly ──────────────────
        if let cached: FSUser = await DiskCache.shared.load(FSUser.self, forKey: "user:\(uid)") {
            profileData = cached
        }
        if let cached: [FSAgent] = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(uid)") {
            agents = cached
        }
        if let cached: [FSHeartbeat] = await DiskCache.shared.load([FSHeartbeat].self, forKey: "events:\(uid)") {
            events = cached
        }
        if let cached: [Int] = await DiskCache.shared.load([Int].self, forKey: "counts:\(uid)"), cached.count == 2 {
            noteCount = cached[0]; highlightCount = cached[1]
        }

        async let fetchedUser          = service.fetchUser(userId: user.user_id)
        async let fetchedAgents        = service.fetchAgents(userId: user.user_id)
        // Dedicated COUNT(*) endpoint rather than fetching+counting the
        // capped/paginated notes collection -- a user with more than one
        // page of notes would otherwise show a truncated total here.
        async let fetchedNoteCount     = service.fetchNotesCount(userId: user.user_id)
        async let fetchedHighlights    = service.fetchHighlights(userId: user.user_id)
        async let fetchedUsage         = service.fetchUsage(userId: user.user_id)
        // Reused for the event-setup group picker (see `groups` above) --
        // no dedicated group-listing fetch is added for this.
        async let fetchedContacts      = service.fetchContacts(userId: user.user_id)

        // Resolve everything into LOCAL results first -- not @Published --
        // so a superseded call's failures never touch shared state before
        // the generation check below. `statsFailed` distinguishes "this
        // fetch genuinely threw" from "this account really has zero", which
        // a bare `?? 0`/`?? []` can't do.
        let userResult = try? await fetchedUser

        var statsFailed = false
        let agentsResult: [FSAgent]
        do { agentsResult = try await fetchedAgents } catch { agentsResult = []; statsFailed = true }
        let noteCountResult: Int
        do { noteCountResult = try await fetchedNoteCount } catch { noteCountResult = 0; statsFailed = true }
        let highlightCountResult: Int
        do { highlightCountResult = try await (fetchedHighlights).count } catch { highlightCountResult = 0; statsFailed = true }

        let usageResult          = try? await fetchedUsage
        let friendRequestsResult = (try? await service.fetchFriendRequests(userId: user.user_id)) ?? []
        let contactsResult       = try? await fetchedContacts

        var allEvents: [FSHeartbeat] = []
        await withTaskGroup(of: [FSHeartbeat].self) { group in
            for agent in agentsResult {
                group.addTask {
                    (try? await service.fetchHeartbeats(userId: user.user_id, agentId: agent.id)) ?? []
                }
            }
            for await hbs in group { allEvents.append(contentsOf: hbs) }
        }

        // A newer load() call has started since this one began -- discard
        // this call's results entirely instead of letting a stale call
        // overwrite whatever the newer call already committed (or is about
        // to). This is what actually fixes the persistent-zero bug: the
        // slower of two overlapping calls no longer wins just by finishing last.
        guard generation == loadGeneration else { return }

        if let userResult { profileData = userResult }
        agents         = agentsResult
        noteCount      = noteCountResult
        highlightCount = highlightCountResult
        usage          = usageResult ?? usage
        friendRequests = friendRequestsResult
        if let (_, groupMap) = contactsResult { groups = groupMap }
        events = allEvents

        // A genuine fetch/decode failure on notes/highlights/agents no
        // longer looks visually identical to "this account has none" --
        // surface it via this screen's existing alert convention. Pull-to-
        // refresh (already on this screen) is the retry path; no new
        // bespoke retry control is introduced.
        if statsFailed {
            statsMsg = "We couldn't load some of your notes, highlights, or agents just now. Pull down to refresh and try again."
        }

        // ── Write fresh account data back to the cache ────────────────────────────
        if let fresh = profileData { await DiskCache.shared.save(fresh, forKey: "user:\(uid)") }
        await DiskCache.shared.save(agents,        forKey: "agents:\(uid)")
        await DiskCache.shared.save(events,        forKey: "events:\(uid)")
        await DiskCache.shared.save([noteCount, highlightCount], forKey: "counts:\(uid)")
    }

    /// Re-fetch the free-tier usage snapshot (after a create/delete changes counts).
    func refreshUsage() async {
        guard let uid = profileData?.user_id else { return }
        if let fresh = try? await service.fetchUsage(userId: uid) { usage = fresh }
    }

    func createEvent(agentId: String, prompt: String, timestamps: [String?], groupId: String? = nil, notesPublic: Bool = false) async {
        guard let uid = profileData?.user_id else { return }
        let hb = FSHeartbeat(id: UUID().uuidString, agent_id: agentId, user_id: uid,
                             timestamps: timestamps, prompt: prompt, group_id: groupId, notes_public: notesPublic)
        do {
            try await service.addHeartbeat(userId: uid, agentId: agentId, heartbeat: hb)
            events.append(hb)
            await refreshUsage()
        } catch {
            // Free-tier cap (or other failure): don't add the event, tell the user.
            limitMsg = (error as? LocalizedError)?.errorDescription ?? "Could not create event."
        }
    }

    /// Manually fires a single heartbeat on demand (task
    /// 20260901-heartbeat-manual-trigger-button), via the same server-side
    /// endpoint/code path the scheduler uses for automatic due firing. As of
    /// task 20260901-heartbeat-manual-force-fire, this always sends a forced
    /// request (NetworkService.commitHeartbeat sends `"force": true`
    /// unconditionally), so it succeeds even if this heartbeat already fired
    /// today — by schedule or an earlier manual force-fire — without
    /// disturbing the scheduler's own once-per-day claim.
    /// Distinguishes the endpoint's four possible outcomes rather than
    /// collapsing them into one generic message:
    ///   - success            → refreshUsage() (mirrors createEvent) + a
    ///                          self-dismissing eventFireMsg confirmation.
    ///   - {"skipped": ...}   → NOTE: this can no longer mean "already fired
    ///                          today" (force bypasses that gate entirely) —
    ///                          it now only means the server's narrower
    ///                          same-instant concurrent-forced-fire guard
    ///                          denied this request (e.g. two devices tapping
    ///                          within the same instant, slipping past this
    ///                          client's own firingHeartbeatIds guard). Still
    ///                          a non-error eventFireMsg, not a failure.
    ///                          PROPOSED COPY, pending explicit approval per
    ///                          this task's UX creative-freedom preference
    ///                          (not silently finalized) — see frontend.json.
    ///   - 403 (notes cap)    → limitMsg, the same "Free Plan Limit" alert
    ///                          createEvent already uses.
    ///   - anything else      → agentMsg, the same "Agent Error" alert other
    ///                          event mutations already use. This also covers
    ///                          an in-band `{"error": ...}` response body
    ///                          (e.g. an unowned/missing heartbeat, or an
    ///                          upstream LLM failure) that the server returns
    ///                          with a 200 rather than throwing.
    func fireHeartbeatNow(_ event: FSHeartbeat) async {
        guard let uid = profileData?.user_id else { return }
        // Guards the double-tap race directly (rather than merely disabling
        // the button visually): a second call for the same heartbeat while
        // one is already in flight is a no-op.
        guard !firingHeartbeatIds.contains(event.id) else { return }
        firingHeartbeatIds.insert(event.id)
        do {
            let result = try await service.commitHeartbeat(
                userId: uid, agentId: event.agent_id, heartbeatId: event.id, prompt: event.prompt
            )
            firingHeartbeatIds.remove(event.id)
            if result["skipped"] != nil {
                // "Already fired today" is no longer a possible/accurate
                // reason for a manual tap now that it always force-fires —
                // the only remaining skip case is the narrower same-instant
                // race. See PROPOSED COPY note above.
                showEventFireMsg(.warning, "Already firing — try again in a moment.")
            } else if let serverError = result["error"] {
                agentMsg = serverError
            } else {
                await refreshUsage()
                showEventFireMsg(.success, "Event fired — check your notes.")
            }
        } catch let error as AppError {
            firingHeartbeatIds.remove(event.id)
            if case .limitReached = error {
                limitMsg = error.errorDescription ?? "You've reached your free plan limit for notes."
            } else {
                agentMsg = error.errorDescription ?? "Could not fire event."
            }
        } catch {
            firingHeartbeatIds.remove(event.id)
            agentMsg = (error as? LocalizedError)?.errorDescription ?? "Could not fire event."
        }
    }

    /// Shows a self-dismissing eventFireMsg (mirrors saveProfile's identical
    /// editMsg-clearing delay elsewhere in this view). Only clears if it's
    /// still the same message by the time the delay elapses, so a fast
    /// second fire's message isn't clobbered by the first one's timer.
    private func showEventFireMsg(_ type: AlertType, _ text: String) {
        eventFireMsg = (type, text)
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if eventFireMsg?.text == text { eventFireMsg = nil }
        }
    }

    func removeEvent(_ event: FSHeartbeat) {
        guard let uid = profileData?.user_id else { return }
        let previous = events
        events.removeAll { $0.id == event.id }
        Task {
            do {
                try await service.deleteHeartbeat(userId: uid, agentId: event.agent_id, heartbeatId: event.id)
            } catch {
                // Revert the optimistic removal so the UI and server can't
                // permanently disagree with no signal to the user (compile-errors #2).
                events = previous
                agentMsg = (error as? LocalizedError)?.errorDescription ?? "Could not delete event."
            }
        }
    }

    func updateEvent(_ event: FSHeartbeat, agentId: String, prompt: String, timestamps: [String?], groupId: String? = nil, notesPublic: Bool = false) async {
        guard let uid = profileData?.user_id else { return }
        let updated = FSHeartbeat(id: event.id, agent_id: agentId, user_id: uid,
                                  timestamps: timestamps, prompt: prompt, group_id: groupId, notes_public: notesPublic)
        do {
            try await service.updateHeartbeat(userId: uid, heartbeatId: event.id, heartbeat: updated)
            if let i = events.firstIndex(where: { $0.id == event.id }) {
                events[i] = updated
            }
        } catch {
            // Server rejected the edit — leave the pre-existing event untouched
            // rather than applying it locally, and tell the user.
            agentMsg = (error as? LocalizedError)?.errorDescription ?? "Could not save event."
        }
    }

    func toggleAgent(id: String, enabled: Bool) {
        guard let uid = profileData?.user_id else { return }
        let previous = agents.first { $0.id == id }?.enabled
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].enabled = enabled
        }
        Task {
            do {
                try await service.updateAgent(userId: uid, agentId: id, enabled: enabled)
            } catch {
                // Revert the optimistic toggle so the switch reflects reality.
                if let i = agents.firstIndex(where: { $0.id == id }), let previous {
                    agents[i].enabled = previous
                }
                agentMsg = (error as? LocalizedError)?.errorDescription ?? "Could not update agent."
            }
        }
    }

    func renameAgent(id: String, name: String) {
        guard let uid = profileData?.user_id else { return }
        let previous = agents.first { $0.id == id }?.name
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].name = name
        }
        Task {
            do {
                try await service.renameAgent(userId: uid, agentId: id, name: name)
            } catch {
                // Revert the optimistic rename.
                if let i = agents.firstIndex(where: { $0.id == id }) {
                    agents[i].name = previous ?? ""
                }
                agentMsg = (error as? LocalizedError)?.errorDescription ?? "Could not rename agent."
            }
        }
    }

    func deleteAgent(id: String) {
        guard let uid = profileData?.user_id else { return }
        let previousAgents = agents
        let previousEvents = events
        agents.removeAll { $0.id == id }
        events.removeAll { $0.agent_id == id }
        Task {
            do {
                try await service.deleteAgent(userId: uid, agentId: id)
            } catch {
                // Revert the optimistic removal (compile-errors #2).
                agents = previousAgents
                events = previousEvents
                agentMsg = (error as? LocalizedError)?.errorDescription ?? "Could not delete agent."
            }
        }
    }

    func createAgent(role: String) async {
        guard let uid = profileData?.user_id else { return }
        do {
            let agent = try await service.createAgent(userId: uid, role: role)
            agents.append(agent)
        } catch {
            // Previously this silently no-opped on failure (createAgent's own
            // fallback also used to fabricate a fake agent — fixed separately
            // in NetworkService). Surface the failure instead of leaving the
            // user believing nothing happened.
            agentMsg = (error as? LocalizedError)?.errorDescription ?? "Could not create agent."
        }
    }

    func acceptRequest(username: String) async {
        guard let uid = profileData?.user_id else { return }
        let previous = friendRequests
        friendRequests.removeAll { $0.username == username }
        do {
            try await service.acceptFriendRequest(userId: uid, username: username)
        } catch {
            // Revert: a failed accept must not silently vanish the request
            // from the UI while the friendship was never established
            // server-side (compile-errors #2).
            friendRequests = previous
            friendMsg = (error as? LocalizedError)?.errorDescription ?? "Could not accept friend request."
        }
    }

    // ── Subscription ───────────────────────────────────────────────────────────

    func loadSubscription(userId: String) async {
        subLoading = true
        defer { subLoading = false }
        var plan = (try? await service.fetchUserSubscription(userId: userId)) ?? nil

        // A free-tier plan is NOT an active paid subscription — treat it as
        // "no plan" so the Subscription section shows the upgrade UI instead of
        // painting the free tier as an active "Group Plan". (The server also now
        // reports free users as no-plan; this is belt-and-suspenders and matches
        // the web client's own free-plan handling.)
        if let p = plan, p.plan_type == "free" { plan = nil }

        // Reconcile a stale Apple plan: if the host's plan is Apple-billed but
        // StoreKit no longer reports an active entitlement (canceled & expired, or
        // revoked), remove it so the UI stops showing a subscription they no longer
        // have. Only touches Apple *host* plans — Stripe/web plans and group
        // memberships (which have no StoreKit entitlement) are left alone.
        autoRenewOff = false
        planEndDate  = nil
        if let p = plan, p.provider == "apple", p.isHost(userId) {
            let active = await StoreKitManager.shared.activeEntitlementProductIDs()
            if active.isEmpty {
                try? await service.cancelSubscription(subscriptionId: p.id)
                plan = nil
            } else if let renewal = await StoreKitManager.shared.currentRenewal(),
                      !renewal.willAutoRenew {
                // Cancelled in the App Store but still within the paid period —
                // surface that it's ending instead of implying an ongoing plan.
                autoRenewOff = true
                planEndDate  = renewal.expirationDate
            }
        }
        subscription = plan
        // Host of a group plan → load members + pending requests.
        if let plan, plan.isHost(userId), plan.plan_type == "group" {
            subMembers  = (try? await service.fetchSubMembers(subscriptionId: plan.id))  ?? []
            subRequests = (try? await service.fetchSubRequests(subscriptionId: plan.id)) ?? []
        } else {
            subMembers = []; subRequests = []
        }
        mySubRequests = (try? await service.fetchMySubRequests(userId: userId)) ?? []

        // No plan → surface friends' group plans that still have room to join.
        if plan == nil {
            var found: [FSJoinablePlan] = []
            if let (contacts, _) = try? await service.fetchContacts(userId: userId) {
                for c in contacts where c.type == .friend {
                    guard let p = (try? await service.fetchUserSubscription(userId: c.id)) ?? nil,
                          p.plan_type == "group", p.isHost(c.id) else { continue }
                    let members = (try? await service.fetchSubMembers(subscriptionId: p.id)) ?? []
                    if members.count < p.max_members {
                        found.append(FSJoinablePlan(plan: p, hostName: c.name, memberCount: members.count))
                    }
                }
            }
            joinablePlans = found
        } else {
            joinablePlans = []
        }

        // Usage was first fetched in load() before the StoreKit entitlement sync,
        // so re-read it now that the subscription state is settled. This keeps the
        // Plan Usage section in agreement with the subscription card.
        await refreshUsage()
    }

    func requestJoin(_ subscriptionId: String) async {
        guard let uid = profileData?.user_id else { return }
        subBusy = true; defer { subBusy = false }
        do {
            try await service.requestJoinSubscription(subscriptionId: subscriptionId, fromUserId: uid)
            await loadSubscription(userId: uid)
        } catch { subMsg = (error as? LocalizedError)?.errorDescription ?? "Could not send request." }
    }

    /// Purchase a plan through StoreKit (Apple handles the payment sheet).
    func purchasePlan(memberCount: Int) async {
        guard let uid = profileData?.user_id else { return }
        subBusy = true; defer { subBusy = false }
        let ok = await StoreKitManager.shared.purchase(memberCount: memberCount, userId: uid, service: service)
        if ok {
            await loadSubscription(userId: uid)
        } else if let e = StoreKitManager.shared.lastError {
            subMsg = e
        }
    }

    func restorePurchases() async {
        guard let uid = profileData?.user_id else { return }
        subBusy = true; defer { subBusy = false }
        let ok = await StoreKitManager.shared.restore(userId: uid, service: service)
        if !ok, let e = StoreKitManager.shared.lastError { subMsg = e }
        await loadSubscription(userId: uid)
    }

    func cancelPlan() async {
        guard let uid = profileData?.user_id, let plan = subscription else { return }
        subBusy = true; defer { subBusy = false }
        do {
            try await service.cancelSubscription(subscriptionId: plan.id)
        } catch {
            // loadSubscription() below still resyncs from server truth, so
            // there's no revert bug here -- but a swallowed failure left the
            // user with no explanation for why nothing visibly changed
            // (compile-errors #3), unlike the sibling updateSeats/acceptRequest(_:).
            subMsg = (error as? LocalizedError)?.errorDescription ?? "Could not cancel plan."
        }
        await loadSubscription(userId: uid)
    }

    /// Host changes how many people the plan covers; server re-prices from the count.
    func updateSeats(memberCount: Int) async {
        guard let uid = profileData?.user_id, let plan = subscription else { return }
        subBusy = true; defer { subBusy = false }
        do {
            try await service.updateSubscriptionSeats(subscriptionId: plan.id, memberCount: memberCount)
        } catch {
            subMsg = (error as? LocalizedError)?.errorDescription ?? "Could not update plan size."
        }
        await loadSubscription(userId: uid)
    }

    func leavePlan() async {
        guard let uid = profileData?.user_id, let plan = subscription else { return }
        subBusy = true; defer { subBusy = false }
        do {
            try await service.removeSubMember(subscriptionId: plan.id, userId: uid)
        } catch {
            subMsg = (error as? LocalizedError)?.errorDescription ?? "Could not leave plan."
        }
        await loadSubscription(userId: uid)
    }

    func removeMember(_ memberId: String) async {
        guard let uid = profileData?.user_id, let plan = subscription else { return }
        do {
            try await service.removeSubMember(subscriptionId: plan.id, userId: memberId)
        } catch {
            subMsg = (error as? LocalizedError)?.errorDescription ?? "Could not remove member."
        }
        await loadSubscription(userId: uid)
    }

    func acceptRequest(_ fromUserId: String) async {
        guard let uid = profileData?.user_id, let plan = subscription else { return }
        do {
            try await service.acceptSubRequest(subscriptionId: plan.id, fromUserId: fromUserId)
            await loadSubscription(userId: uid)
        } catch { subMsg = (error as? LocalizedError)?.errorDescription ?? "Could not accept." }
    }

    func declineRequest(_ fromUserId: String) async {
        guard let uid = profileData?.user_id, let plan = subscription else { return }
        let previous = subRequests
        subRequests.removeAll { $0.user_id == fromUserId }
        do {
            try await service.declineSubRequest(subscriptionId: plan.id, fromUserId: fromUserId)
        } catch {
            subRequests = previous
            subMsg = (error as? LocalizedError)?.errorDescription ?? "Could not decline request."
        }
        await loadSubscription(userId: uid)
    }

    func cancelMyRequest(_ subscriptionId: String) async {
        guard let uid = profileData?.user_id else { return }
        // Unlike the sibling methods above, this one never resynced via
        // loadSubscription() at all, so a failed decline previously left the
        // client permanently believing the request was gone with zero
        // self-healing and zero error surfaced (compile-errors #2).
        let previous = mySubRequests
        mySubRequests.removeAll { $0.subscription_id == subscriptionId }
        do {
            try await service.declineSubRequest(subscriptionId: subscriptionId, fromUserId: uid)
        } catch {
            mySubRequests = previous
            subMsg = (error as? LocalizedError)?.errorDescription ?? "Could not cancel request."
        }
    }
}

// ── Root account view ─────────────────────────────────────────────────────────
struct AccountView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = AccountViewModel()
    @ObservedObject private var store = StoreKitManager.shared

    // Subscription: member-count picker for a new plan (1-8)
    @State private var selectedMemberCount = 1
    // Subscription: host's in-progress seat-count edit on an active plan
    @State private var editMemberCount: Int? = nil
    // Subscription: "What's included" benefits disclosure — shared by the
    // active-subscriber and pre-purchase states, which are mutually exclusive
    // branches of the same section, so one toggle is safe. Pure UI display
    // state with no backend/VM logic behind it, so it's local @State rather
    // than @Published on AccountViewModel (matches showBlockedUsers below).
    @State private var showBenefits = false

    // Edit profile
    @State private var username     = ""
    @State private var email        = ""
    @State private var password     = ""
    @State private var timezone     = "UTC"

    // Agents
    @State private var newAgentRole   = ""
    @State private var activeSheet:   AccountSheet? = nil
    @State private var renameAgentId: String? = nil
    @State private var renameText     = ""

    enum AccountSheet: Identifiable {
        case newAgent
        case newEvent
        case editEvent(FSHeartbeat)
        case timezonePicker
        var id: String {
            switch self {
            case .newAgent:                 return "newAgent"
            case .newEvent:                 return "newEvent"
            case .editEvent(let e):         return "event-\(e.id)"
            case .timezonePicker:           return "timezonePicker"
            }
        }
    }

    @State private var showBlockedUsers = false

    // Two-factor authentication (email code)
    @State private var mfaEnabled = false
    @State private var mfaLoading = false
    @State private var mfaMsg = ""
    @State private var mfaMsgIsError = false
    @State private var showMfaSetup = false
    @State private var mfaSetupCode = ""
    @State private var mfaSetupLoading = false
    @State private var showMfaDisable = false
    @State private var mfaDisablePassword = ""
    @State private var mfaDisableLoading = false

    // Danger zone
    @State private var deleteConfirm  = ""
    @State private var showDeleteAlert = false
    @State private var deleteAccountError: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                // Warm bloom ground (shared visual language with Chat/Notes/Dashboard).
                RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                               center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                    .ignoresSafeArea()
                RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                               center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // ── Profile header (avatar + name) ────────────────────
                        profileHeader

                        // ── Stats (mirrors StatBox row) ───────────────────────
                        statsSection

                        // ── Subscription ───────────────────────────────────────
                        subscriptionSection

                        // ── Plan usage ─────────────────────────────────────────
                        usageSection

                        // ── Edit profile ───────────────────────────────────────
                        editProfileSection

                        // ── Friend requests ────────────────────────────────────
                        friendRequestsSection

                        // ── Agents ──────────────────────────────────────────────
                        agentsSection

                        // ── Events ──────────────────────────────────────────────
                        eventsSection

                        // ── Two-Factor Authentication ──────────────────────────
                        twoFactorSection

                        // ── Privacy & Safety ───────────────────────────────────
                        privacySafetySection

                        // ── Legal ───────────────────────────────────────────────
                        legalSection

                        // ── Sign Out ────────────────────────────────────────────
                        signOutSection

                        // ── Danger zone ─────────────────────────────────────────
                        dangerZone
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, Theme.spacingMD)
                    .padding(.bottom, 150) // clears the floating tab bar
                }
                // Pull-to-refresh (task 20260831-interaction-polish-conventions):
                // wired to this screen's existing reload method
                // (refreshAccountData(), below) rather than replaying the
                // whole `.task` verbatim — see that method's own comment for
                // why the StoreKit calls stay out of it. `vm.isLoading` isn't
                // read anywhere in this view's body (unlike NotesListView/
                // ChatRootView, which gate their whole list on it), so this
                // can call vm.load() directly with no risk of blanking the
                // screen mid-refresh.
                .refreshable {
                    await refreshAccountData()
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $showBlockedUsers) {
                BlockedUsersView(userId: appState.currentUser?.user_id ?? "", service: appState.service)
            }
        }
        // Shared keyboard-dismiss convention (task
        // 20260831-interaction-polish-conventions) — covers every TextField
        // in this screen's Edit Profile / Danger Zone sections below.
        .dismissesKeyboardOnScrollAndTap()
        .task {
            if let user = appState.currentUser {
                await vm.load(service: appState.service, user: user)
                // Seed local @State from the freshly-fetched profile (vm.profileData),
                // not the stale pre-fetch `user` snapshot captured above — falling back
                // to `user` only if the fetch somehow left profileData nil.
                let freshUser = vm.profileData ?? user
                username = freshUser.username
                email    = freshUser.email
                timezone = freshUser.timezone
                mfaEnabled = freshUser.mfa_enabled
                // StoreKit: start listening, load products, and push any active
                // entitlements to the backend before reading the subscription.
                store.startListening()
                await store.loadProducts()
                await store.syncEntitlements(userId: user.user_id, service: appState.service)
                await vm.loadSubscription(userId: user.user_id)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newAgent:
                NewAgentSheet(role: $newAgentRole) {
                    let role = newAgentRole
                    newAgentRole = ""
                    Task { await vm.createAgent(role: role) }
                }
            case .newEvent:
                EventSetupSheet(agents: vm.agents, groups: vm.groups) { agentId, prompt, timestamps, groupId, notesPublic in
                    Task { await vm.createEvent(agentId: agentId, prompt: prompt, timestamps: timestamps, groupId: groupId, notesPublic: notesPublic) }
                }
            case .editEvent(let event):
                EventSetupSheet(agents: vm.agents, groups: vm.groups, existing: event) { agentId, prompt, timestamps, groupId, notesPublic in
                    Task { await vm.updateEvent(event, agentId: agentId, prompt: prompt, timestamps: timestamps, groupId: groupId, notesPublic: notesPublic) }
                }
            case .timezonePicker:
                TimeZonePickerSheet(selected: timezone) { picked in
                    timezone = picked
                }
            }
        }
        .alert("Free Plan Limit", isPresented: Binding(
            get:  { vm.limitMsg != nil },
            set:  { if !$0 { vm.limitMsg = nil } }
        )) {
            Button("OK", role: .cancel) { vm.limitMsg = nil }
        } message: {
            Text(vm.limitMsg ?? "")
        }
        .alert("Agent Error", isPresented: Binding(
            get:  { vm.agentMsg != nil },
            set:  { if !$0 { vm.agentMsg = nil } }
        )) {
            Button("OK", role: .cancel) { vm.agentMsg = nil }
        } message: {
            Text(vm.agentMsg ?? "")
        }
        .alert("Account Details", isPresented: Binding(
            get:  { vm.statsMsg != nil },
            set:  { if !$0 { vm.statsMsg = nil } }
        )) {
            Button("OK", role: .cancel) { vm.statsMsg = nil }
        } message: {
            Text(vm.statsMsg ?? "")
        }
        .alert("Friend Request Error", isPresented: Binding(
            get:  { vm.friendMsg != nil },
            set:  { if !$0 { vm.friendMsg = nil } }
        )) {
            Button("OK", role: .cancel) { vm.friendMsg = nil }
        } message: {
            Text(vm.friendMsg ?? "")
        }
        .alert("Couldn't Delete Account", isPresented: Binding(
            get:  { deleteAccountError != nil },
            set:  { if !$0 { deleteAccountError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteAccountError = nil }
        } message: {
            Text(deleteAccountError ?? "")
        }
        .alert("Rename Agent", isPresented: Binding(
            get:  { renameAgentId != nil },
            set:  { if !$0 { renameAgentId = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renameAgentId {
                    vm.renameAgent(id: id, name: renameText.trimmingCharacters(in: .whitespaces))
                }
                renameAgentId = nil
            }
            Button("Cancel", role: .cancel) { renameAgentId = nil }
        } message: {
            Text("Enter a display name for this agent.")
        }
        .alert("Delete Account", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                let uid = appState.currentUser?.user_id ?? ""
                Task {
                    // C4: a swallowed failure here previously signed the user
                    // out unconditionally, so a failed deletion looked
                    // identical to a successful one -- only sign out on
                    // confirmed success; surface an alert otherwise.
                    do {
                        try await appState.service.deleteUser(userId: uid)
                        await MainActor.run { appState.signOut() }
                    } catch {
                        await MainActor.run {
                            deleteAccountError = (error as? LocalizedError)?.errorDescription
                                ?? "Could not delete your account. Please try again."
                        }
                    }
                }
            }
        } message: {
            Text("This will permanently delete your account and all data. This cannot be undone.")
        }
    }

    // ── Section builders ───────────────────────────────────────────────────────

    private var profileHeader: some View {
        VStack(spacing: Theme.spacingMD) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: "#EDAB3C").opacity(0.32), Color(hex: "#B8761D").opacity(0.2)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                Text(appState.currentUser?.initials ?? "?")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.goldLight)
            }
            .overlay(Circle().stroke(Theme.gold.opacity(0.5), lineWidth: 1.5))
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(vm.profileData?.username ?? "")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment)
                Text(vm.profileData?.email ?? "")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingMD)
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Overview")
            HStack {
                StatBox(value: vm.friendCount,    label: "Friends")
                StatBox(value: vm.groupCount,     label: "Groups")
                StatBox(value: vm.noteCount,      label: "Notes")
                StatBox(value: vm.highlightCount, label: "Verses")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    @ViewBuilder
    private var usageSection: some View {
        if let usage = vm.usage {
            // The subscription record is authoritative; force "unlimited" when the
            // user has a paid plan even if this usage payload predates the sync.
            let unlimited = vm.hasUnlimitedPlan
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                sectionLabel("Plan Usage")
                usageRow("Notes", usage.notes, hint: "last \(usage.window_days) days", forceUnlimited: unlimited)
                Divider().background(Theme.borderGoldFaint)
                usageRow("Agent events", usage.agentEvents, hint: nil, forceUnlimited: unlimited)
                if !unlimited {
                    Divider().background(Theme.borderGoldFaint)
                    Text("You're on the free plan. Upgrade to a Group plan for unlimited notes and events.")
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.textGoldMuted)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .glassCard(cornerRadius: 20)
        }
    }

    private func usageRow(_ label: String, _ r: FSUsageResource, hint: String?, forceUnlimited: Bool) -> some View {
        let unlimited = forceUnlimited || r.unlimited
        return VStack(alignment: .leading, spacing: Theme.spacingXS + 2) {
            HStack(spacing: Theme.spacingSM) {
                Text(label)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                if let hint, !unlimited {
                    Text(hint)
                        .font(.inter(Theme.fontXS))
                        .foregroundColor(Theme.textMuted)
                }
                Spacer()
                Text(unlimited ? "Unlimited" : "\(r.used) / \(r.limit)")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(unlimited ? Theme.gold : (r.maxedOut ? Theme.error : Theme.textGoldMuted))
            }
            if !unlimited {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.parchment.opacity(0.12))
                        Capsule()
                            .fill(r.maxedOut ? Theme.error : Theme.gold)
                            .frame(width: max(3, geo.size.width * r.fraction))
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.vertical, Theme.spacingXS)
    }

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Subscription")

            if vm.subLoading {
                HStack { Spacer(); ProgressView().tint(Theme.gold); Spacer() }
            } else if let plan = vm.subscription {
                activePlanRow(plan)
                benefitsDisclosure(memberCount: plan.max_members, isExpanded: $showBenefits)

                if vm.isSubHost && plan.plan_type == "group" {
                    seatCountEditRow(plan)

                    if !vm.subMembers.isEmpty {
                        rowCaption("Members (\(vm.subMembers.count)/\(plan.max_members))")
                    }
                    ForEach(vm.subMembers) { memberRow($0) }

                    if !vm.subRequests.isEmpty {
                        rowCaption("Join Requests")
                        ForEach(vm.subRequests) { requestRow($0) }
                    }
                }
                Divider().background(Theme.borderGoldFaint)
                managePlanRow(plan)
            } else {
                rowCaption("Start with a free 1-month trial — you won't be billed until it ends.")
                memberCountPickerRow()
                if !vm.joinablePlans.isEmpty {
                    Divider().background(Theme.borderGoldFaint)
                    rowCaption("Join a Friend's Group Plan")
                    ForEach(vm.joinablePlans) { joinableRow($0) }
                }
            }

            // Outstanding requests this user has sent.
            if !vm.mySubRequests.isEmpty {
                Divider().background(Theme.borderGoldFaint)
                rowCaption("Your Pending Requests")
                ForEach(vm.mySubRequests) { myRequestRow($0) }
            }

            Divider().background(Theme.borderGoldFaint)

            // Restore a subscription bought on another device / after reinstall.
            Button { Task { await vm.restorePurchases() } } label: {
                ghostPill("Restore Purchases", labelColor: Theme.textGoldMuted)
            }
            .disabled(vm.subBusy)

            if let msg = vm.subMsg {
                Text(msg)
                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.error)
                    .padding(.horizontal, Theme.spacingSM).padding(.vertical, Theme.spacingXS + 2)
                    .background(Theme.error.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    // ── Subscription row builders ────────────────────────────────────────────────

    private func rowCaption(_ text: String) -> some View {
        Text(text)
            .font(.inter(Theme.fontSM))
            .foregroundColor(Theme.textMuted)
    }

    private func activePlanRow(_ plan: FSSubscription) -> some View {
        HStack(spacing: Theme.spacingMD) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.12)).frame(width: 40, height: 40)
                Image(systemName: vm.isSubHost ? "crown.fill" : "person.3.fill")
                    .foregroundColor(Theme.gold)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Group Plan")
                        .font(.inter(Theme.fontBody)).foregroundColor(Theme.parchment)
                    let badge = plan.is_trial ? "Free trial" : (vm.autoRenewOff ? "Cancelling" : plan.status.capitalized)
                    Text(badge)
                        .font(.inter(Theme.fontXXS)).tracking(1)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((vm.autoRenewOff ? Theme.error : Theme.gold).opacity(0.15))
                        .foregroundColor(vm.autoRenewOff ? Theme.error : Theme.gold)
                        .clipShape(Capsule())
                }
                Text("\(plan.priceLabel)/mo · \(vm.isSubHost ? "You are the host" : "Member")"
                     + (plan.plan_type == "group" ? " · up to \(plan.max_members)" : ""))
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.textMuted)
                // Trial / next-billing line (host only — they own billing).
                if vm.isSubHost {
                    if vm.autoRenewOff {
                        Text("Auto-renew off · cancels \(Self.mediumDate(vm.planEndDate) ?? plan.nextBillingLabel) · access until then")
                            .font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                    } else if !plan.nextBillingLabel.isEmpty {
                        Text(plan.is_trial
                             ? "🎁 \(plan.trial_days_remaining) day\(plan.trial_days_remaining == 1 ? "" : "s") left · first billing \(plan.nextBillingLabel)"
                             : "Next billing \(plan.nextBillingLabel)"
                             + (plan.card_last4.isEmpty ? "" : " · \(plan.card_brand.capitalized) •••• \(plan.card_last4)"))
                            .font(.inter(Theme.fontXS)).foregroundColor(Theme.textGoldMuted)
                    }
                }
            }
            Spacer()
        }
    }

    private func memberRow(_ m: FSSubMember) -> some View {
        HStack(spacing: Theme.spacingSM) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.15)).frame(width: 30, height: 30)
                Text(String(m.username.prefix(1)).uppercased()).font(.playfair(Theme.fontXS)).foregroundColor(Theme.gold)
            }
            Text(m.username + (m.user_id == vm.profileData?.user_id ? " (you)" : ""))
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
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
    // Blocked Users row (privacySafetySection, AccountView.swift:1424-1433), swapping
    // chevron.right (navigate) for chevron.down/up (expand/collapse in place): this
    // toggles content inline rather than navigating to another screen.
    private func benefitsDisclosure(memberCount: Int, isExpanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS + 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack {
                    Label("What's included", systemImage: "info.circle")
                        .font(.inter(Theme.fontBody))
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
                    // Fallback numbers mirror the server source of truth
                    // (api/schemas/subscription.py FREE_LIMITS / NOTES_WINDOW_DAYS)
                    // for the brief window before vm.usage loads — same pattern
                    // as fallbackPriceCents above, which mirrors GROUP_PRICE_CENTS.
                    benefitRow("Unlimited notes",
                                "Free plan: \(vm.usage?.notes.limit ?? 10) every \(vm.usage?.window_days ?? 7) days")
                    benefitRow("Unlimited agent events",
                                "Free plan: \(vm.usage?.agentEvents.limit ?? 1)")
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
    private func benefitRow(_ title: String, _ caption: String) -> some View {
        HStack(alignment: .top, spacing: Theme.spacingSM) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(Theme.gold)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                Text(caption).font(.inter(Theme.fontXXS)).foregroundColor(Theme.textMuted)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func requestRow(_ r: FSSubMember) -> some View {
        HStack(spacing: Theme.spacingSM) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.15)).frame(width: 30, height: 30)
                Text(String(r.username.prefix(1)).uppercased()).font(.playfair(Theme.fontXS)).foregroundColor(Theme.gold)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(r.username).font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                Text("Wants to join").font(.inter(Theme.fontXS)).foregroundColor(Theme.textMuted)
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
    private func managePlanRow(_ plan: FSSubscription) -> some View {
        if vm.isSubHost && plan.provider == "apple" {
            // Apple subscriptions can only be canceled through the App Store.
            Button { Task { await store.showManageSubscriptions() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                    Text("Manage Subscription").font(.inter(Theme.fontSM))
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
                    Text(vm.isSubHost ? "Cancel Plan" : "Leave Plan").font(.inter(Theme.fontSM))
                }
                .foregroundColor(Theme.error)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(Capsule().stroke(Theme.error.opacity(0.4), lineWidth: 1))
            }
            .disabled(vm.subBusy)
        }
    }

    // Fallback prices (mirrors api/schemas/subscription.py GROUP_PRICE_CENTS) used
    // only until StoreKit's own localized prices have loaded.
    private static let fallbackPriceCents: [Int: Int] = [
        1: 1000, 2: 1799, 3: 2699, 4: 3599, 5: 4499, 6: 5399, 7: 6299, 8: 7199,
    ]
    private func fallbackPriceLabel(for count: Int) -> String {
        String(format: "$%.2f", Double(Self.fallbackPriceCents[count] ?? 1000) / 100)
    }

    private func memberCountPickerRow() -> some View {
        let price = store.displayPrice(for: selectedMemberCount) ?? fallbackPriceLabel(for: selectedMemberCount)
        return VStack(alignment: .leading, spacing: Theme.spacingSM) {
            HStack(spacing: Theme.spacingMD) {
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.12)).frame(width: 36, height: 36)
                    Image(systemName: "person.3.fill").foregroundColor(Theme.gold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group — \(price)/mo")
                        .font(.inter(Theme.fontBody)).foregroundColor(Theme.parchment)
                    Text("Free for 1 month · choose 1-8 members")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textMuted)
                }
                Spacer()
            }
            Stepper("Members: \(selectedMemberCount)", value: $selectedMemberCount, in: 1...8)
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
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
            .font(.inter(Theme.fontXXS))
            .foregroundColor(Theme.textGoldMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func seatCountEditRow(_ plan: FSSubscription) -> some View {
        if let editing = editMemberCount {
            HStack(spacing: Theme.spacingSM) {
                Stepper("Members: \(editing)",
                        value: Binding(get: { editing }, set: { editMemberCount = $0 }), in: 1...8)
                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                Button { Task { await vm.updateSeats(memberCount: editing); editMemberCount = nil } } label: {
                    gradientPill("Save", compact: true)
                }
                .disabled(vm.subBusy)
                Button { editMemberCount = nil } label: {
                    ghostPill("Cancel", compact: true)
                }
            }
        } else {
            Button {
                editMemberCount = plan.max_members
            } label: {
                ghostPill("Change plan size (\(plan.max_members) member\(plan.max_members == 1 ? "" : "s"))", labelColor: Theme.gold)
            }
        }
    }

    private func joinableRow(_ j: FSJoinablePlan) -> some View {
        let pending = vm.mySubRequests.contains { $0.subscription_id == j.plan.id }
        return HStack(spacing: Theme.spacingSM) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.15)).frame(width: 30, height: 30)
                Text(String(j.hostName.prefix(1)).uppercased()).font(.playfair(Theme.fontXS)).foregroundColor(Theme.gold)
            }
            Text("\(j.hostName)'s Group · \(j.memberCount)/\(j.plan.max_members)")
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
            Spacer()
            Button(pending ? "Requested" : "Request") { Task { await vm.requestJoin(j.plan.id) } }
                .font(.inter(Theme.fontXS)).foregroundColor(pending ? Theme.textMuted : Theme.gold)
                .buttonStyle(.borderless).disabled(pending || vm.subBusy)
        }
    }

    private func myRequestRow(_ r: FSSubRequest) -> some View {
        HStack {
            Image(systemName: "clock").foregroundColor(Theme.textGoldMuted)
            Text("Pending group plan request").font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
            Spacer()
            Button("Cancel") { Task { await vm.cancelMyRequest(r.subscription_id) } }
                .font(.inter(Theme.fontXS)).foregroundColor(Theme.textMuted).buttonStyle(.borderless)
        }
    }

    private var editProfileSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Edit Profile")

            // Edit message
            if let msg = vm.editMsg {
                HStack(spacing: Theme.spacingSM) {
                    Image(systemName: msg.type == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    Text(msg.text)
                        .font(.inter(Theme.fontSM))
                }
                .foregroundColor(msg.type == .success ? Theme.success : Theme.error)
                .padding(.horizontal, Theme.spacingSM).padding(.vertical, Theme.spacingXS + 2)
                .background((msg.type == .success ? Theme.success : Theme.error).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
            }

            // Username
            HStack {
                Image(systemName: "person").foregroundColor(Theme.textGoldMuted).frame(width: 22)
                TextField("Username", text: $username)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .autocapitalization(.none)
                    .accessibilityLabel("Username field")
            }
            Divider().background(Theme.borderGoldFaint)

            // Email
            HStack {
                Image(systemName: "envelope").foregroundColor(Theme.textGoldMuted).frame(width: 22)
                TextField("Email", text: $email)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .accessibilityLabel("Email field")
            }
            Divider().background(Theme.borderGoldFaint)

            // Timezone — opens a searchable picker sheet; drives the nightly
            // backup schedule (it runs at this timezone's local 3am).
            Button(action: { activeSheet = .timezonePicker }) {
                HStack {
                    Image(systemName: "clock").foregroundColor(Theme.textGoldMuted).frame(width: 22)
                    Text("Timezone")
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Text(timezone)
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.textGoldMuted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textGoldMuted)
                }
            }
            .accessibilityLabel("Timezone: \(timezone)")
            Divider().background(Theme.borderGoldFaint)

            // Password
            HStack {
                Image(systemName: "lock").foregroundColor(Theme.textGoldMuted).frame(width: 22)
                SecureField("New Password (leave blank to keep)", text: $password)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .accessibilityLabel("New password field")
            }
            Divider().background(Theme.borderGoldFaint)

            Button(action: saveProfile) {
                gradientPill("Save Changes")
            }
            .accessibilityLabel("Save profile changes")
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    private var friendRequestsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Friend Requests")

            if let msg = vm.friendMsg {
                Text(msg)
                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.error)
                    .padding(.horizontal, Theme.spacingSM).padding(.vertical, Theme.spacingXS + 2)
                    .background(Theme.error.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
            }

            if vm.friendRequests.isEmpty {
                Text("No pending friend requests.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(Array(vm.friendRequests.enumerated()), id: \.offset) { idx, req in
                    if idx > 0 { Divider().background(Theme.borderGoldFaint) }
                    HStack {
                        ZStack {
                            Circle().fill(Theme.gold.opacity(0.15)).frame(width: 36, height: 36)
                            Text(String(req.username.prefix(1)).uppercased())
                                .font(.playfair(Theme.fontSM)).foregroundColor(Theme.gold)
                        }
                        VStack(alignment: .leading) {
                            Text(req.username).font(.inter(Theme.fontBody)).foregroundColor(Theme.parchment)
                            Text("Wants to be your friend").font(.inter(Theme.fontXS)).foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                        Button {
                            Task { await vm.acceptRequest(username: req.username) }
                        } label: {
                            gradientPill("Accept", compact: true)
                        }
                        .accessibilityLabel("Accept friend request from \(req.username)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
        // Test-only hook (no visual/behavioral effect): lets AccountUITests
        // measure this card's rendered frame width to prove it matches its
        // sibling sections instead of shrink-wrapping around a short empty-state
        // string. See test_friendRequestsSection_emptyState_matchesAvailableContentWidth.
        // .accessibilityElement(children: .combine) is required alongside the
        // identifier below — without it, a bare identifier on a plain (non-
        // accessibility-element) VStack gets pushed down onto each descendant
        // leaf individually instead of producing one queryable otherElements
        // container, which is what the test actually looks up.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Friend Requests card")
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Agents")

            Text("Enabled agents participate in your chats and can summarize study sessions.")
                .font(.inter(Theme.fontSM))
                .foregroundColor(Theme.textMuted)

            if vm.agents.isEmpty {
                Divider().background(Theme.borderGoldFaint)
                Text("No agents yet. Tap + to create one.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            } else {
                // Iterate over stable values (vm.agents), not ForEach($vm.agents) —
                // an index-keyed array Binding. Deleting the last row from inside
                // this row's own .contextMenu action, while ForEach($vm.agents) still
                // holds index-derived Bindings into the (now-shrunk-or-empty) array,
                // is a well-documented SwiftUI footgun (out-of-bounds access inside
                // SwiftUI's binding/diffing machinery once the dismiss transition
                // races the mutation) — this is what crashed
                // test_eventsSection_newEventDisabled_whenNoAgents_reenabledAfterCreatingAgent.
                // Sourcing the Toggle's binding via agentEnabledBinding(id:), keyed by
                // agent.id and re-resolved against vm.agents on every get/set, removes
                // the dangling-index hazard structurally instead of just timing around it.
                ForEach(vm.agents) { agent in
                    Divider().background(Theme.borderGoldFaint)
                    HStack(spacing: Theme.spacingMD) {
                        ZStack {
                            Circle().fill(Theme.gold.opacity(0.12)).frame(width: 36, height: 36)
                            Image(systemName: "brain").foregroundColor(Theme.gold)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayLabel)
                                .font(.inter(Theme.fontBody))
                                .foregroundColor(Theme.parchment)
                            Text(agent.role.isEmpty ? "Default spiritual guide role" : String(agent.role.prefix(60)))
                                .font(.inter(Theme.fontXS))
                                .foregroundColor(Theme.textMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                        // Enable/disable stays inline — it's a quick at-a-glance switch.
                        // vm.toggleAgent(id:enabled:) is already id-keyed (looks the
                        // agent up by id, not index) and is the sole source of truth
                        // for the optimistic update + revert-on-failure, so the
                        // binding's setter just delegates to it directly.
                        Toggle("", isOn: agentEnabledBinding(id: agent.id))
                            .labelsHidden()
                            .tint(Theme.gold)
                            .scaleEffect(0.85)
                            .accessibilityLabel(agent.enabled ? "Disable agent" : "Enable agent")
                        // Rename / delete moved into a long-press context menu.
                        Image(systemName: "ellipsis")
                            .foregroundColor(Theme.textMuted)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(action: {
                            renameText    = agent.name.isEmpty ? agent.displayLabel : agent.name
                            renameAgentId = agent.id
                        }) { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive, action: { vm.deleteAgent(id: agent.id) }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Agent: \(agent.displayLabel). \(agent.enabled ? "Enabled" : "Disabled").")
                    .accessibilityHint("Double-tap and hold for options.")
                    .accessibilityAction(named: "Rename agent") {
                        renameText    = agent.name.isEmpty ? agent.displayLabel : agent.name
                        renameAgentId = agent.id
                    }
                    .accessibilityAction(named: "Delete agent") { vm.deleteAgent(id: agent.id) }
                }
            }

            Divider().background(Theme.borderGoldFaint)
            Button(action: { activeSheet = .newAgent }) {
                ghostLabelPill(icon: "plus", "New Agent")
            }
            .accessibilityLabel("Create new agent")
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    // id-keyed Binding for an individual agent row's Toggle, re-resolved against
    // vm.agents on every get/set instead of an index captured once at ForEach
    // build time. Pairs with ForEach(vm.agents) (value iteration) in agentsSection
    // above — together they remove the dangling-array-index crash that
    // ForEach($vm.agents) had when a row's own contextMenu deleted the last agent.
    private func agentEnabledBinding(id: String) -> Binding<Bool> {
        Binding(
            get: { vm.agents.first(where: { $0.id == id })?.enabled ?? false },
            set: { vm.toggleAgent(id: id, enabled: $0) }
        )
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Events")

            Text("Events are AI-powered check-ins. When the scheduled time arrives, your agent responds to the prompt and saves a note.")
                .font(.inter(Theme.fontSM))
                .foregroundColor(Theme.textMuted)

            // Manual "execute now" confirmation (task
            // 20260901-heartbeat-manual-trigger-button) — mirrors
            // editProfileSection's editMsg banner pattern. Free-tier-cap and
            // genuine-failure outcomes go through the existing limitMsg/
            // agentMsg alerts below instead of this banner.
            if let msg = vm.eventFireMsg {
                HStack(spacing: Theme.spacingSM) {
                    Image(systemName: msg.type == .success ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                    Text(msg.text)
                        .font(.inter(Theme.fontSM))
                }
                .foregroundColor(msg.type == .success ? Theme.success : Theme.gold)
                .padding(.horizontal, Theme.spacingSM).padding(.vertical, Theme.spacingXS + 2)
                .background((msg.type == .success ? Theme.success : Theme.gold).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
            }

            if vm.events.isEmpty {
                Divider().background(Theme.borderGoldFaint)
                Text("No events yet. Tap + to schedule one.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(vm.events) { event in
                    Divider().background(Theme.borderGoldFaint)
                    EventRow(
                        event:     event,
                        agentName: agentName(for: event.agent_id),
                        isFiring:  vm.firingHeartbeatIds.contains(event.id),
                        onEdit:    { activeSheet = .editEvent(event) },
                        onDelete:  { vm.removeEvent(event) },
                        onFire:    { Task { await vm.fireHeartbeatNow(event) } }
                    )
                }
            }

            Divider().background(Theme.borderGoldFaint)
            Button(action: {
                guard !vm.agents.isEmpty else { return }
                appState.requestPushNotifications()
                activeSheet = .newEvent
            }) {
                ghostLabelPill(icon: "plus", "New Event", color: vm.agents.isEmpty ? Theme.textMuted : Theme.gold)
            }
            .disabled(vm.agents.isEmpty)
            .accessibilityLabel("Create new event")
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    private var twoFactorSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Two-Factor Authentication")

            if !mfaMsg.isEmpty {
                Text(mfaMsg)
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(mfaMsgIsError ? .red : Theme.gold)
            }
            Toggle(isOn: Binding(
                get: { mfaEnabled },
                set: { newValue in Task { await handleMfaToggle(newValue) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Two-Factor Authentication")
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Text("Emails a 6-digit code to \(appState.currentUser?.email ?? "your email") every time you sign in.")
                        .font(.inter(Theme.fontXXS))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .disabled(mfaLoading)
            .tint(Theme.gold)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
        .sheet(isPresented: $showMfaSetup) {
            MfaSetupSheet(
                code: $mfaSetupCode,
                isLoading: mfaSetupLoading,
                onConfirm: { Task { await handleMfaConfirm() } },
                onCancel: { showMfaSetup = false; mfaSetupCode = "" }
            )
        }
        .sheet(isPresented: $showMfaDisable) {
            MfaDisableSheet(
                password: $mfaDisablePassword,
                isLoading: mfaDisableLoading,
                onConfirm: { Task { await handleMfaDisableConfirm() } },
                onCancel: { showMfaDisable = false; mfaDisablePassword = "" }
            )
        }
    }

    private func handleMfaToggle(_ newValue: Bool) async {
        mfaMsg = ""
        if !newValue {
            showMfaDisable = true
            return
        }
        mfaLoading = true
        defer { mfaLoading = false }
        do {
            try await appState.service.mfaEnable()
            showMfaSetup = true
        } catch {
            mfaMsgIsError = true
            mfaMsg = error.localizedDescription
        }
    }

    private func handleMfaConfirm() async {
        mfaSetupLoading = true
        defer { mfaSetupLoading = false }
        do {
            try await appState.service.mfaConfirm(code: mfaSetupCode)
            mfaEnabled = true
            if var user = appState.currentUser { user.mfa_enabled = true; appState.updateUser(user) }
            showMfaSetup = false
            mfaSetupCode = ""
            mfaMsgIsError = false
            mfaMsg = "Two-factor authentication is now on."
        } catch {
            mfaMsgIsError = true
            mfaMsg = error.localizedDescription
        }
    }

    private func handleMfaDisableConfirm() async {
        mfaDisableLoading = true
        defer { mfaDisableLoading = false }
        do {
            try await appState.service.mfaDisable(password: mfaDisablePassword)
            mfaEnabled = false
            if var user = appState.currentUser { user.mfa_enabled = false; appState.updateUser(user) }
            showMfaDisable = false
            mfaDisablePassword = ""
            mfaMsgIsError = false
            mfaMsg = "Two-factor authentication is now off."
        } catch {
            mfaMsgIsError = true
            mfaMsg = error.localizedDescription
        }
    }

    private var privacySafetySection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Privacy & Safety")
            Button(action: { showBlockedUsers = true }) {
                HStack {
                    Label("Blocked Users", systemImage: "hand.raised")
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .accessibilityLabel("Manage blocked users")
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Legal")

            Link(destination: URL(string: "https://fellowscript.com/#/privacy")!) {
                HStack {
                    Label("Privacy Policy", systemImage: "hand.raised")
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .accessibilityLabel("Open Privacy Policy")
            Divider().background(Theme.borderGoldFaint)

            Link(destination: URL(string: "https://fellowscript.com/#/terms")!) {
                HStack {
                    Label("Terms of Service", systemImage: "doc.text")
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .accessibilityLabel("Open Terms of Service")
            Divider().background(Theme.borderGoldFaint)

            HStack {
                Label("Version", systemImage: "info.circle")
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    // Kept as its own standalone, neutral (non-danger-tinted) card — a distinct,
    // low-risk action that shouldn't visually escalate to Danger Zone's red severity.
    private var signOutSection: some View {
        Button(action: appState.signOut) {
            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                .foregroundColor(Theme.error)
                .font(.inter(Theme.fontBody))
        }
        .accessibilityLabel("Sign out of your account")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Danger Zone")
                .font(.inter(Theme.fontXXS)).tracking(4)
                .foregroundColor(Theme.error.opacity(0.65))

            Text("Permanently deletes your account, all notes, highlights, and removes you from all groups and friend lists. This cannot be undone.")
                .font(.inter(Theme.fontSM))
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "person").foregroundColor(Theme.error.opacity(0.60)).frame(width: 22)
                TextField(appState.currentUser?.username ?? "yourname", text: $deleteConfirm)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .autocapitalization(.none)
                    .accessibilityLabel("Type your username to confirm deletion")
            }

            Button(action: {
                if deleteConfirm == (appState.currentUser?.username ?? "") {
                    showDeleteAlert = true
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Delete My Account").font(.inter(Theme.fontSM))
                }
                .foregroundColor(Theme.error)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(Capsule().stroke(Theme.error.opacity(0.4), lineWidth: 1))
            }
            .disabled(deleteConfirm != (appState.currentUser?.username ?? ""))
            .accessibilityLabel("Delete account button")
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(tint: Theme.dangerBg, border: [Color.white.opacity(0.12), Theme.borderDanger])
    }

    // ── Helpers ────────────────────────────────────────────────────────────────
    @ViewBuilder
    /// "Aug 15, 2026" for a Date, or nil. Used for the Apple auto-renew-off line.
    private static func mediumDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: date)
    }

    // ── Shared pill controls (reused across sections; recipes cited in the design
    // doc's §1 "Reused visual language" table — gradient CTA pill mirrors
    // GroupActivityWidget's "Continue reading" pill / Note-Editor Save pill; ghost
    // outline pill and ghost icon+label pill mirror NoteEditorView's header chips) ─
    private func gradientPill(_ title: String, compact: Bool = false) -> some View {
        Text(title)
            .font(.inter(compact ? Theme.fontXS : Theme.fontSM, weight: .semibold))
            .foregroundColor(Color(hex: "#24170A"))
            .padding(.horizontal, compact ? 14 : 20)
            .frame(height: compact ? 32 : 36)
            .background(
                LinearGradient(colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(Capsule())
    }

    private func ghostPill(_ title: String, compact: Bool = false,
                            labelColor: Color = Theme.textSecondary,
                            strokeColor: Color = Theme.parchment.opacity(0.14)) -> some View {
        Text(title)
            .font(.inter(compact ? Theme.fontXS : Theme.fontSM))
            .foregroundColor(labelColor)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 32 : 36)
            .overlay(Capsule().stroke(strokeColor, lineWidth: 1))
    }

    private func ghostLabelPill(icon: String, _ title: String, color: Color = Theme.gold) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title).font(.inter(Theme.fontSM))
        }
        .foregroundColor(color)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(Capsule().stroke(Theme.parchment.opacity(0.14), lineWidth: 1))
    }

    private func agentName(for agentId: String) -> String {
        vm.agents.first(where: { $0.id == agentId })?.displayLabel ?? "Agent"
    }

    private func saveProfile() {
        guard let user = appState.currentUser else { return }
        var body: [String: String] = [:]
        if !username.isEmpty && username != user.username { body["username"] = username }
        if !email.isEmpty    && email    != user.email    { body["email"]    = email    }
        if !password.isEmpty                              { body["plain_pass"] = password }
        if timezone != user.timezone                      { body["timezone"]   = timezone }
        Task {
            do {
                let updated = try await appState.service.updateUser(userId: user.user_id, body: body)
                appState.updateUser(updated)
                vm.profileData = updated
                vm.editMsg = (.success, "Profile updated.")
            } catch {
                // Never show "Profile updated." on a failed save — surface the
                // real error instead so a rejected/failed write is visible.
                vm.editMsg = (.error, error.localizedDescription)
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            vm.editMsg = nil
        }
        password = ""
    }

    /// Pull-to-refresh's reload method (task
    /// 20260831-interaction-polish-conventions): re-runs the profile/agents/
    /// events/usage/friend-requests fetch (`vm.load`) and the subscription
    /// fetch (`vm.loadSubscription`), same as `.task` above, then reseeds
    /// this screen's local @State fields from the freshly-fetched profile —
    /// identical to `.task`'s own seeding. Deliberately does NOT re-run
    /// `store.startListening()`/`loadProducts()`/`syncEntitlements()`: those
    /// are one-time StoreKit session bootstrapping for this app launch, not
    /// this screen's own "reload my data" concern, and re-invoking entitlement
    /// sync on every pull-to-refresh would be new business logic beyond
    /// "wiring the existing reload method into `.refreshable`" (out of this
    /// task's bounds) with its own side effects worth not introducing here.
    private func refreshAccountData() async {
        guard let user = appState.currentUser else { return }
        await vm.load(service: appState.service, user: user)
        let freshUser = vm.profileData ?? user
        username   = freshUser.username
        email      = freshUser.email
        timezone   = freshUser.timezone
        mfaEnabled = freshUser.mfa_enabled
        await vm.loadSubscription(userId: user.user_id)
    }
}

// ── Stat box ──────────────────────────────────────────────────────────────────
struct StatBox: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.playfair(Theme.fontDisplayLG))
                .foregroundColor(Theme.gold)
            Text(label)
                .font(.inter(Theme.fontXXS)).tracking(3).textCase(.uppercase)
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingSM)
        .accessibilityLabel("\(value) \(label)")
    }
}

// ── New agent sheet ───────────────────────────────────────────────────────────
// Visual redesign (task 20260902-submenu-visual-redesign): moved off native
// Form/Section onto the shared warm-bloom-ground background + widgetCard()
// layout; the "CUSTOM ROLE (OPTIONAL)" header keeps its already-correct
// styling, just moved out of Form's header: closure into a plain Text above
// the card. .medium detent and callback wiring unchanged.
struct NewAgentSheet: View {
    @Binding var role: String
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    Text("CUSTOM ROLE (OPTIONAL)")
                        .font(.inter(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)

                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        Text("Optionally give this agent a custom role. Leave blank to use the default spiritual guide role.")
                            .font(.inter(Theme.fontSM))
                            .foregroundColor(Theme.textSecondary)
                        TextEditor(text: $role)
                            .font(.inter(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 80)
                            .accessibilityLabel("Agent role description")
                    }
                    .widgetCard()
                }
                .padding(Theme.spacingLG)
            }
            .warmBloomBackground()
            // Shared keyboard-dismiss convention (task
            // 20260831-interaction-polish-conventions).
            .dismissesKeyboardOnScrollAndTap()
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            // Follow-up polish (task 20260902-submenu-followup-polish): same
            // ghost-chip-Cancel / PillButton-Create / centered-`.principal`-
            // title treatment as ChatRootView's AddFriendSheet/AddGroupSheet
            // -- see AddFriendSheet's toolbar comment for the full rationale.
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) { cancelGhostChip }
                        .buttonStyle(.plain)
                }
                .suppressAutomaticGlassChrome()
                ToolbarItem(placement: .principal) {
                    Text("New Agent")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.parchment)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    PillButton(title: "Create") { onCreate(); dismiss() }
                }
                .suppressAutomaticGlassChrome()
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    // Ghost-chip Cancel label (see ChatRootView.swift's sheetGhostCancelLabel
    // for the shared recipe/rationale comment -- bespoke per-sheet copy here
    // rather than a new cross-file shared component per this task's spec).
    private var cancelGhostChip: some View {
        Text("Cancel")
            .font(.inter(Theme.fontSM))
            .foregroundColor(Theme.textSecondary)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(Theme.parchment.opacity(0.06)))
            .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1))
    }
}

// ── Timezone picker sheet ───────────────────────────────────────────────────
// Full IANA timezone list via Foundation (mirrors the web Account page's use
// of Intl.supportedValuesOf('timeZone')); searchable since there are 400+.
struct TimeZonePickerSheet: View {
    let selected: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var allZones: [String] { TimeZone.knownTimeZoneIdentifiers.sorted() }
    private var filtered: [String] {
        guard !query.isEmpty else { return allZones }
        return allZones.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { tz in
                Button(action: { onPick(tz); dismiss() }) {
                    HStack {
                        Text(tz)
                            .font(.inter(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                        Spacer()
                        if tz == selected {
                            Image(systemName: "checkmark").foregroundColor(Theme.gold)
                        }
                    }
                }
                .listRowBackground(Theme.cardBg)
                .accessibilityLabel(tz == selected ? "\(tz), selected" : tz)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgPage)
            .searchable(text: $query, prompt: "Search timezones")
            .navigationTitle("Timezone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// ── Event row (shown in Events section) ───────────────────────────────────────
struct EventRow: View {
    let event:     FSHeartbeat
    let agentName: String
    // Manual "execute now" trigger (task 20260901-heartbeat-manual-trigger-button).
    let isFiring:  Bool
    let onEdit:    () -> Void
    let onDelete:  () -> Void
    let onFire:    () -> Void

    var body: some View {
        HStack(spacing: Theme.spacingMD) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.12)).frame(width: 30, height: 30)
                Image(systemName: "bolt.fill").foregroundColor(Theme.gold).font(.caption)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.prompt.isEmpty ? "Untitled Event" : String(event.prompt.prefix(50)))
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(event.scheduleSummary)
                    Text("·")
                    Text(agentName)
                }
                .font(.inter(Theme.fontXS))
                .foregroundColor(Theme.textMuted)
            }
            Spacer()
            // Always-visible "execute now": unlike Edit/Delete (which stay in
            // the long-press context menu below), this fires immediately on
            // tap rather than needing that menu discovered first. A separate
            // glyph from the row's own bolt.fill identity icon above avoids
            // visually implying the row icon itself is tappable.
            Button(action: onFire) {
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.16)).frame(width: 28, height: 28)
                    if isFiring {
                        ProgressView().tint(Theme.gold).scaleEffect(0.7)
                    } else {
                        Image(systemName: "play.fill").foregroundColor(Theme.gold).font(.caption2)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isFiring)
            .accessibilityLabel(isFiring ? "Firing event now" : "Fire event now")
            .accessibilityHint("Immediately runs this event's agent and saves a note, without waiting for its schedule.")
            // Discoverability hint: signals a long-press context menu is available.
            Image(systemName: "ellipsis")
                .foregroundColor(Theme.textMuted)
                .font(.caption)
                .accessibilityHidden(true)
        }
        // Whole row is the long-press target (Spacer included).
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Event: \(event.prompt.isEmpty ? "Untitled Event" : String(event.prompt.prefix(50))). Scheduled \(event.scheduleSummary).")
        .accessibilityHint("Double-tap and hold for options.")
        .accessibilityAction(named: "Edit", onEdit)
        .accessibilityAction(named: "Delete", onDelete)
        .accessibilityAction(named: "Fire Now", onFire)
    }
}

// ── Helper to make String Identifiable for sheet(item:) ──────────────────────
struct IdentifiableString: Identifiable {
    let value: String
    var id: String { value }
}
