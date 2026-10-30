// DashboardPickupPastNoteTests.swift -- coverage for task
// 20261029-home-pickup-past-note: "Pick up from your past note" state on
// FriendActivityHeroCard when no friend has activity within 48h.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

@MainActor
final class DashboardPickupPastNoteTests: XCTestCase {

    private func uid() -> String { "user-\(UUID().uuidString)" }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private func ago(hours: Double) -> String { iso(Date().addingTimeInterval(-hours * 3600)) }

    private func note(_ id: String, user: String = "", group: String = "", reply: Bool = false,
                      ts: String, title: String = "T", text: String = "body") -> FSNote {
        var n = FSNote()
        n.id = id; n.user = user; n.group_id = group; n.is_reply = reply
        n.timestamp = ts; n.title = title; n.text = text
        return n
    }

    private func feed(lastActive: String?) -> FSFriendActivityFeed {
        FSFriendActivityFeed(
            friends_active: [FSFriendActivityEntry(friend_id: "f1", username: "Alice", last_active_at: lastActive, note_preview: nil)],
            check_in_candidates: []
        )
    }

    // MARK: 48h check

    func test_hasActivity_boundary() {
        let now = Date()
        func f(_ h: Double) -> FSFriendActivityFeed { feed(lastActive: iso(now.addingTimeInterval(-h * 3600))) }
        XCTAssertTrue(f(47.9).hasActivity(within: FSFriendActivityFeed.inactivityWindow, now: now))
        XCTAssertFalse(f(48.1).hasActivity(within: FSFriendActivityFeed.inactivityWindow, now: now))
        XCTAssertFalse(feed(lastActive: nil).hasActivity(within: FSFriendActivityFeed.inactivityWindow, now: now))
        XCTAssertFalse(feed(lastActive: "garbage").hasActivity(within: FSFriendActivityFeed.inactivityWindow, now: now))
        XCTAssertFalse(FSFriendActivityFeed.empty.hasActivity(within: FSFriendActivityFeed.inactivityWindow, now: now))
    }

    func test_hasActivity_anyRecentFriendCounts() {
        let f = FSFriendActivityFeed(friends_active: [
            FSFriendActivityEntry(friend_id: "old", username: "Old", last_active_at: ago(hours: 200), note_preview: nil),
            FSFriendActivityEntry(friend_id: "new", username: "New", last_active_at: ago(hours: 1), note_preview: nil),
        ], check_in_candidates: [])
        XCTAssertTrue(f.hasActivity(within: FSFriendActivityFeed.inactivityWindow))
    }

    // MARK: candidate eligibility

    func test_candidates_ownPersonalOldParseableOnly() {
        let me = "me"
        let notes: [String: FSNote] = [
            "ok":      note("ok", user: me, ts: ago(hours: 100)),
            "okEmpty": note("okEmpty", user: "", ts: ago(hours: 100)),
            "recent":  note("recent", user: me, ts: ago(hours: 47)),
            "other":   note("other", user: "someone-else", ts: ago(hours: 100)),
            "group":   note("group", user: me, group: "g1", ts: ago(hours: 100)),
            "reply":   note("reply", user: me, reply: true, ts: ago(hours: 100)),
            "badTs":   note("badTs", user: me, ts: "not a date"),
            "emptyTs": note("emptyTs", user: me, ts: ""),
        ]
        let ids = Set(DashboardViewModel.pickupCandidates(notes: notes, userId: me).map(\.id))
        XCTAssertEqual(ids, ["ok", "okEmpty"])
    }

    func test_candidates_48hBoundary() {
        let now = Date()
        let notes: [String: FSNote] = [
            "in":  note("in",  user: "me", ts: iso(now.addingTimeInterval(-47.9 * 3600))),
            "out": note("out", user: "me", ts: iso(now.addingTimeInterval(-48.1 * 3600))),
        ]
        let ids = DashboardViewModel.pickupCandidates(notes: notes, userId: "me", now: now).map(\.id)
        XCTAssertEqual(ids, ["out"])
    }

    func test_candidates_noNotes_empty() {
        XCTAssertTrue(DashboardViewModel.pickupCandidates(notes: [:], userId: "me").isEmpty)
    }

    // MARK: view model load()

    private func service(notes: [String: FSNote], feed: FSFriendActivityFeed = .empty) -> ThrowingTestDataService {
        let s = ThrowingTestDataService()
        s.fetchNotesPageQueue = [NotesPage(notes: notes, nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false)]
        s.fetchFriendActivityResult = feed
        return s
    }

    func test_load_picksOnlyEligibleOwnOldNote() async {
        let me = uid()
        let notes = [
            "a": note("a", user: me, ts: ago(hours: 100)),
            "recent": note("recent", user: me, ts: ago(hours: 1)),
            "other": note("other", user: "x", ts: ago(hours: 100)),
        ]
        let vm = DashboardViewModel()
        await vm.load(service: service(notes: notes), userId: me)
        XCTAssertEqual(vm.pickupNote?.id, "a")
    }

    func test_load_noEligibleNotes_nilPick() async {
        let me = uid()
        let vm = DashboardViewModel()
        await vm.load(service: service(notes: ["r": note("r", user: me, ts: ago(hours: 1))]), userId: me)
        XCTAssertNil(vm.pickupNote)
    }

    func test_load_noNotes_nilPick() async {
        let me = uid()
        let vm = DashboardViewModel()
        await vm.load(service: service(notes: [:]), userId: me)
        XCTAssertNil(vm.pickupNote)
    }

    func test_load_pickVariesAcrossLoads() async {
        var notes: [String: FSNote] = [:]
        for i in 0..<3 { notes["n\(i)"] = note("n\(i)", user: "me", ts: ago(hours: 100)) }
        let vm = DashboardViewModel()
        var seen = Set<String>()
        for _ in 0..<40 {
            let me = uid()
            var ns = notes; for k in ns.keys { ns[k]?.user = me }
            await vm.load(service: service(notes: ns), userId: me)
            if let p = vm.pickupNote { seen.insert(p.id) }
        }
        XCTAssertGreaterThan(seen.count, 1)
    }

    func test_load_failedRefreshKeepsPick() async {
        let me = uid()
        let vm = DashboardViewModel()
        await vm.load(service: service(notes: ["a": note("a", user: me, ts: ago(hours: 100))]), userId: me)
        XCTAssertEqual(vm.pickupNote?.id, "a")

        let failing = ThrowingTestDataService()
        failing.fetchNotesError = AppError.networkError("down")
        failing.fetchFriendActivityError = AppError.networkError("down")
        await vm.load(service: failing, userId: me)
        XCTAssertEqual(vm.pickupNote?.id, "a", "failed refresh must not wipe or re-roll the pick")
    }

    func test_load_saveNoteRefreshesPick() async {
        let me = uid()
        let vm = DashboardViewModel()
        let s = service(notes: ["a": note("a", user: me, ts: ago(hours: 100), title: "Old")])
        await vm.load(service: s, userId: me)
        var edited = vm.pickupNote!
        edited.title = "Edited"
        _ = await vm.saveNote(edited, editingId: "a", userId: me)
        XCTAssertEqual(vm.pickupNote?.title, "Edited")
    }

    // MARK: card rendering

    func test_card_staleActivity_showsPickup() throws {
        let n = note("a", user: "me", ts: ago(hours: 100), title: "My Title", text: "hello world")
        let sut = FriendActivityHeroCard(feed: feed(lastActive: ago(hours: 100)), onOpenFriend: { _ in }, pickupNote: n)
        XCTAssertNoThrow(try sut.inspect().find(text: "Pick up from your past note"))
        XCTAssertNoThrow(try sut.inspect().find(text: "My Title"))
        XCTAssertThrowsError(try sut.inspect().find(textWhere: { t, _ in t.contains("Alice was active") }))
    }

    func test_card_recentActivity_unchanged() throws {
        let n = note("a", user: "me", ts: ago(hours: 100))
        let sut = FriendActivityHeroCard(feed: feed(lastActive: ago(hours: 1)), onOpenFriend: { _ in }, pickupNote: n)
        XCTAssertThrowsError(try sut.inspect().find(text: "Pick up from your past note"))
        XCTAssertNoThrow(try sut.inspect().find(textWhere: { t, _ in t.contains("Alice was active") }))
    }

    func test_card_noFriends_withPickup_showsPickup() throws {
        let n = note("a", user: "me", ts: ago(hours: 100))
        let sut = FriendActivityHeroCard(feed: .empty, onOpenFriend: { _ in }, pickupNote: n)
        XCTAssertNoThrow(try sut.inspect().find(text: "Pick up from your past note"))
        XCTAssertThrowsError(try sut.inspect().find(textWhere: { t, _ in t.contains("Add a friend") }))
    }

    func test_card_noFriends_noPickup_keepsEmptyState() throws {
        let sut = FriendActivityHeroCard(feed: .empty, onOpenFriend: { _ in })
        XCTAssertNoThrow(try sut.inspect().find(textWhere: { t, _ in t.contains("Add a friend") }))
        XCTAssertThrowsError(try sut.inspect().find(text: "Pick up from your past note"))
    }

    func test_card_tapInvokesCallbackWithNote() throws {
        let n = note("a", user: "me", ts: ago(hours: 100))
        var opened: String?
        let sut = FriendActivityHeroCard(feed: .empty, onOpenFriend: { _ in }, pickupNote: n, onOpenPickup: { opened = $0.id })
        try sut.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(opened, "a")
    }
}
