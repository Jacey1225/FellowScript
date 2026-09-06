// Account/AccountViewModel.swift — AccountView's view model, split out of
// AccountView.swift (readability #6, 20260904-frontend-arch-sweep): that
// file combined this view model with many unrelated view sections in one
// 2000+-line file. Pure file-organization move -- same type, same behavior,
// no interface change. See AccountView.swift's header comment for the full
// split rationale and the list of sibling section files.

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
    @Published var friendRequests:  [(id: String, username: String, profile_photo_url: String?)] = []
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
    // Shown when the notes-count/highlights/agents/events fetch genuinely
    // fails (network/HTTP error or decode failure) on the *current* load()
    // call — task 20260903-account-stats-not-loading (notes/highlights/
    // agents), extended to events by 20260903-account-events-not-loading.
    // Previously these silently collapsed to 0/empty on any failure, which
    // looked visually identical to the account genuinely having none.
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
        // a bare `?? 0`/`?? []`/`try?` can't do. (task
        // 20260904-compliance-error-handling-consistency, H8: this used to
        // apply to only 3 of the 7 concurrent fetches below -- user, usage,
        // friendRequests, and contacts silently fell back via bare `try?`
        // exactly like the agents/notes/highlights bug this screen already
        // fixed. All 7 now feed the same `statsFailed` flag.)
        var statsFailed = false

        let userResult: FSUser?
        do { userResult = try await fetchedUser } catch { userResult = nil; statsFailed = true }

        // Bug fix (cache-clobber sweep, task
        // 20260905-pull-to-refresh-cache-clobber): agents/noteCount/
        // highlightCount/friendRequests used to default to `[]`/`0` on a
        // caught throw and then get written unconditionally below, wiping
        // already-displayed data on a transient failure exactly like the
        // profileData/usage/groups bug this same method already fixed (H8).
        // These four are now `nil` on failure instead of a defaulted empty
        // value, so the write below can tell "genuinely empty" apart from
        // "fetch failed" and only overwrite on the former.
        let agentsResult: [FSAgent]?
        do { agentsResult = try await fetchedAgents } catch { agentsResult = nil; statsFailed = true }
        let noteCountResult: Int?
        do { noteCountResult = try await fetchedNoteCount } catch { noteCountResult = nil; statsFailed = true }
        let highlightCountResult: Int?
        do { highlightCountResult = try await (fetchedHighlights).count } catch { highlightCountResult = nil; statsFailed = true }

        let usageResult: FSUsage?
        do { usageResult = try await fetchedUsage } catch { usageResult = nil; statsFailed = true }

        let friendRequestsResult: [(id: String, username: String, profile_photo_url: String?)]?
        do { friendRequestsResult = try await service.fetchFriendRequests(userId: user.user_id) } catch { friendRequestsResult = nil; statsFailed = true }

        let contactsResult: ([FSContact], [String: FSGroup])?
        do { contactsResult = try await fetchedContacts } catch { contactsResult = nil; statsFailed = true }

        // task 20260903-account-events-not-loading: previously `(try? ...)
        // ?? []` swallowed a genuine per-agent fetch/decode failure (e.g.
        // this task's root cause -- a missing-column decode throw) exactly
        // like the pre-fix notes/highlights/agents fetches did, rendering
        // identically to "this agent really has no events configured". Track
        // failures into `statsFailed` (below) the same way those three
        // already do, rather than adding a bespoke second failure flag/message.
        //
        // Bug fix (20260905-pull-to-refresh-cache-clobber): if fetchAgents
        // itself failed (agentsResult == nil), there's no agent list to walk
        // at all -- previously that silently produced an empty allEvents,
        // which then wiped the existing `events` below. Now that case is
        // skipped entirely so `events` is left untouched by the write below.
        // And within the walk, an individual agent's failed heartbeat fetch
        // (`hbs == nil`) now falls back to that agent's own previously-known
        // events instead of dropping them, mirroring
        // NotesViewModel.fetchAndCache's per-group preserve-on-failure splice.
        var allEvents: [FSHeartbeat] = []
        let eventsUsable = agentsResult != nil
        if let agentsResult {
            await withTaskGroup(of: (String, [FSHeartbeat]?).self) { group in
                for agent in agentsResult {
                    group.addTask {
                        (agent.id, try? await service.fetchHeartbeats(userId: user.user_id, agentId: agent.id))
                    }
                }
                for await (agentId, hbs) in group {
                    if let hbs {
                        allEvents.append(contentsOf: hbs)
                    } else {
                        statsFailed = true
                        allEvents.append(contentsOf: events.filter { $0.agent_id == agentId })
                    }
                }
            }
        }

        // A newer load() call has started since this one began -- discard
        // this call's results entirely instead of letting a stale call
        // overwrite whatever the newer call already committed (or is about
        // to). This is what actually fixes the persistent-zero bug: the
        // slower of two overlapping calls no longer wins just by finishing last.
        guard generation == loadGeneration else { return }

        if let userResult { profileData = userResult }
        if let agentsResult { agents = agentsResult }
        if let noteCountResult { noteCount = noteCountResult }
        if let highlightCountResult { highlightCount = highlightCountResult }
        usage          = usageResult ?? usage
        if let friendRequestsResult { friendRequests = friendRequestsResult }
        if let (_, groupMap) = contactsResult { groups = groupMap }
        if eventsUsable { events = allEvents }

        // A genuine fetch/decode failure on any of the 7 concurrent fetches
        // above (or the per-agent events fetch) no longer looks visually
        // identical to "this account has none" -- surface it via this
        // screen's existing alert convention. Pull-to-refresh (already on
        // this screen) is the retry path; no new bespoke retry control is
        // introduced. (task 20260903-account-events-not-loading extended
        // this to cover events; task
        // 20260904-compliance-error-handling-consistency (H8) extended it
        // further to cover profile/usage/friend-requests/contacts, the
        // remaining 4 of 7 that previously bypassed this mechanism via a
        // bare `try?`.)
        if statsFailed {
            statsMsg = "We couldn't load some of your account data (notes, highlights, agents, events, or profile/usage info) just now. Pull down to refresh and try again."
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

    func createEvent(agentId: String, prompt: String, timestamps: [String?], groupId: String? = nil, notesPublic: Bool = false, idempotencyKey: String? = nil) async {
        guard let uid = profileData?.user_id else { return }
        let hb = FSHeartbeat(id: UUID().uuidString, agent_id: agentId, user_id: uid,
                             timestamps: timestamps, prompt: prompt, group_id: groupId, notes_public: notesPublic)
        do {
            try await service.addHeartbeat(userId: uid, agentId: agentId, heartbeat: hb, idempotencyKey: idempotencyKey)
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

        // Bug fix (cache-clobber sweep, task
        // 20260905-pull-to-refresh-cache-clobber): `try?` used to collapse a
        // genuine fetch failure to the same `nil` as a proven "no active
        // subscription" success, so a transient failure unconditionally
        // wrote `subscription = nil` below and nulled out an already-
        // displayed active plan. Track whether the fetch itself threw
        // separately, and bail out early on failure -- leaving
        // subscription/autoRenewOff/planEndDate and everything derived from
        // them untouched -- rather than reconciling downstream state from an
        // untrustworthy result.
        var plan: FSSubscription?
        do {
            plan = try await service.fetchUserSubscription(userId: userId)
        } catch {
            subMsg = "Could not refresh your subscription status. Pull down to refresh and try again."
            return
        }

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
