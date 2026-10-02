// PlanBlockTests.swift — task 20261002-free-plan-limits-ui. Pure-logic tests for
// the Free-plan blocked-action detector, prompt copy, the one-shot presenter and
// the Account limits list (no network, no UI hosting).

import XCTest
@testable import FellowScript

@MainActor
final class PlanBlockTests: XCTestCase {

    override func setUp() async throws {
        UpgradePromptCenter.shared.dismiss()
        UpgradePromptCenter.shared.scrollToSubscription = false
    }

    private func mapped403(_ json: String, status: Int = 403) -> Error? {
        let url = URL(string: "https://example.test/x")!
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        do { try NetworkService.shared.throwIfError(resp, Data(json.utf8)); return nil } catch { return error }
    }

    // ── Detector ─────────────────────────────────────────────────────────────

    func test_detector_acceptsAllFiveResources_underDetail() {
        for r in ["notes", "agent_events", "sessions", "session_summaries", "explorer_publish"] {
            let err = mapped403("""
            {"detail": {"resource": "\(r)", "allowed": false, "unlimited": false, "used": 1, "limit": 1, "remaining": 0}}
            """)!
            let info = PlanBlock.info(from: err)
            XCTAssertEqual(info?.resource, r, r)
        }
    }

    func test_detector_acceptsBareBody() {
        let err = mapped403("""
        {"resource": "sessions", "allowed": false, "unlimited": false, "used": 1, "limit": 1, "remaining": 0}
        """)!
        XCTAssertEqual(PlanBlock.info(from: err), BlockedInfo(resource: "sessions", used: 1, limit: 1))
    }

    func test_detector_paidOnlyFlagFollowsResource() {
        XCTAssertTrue(BlockedInfo(resource: "explorer_publish", used: 0, limit: 0).paidOnly)
        XCTAssertTrue(BlockedInfo(resource: "session_summaries", used: 0, limit: 0).paidOnly)
        XCTAssertFalse(BlockedInfo(resource: "notes", used: 5, limit: 5).paidOnly)
    }

    func test_detector_ignoresNoteCharsAnnouncementsAndOtherErrors() {
        XCTAssertNil(PlanBlock.info(from: AppError.limitReached(resource: "note_chars", used: 5, limit: 4)))
        XCTAssertNil(PlanBlock.info(from: AppError.limitReached(resource: "announcements", used: 1, limit: 1)))
        XCTAssertNil(PlanBlock.info(from: AppError.networkError("Forbidden")))
        // A permission 403 (plain string detail) is not a plan block.
        XCTAssertNil(PlanBlock.info(from: mapped403(#"{"detail": "Not a member of this group"}"#)!))
    }

    // ── Copy ─────────────────────────────────────────────────────────────────

    func test_copy_interpolatesLimitsFromTheBlockedResponse() {
        XCTAssertTrue(PlanBlock.body(for: BlockedInfo(resource: "notes", used: 7, limit: 7)).contains("7 notes per week"))
        XCTAssertTrue(PlanBlock.body(for: BlockedInfo(resource: "agent_events", used: 1, limit: 1)).contains("1 scheduled devotion."))
        XCTAssertTrue(PlanBlock.body(for: BlockedInfo(resource: "sessions", used: 1, limit: 1)).contains("1 session at a time"))
        XCTAssertEqual(PlanBlock.body(for: BlockedInfo(resource: "session_summaries", used: 0, limit: 0)),
                       "Session summaries are for subscribers.")
        XCTAssertTrue(PlanBlock.body(for: BlockedInfo(resource: "explorer_publish", used: 0, limit: 0))
            .contains("Browsing and joining stay free"))
        // A missing figure is omitted, never rendered as a stale literal.
        XCTAssertFalse(PlanBlock.body(for: BlockedInfo(resource: "notes", used: 0, limit: 0)).contains("0"))
        XCTAssertEqual(PlanBlock.title, "Not available on the Free plan")
    }

    // ── Presenter ────────────────────────────────────────────────────────────

    func test_presenter_showsForPlanBlock_notForOtherErrors_andLatestReplaces() {
        let c = UpgradePromptCenter.shared
        XCTAssertFalse(c.present(for: AppError.networkError("boom")))
        XCTAssertNil(c.prompt)
        XCTAssertTrue(c.present(for: AppError.limitReached(resource: "notes", used: 5, limit: 5)))
        XCTAssertEqual(c.prompt?.resource, "notes")
        let before = c.blockCount
        XCTAssertTrue(c.present(for: AppError.limitReached(resource: "sessions", used: 1, limit: 1)))
        XCTAssertEqual(c.prompt?.resource, "sessions")
        XCTAssertEqual(c.blockCount, before + 1)
        c.dismiss()
        XCTAssertNil(c.prompt)
    }

    func test_subscribe_clearsPrompt_setsScrollSignal_andPostsOpenPlans() {
        let c = UpgradePromptCenter.shared
        _ = c.present(for: AppError.limitReached(resource: "explorer_publish", used: 0, limit: 0))
        let exp = expectation(forNotification: .fsOpenSubscriptionPlans, object: nil)
        c.subscribe()
        wait(for: [exp], timeout: 1)
        XCTAssertNil(c.prompt)
        XCTAssertTrue(c.scrollToSubscription)
    }

    // ── Limits list ──────────────────────────────────────────────────────────

    private func usage(_ json: String) throws -> FSUsage {
        try JSONDecoder().decode(FSUsage.self, from: Data(json.utf8))
    }

    func test_freePlanRows_renderEveryLimitFromPayload() throws {
        let u = try usage("""
        {"subscribed": false, "plan_type": "free", "window_days": 7,
         "resources": {
           "notes": {"unlimited": false, "used": 2, "limit": 5, "remaining": 3},
           "agent_events": {"unlimited": false, "used": 0, "limit": 1, "remaining": 1},
           "sessions": {"unlimited": false, "used": 0, "limit": 1, "remaining": 1}},
         "paid_only": {"session_summaries": {"allowed": false, "free_allowed": false},
                       "explorer_publish": {"allowed": false, "free_allowed": false}}}
        """)
        let rows = u.freePlanRows
        XCTAssertEqual(rows.map(\.label), ["Notes", "Scheduled devotions", "Hosting sessions",
                                           "Session summaries", "Publish to Explorer"])
        XCTAssertEqual(rows[0].value, "5 per week")
        XCTAssertEqual(rows[1].value, "1 in total")
        XCTAssertEqual(rows[2].value, "1 at a time")
        XCTAssertEqual(rows[2].caption, "Join as many as you like")
        XCTAssertEqual(rows[3].value, "Subscribers only"); XCTAssertTrue(rows[3].locked)
        XCTAssertEqual(rows[4].value, "Subscribers only"); XCTAssertTrue(rows[4].locked)
        XCTAssertEqual(rows[4].caption, "Browsing and joining stay free")
    }

    func test_freePlanRows_followServerChanges() throws {
        let u = try usage("""
        {"subscribed": false, "plan_type": "free", "window_days": 10,
         "resources": {"notes": {"unlimited": false, "used": 0, "limit": 8, "remaining": 8}},
         "paid_only": {"session_summaries": {"allowed": true, "free_allowed": true}}}
        """)
        XCTAssertEqual(u.freePlanRows.first?.value, "8 every 10 days")
        let summaries = u.freePlanRows.first { $0.label == "Session summaries" }
        XCTAssertEqual(summaries?.value, "Included")
        XCTAssertEqual(summaries?.locked, false)
    }

    func test_usageDecodes_withoutNewFields_forOlderServers() throws {
        let u = try usage(#"{"subscribed": false, "plan_type": "free", "window_days": 7, "resources": {}}"#)
        XCTAssertNil(u.paid_only)
        XCTAssertNil(u.sessions)
        XCTAssertTrue(u.freePlanRows.isEmpty)
    }
}
