// FriendInviteOfferCodeTests.swift — task 20261003-ios-friend-offer-code-redeem,
// step 6. Covers NetworkService+Promo.swift (fetchFriendCode,
// requestIosOfferCode, signUp invite_code) against the real NetworkService via
// StubURLProtocol, and InviteCodeViewModel's throw-not-fabricate and
// cache-preserved-on-failed-refresh behavior. No live calls.

import XCTest
@testable import FellowScript

@MainActor
final class FriendInviteOfferCodeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.resetRequestLog()
    }

    private func stub(_ status: Int, _ body: String) {
        StubURLProtocol.stubStatusCode = status
        StubURLProtocol.stubBody = body.data(using: .utf8)!
    }

    private let okOffer = #"{"offer_code":"ABCD1234","redeem_url":"https://apps.apple.com/redeem?ctx=offercodes&id=1&code=ABCD1234","expires_at":null}"#

    // MARK: requestIosOfferCode

    func test_offerCode_success_decodesAndPostsCode() async throws {
        stub(200, okOffer)
        let offer = try await NetworkService.shared.requestIosOfferCode(userId: "u1", code: "FRIEND1")
        XCTAssertEqual(offer.offer_code, "ABCD1234")
        let req = try XCTUnwrap(StubURLProtocol.requestLog.last)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/api/promo/u1/ios-offer-code")
        XCTAssertEqual(req.bodyJSON?["code"] as? String, "FRIEND1")
    }

    func test_offerCode_statusMapping() async {
        let cases: [(Int, InviteCodeError)] = [
            (400, .invalid), (401, .invalid), (403, .invalid), (422, .invalid),
            (404, .disabled), (429, .rateLimited), (500, .unavailable), (503, .unavailable),
        ]
        for (status, expected) in cases {
            stub(status, #"{"detail":"invalid_invite_code"}"#)
            do {
                _ = try await NetworkService.shared.requestIosOfferCode(userId: "u1", code: "X")
                XCTFail("status \(status) must throw")
            } catch let e as InviteCodeError {
                XCTAssertEqual(e, expected, "status \(status)")
            } catch {
                XCTFail("status \(status): expected InviteCodeError, got \(error)")
            }
        }
    }

    func test_offerCode_malformedOrEmptyBody_throwsUnavailable_neverFabricates() async {
        for body in ["{}", #"{"offer_code":"","redeem_url":"https://apps.apple.com/x"}"#, "not json", ""] {
            stub(200, body)
            do {
                _ = try await NetworkService.shared.requestIosOfferCode(userId: "u1", code: "X")
                XCTFail("body \(body) must throw")
            } catch let e as InviteCodeError {
                XCTAssertEqual(e, .unavailable)
            } catch {
                XCTFail("expected InviteCodeError.unavailable, got \(error)")
            }
        }
    }

    func test_offerCode_errorMessagesDoNotRevealRejectionReason() {
        let msgs = [InviteCodeError.invalid, .rateLimited, .unavailable, .disabled].compactMap(\.errorDescription)
        XCTAssertEqual(msgs.count, 4)
        for m in msgs {
            let l = m.lowercased()
            for leak in ["own code", "already", "not a new", "expired", "exhausted", "cap"] {
                XCTAssertFalse(l.contains(leak), "\(m) leaks '\(leak)'")
            }
        }
    }

    func test_offerCode_isNotRetried() async {
        stub(503, "{}")
        _ = try? await NetworkService.shared.requestIosOfferCode(userId: "u1", code: "X")
        XCTAssertEqual(StubURLProtocol.requestLog.filter { $0.path.hasSuffix("/ios-offer-code") }.count, 1)
    }

    // MARK: fetchFriendCode

    func test_friendCode_success() async throws {
        stub(200, #"{"code":"MINE42","link":"https://fellowscript.com/?code=MINE42","percent_off":50}"#)
        let fc = try await NetworkService.shared.fetchFriendCode(userId: "u1")
        XCTAssertEqual(fc, FSFriendCode(code: "MINE42", link: "https://fellowscript.com/?code=MINE42", percent_off: 50))
        let req = try XCTUnwrap(StubURLProtocol.requestLog.last)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/api/promo/u1/friend-code")
    }

    func test_friendCode_404_returnsNil() async throws {
        stub(404, #"{"detail":"Not found"}"#)
        let fc = try await NetworkService.shared.fetchFriendCode(userId: "u1")
        XCTAssertNil(fc)
    }

    func test_friendCode_serverError_throws_andMalformedThrows() async {
        stub(500, #"{"detail":"boom"}"#)
        do { _ = try await NetworkService.shared.fetchFriendCode(userId: "u1"); XCTFail("500 must throw") } catch {}
        stub(200, "{}")
        do { _ = try await NetworkService.shared.fetchFriendCode(userId: "u1"); XCTFail("malformed must throw") } catch {}
    }

    // MARK: signUp invite_code

    func test_signUp_sendsInviteCodeWhenPresent_omitsWhenEmpty() async throws {
        stub(200, #"{"user_id":"u9","username":"n","email":"n@e.com"}"#)
        _ = try await NetworkService.shared.signUp(username: "n", email: "n@e.com", password: "pw", termsAccepted: true, inviteCode: "FRIEND1")
        XCTAssertEqual(StubURLProtocol.requestLog.last?.path, "/api/signup")
        XCTAssertEqual(StubURLProtocol.requestLog.last?.bodyJSON?["invite_code"] as? String, "FRIEND1")

        StubURLProtocol.resetRequestLog()
        _ = try await NetworkService.shared.signUp(username: "n", email: "n@e.com", password: "pw", termsAccepted: true, inviteCode: "")
        XCTAssertNil(StubURLProtocol.requestLog.last?.bodyJSON?["invite_code"])
        StubURLProtocol.resetRequestLog()
        _ = try await NetworkService.shared.signUp(username: "n", email: "n@e.com", password: "pw", termsAccepted: true, inviteCode: nil)
        XCTAssertNil(StubURLProtocol.requestLog.last?.bodyJSON?["invite_code"])
    }

    // MARK: InviteCodeViewModel

    func test_normalize_acceptsBareCodeAndLink() {
        XCTAssertEqual(InviteCodeViewModel.normalize("  ABC123 \n"), "ABC123")
        XCTAssertEqual(InviteCodeViewModel.normalize("https://fellowscript.com/?code=XYZ9"), "XYZ9")
        XCTAssertEqual(InviteCodeViewModel.normalize(String(repeating: "a", count: 200)).count, 64)
    }

    func test_viewModel_failedRefreshKeepsCachedCode() async {
        let uid = "vm-user-\(UUID().uuidString)"
        let vm = InviteCodeViewModel()
        vm.service = NetworkService.shared
        stub(200, #"{"code":"KEEP1","link":"https://fellowscript.com/?code=KEEP1","percent_off":50}"#)
        await vm.loadFriendCode(userId: uid)
        XCTAssertEqual(vm.friendCode?.code, "KEEP1")
        XCTAssertFalse(vm.friendCodeFailed)

        stub(500, #"{"detail":"down"}"#)
        await vm.loadFriendCode(userId: uid)
        XCTAssertEqual(vm.friendCode?.code, "KEEP1", "cache must survive a failed refresh")
        XCTAssertTrue(vm.friendCodeFailed)

        // A fresh view model (new launch) still sees the cached code while offline.
        let vm2 = InviteCodeViewModel()
        vm2.service = NetworkService.shared
        await vm2.loadFriendCode(userId: uid)
        XCTAssertEqual(vm2.friendCode?.code, "KEEP1")
        XCTAssertTrue(vm2.friendCodeFailed)
        await DiskCache.shared.remove(forKey: "friendcode_\(uid)")
    }

    func test_viewModel_404HidesShareSection() async {
        let vm = InviteCodeViewModel()
        vm.service = NetworkService.shared
        stub(404, "{}")
        await vm.loadFriendCode(userId: "vm-404-\(UUID().uuidString)")
        XCTAssertTrue(vm.shareHidden)
        XCTAssertNil(vm.friendCode)
    }

    func test_viewModel_redeemFailures_surfaceUniformMessage_noRedeemFlow() async {
        let vm = InviteCodeViewModel()
        vm.service = NetworkService.shared
        var resynced = false
        vm.codeInput = "BADCODE"
        stub(400, #"{"detail":"invalid_invite_code"}"#)
        await vm.redeem(userId: "u1") { resynced = true }
        XCTAssertEqual(vm.redeemMsg, InviteCodeError.invalid.errorDescription)
        XCTAssertNil(vm.redeemInfo)
        XCTAssertFalse(resynced, "no resync/redeem sheet on failure")
        XCTAssertEqual(vm.codeInput, "BADCODE", "input kept for correction")
        XCTAssertFalse(vm.redeemBusy)

        stub(429, "{}")
        await vm.redeem(userId: "u1") { resynced = true }
        XCTAssertEqual(vm.redeemMsg, InviteCodeError.rateLimited.errorDescription)

        stub(503, "{}")
        await vm.redeem(userId: "u1") { resynced = true }
        XCTAssertEqual(vm.redeemMsg, InviteCodeError.unavailable.errorDescription)

        stub(404, "{}")
        await vm.redeem(userId: "u1") { resynced = true }
        XCTAssertTrue(vm.redeemHidden)
        XCTAssertFalse(resynced)
    }

    func test_viewModel_redeem_emptyInputMakesNoRequest() async {
        let vm = InviteCodeViewModel()
        vm.service = NetworkService.shared
        vm.codeInput = "   "
        await vm.redeem(userId: "u1") { }
        XCTAssertTrue(StubURLProtocol.requestLog.isEmpty)
    }
}
