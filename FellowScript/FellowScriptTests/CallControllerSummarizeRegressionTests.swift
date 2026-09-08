// CallControllerSummarizeRegressionTests.swift — regression coverage for
// task 20260907-session-summary-wireup, step 3 (frontend) / step 4 (testing).
//
// Frontend step 3 wired CallController.end() to fire-and-forget
// NetworkService.summarizeSession(...) when a summarize:true session's call
// ends, but only if the ending user is the session's creator (avoids minting
// one duplicate "Session Summary — {title}" note per still-connected
// participant in a group call, since the notes table has no per-session
// uniqueness constraint). This proves:
//
// 1. summarize:true + ended by the creator -> summarizeSession invoked
//    exactly once, with the correct userId/agentId/session/groupId.
// 2. summarize:false (or default) -> summarizeSession is never invoked.
// 3. summarize:true but ended by a non-creator participant -> never invoked
//    (the group-call dedup guard).
// 4. Zero-agents case -> resolveAgentId auto-creates one via createAgent
//    (role: "") and that id is the one summarizeSession is called with.
// 5. A summarize failure (network error / quota / LLM 502) doesn't
//    block/delay/crash call teardown (session/isExpanded/service are already
//    cleared synchronously in end(), before the fire-and-forget Task even
//    starts) and surfaces through CallController.summarizeNotice with a
//    warm, non-technical message (UI/UX Q17.3), not the raw error string.
// 6. Existing coverage for summarizeSession itself (ChipToggleTests'
//    Summarize-chip UI test) is unaffected by this change.

import XCTest
@testable import FellowScript

@MainActor
final class CallControllerSummarizeRegressionTests: XCTestCase {

    override func tearDown() async throws {
        // CallController.shared is a singleton -- reset the fields this test
        // suite can reach so a failure/early-return here can't leak state
        // into another test in this file or another file that later touches
        // CallController.shared.
        let call = CallController.shared
        call.session = nil
        call.isExpanded = false
        call.joinError = nil
        call.summarizeNotice = nil
        try await super.tearDown()
    }

    private func makeSession(summarize: Bool, creatorId: String, groupId: String = "group-1") -> FSSession {
        var session = FSSession()
        session.title = "Morning Prayer"
        session.verses = ["John 3:16"]
        session.prompts = ["How does this verse speak to you today?"]
        session.summarize = summarize
        session.creator_id = creatorId
        session.group_id = groupId
        return session
    }

    /// Happy path: summarize:true, ended by the session's own creator ->
    /// summarizeSession must be called exactly once with the right args.
    func test_end_invokesSummarizeSession_whenSummarizeTrueAndEndedByCreator() async throws {
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [FSAgent(id: "agent-99", user_id: "user-1", role: "", enabled: true, chats: [])]
        let session = makeSession(summarize: true, creatorId: "user-1", groupId: "group-42")

        let call = CallController.shared
        call.start(session: session, service: service, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.summarizeSessionCallCount, 1,
                        "a summarize:true session ended by its own creator must trigger exactly one summarize call")
        XCTAssertEqual(service.lastSummarizeSessionArgs?.userId, "user-1")
        XCTAssertEqual(service.lastSummarizeSessionArgs?.agentId, "agent-99")
        XCTAssertEqual(service.lastSummarizeSessionArgs?.groupId, "group-42")
        XCTAssertEqual(service.lastSummarizeSessionArgs?.session.title, "Morning Prayer")
        XCTAssertEqual(service.lastSummarizeSessionArgs?.session.verses, ["John 3:16"])
        // Call teardown itself must have actually happened, not been blocked
        // by the fire-and-forget summarize path.
        XCTAssertNil(call.session)
        XCTAssertFalse(call.isExpanded)
    }

    /// summarize:false (or default) must never invoke summarizeSession.
    func test_end_doesNotInvokeSummarizeSession_whenSummarizeFalse() async throws {
        let service = ThrowingTestDataService()
        let session = makeSession(summarize: false, creatorId: "user-1")

        let call = CallController.shared
        call.start(session: session, service: service, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.summarizeSessionCallCount, 0)
        XCTAssertEqual(service.createAgentCallCount, 0,
                        "agent resolution should never even run when summarize is off")
    }

    /// Group-call dedup guard: summarize:true but the user ending the call is
    /// NOT the session's creator -> must not invoke summarizeSession (a
    /// different participant's own end() firing this too would mint a
    /// duplicate note, since notes has no per-session uniqueness constraint).
    func test_end_doesNotInvokeSummarizeSession_whenEndedByNonCreatorParticipant() async throws {
        let service = ThrowingTestDataService()
        let session = makeSession(summarize: true, creatorId: "user-1")

        let call = CallController.shared
        call.start(session: session, service: service, userId: "user-2")
        call.end()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.summarizeSessionCallCount, 0)
    }

    /// Zero-agents case: resolveAgentId must auto-create one (role: "", no
    /// picker UI, per the open question this task resolved) and summarize
    /// with that id.
    func test_end_autoCreatesAgent_whenUserHasNoExistingAgents() async throws {
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = []
        service.createAgentResult = FSAgent(id: "brand-new-agent", user_id: "user-1", role: "", enabled: true, chats: [])
        let session = makeSession(summarize: true, creatorId: "user-1")

        let call = CallController.shared
        call.start(session: session, service: service, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.createAgentCallCount, 1)
        XCTAssertEqual(service.lastCreateAgentRole, "")
        XCTAssertEqual(service.summarizeSessionCallCount, 1)
        XCTAssertEqual(service.lastSummarizeSessionArgs?.agentId, "brand-new-agent")
    }

    /// A summarize failure (network error, quota 403, LLM 502) must not
    /// block/delay/crash call teardown -- teardown happens synchronously in
    /// end() before the fire-and-forget Task even starts -- and must surface
    /// through summarizeNotice with a warm, non-technical message rather
    /// than the raw thrown error string (UI/UX Q17.3).
    func test_end_doesNotBlockTeardown_andSurfacesWarmNotice_whenSummarizeFails() async throws {
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [FSAgent(id: "agent-1", user_id: "user-1", role: "", enabled: true, chats: [])]
        service.summarizeSessionError = AppError.networkError("HTTP 502 Bad Gateway from LLM provider")
        let session = makeSession(summarize: true, creatorId: "user-1")

        let call = CallController.shared
        call.start(session: session, service: service, userId: "user-1")
        call.end()

        // Teardown is synchronous inside end() -- assert it already happened
        // immediately, before even sleeping for the async summarize attempt.
        XCTAssertNil(call.session)
        XCTAssertFalse(call.isExpanded)

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.summarizeSessionCallCount, 1,
                        "the attempt must still have been made, not skipped")
        let notice = try XCTUnwrap(call.summarizeNotice)
        XCTAssertFalse(notice.contains("502"), "the raw technical error must not leak into the user-facing notice")
        XCTAssertFalse(notice.contains("Bad Gateway"))
        XCTAssertFalse(notice.isEmpty)
    }

    /// A successful summarize must never populate summarizeNotice -- that
    /// field is failure-only, so a stale/incorrect toast can't appear after
    /// a call that actually succeeded.
    func test_end_leavesSummarizeNoticeNil_whenSummarizeSucceeds() async throws {
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [FSAgent(id: "agent-1", user_id: "user-1", role: "", enabled: true, chats: [])]
        let session = makeSession(summarize: true, creatorId: "user-1")

        let call = CallController.shared
        call.start(session: session, service: service, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.summarizeSessionCallCount, 1)
        XCTAssertNil(call.summarizeNotice)
    }
}
