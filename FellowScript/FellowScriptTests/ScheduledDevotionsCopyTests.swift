// ScheduledDevotionsCopyTests.swift — guards the user-facing rename of
// "agent events" to "scheduled devotions". Wire names (agent_events, /agent,
// heartbeat routes) are public identifiers and must NOT change.

import XCTest
@testable import FellowScript

final class ScheduledDevotionsCopyTests: XCTestCase {

    func test_limitReached_agentEvents_usesFriendlyScheduledDevotionsWording() {
        let msg = AppError.limitReached(resource: "agent_events", used: 1, limit: 1).errorDescription ?? ""
        XCTAssertTrue(msg.contains("1 scheduled devotion."), msg)
        XCTAssertTrue(msg.contains("as many as you like"), msg)
        XCTAssertFalse(msg.lowercased().contains("agent"), msg)
        XCTAssertFalse(msg.lowercased().contains("event"), msg)
    }

    func test_limitReached_notes_wordingUnchanged() {
        let msg = AppError.limitReached(resource: "notes", used: 10, limit: 10).errorDescription ?? ""
        XCTAssertEqual(msg, "You've reached your free plan limit for notes (max 10). Upgrade to a Group plan for unlimited access.")
    }
}
