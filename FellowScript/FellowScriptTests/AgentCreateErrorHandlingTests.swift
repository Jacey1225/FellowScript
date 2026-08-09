// AgentCreateErrorHandlingTests.swift — regression coverage for
// task: 20260808-ios-backend-integration-audit, backend step 11 finding #2 /
// frontend step 12 fix.
//
// NetworkService.createAgent() previously used the unchecked `requestRaw`
// (no throwIfError) and, on ANY failure to decode an "id" out of the
// response — a network error, a 4xx/5xx rejection, or simply a malformed
// body — fell through to `return FSAgent(id: UUID().uuidString, ...)`:
// fabricating a plausible-looking success value with a client-generated id
// instead of surfacing failure at all. Backend step 11 called this out as
// "the worst instance" of the audit's silent-failure pattern, since it
// invents a success rather than merely dropping one.
//
// The fix switched to `checkedRequestRaw` and replaced the fabricated
// fallback with a thrown AppError.networkError.
//
// Exercised against the real NetworkService (not MockDataService) via the
// StubURLProtocol harness shared with NetworkServiceGetErrorHandlingTests /
// GroupCreateUpdateErrorHandlingTests, since the bug lives in NetworkService's
// HTTP/decode handling itself.
//
// Verified here via `swiftc -parse` only — no Xcode/simulator available in
// this environment (see prior steps' identical constraint note).

import XCTest
@testable import FellowScript

final class AgentCreateErrorHandlingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    /// Before the fix: a 422 (e.g. free-tier limit or content-filter
    /// rejection) fell through to the fabricated-agent fallback instead of
    /// throwing.
    func test_createAgent_throws_on422_insteadOfFabricatingAgent() async {
        StubURLProtocol.stubStatusCode = 422
        StubURLProtocol.stubBody = #"{"detail": "Agent limit reached"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.createAgent(userId: "user-123", role: "")
            XCTFail("createAgent() must throw on a 422 rejection, not fabricate a fake FSAgent")
        } catch {
            // expected — any thrown error is correct; the important behavior
            // is that it throws instead of returning a fabricated agent.
        }
    }

    /// Before the fix: a 401 (expired session) also fell through silently.
    func test_createAgent_throws_on401_insteadOfFabricatingAgent() async {
        StubURLProtocol.stubStatusCode = 401
        StubURLProtocol.stubBody = #"{"detail": "Not authenticated"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.createAgent(userId: "user-123", role: "")
            XCTFail("createAgent() must throw on a 401 (expired session), not fabricate a fake FSAgent")
        } catch {
            // expected
        }
    }

    /// The single worst-case scenario called out by backend step 11: a 200
    /// response whose body doesn't actually contain a decodable "id" (e.g. a
    /// malformed/empty body). Before the fix this STILL returned a fabricated
    /// FSAgent with a client-generated UUID — a 2xx status code alone was
    /// never a reliable signal here, only a decodable id was.
    func test_createAgent_throws_on200WithMalformedBody_insteadOfFabricatingAgent() async {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"unexpected": "shape"}"#.data(using: .utf8)!

        do {
            let agent = try await NetworkService.shared.createAgent(userId: "user-123", role: "")
            XCTFail("createAgent() must throw when the response has no 'id' field, not fabricate " +
                     "FSAgent(id: \(agent.id), ...) with a client-generated UUID")
        } catch {
            // expected
        }
    }

    /// Happy path: a well-formed 201 with an id still succeeds cleanly, and
    /// the returned agent's id is the SERVER's id, not a fabricated one —
    /// regression guard so the fix doesn't turn successful creates into
    /// false failures or silently keep using a fabricated id on success too.
    func test_createAgent_succeeds_on201WithId() async throws {
        StubURLProtocol.stubStatusCode = 201
        StubURLProtocol.stubBody = #"{"id": "server-generated-agent-id"}"#.data(using: .utf8)!

        let agent = try await NetworkService.shared.createAgent(userId: "user-123", role: "A custom role")
        XCTAssertEqual(agent.id, "server-generated-agent-id",
                        "on success, the returned agent's id must come from the server response, not a client-generated UUID")
        XCTAssertEqual(agent.role, "A custom role")
    }
}
