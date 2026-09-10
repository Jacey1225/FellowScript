// NetworkService+Subscriptions.swift — plan lifecycle (start/cancel/seats),
// members/requests, and Apple StoreKit-2 transaction sync. Mirrors
// api/routes/subscription.py. Split out of NetworkService.swift (readability
// #H16, 20260904-frontend-arch-sweep) -- same type, same behavior, just this
// domain's own file. See NetworkService.swift's header comment for the full
// split rationale and the list of sibling domain files.

import Foundation

extension NetworkService {

    func fetchUserSubscription(userId: String) async throws -> FSSubscription? {
        // The backend returns 404 {"detail": "No active subscription"} when the
        // user is on no plan. FSSubscription's lenient decoder would otherwise
        // happily decode that error body into a default (bogus "individual")
        // plan, so explicitly treat that one documented status -- and any
        // subscription that came back without a real id -- as "no subscription".
        //
        // Root-cause fix (task 20260910-refresh-clobber-live-rootcause, spec
        // mechanism 5): this used to bypass `get()` entirely (raw
        // `URLSession.shared.data(from:)`, no requestTimeout override, no
        // retry, no throwIfError) AND treated every status >= 400 -- not just
        // the documented 404 -- as a silent "no subscription", including a
        // genuine 403/429/5xx. That's exactly the Q27 violation this task's
        // preference profile calls out (silently substituting a default for
        // an unproven result) and it's also what let the live-capture-
        // confirmed Cloudflare-edge 403 burst (frontend step 2's live
        // capture: an in-flight-guard-missing request storm from
        // AccountView's `.task`+`.refreshable`) pass through completely
        // unsurfaced. Now routed through `getRawResponse` (same
        // timeout + bounded-retry-on-5xx/transport-error hardening every
        // other read gets via `get()`), with ONLY the documented 404 mapped
        // to `nil`; every other non-2xx status goes through the same
        // `throwIfError` mapping (AppError.limitReached/.rateLimited/
        // .networkError) as everywhere else, so a genuine failure now
        // actually reaches `AccountViewModel.loadSubscription`'s catch block
        // instead of masquerading as "no active plan".
        let endpoint = "GET /subscriptions/user/{user_id}"
        let response: URLResponse
        let data: Data
        do {
            (data, response) = try await getRawResponse("/subscriptions/user/\(encodeURIComponent(userId))")
        } catch {
            RefreshDiagnostics.fetchOutcome(endpoint: endpoint, outcome: "failure",
                                             errorClass: RefreshDiagnostics.errorClass(error), taskCancelled: Task.isCancelled)
            throw error
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            RefreshDiagnostics.fetchOutcome(endpoint: endpoint, outcome: "http-error-status-404-no-subscription")
            return nil
        }
        do {
            try throwIfError(response, data)
        } catch {
            RefreshDiagnostics.fetchOutcome(endpoint: endpoint, outcome: "failure",
                                             errorClass: RefreshDiagnostics.errorClass(error), taskCancelled: Task.isCancelled)
            throw error
        }
        guard let sub = decode(FSSubscription.self, from: data), !sub.id.isEmpty else {
            RefreshDiagnostics.fetchOutcome(endpoint: endpoint, outcome: "decode-nil-or-empty-id")
            return nil
        }
        RefreshDiagnostics.fetchOutcome(endpoint: endpoint, outcome: "success", count: 1)
        return sub
    }

    // GET /subscriptions/user/{userId}/usage → free-tier usage snapshot.
    func fetchUsage(userId: String) async throws -> FSUsage? {
        let data = try await get("/subscriptions/user/\(encodeURIComponent(userId))/usage")
        return decode(FSUsage.self, from: data)
    }

    func startSubscription(userId: String, memberCount: Int, billing: FSBillingInfo?) async throws -> String {
        var body: [String: Any] = ["user_id": userId, "member_count": memberCount, "provider": "stripe"]
        if let b = billing {
            // Only non-sensitive billing metadata is transmitted.
            body["card_brand"]     = b.brand
            body["card_last4"]     = b.last4
            body["card_exp_month"] = b.expMonth
            body["card_exp_year"]  = b.expYear
        }
        // checkedRequestRaw (not requestRaw) so a real 400/403 rejection throws
        // with the server's actual detail instead of silently falling through
        // to the generic "Could not start plan." guard below.
        let data = try await checkedRequestRaw("/subscriptions/", method: "POST", jsonObject: body)
        guard let result = decode([String: String].self, from: data), let id = result["id"] else {
            throw AppError.networkError("Could not start plan.")
        }
        return id
    }

    func cancelSubscription(subscriptionId: String) async throws {
        _ = try await request("/subscriptions/\(encodeURIComponent(subscriptionId))", method: "DELETE")
    }

    // Host changes how many people the plan covers; server re-prices from member_count.
    func updateSubscriptionSeats(subscriptionId: String, memberCount: Int) async throws {
        // checkedRequestRaw so a 403 ("only the host may do this") or 404 (plan
        // gone) actually throws instead of being silently discarded — mirrors
        // updateUser()/createGroup() elsewhere in this file.
        _ = try await checkedRequestRaw("/subscriptions/\(encodeURIComponent(subscriptionId))", method: "PUT",
                                        jsonObject: ["member_count": memberCount])
    }

    func fetchSubMembers(subscriptionId: String) async throws -> [FSSubMember] {
        let data = try await get("/subscriptions/\(encodeURIComponent(subscriptionId))/members")
        return decode([FSSubMember].self, from: data) ?? []
    }

    func removeSubMember(subscriptionId: String, userId: String) async throws {
        _ = try await request("/subscriptions/\(encodeURIComponent(subscriptionId))/members/\(encodeURIComponent(userId))",
                              method: "DELETE")
    }

    func fetchSubRequests(subscriptionId: String) async throws -> [FSSubMember] {
        let data = try await get("/subscriptions/\(encodeURIComponent(subscriptionId))/requests")
        return decode([FSSubMember].self, from: data) ?? []
    }

    func fetchMySubRequests(userId: String) async throws -> [FSSubRequest] {
        let data = try await get("/subscriptions/user/\(encodeURIComponent(userId))/requests")
        return decode([FSSubRequest].self, from: data) ?? []
    }

    func requestJoinSubscription(subscriptionId: String, fromUserId: String) async throws {
        _ = try await request("/subscriptions/\(encodeURIComponent(subscriptionId))/requests?from_user_id=\(encodeURIComponent(fromUserId))",
                              method: "POST")
    }

    func acceptSubRequest(subscriptionId: String, fromUserId: String) async throws {
        _ = try await request("/subscriptions/\(encodeURIComponent(subscriptionId))/requests/\(encodeURIComponent(fromUserId))/accept",
                              method: "POST")
    }

    func declineSubRequest(subscriptionId: String, fromUserId: String) async throws {
        _ = try await request("/subscriptions/\(encodeURIComponent(subscriptionId))/requests/\(encodeURIComponent(fromUserId))",
                              method: "DELETE")
    }

    func syncAppleSubscription(userId: String, jws: String) async throws -> FSSubscription? {
        // Forwards a StoreKit 2 signed transaction; backend verifies + records.
        // This is the highest-stakes call in the app — real Apple money has
        // already changed hands by the time StoreKitManager.purchase() calls
        // this. checkedRequestRaw (not requestRaw) so a 400 (invalid
        // transaction / untrusted environment / unknown product) or 409
        // (subscription already linked to a different account) actually
        // throws instead of silently decoding an error body into a lenient,
        // bogus-default FSSubscription — StoreKitManager depends on this
        // throwing to know whether it's safe to finish() the transaction and
        // report the purchase as successful.
        let data = try await checkedRequestRaw("/subscriptions/apple/sync", method: "POST",
                                               jsonObject: ["user_id": userId, "jws": jws])
        // A successful "expired" response (`{"status": "expired"}`) has no id,
        // same as fetchUserSubscription's no-subscription case just above —
        // treat a missing id as "no active subscription" rather than a bogus
        // empty-id plan.
        guard let sub = decode(FSSubscription.self, from: data), !sub.id.isEmpty else { return nil }
        return sub
    }
}
