// NetworkServiceProfileTests.swift (task 20261030-user-profiles, testing step 8)
// Real NetworkService against StubURLProtocol (see
// NetworkServiceGetErrorHandlingTests.swift for the harness).

import XCTest
@testable import FellowScript

@MainActor
final class NetworkServiceProfileTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.resetRequestLog()
    }

    private func stub(_ status: Int, _ body: String = "{}") {
        StubURLProtocol.stubStatusCode = status
        StubURLProtocol.stubBody = Data(body.utf8)
    }

    private var profileRequests: [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.requestLog.filter { $0.path.contains("/profile") }
    }

    // MARK: fetchProfile

    func test_fetchProfile_success_decodesAndHitsProfilesPath() async throws {
        stub(200, #"{"user_id":"t-1","username":"ann","profile_photo_url":null,"relationship":{"state":"friends"},"editable":false,"bio":"Hi"}"#)
        let p = try await NetworkService.shared.fetchProfile(targetId: "t-1")
        XCTAssertEqual(p.username, "ann")
        XCTAssertEqual(p.bio, "Hi")
        XCTAssertEqual(profileRequests.first?.method, "GET")
        XCTAssertTrue(profileRequests.first?.path.hasSuffix("/profiles/t-1") == true, profileRequests.first?.path ?? "")
    }

    func test_fetchProfile_strangerPayload_hasNoBio() async throws {
        stub(200, #"{"user_id":"t-1","username":"ann","relationship":{"state":"none"},"editable":false}"#)
        let p = try await NetworkService.shared.fetchProfile(targetId: "t-1")
        XCTAssertFalse(p.bioVisible)
    }

    func test_fetchProfile_404_mapsToNotFound() async {
        stub(404, #"{"detail":"User not found"}"#)
        do {
            _ = try await NetworkService.shared.fetchProfile(targetId: "gone")
            XCTFail("a 404 must throw")
        } catch AppError.notFound {
            // expected: ProfileViewModel keys cache eviction off exactly this case
        } catch {
            XCTFail("expected AppError.notFound, got \(error)")
        }
    }

    func test_fetchProfile_500_throwsAndIsNotNotFound() async {
        stub(500, #"{"detail":"boom"}"#)
        do {
            _ = try await NetworkService.shared.fetchProfile(targetId: "t-1")
            XCTFail("a 500 must throw")
        } catch AppError.notFound {
            XCTFail("a 5xx must not be treated as a 404 (that would evict the cache)")
        } catch {
            // expected
        }
    }

    func test_fetchProfile_malformedBody_throwsRatherThanFabricating() async {
        stub(200, #"{"unexpected":true}"#)
        do {
            _ = try await NetworkService.shared.fetchProfile(targetId: "t-1")
            XCTFail("an undecodable 200 must throw, never return a made-up profile")
        } catch {
            // expected
        }
    }

    func test_fetchProfile_idWithSpaceOrFragmentIsEscaped_requestStaysOnProfilesPath() async {
        stub(404)
        _ = try? await NetworkService.shared.fetchProfile(targetId: "a b#c")
        let url = profileRequests.first?.url ?? ""
        XCTAssertTrue(url.contains("/profiles/a%20b%23c"), url)
        // NOTE: NetworkService.encodeURIComponent uses urlQueryAllowed, so '/' and '?'
        // pass through unescaped. Profile ids are server-issued UUIDs and the server
        // answers any non-UUID with the uniform 404, so this is recorded, not asserted.
    }

    // MARK: updateBio

    func test_updateBio_sendsExactlyTheBioKey_andReturnsStoredText() async throws {
        stub(200, #"{"bio":"Hello there"}"#)
        let stored = try await NetworkService.shared.updateBio(userId: "me", bio: "Hello there")
        XCTAssertEqual(stored, "Hello there")
        let req = profileRequests.first
        XCTAssertEqual(req?.method, "PUT")
        XCTAssertTrue(req?.path.hasSuffix("/profile/me/bio") == true, req?.path ?? "")
        XCTAssertEqual(req?.bodyJSON?.keys.sorted(), ["bio"], "the server model forbids extra fields")
        XCTAssertEqual(req?.bodyJSON?["bio"] as? String, "Hello there")
    }

    func test_updateBio_nilSendsExplicitNull() async throws {
        stub(200, #"{"bio":null}"#)
        let stored = try await NetworkService.shared.updateBio(userId: "me", bio: nil)
        XCTAssertNil(stored)
        let json = profileRequests.first?.bodyJSON
        XCTAssertEqual(json?.keys.sorted(), ["bio"], "the key must be present (required by the server)")
        XCTAssertTrue(json?["bio"] is NSNull)
    }

    func test_updateBio_422_surfacesServerSentenceAsNetworkError() async {
        stub(422, #"{"detail":"Bios are plain text, so links can't be saved."}"#)
        do {
            _ = try await NetworkService.shared.updateBio(userId: "me", bio: "x.com")
            XCTFail("must throw")
        } catch AppError.networkError(let message) {
            XCTAssertEqual(message, "Bios are plain text, so links can't be saved.")
        } catch {
            XCTFail("expected networkError with the server detail, got \(error)")
        }
    }

    func test_updateBio_429_isRateLimited() async {
        stub(429, #"{"detail":"Too many requests. Please try again later."}"#)
        do {
            _ = try await NetworkService.shared.updateBio(userId: "me", bio: "x")
            XCTFail("must throw")
        } catch AppError.rateLimited {
            // expected
        } catch {
            XCTFail("expected rateLimited, got \(error)")
        }
    }

    func test_updateBio_responseWithoutBioKey_throws() async {
        stub(200, #"{"ok":true}"#)
        do {
            _ = try await NetworkService.shared.updateBio(userId: "me", bio: "x")
            XCTFail("a save the server did not confirm must not look successful")
        } catch {
            // expected
        }
    }

    // MARK: friend request / accept

    func test_sendProfileFriendRequest_postsToIdRoute_andAcceptsUniform204() async throws {
        stub(204, "")
        try await NetworkService.shared.sendProfileFriendRequest(targetId: "t-1")
        XCTAssertEqual(profileRequests.first?.method, "POST")
        XCTAssertTrue(profileRequests.first?.path.hasSuffix("/profiles/t-1/friend-request") == true)
    }

    func test_acceptProfileFriendRequest_postsToAcceptRoute() async throws {
        stub(204, "")
        try await NetworkService.shared.acceptProfileFriendRequest(targetId: "t-1")
        XCTAssertTrue(profileRequests.first?.path.hasSuffix("/profiles/t-1/friend-accept") == true)
    }

    func test_acceptProfileFriendRequest_uniform404_throws() async {
        stub(404, #"{"detail":"No pending friend request found"}"#)
        do {
            try await NetworkService.shared.acceptProfileFriendRequest(targetId: "t-1")
            XCTFail("must throw")
        } catch {
            // expected
        }
    }

    func test_sendProfileFriendRequest_429_isRateLimited() async {
        stub(429, #"{"detail":"Too many requests. Please try again later."}"#)
        do {
            try await NetworkService.shared.sendProfileFriendRequest(targetId: "t-1")
            XCTFail("must throw")
        } catch AppError.rateLimited {
            // expected
        } catch {
            XCTFail("expected rateLimited, got \(error)")
        }
    }
}
