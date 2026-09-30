// SubscriptionInviteLinksTests.swift — task 20260930-subscription-seat-invites (testing gate).
//
// Covers the iOS side of subscription-seat invite links: preview decoding for
// the minimal subscription preview, failure mapping (other_plan / blocked copy),
// the join view model for a subscription link (a REQUEST, never membership),
// and the invite-links view model in plan mode (sibling routes, plan copy,
// not_eligible, per-kind cache). Uses the shared StubURLProtocol harness.

import XCTest
@testable import FellowScript

private let subToken = String(repeating: "S", count: 43)

@MainActor
final class SubscriptionInviteJoinTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(StubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(StubURLProtocol.self); super.tearDown() }
    override func setUp() { super.setUp(); StubURLProtocol.resetRequestLog() }

    private func stub(_ status: Int, _ body: String) {
        StubURLProtocol.stubStatusCode = status
        StubURLProtocol.stubBody = Data(body.utf8)
    }
    private let previewJSON = #"{"kind":"subscription","inviter_username":"olivia","plan_type":"group"}"#
    private func vm() -> JoinInviteViewModel { JoinInviteViewModel(service: NetworkService.shared, token: subToken) }

    func test_minimalSubscriptionPreview_decodes_withoutGroupFields() async {
        stub(200, previewJSON)
        let m = vm()
        await m.loadPreview()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.preview?.kind, "subscription")
        XCTAssertEqual(m.preview?.isSubscription, true)
        XCTAssertEqual(m.preview?.inviter_username, "olivia")
        XCTAssertEqual(m.preview?.plan_type, "group")
        XCTAssertEqual(m.preview?.group_name, "")
        XCTAssertEqual(m.preview?.member_count, 0)
        XCTAssertNil(m.preview?.photo_url)
    }

    func test_groupPreview_stillDecodes_andIsNotSubscription() async {
        stub(200, #"{"kind":"group","group_name":"Bible Crew","photo_url":null,"inviter_username":"sam","member_count":3}"#)
        let m = vm()
        await m.loadPreview()
        XCTAssertEqual(m.preview?.isSubscription, false)
        XCTAssertEqual(m.preview?.group_name, "Bible Crew")
        XCTAssertEqual(m.preview?.member_count, 3)
    }

    func test_previewMissingInviter_throwsNotFabricated() async {
        stub(200, #"{"kind":"subscription"}"#)
        let m = vm()
        await m.loadPreview()
        XCTAssertNil(m.preview)
        XCTAssertEqual(m.phase, .failed(.network))
    }

    func test_redeem_filesRequest_notMembership() async {
        stub(200, previewJSON)
        let m = vm()
        await m.loadPreview()
        stub(200, #"{"kind":"subscription","target_id":"s1","joined":false,"already_member":false,"requested":true,"pending":true}"#)
        let out = await m.join(userId: "u1")
        XCTAssertEqual(m.phase, .joined)
        XCTAssertEqual(m.requestOutcome, .requested)
        XCTAssertEqual(out?.result.joined, false, "a subscription redeem must never report membership")
        XCTAssertEqual(out?.result.requested, true)
        let req = StubURLProtocol.requestLog.last
        XCTAssertEqual(req?.path, "/api/invites/u1/redeem")
        XCTAssertEqual(req?.bodyJSON?["token"] as? String, subToken)
        XCTAssertFalse(req?.url.contains(subToken) ?? true)
    }

    func test_redeem_alreadyMember_outcome() async {
        stub(200, #"{"kind":"subscription","target_id":"s1","joined":false,"already_member":true}"#)
        let m = vm()
        _ = await m.join(userId: "u1")
        XCTAssertEqual(m.requestOutcome, .alreadyMember)
    }

    func test_groupRedeem_leavesRequestOutcomeNil() async {
        stub(200, #"{"kind":"group","target_id":"g1","joined":true,"already_member":false}"#)
        let m = vm()
        _ = await m.join(userId: "u1")
        XCTAssertNil(m.requestOutcome)
    }

    func test_failureMapping_otherPlan_andBlockedCopy() {
        func f(_ s: Int, _ c: String?) -> InviteFailure { InviteFailure(InviteAPIError(status: s, code: c, message: "m")) }
        XCTAssertEqual(f(409, "other_plan"), .otherPlan)
        XCTAssertEqual(f(409, "full"), .full)
        XCTAssertEqual(f(409, nil), .full)
        XCTAssertEqual(InviteFailure.otherPlan.title, "You're already on a paid plan.")
        XCTAssertFalse(InviteFailure.otherPlan.isRetryable)
        XCTAssertEqual(InviteFailure.blocked.title(subscription: true), "You can't request to join this plan.")
        XCTAssertEqual(InviteFailure.blocked.title(subscription: false), "You can't join this group.")
        XCTAssertEqual(InviteFailure.full.title(subscription: true), InviteFailure.full.title)
        XCTAssertNil(InviteFailure.blocked.body)
    }

    func test_redeem_otherPlan409_isTerminal_clearsPending() async {
        stub(409, #"{"detail":{"code":"other_plan","message":"x"}}"#)
        let m = vm()
        var terminal = 0
        m.onTerminal = { terminal += 1 }
        let out = await m.join(userId: "u1")
        XCTAssertNil(out)
        XCTAssertEqual(m.phase, .failed(.otherPlan))
        XCTAssertNil(m.requestOutcome)
        XCTAssertEqual(terminal, 1)
    }
}

@MainActor
final class SubscriptionInviteLinksViewModelTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(StubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(StubURLProtocol.self); super.tearDown() }
    override func setUp() { super.setUp(); StubURLProtocol.resetRequestLog() }

    private func stub(_ status: Int, _ body: String) {
        StubURLProtocol.stubStatusCode = status
        StubURLProtocol.stubBody = Data(body.utf8)
    }
    private func vm(sub: String = "s-\(UUID().uuidString)") -> InviteLinksViewModel {
        InviteLinksViewModel(service: NetworkService.shared, subscriptionId: sub, userId: "u1")
    }
    private let listJSON = """
    {"invites":[{"invite_id":"i1","created_by_username":"me","is_mine":true,"created_at":"2026-09-30T00:00:00Z","expires_at":"2026-10-07T00:00:00Z","max_uses":3,"use_count":1,"remaining_uses":2}],
     "options":{"default_expiry_days":7,"allowed_expiry_days":[1,7],"default_max_uses":3,"allowed_max_uses":[1,3],"max_active_links_per_subscription":3}}
    """

    func test_list_usesSubscriptionRoute_andDecodesOptionsWithoutGroupKey() async {
        stub(200, listJSON)
        let m = vm(sub: "sub-42")
        await m.load()
        XCTAssertTrue(m.isSubscription)
        XCTAssertEqual(m.list?.invites.count, 1)
        XCTAssertNil(m.list?.options.max_active_links_per_user_per_group)
        XCTAssertEqual(m.list?.options.max_active_links_per_subscription, 3)
        let req = StubURLProtocol.requestLog.last
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.path, "/api/invites/u1/subscriptions/sub-42")
    }

    func test_groupOptionsJSON_stillDecodes() async {
        stub(200, #"{"invites":[],"options":{"default_expiry_days":7,"allowed_expiry_days":[7],"default_max_uses":25,"allowed_max_uses":[25],"max_active_links_per_user_per_group":5}}"#)
        let m = InviteLinksViewModel(service: NetworkService.shared, groupId: "g-\(UUID().uuidString)", userId: "u1")
        await m.load()
        XCTAssertEqual(m.list?.options.max_active_links_per_user_per_group, 5)
        XCTAssertFalse(m.isSubscription)
        XCTAssertTrue(StubURLProtocol.requestLog.last?.path.contains("/groups/") ?? false)
    }

    func test_flagOff404_hides() async {
        stub(404, #"{"detail":"Not found"}"#)
        let m = vm()
        await m.load()
        XCTAssertTrue(m.unavailable)
        XCTAssertNil(m.list)
    }

    func test_create_postsToSubscriptionRoute_revealsOnce() async {
        stub(200, listJSON)
        let m = vm(sub: "sub-7")
        await m.load()
        let url = "https://fellowscript.com/join/\(subToken)"
        stub(200, #"{"invite_id":"n1","token":"\#(subToken)","url":"\#(url)","created_at":"2026-09-30T00:00:00Z","expires_at":"2026-10-07T00:00:00Z","max_uses":3,"use_count":0}"#)
        await m.create()
        XCTAssertEqual(m.revealedURL, url)
        let req = StubURLProtocol.requestLog.last
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.path, "/api/invites/u1/subscriptions/sub-7")
        XCTAssertEqual(req?.bodyJSON?["max_uses"] as? Int, 3)
        let encoded = String(data: try! JSONEncoder().encode(m.list!), encoding: .utf8)!
        XCTAssertFalse(encoded.contains(subToken))
    }

    func test_createErrors_usePlanCopy() async {
        stub(200, listJSON)
        let m = vm()
        await m.load()
        stub(409, #"{"detail":{"code":"not_eligible","message":"x"}}"#)
        await m.create()
        XCTAssertEqual(m.createError, "Invite links need an active plan with more than one seat.")
        stub(409, #"{"detail":{"code":"link_limit","message":"x"}}"#)
        await m.create()
        XCTAssertEqual(m.createError, "You have the maximum number of active links for this plan. Revoke one to make another.")
        stub(403, #"{"detail":"no"}"#)
        await m.create()
        XCTAssertEqual(m.createError, "You can't create an invite link for this plan.")
        XCTAssertNil(m.revealedURL)
    }

    func test_revoke403_usesPlanOwnerCopy() async {
        stub(200, listJSON)
        let m = vm()
        await m.load()
        stub(403, #"{"detail":"no"}"#)
        await m.revoke(m.list!.invites[0], reduceMotion: true)
        XCTAssertEqual(m.rowErrors["i1"], "Only the plan owner can revoke this link.")
        XCTAssertEqual(m.list?.invites.count, 1)
    }

    func test_reset_usesSubscriptionResetRoute() async {
        stub(200, listJSON)
        let m = vm(sub: "sub-9")
        await m.load()
        stub(200, #"{"revoked":1}"#)
        let ok = await m.resetAll()
        XCTAssertTrue(ok)
        XCTAssertEqual(m.resetStatus, "1 link revoked")
        XCTAssertEqual(StubURLProtocol.requestLog.last?.path, "/api/invites/u1/subscriptions/sub-9/reset")
    }
}
