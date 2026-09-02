// DashboardFriendRandomizationTests.swift — coverage for task
// 20260902-dashboard-friend-randomization, testing step 3.
//
// Backend step 1 (api/backend/interactions/friends.py) replaced the
// check-in nudge's single server-picked winner with a bounded
// `check_in_candidates` pool. Frontend step 2 made both dashboard friend
// surfaces genuinely randomized per DashboardViewModel.load() call:
//   - FriendActivityHeroCard's headline friend: DashboardViewModel.heroFriendPick,
//     rolled via `friendActivity.friends_active.randomElement()`.
//   - CheckInRow's nudge friend: DashboardViewModel.checkInPick, rolled via
//     `friendActivity.check_in_candidates.randomElement()`.
// Both rolls happen exactly once, at the end of load(), after friendActivity
// itself has fully settled for that call (see DashboardView.swift's load()).
//
// This file proves the actual acceptance criteria for the randomization
// itself (DashboardFriendActivityLoadTests.swift already covers
// vm.friendActivity's own shape/empty-state/cache-first/failure-handling
// behavior, which this task didn't change):
//
//   1. Both picks draw ONLY from the real candidate set — never a friend_id
//      that isn't actually present in friends_active/check_in_candidates.
//   2. Repeated load() calls against a feed with multiple candidates are
//      CAPABLE of producing more than one distinct pick — proving this is
//      real per-load randomization, not a pinned/memoized single winner.
//   3. 0-candidate and 1-candidate feeds never crash and behave correctly:
//      nil pick for 0, the single candidate (every time) for 1.
//   4. FriendActivityHeroCard's `primary` parameter, when supplied, overrides
//      `feed.friends_active.first` — proving DashboardView's call site
//      (which threads `vm.heroFriendPick` through) actually drives what
//      renders, not just what's stored on the view model.
//   5. FriendActivityHeroCard's `primary` parameter, when omitted (nil,
//      matching every pre-existing call site/preview/test in
//      DashboardEmptyStateTests.swift), falls back to the old deterministic
//      `.first` behavior — proving this change didn't regress those.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

@MainActor
final class DashboardFriendRandomizationTests: XCTestCase {

    private func freshUserId() -> String { "user-\(UUID().uuidString)" }

    /// Deterministic "today" timestamp, matching DashboardEmptyStateTests'
    /// own technique, so headline copy assertions (`"<name> was active
    /// today"`) don't depend on what real date the test happens to run on.
    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private func multiCandidateFeed() -> FSFriendActivityFeed {
        FSFriendActivityFeed(
            friends_active: [
                FSFriendActivityEntry(friend_id: "hero-a", username: "Alice", last_active_at: isoNow(), note_preview: nil),
                FSFriendActivityEntry(friend_id: "hero-b", username: "Bea",   last_active_at: isoNow(), note_preview: nil),
                FSFriendActivityEntry(friend_id: "hero-c", username: "Cy",    last_active_at: isoNow(), note_preview: nil),
            ],
            check_in_candidates: [
                FSCheckInCandidate(friend_id: "ci-a", username: "Dee",  days_since_contact: 20),
                FSCheckInCandidate(friend_id: "ci-b", username: "Eli",  days_since_contact: 15),
                FSCheckInCandidate(friend_id: "ci-c", username: "Fay",  days_since_contact: 10),
            ]
        )
    }

    // MARK: 1 — picks draw only from the real candidate set

    func test_picks_alwaysDrawFromTheActualCandidateSet_neverAForeignId() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let feed = multiCandidateFeed()
        service.fetchFriendActivityResult = feed
        let heroIds = Set(feed.friends_active.map(\.friend_id))
        let checkInIds = Set(feed.check_in_candidates.map(\.friend_id))

        for _ in 0..<15 {
            await vm.load(service: service, userId: freshUserId())
            guard let hero = vm.heroFriendPick, let checkIn = vm.checkInPick else {
                XCTFail("both picks must be non-nil when the feed has multiple candidates")
                continue
            }
            XCTAssertTrue(heroIds.contains(hero.friend_id),
                          "heroFriendPick (\(hero.friend_id)) must always be one of friends_active's real ids")
            XCTAssertTrue(checkInIds.contains(checkIn.friend_id),
                          "checkInPick (\(checkIn.friend_id)) must always be one of check_in_candidates' real ids")
        }
    }

    // MARK: 2 — repeated loads are capable of producing distinct picks

    func test_repeatedLoads_canProduceDistinctHeroAndCheckInPicks() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        service.fetchFriendActivityResult = multiCandidateFeed()

        var heroPicks = Set<String>()
        var checkInPicks = Set<String>()

        // 40 iterations against a 3-candidate pool each: the chance every
        // single one lands on the same friend by pure independent randomness
        // is (1/3)^39 for each -- effectively zero -- so this is a reliable,
        // not flaky, proof that the pick genuinely varies across loads
        // rather than being pinned to one winner.
        for _ in 0..<40 {
            await vm.load(service: service, userId: freshUserId())
            if let hero = vm.heroFriendPick { heroPicks.insert(hero.friend_id) }
            if let checkIn = vm.checkInPick { checkInPicks.insert(checkIn.friend_id) }
        }

        XCTAssertGreaterThan(heroPicks.count, 1,
                             "hero pick must vary across repeated loads when multiple friends are active, got only: \(heroPicks)")
        XCTAssertGreaterThan(checkInPicks.count, 1,
                             "check-in pick must vary across repeated loads when multiple candidates exist, got only: \(checkInPicks)")
    }

    // MARK: 3 — 0/1-candidate edge cases never crash

    func test_zeroCandidates_picksAreNil_noCrash() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        service.fetchFriendActivityResult = .empty

        await vm.load(service: service, userId: freshUserId())

        XCTAssertNil(vm.heroFriendPick)
        XCTAssertNil(vm.checkInPick)
    }

    func test_singleCandidateEach_pickIsAlwaysThatOneCandidate_acrossRepeatedLoads() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let singleFeed = FSFriendActivityFeed(
            friends_active: [FSFriendActivityEntry(friend_id: "solo-hero", username: "Solo", last_active_at: "2026-08-30T09:00:00Z", note_preview: nil)],
            check_in_candidates: [FSCheckInCandidate(friend_id: "solo-ci", username: "Solo", days_since_contact: 3)]
        )
        service.fetchFriendActivityResult = singleFeed

        for _ in 0..<5 {
            await vm.load(service: service, userId: freshUserId())
            XCTAssertEqual(vm.heroFriendPick?.friend_id, "solo-hero")
            XCTAssertEqual(vm.checkInPick?.friend_id, "solo-ci")
        }
    }

    // MARK: 4 — FriendActivityHeroCard's `primary` param overrides `.first`

    func test_friendActivityHeroCard_explicitPrimary_overridesFriendsActiveFirst() throws {
        let feed = multiCandidateFeed() // .first would be "hero-a"/Alice
        let overridden = feed.friends_active.first { $0.friend_id == "hero-c" }! // Cy
        let sut = FriendActivityHeroCard(feed: feed, primary: overridden) { _ in }

        XCTAssertNoThrow(try sut.inspect().find(textWhere: { text, _ in text.contains("Cy was active") }),
                          "an explicitly threaded `primary` must be what actually renders, overriding feed.friends_active.first (Alice)")
        XCTAssertThrowsError(try sut.inspect().find(textWhere: { text, _ in text.contains("Alice was active") }),
                              "the overridden .first entry (Alice) must not also render once `primary` is supplied") { _ in }
    }

    // MARK: 5 — omitted `primary` (nil) preserves the old deterministic `.first` fallback

    func test_friendActivityHeroCard_omittedPrimary_fallsBackToFriendsActiveFirst() throws {
        let feed = multiCandidateFeed() // .first is "hero-a"/Alice
        let sut = FriendActivityHeroCard(feed: feed) { _ in } // primary omitted -> nil default

        XCTAssertNoThrow(try sut.inspect().find(textWhere: { text, _ in text.contains("Alice was active") }),
                          "omitting `primary` must preserve the pre-randomization deterministic .first behavior for callers/previews/tests that don't thread a pick through")
    }
}
