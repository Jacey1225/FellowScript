// GroupInviteLinksTests.swift — task 20260929-group-invite-links (testing gate).
//
// Covers: strict invite URL parsing (universal link + custom scheme; malformed,
// foreign host, extra path all rejected), the pending-invite store living in the
// Keychain (not UserDefaults) with a 24h TTL, AppState pending-invite lifecycle
// (set / replace / clear on sign-out / ignore non-invite URLs), the join
// view-model state machine and exact failure mapping, the network layer
// (token only in POST bodies, throw-not-fabricate), and feature-flag 404
// handling in the invite-links section view model.
//
// Uses the shared StubURLProtocol harness from
// NetworkServiceGetErrorHandlingTests.swift against the real NetworkService.

import XCTest
import Security
@testable import FellowScript

private let goodToken = String(repeating: "A", count: 43)
private let otherToken = String(repeating: "b", count: 42) + "_"

// MARK: - URL parsing

final class InviteLinkParsingTests: XCTestCase {
    private func t(_ s: String) -> String? { URL(string: s).flatMap(InviteLink.token(from:)) }

    func test_universalLink_parses() {
        XCTAssertEqual(t("https://fellowscript.com/join/\(goodToken)"), goodToken)
        XCTAssertEqual(t("https://www.fellowscript.com/join/\(goodToken)"), goodToken)
        XCTAssertEqual(t("https://FellowScript.com/join/\(goodToken)/"), goodToken)
        XCTAssertEqual(t("https://fellowscript.com/join/\(otherToken)"), otherToken)
    }

    func test_customScheme_parses() {
        XCTAssertEqual(t("com.fellowscript.app://join/\(goodToken)"), goodToken)
    }

    func test_rejects_foreignHosts_and_lookalikes() {
        XCTAssertNil(t("https://evil.com/join/\(goodToken)"))
        XCTAssertNil(t("https://fellowscript.com.evil.com/join/\(goodToken)"))
        XCTAssertNil(t("https://evilfellowscript.com/join/\(goodToken)"))
        XCTAssertNil(t("https://fellowscript.com@evil.com/join/\(goodToken)"))
    }

    func test_rejects_wrongScheme() {
        XCTAssertNil(t("http://fellowscript.com/join/\(goodToken)"))
        XCTAssertNil(t("ftp://fellowscript.com/join/\(goodToken)"))
        XCTAssertNil(t("otherapp://join/\(goodToken)"))
        XCTAssertNil(t("javascript:alert(1)"))
    }

    func test_rejects_extraOrWrongPath() {
        XCTAssertNil(t("https://fellowscript.com/join/\(goodToken)/extra"))
        XCTAssertNil(t("https://fellowscript.com/x/join/\(goodToken)"))
        XCTAssertNil(t("https://fellowscript.com/invite/\(goodToken)"))
        XCTAssertNil(t("https://fellowscript.com/join"))
        XCTAssertNil(t("https://fellowscript.com/join/"))
        XCTAssertNil(t("com.fellowscript.app://join/\(goodToken)/extra"))
        XCTAssertNil(t("com.fellowscript.app://other/\(goodToken)"))
        XCTAssertNil(t("com.fellowscript.app://\(goodToken)"))
    }

    func test_rejects_malformedTokens() {
        XCTAssertNil(t("https://fellowscript.com/join/abc"))
        XCTAssertNil(t("https://fellowscript.com/join/\(String(repeating: "A", count: 42))"))
        XCTAssertNil(t("https://fellowscript.com/join/\(String(repeating: "A", count: 44))"))
        XCTAssertNil(t("https://fellowscript.com/join/\(String(repeating: "A", count: 42))!"))
        XCTAssertNil(t("https://fellowscript.com/join/\(String(repeating: "A", count: 42))."))
        XCTAssertNil(t("https://fellowscript.com/join/\(String(repeating: "\u{00E9}", count: 43))"))
    }

    func test_isWellFormed() {
        XCTAssertTrue(InviteLink.isWellFormed(goodToken))
        XCTAssertTrue(InviteLink.isWellFormed(otherToken))
        XCTAssertFalse(InviteLink.isWellFormed(""))
        XCTAssertFalse(InviteLink.isWellFormed(String(repeating: "A", count: 43) + "A"))
    }
}

// MARK: - Keychain store

final class PendingInviteStoreTests: XCTestCase {
    override func setUp() { super.setUp(); PendingInviteStore.clear() }
    override func tearDown() { PendingInviteStore.clear(); super.tearDown() }

    func test_saveLoadClear_roundTrip() {
        XCTAssertNil(PendingInviteStore.load())
        XCTAssertTrue(PendingInviteStore.save(goodToken))
        XCTAssertEqual(PendingInviteStore.load(), goodToken)
        PendingInviteStore.clear()
        XCTAssertNil(PendingInviteStore.load())
    }

    func test_newestReplacesOlder() {
        PendingInviteStore.save(goodToken)
        PendingInviteStore.save(otherToken)
        XCTAssertEqual(PendingInviteStore.load(), otherToken)
    }

    func test_rejectsMalformedToken() {
        XCTAssertFalse(PendingInviteStore.save("short"))
        XCTAssertNil(PendingInviteStore.load())
    }

    func test_expiresAfter24h_andIsPurged() {
        let saved = Date()
        PendingInviteStore.save(goodToken, now: saved)
        XCTAssertEqual(PendingInviteStore.load(now: saved.addingTimeInterval(PendingInviteStore.ttl)), goodToken)
        XCTAssertNil(PendingInviteStore.load(now: saved.addingTimeInterval(PendingInviteStore.ttl + 1)))
        XCTAssertNil(PendingInviteStore.load(now: saved), "expired entry must have been deleted, not just hidden")
    }

    func test_ttlIs24Hours() { XCTAssertEqual(PendingInviteStore.ttl, 86_400) }

    func test_storedInKeychain_notUserDefaults() {
        PendingInviteStore.save(goodToken)
        // Present in the Keychain under the dedicated service...
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.fellowscript.app.pending-invite",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &out), errSecSuccess)
        let attrs = out as? [String: Any]
        XCTAssertEqual(attrs?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        // ...and nowhere in UserDefaults, in any form.
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        XCTAssertFalse("\(defaults)".contains(goodToken))
    }

    func test_corruptEntryIsDiscarded() {
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.fellowscript.app.pending-invite",
            kSecAttrAccount as String: "token",
            kSecValueData as String: Data("not json".utf8),
        ]
        SecItemDelete(add as CFDictionary)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        XCTAssertNil(PendingInviteStore.load())
    }
}

// MARK: - AppState lifecycle

@MainActor
final class AppStatePendingInviteTests: XCTestCase {
    override func setUp() { super.setUp(); PendingInviteStore.clear() }
    override func tearDown() { PendingInviteStore.clear(); super.tearDown() }

    private func makeState() -> AppState { AppState(service: ThrowingTestDataService()) }

    func test_universalLink_setsPending_andPersistsToKeychain() {
        let s = makeState()
        s.handleIncomingURL(URL(string: "https://fellowscript.com/join/\(goodToken)")!)
        XCTAssertEqual(s.pendingInviteToken, goodToken)
        XCTAssertEqual(PendingInviteStore.load(), goodToken)
    }

    func test_customScheme_setsPending() {
        let s = makeState()
        s.handleIncomingURL(URL(string: "com.fellowscript.app://join/\(goodToken)")!)
        XCTAssertEqual(s.pendingInviteToken, goodToken)
    }

    func test_nonInviteAndForeignURLs_areIgnored() {
        let s = makeState()
        s.handleIncomingURL(URL(string: "https://evil.com/join/\(goodToken)")!)
        s.handleIncomingURL(URL(string: "https://fellowscript.com/join/bad")!)
        s.handleIncomingURL(URL(string: "com.fellowscript.app://open")!)
        XCTAssertNil(s.pendingInviteToken)
        XCTAssertNil(PendingInviteStore.load())
    }

    func test_newerLinkReplacesOlder() {
        let s = makeState()
        s.handleIncomingURL(URL(string: "https://fellowscript.com/join/\(goodToken)")!)
        s.handleIncomingURL(URL(string: "https://fellowscript.com/join/\(otherToken)")!)
        XCTAssertEqual(s.pendingInviteToken, otherToken)
        XCTAssertEqual(PendingInviteStore.load(), otherToken)
    }

    func test_coldLaunch_restoresPendingFromKeychain() {
        PendingInviteStore.save(goodToken)
        XCTAssertEqual(makeState().pendingInviteToken, goodToken)
    }

    func test_clear_consumesOnce_andResetsDeferral() {
        let s = makeState()
        s.setPendingInvite(goodToken)
        s.inviteDeferredForAuth = true
        s.clearPendingInvite()
        XCTAssertNil(s.pendingInviteToken)
        XCTAssertNil(PendingInviteStore.load())
        XCTAssertFalse(s.inviteDeferredForAuth)
    }

    func test_signOut_clearsPendingInvite() {
        let s = makeState()
        s.setPendingInvite(goodToken)
        s.signOut()
        XCTAssertNil(s.pendingInviteToken)
        XCTAssertNil(PendingInviteStore.load())
    }
}

// MARK: - Failure mapping + view model + network

@MainActor
final class JoinInviteViewModelTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(StubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(StubURLProtocol.self); super.tearDown() }
    override func setUp() { super.setUp(); StubURLProtocol.resetRequestLog() }

    private func stub(_ status: Int, _ body: String) {
        StubURLProtocol.stubStatusCode = status
        StubURLProtocol.stubBody = Data(body.utf8)
    }
    private let previewJSON = #"{"kind":"group","group_name":"Bible Crew","photo_url":null,"inviter_username":"sam","member_count":3}"#
    private func vm() -> JoinInviteViewModel { JoinInviteViewModel(service: NetworkService.shared, token: goodToken) }

    // Exact copy + mapping
    func test_failureMapping_andCopy() {
        func f(_ status: Int, _ code: String? = nil) -> InviteFailure {
            InviteFailure(InviteAPIError(status: status, code: code, message: "m"))
        }
        XCTAssertEqual(f(0), .network)
        XCTAssertEqual(f(503), .network)
        XCTAssertEqual(f(429), .rateLimited)
        XCTAssertEqual(f(404), .invalid)
        XCTAssertEqual(f(410, "revoked"), .revoked)
        XCTAssertEqual(f(410, "expired"), .expired)
        XCTAssertEqual(f(410), .expired)
        XCTAssertEqual(f(409), .full)
        XCTAssertEqual(f(409, "full"), .full)
        XCTAssertEqual(f(409, "group_full"), .groupFull)
        XCTAssertEqual(f(409, "other_plan"), .otherPlan)
        XCTAssertEqual(f(403), .blocked)
        XCTAssertEqual(InviteFailure.blocked.title, "You can't join this group.")
        XCTAssertNil(InviteFailure.blocked.body, "blocked copy must not hint at why")
        XCTAssertEqual(InviteFailure.invalid.title, "This invite link isn't valid anymore")
        XCTAssertEqual(InviteFailure.expired.title, "This invite link has expired.")
        XCTAssertEqual(InviteFailure.revoked.title, "This invite link was revoked.")
        XCTAssertEqual(InviteFailure.full.title, "This invite link has reached its limit.")
        XCTAssertEqual(InviteFailure.groupFull.title, "This group is full.")
        XCTAssertNotEqual(InviteFailure.groupFull.title, InviteFailure.full.title)
        XCTAssertTrue(InviteFailure.rateLimited.isRetryable)
        XCTAssertTrue(InviteFailure.network.isRetryable)
        for terminal in [InviteFailure.invalid, .expired, .revoked, .full, .groupFull, .blocked] { XCTAssertFalse(terminal.isRetryable) }
    }

    func test_preview_success_readyState_andTokenOnlyInBody() async {
        stub(200, previewJSON)
        let m = vm()
        await m.loadPreview()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.preview?.group_name, "Bible Crew")
        XCTAssertEqual(m.preview?.inviter_username, "sam")
        XCTAssertEqual(m.preview?.member_count, 3)
        let req = StubURLProtocol.requestLog.last
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.path, "/api/invites/preview")
        XCTAssertFalse(req?.url.contains(goodToken) ?? true)
        XCTAssertEqual(req?.bodyJSON?["token"] as? String, goodToken)
    }

    func test_preview404_isTerminal_clearsPending() async {
        stub(404, #"{"detail":"Not found"}"#)
        let m = vm()
        var terminal = 0
        m.onTerminal = { terminal += 1 }
        await m.loadPreview()
        XCTAssertEqual(m.phase, .failed(.invalid))
        XCTAssertNil(m.preview)
        XCTAssertEqual(terminal, 1)
    }

    func test_preview429_isRetryable_keepsPending() async {
        stub(429, #"{"detail":"slow"}"#)
        let m = vm()
        var terminal = 0
        m.onTerminal = { terminal += 1 }
        await m.loadPreview()
        XCTAssertEqual(m.phase, .failed(.rateLimited))
        XCTAssertEqual(terminal, 0)
        stub(200, previewJSON)
        await m.loadPreview()
        XCTAssertEqual(m.phase, .ready)
    }

    func test_undecodablePreview_throws_notFabricated() async {
        stub(200, #"{"unexpected":true}"#)
        let m = vm()
        await m.loadPreview()
        XCTAssertNil(m.preview)
        XCTAssertEqual(m.phase, .failed(.network))
    }

    func test_join_success_and_alreadyMember() async {
        stub(200, #"{"kind":"group","target_id":"g1","joined":true,"already_member":false}"#)
        var m = vm()
        var out = await m.join(userId: "u1")
        XCTAssertEqual(m.phase, .joined)
        XCTAssertEqual(out?.result.target_id, "g1")
        XCTAssertEqual(out?.sessionExpired, false)
        let req = StubURLProtocol.requestLog.last
        XCTAssertEqual(req?.path, "/api/invites/u1/redeem")
        XCTAssertEqual(req?.bodyJSON?["token"] as? String, goodToken)
        XCTAssertFalse(req?.url.contains(goodToken) ?? true)

        stub(200, #"{"kind":"group","target_id":"g1","joined":false,"already_member":true}"#)
        m = vm()
        out = await m.join(userId: "u1")
        XCTAssertEqual(m.phase, .joined)
        XCTAssertEqual(out?.result.already_member, true)
    }

    func test_join_terminalErrors() async {
        let cases: [(Int, String, InviteFailure)] = [
            (410, #"{"detail":{"code":"expired","message":"x"}}"#, .expired),
            (410, #"{"detail":{"code":"revoked","message":"x"}}"#, .revoked),
            (409, #"{"detail":{"code":"full","message":"x"}}"#, .full),
            (409, #"{"detail":{"code":"group_full","message":"This group is full."}}"#, .groupFull),
            (403, #"{"detail":{"code":"blocked","message":"x"}}"#, .blocked),
            (404, #"{"detail":"Not found"}"#, .invalid),
        ]
        for (status, body, expected) in cases {
            stub(status, body)
            let m = vm()
            var terminal = 0
            m.onTerminal = { terminal += 1 }
            let out = await m.join(userId: "u1")
            XCTAssertNil(out)
            XCTAssertEqual(m.phase, .failed(expected), "status \(status)")
            XCTAssertEqual(terminal, 1, "status \(status) must clear the pending invite")
        }
    }

    func test_join_retryableErrors_keepPending_andRetryActionIsRedeem() async {
        stub(429, #"{"detail":"slow"}"#)
        let m = vm()
        var terminal = 0
        m.onTerminal = { terminal += 1 }
        _ = await m.join(userId: "u1")
        XCTAssertEqual(m.phase, .failed(.rateLimited))
        XCTAssertEqual(terminal, 0)
        XCTAssertTrue(m.retryAction())
    }

    func test_join_401_returnsSessionExpired_keepsPending_noFailure() async {
        stub(401, #"{"detail":"Not authenticated"}"#)
        let m = vm()
        var terminal = 0
        m.onTerminal = { terminal += 1 }
        let out = await m.join(userId: "u1")
        XCTAssertEqual(out?.sessionExpired, true)
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(terminal, 0)
    }

    func test_join_ignoredWhileAlreadyJoining() async {
        stub(200, #"{"kind":"group","target_id":"g1","joined":true,"already_member":false}"#)
        let m = vm()
        m.phase = .joining
        let out = await m.join(userId: "u1")
        XCTAssertNil(out)
        XCTAssertTrue(StubURLProtocol.requestLog.isEmpty, "double tap must not send a second redeem")
    }
}

// MARK: - Invite links section (feature flag + show-once)

@MainActor
final class InviteLinksViewModelTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(StubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(StubURLProtocol.self); super.tearDown() }
    override func setUp() { super.setUp(); StubURLProtocol.resetRequestLog() }

    private func stub(_ status: Int, _ body: String) {
        StubURLProtocol.stubStatusCode = status
        StubURLProtocol.stubBody = Data(body.utf8)
    }
    private func vm(group: String = "g-\(UUID().uuidString)") -> InviteLinksViewModel {
        InviteLinksViewModel(service: NetworkService.shared, groupId: group, userId: "u1")
    }
    private let listJSON = """
    {"invites":[{"invite_id":"i1","created_by_username":"ann","is_mine":false,"created_at":"2026-09-30T00:00:00Z","expires_at":"2026-10-07T00:00:00Z","max_uses":25,"use_count":3,"remaining_uses":22}],
     "options":{"default_expiry_days":7,"allowed_expiry_days":[1,7,30],"default_max_uses":25,"allowed_max_uses":[1,5,25],"max_active_links_per_user_per_group":5}}
    """

    func test_flagOff404_hidesSection_noErrorShown() async {
        stub(404, #"{"detail":"Not found"}"#)
        let m = vm()
        await m.load()
        XCTAssertTrue(m.unavailable)
        XCTAssertNil(m.list)
        XCTAssertNil(m.loadError)
    }

    func test_list_isMetadataOnly() async {
        stub(200, listJSON)
        let m = vm()
        await m.load()
        XCTAssertFalse(m.unavailable)
        XCTAssertEqual(m.list?.invites.count, 1)
        XCTAssertEqual(m.list?.invites.first?.remaining_uses, 22)
        XCTAssertNil(m.revealedURL)
        XCTAssertEqual(StubURLProtocol.requestLog.last?.method, "GET")
    }

    func test_failedFirstLoad_showsError_notFabricatedEmpty() async {
        stub(500, #"{"detail":"boom"}"#)
        let m = vm()
        await m.load()
        XCTAssertNil(m.list)
        XCTAssertEqual(m.loadError, "Couldn't load invite links.")
    }

    func test_failedRefresh_keepsLastGoodList() async {
        stub(200, listJSON)
        let m = vm()
        await m.load()
        stub(500, #"{"detail":"boom"}"#)
        await m.load()
        XCTAssertEqual(m.list?.invites.count, 1)
        XCTAssertTrue(m.refreshFailed)
        XCTAssertNil(m.loadError)
    }

    func test_403_onList_flagsRemovedFromGroup() async {
        stub(403, #"{"detail":"no"}"#)
        let m = vm()
        await m.load()
        XCTAssertTrue(m.removedFromGroup)
    }

    func test_create_revealsLinkOnce_andListRowHasNoLink() async {
        stub(200, listJSON)
        let m = vm()
        await m.load()
        let url = "https://fellowscript.com/join/\(goodToken)"
        stub(200, #"{"invite_id":"n1","token":"\#(goodToken)","url":"\#(url)","created_at":"2026-09-30T00:00:00Z","expires_at":"2026-10-07T00:00:00Z","max_uses":25,"use_count":0}"#)
        await m.create()
        XCTAssertEqual(m.revealedURL, url)
        XCTAssertEqual(m.list?.invites.first?.invite_id, "n1")
        XCTAssertEqual(m.list?.invites.first?.remaining_uses, 25)
        let req = StubURLProtocol.requestLog.last
        XCTAssertEqual(req?.method, "POST")
        // Group links never expire: the create body must not carry an expiry.
        XCTAssertNil(req?.bodyJSON?["expires_in_days"], "group create must not send expires_in_days")
        XCTAssertEqual(req?.bodyJSON?["max_uses"] as? Int, 25)
        // Encoded list rows (what is cached to disk) never carry a token/url.
        let encoded = String(data: try! JSONEncoder().encode(m.list!), encoding: .utf8)!
        XCTAssertFalse(encoded.contains(goodToken))
    }

    func test_createErrors_areSurfaced() async {
        stub(200, listJSON)
        let m = vm()
        await m.load()
        stub(409, #"{"detail":{"code":"link_limit","message":"x"}}"#)
        await m.create()
        XCTAssertEqual(m.createError, "You have the maximum number of active links for this group. Revoke one to make another.")
        XCTAssertNil(m.revealedURL)
        stub(429, #"{"detail":"slow"}"#)
        await m.create()
        XCTAssertEqual(m.createError, "Too many tries. Wait a minute and try again.")
    }

    func test_revoke_removesRow_andFailureKeepsIt() async {
        stub(200, listJSON)
        let m = vm()
        await m.load()
        let item = m.list!.invites[0]
        stub(403, #"{"detail":"no"}"#)
        await m.revoke(item, reduceMotion: true)
        XCTAssertEqual(m.list?.invites.count, 1)
        XCTAssertEqual(m.rowErrors["i1"], "Only the person who made this link, or the group creator, can revoke it.")
        stub(200, "{}")
        await m.revoke(item, reduceMotion: true)
        XCTAssertEqual(m.list?.invites.count, 0)
        XCTAssertEqual(StubURLProtocol.requestLog.last?.method, "DELETE")
    }

    func test_reset_clearsRows_andReportsCount() async {
        stub(200, listJSON)
        let m = vm()
        await m.load()
        stub(200, #"{"revoked":2}"#)
        let ok = await m.resetAll()
        XCTAssertTrue(ok)
        XCTAssertEqual(m.list?.invites.count, 0)
        XCTAssertEqual(m.resetStatus, "2 links revoked")
    }
}
