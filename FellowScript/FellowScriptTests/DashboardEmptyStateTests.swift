// DashboardEmptyStateTests.swift — coverage for task
// 20260826-friend-activity-dashboard-implementation, testing step 5
// (re-entry pass): empty-state rendering for the Editorial Hero dashboard's
// three new/changed components (Dashboard/DashboardComponents.swift):
// FriendActivityHeroCard, CheckInRow, NoteResumeCard.
//
// Per the acceptance criteria ("Empty states are handled explicitly and
// match real conditions rather than being assumed away: no friends yet,
// friends with no recent activity, and no recent note to resume all render
// a defined (not broken/blank) state") this file proves each of those three
// states renders its own distinct, non-blank copy — plus a happy-path
// regression guard per component so the empty-state coverage can't
// accidentally pass by disabling the populated branch entirely.
//
// None of FriendActivityHeroCard/CheckInRow/NoteResumeCard hold their own
// @State — they're pure functions of their `let` properties — so (matching
// this target's existing convention for stateless components, e.g.
// PillButtonTests.swift/ChipToggleTests.swift) these are inspected directly
// via `.inspect()` with no ViewHosting/didAppear needed.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class FriendActivityHeroCardTests: XCTestCase {

    // Deterministic "today" timestamp so activityDayLabel's
    // Calendar.isDateInToday branch is exercised reliably regardless of
    // what real date the test happens to run on.
    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    // MARK: Empty state 1 — no friends at all

    func test_noFriends_rendersAddAFriendEmptyState_notActivityRow() throws {
        let sut = FriendActivityHeroCard(feed: .empty) { _ in }

        XCTAssertNoThrow(try sut.inspect().find(text: "Add a friend to see their notes and highlights here."))
        // The "Friend activity" eyebrow label was leaked internal jargon not
        // present in the approved mockup (task 20260827-dashboard-old-ui-cleanup)
        // -- the no-friends empty state must not render it.
        XCTAssertThrowsError(try sut.inspect().find(text: "Friend activity"),
                              "the 'Friend activity' section label must not render -- it's not in the approved mockup") { _ in }
    }

    // MARK: Empty state 2 — friends exist, but none have any tracked activity

    func test_friendsWithNoTrackedActivity_rendersNoRecentActivityMessage_distinctFromNoFriendsState() throws {
        let feed = FSFriendActivityFeed(
            friends_active: [
                FSFriendActivityEntry(friend_id: "f1", username: "Sarah", last_active_at: nil, note_preview: nil),
            ],
            check_in: nil
        )
        let sut = FriendActivityHeroCard(feed: feed) { _ in }

        XCTAssertNoThrow(try sut.inspect().find(text: "No recent activity from your friends yet."))
        XCTAssertThrowsError(try sut.inspect().find(text: "Add a friend to see their notes and highlights here."),
                              "friends-with-no-activity must render its own message, not fall back to the no-friends copy") { _ in }
    }

    // MARK: Happy path — active friend with a note preview (regression guard)

    func test_activeFriendWithNotePreview_rendersHeadlineAndPreviewText() throws {
        let feed = FSFriendActivityFeed(
            friends_active: [
                FSFriendActivityEntry(
                    friend_id: "f1", username: "Sarah", last_active_at: isoNow(),
                    note_preview: FSFriendNotePreview(note_id: "n1", title: "Morning reflection",
                                                        text: "Started reading Psalm 23 again this morning.",
                                                        timestamp: isoNow())
                )
            ],
            check_in: nil
        )
        let sut = FriendActivityHeroCard(feed: feed) { _ in }

        XCTAssertNoThrow(try sut.inspect().find(text: "Sarah wrote a note today"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Started reading Psalm 23 again this morning."))
        XCTAssertThrowsError(try sut.inspect().find(text: "No recent activity from your friends yet."))
        XCTAssertThrowsError(try sut.inspect().find(text: "Add a friend to see their notes and highlights here."))
    }

    // MARK: Happy path — active friend WITHOUT a note preview still gets a headline

    func test_activeFriendWithoutNotePreview_rendersWasActiveHeadline_noPreviewPanel() throws {
        let feed = FSFriendActivityFeed(
            friends_active: [
                FSFriendActivityEntry(friend_id: "f2", username: "Marcus", last_active_at: isoNow(), note_preview: nil)
            ],
            check_in: nil
        )
        let sut = FriendActivityHeroCard(feed: feed) { _ in }

        XCTAssertNoThrow(try sut.inspect().find(text: "Marcus was active today"))
    }

    // MARK: Tap wiring — activityRow's tap invokes onOpenFriend with the primary entry

    func test_tappingActivityRow_invokesOnOpenFriend_withPrimaryEntry() throws {
        var opened: FSFriendActivityEntry?
        let entry = FSFriendActivityEntry(friend_id: "f1", username: "Sarah", last_active_at: isoNow(), note_preview: nil)
        let feed = FSFriendActivityFeed(friends_active: [entry], check_in: nil)
        let sut = FriendActivityHeroCard(feed: feed) { opened = $0 }

        // activityRow's Button is the only Button in the populated (single
        // active friend, no note preview) render tree -- avatarStackRow is
        // plain Circles/Text, not tappable.
        try sut.inspect().find(ViewType.Button.self).tap()

        XCTAssertEqual(opened?.friend_id, "f1")
    }
}

final class CheckInRowTests: XCTestCase {

    // MARK: Badge text variants (all four branches of CheckInRow.badgeText)

    func test_badgeText_nilDaysSinceContact_rendersNeverMessaged() throws {
        let sut = CheckInRow(checkIn: FSCheckInCandidate(friend_id: "f1", username: "Quiet Friend", days_since_contact: nil)) {}
        XCTAssertNoThrow(try sut.inspect().find(text: "Never messaged"),
                          "a friend with tracked activity but no direct-message history yet must render a defined, non-crashing badge")
    }

    func test_badgeText_zeroDays_rendersTalkedToday() throws {
        let sut = CheckInRow(checkIn: FSCheckInCandidate(friend_id: "f1", username: "Sarah", days_since_contact: 0)) {}
        XCTAssertNoThrow(try sut.inspect().find(text: "Talked today"))
    }

    func test_badgeText_oneDay_rendersSingularDayPhrasing() throws {
        let sut = CheckInRow(checkIn: FSCheckInCandidate(friend_id: "f1", username: "Sarah", days_since_contact: 1)) {}
        XCTAssertNoThrow(try sut.inspect().find(text: "It's been 1 day"))
    }

    func test_badgeText_multipleDays_rendersPluralDayPhrasing() throws {
        let sut = CheckInRow(checkIn: FSCheckInCandidate(friend_id: "f1", username: "Sarah", days_since_contact: 6)) {}
        XCTAssertNoThrow(try sut.inspect().find(text: "It's been 6 days"))
    }

    func test_headline_includesFriendUsername() throws {
        let sut = CheckInRow(checkIn: FSCheckInCandidate(friend_id: "f1", username: "Sarah", days_since_contact: 6)) {}
        XCTAssertNoThrow(try sut.inspect().find(text: "Check in with Sarah"))
    }

    func test_tappingCTAButton_invokesOnTap() throws {
        var tapped = false
        let sut = CheckInRow(checkIn: FSCheckInCandidate(friend_id: "f1", username: "Sarah", days_since_contact: 6)) { tapped = true }
        // The CTA Button's label is a plain Circle/Image (its user-facing
        // "Check in with Sarah" text lives in a sibling VStack, not inside
        // the Button itself -- the button is identified by accessibility
        // label only), so it's the only Button in the tree either way.
        try sut.inspect().find(ViewType.Button.self).tap()
        XCTAssertTrue(tapped)
    }
}

final class NoteResumeCardTests: XCTestCase {

    // MARK: Empty state 3 — no recent note to resume

    func test_nilNote_rendersHaventWrittenEmptyState_andStartANotePillCopy() throws {
        let sut = NoteResumeCard(note: nil) {}

        XCTAssertNoThrow(try sut.inspect().find(text: "You haven't written a note yet."))
        XCTAssertNoThrow(try sut.inspect().find(text: "Start a note"))
        XCTAssertNoThrow(try sut.inspect().find(text: "capture a reflection"))
        XCTAssertThrowsError(try sut.inspect().find(text: "Open note"),
                              "the empty state must not show the populated 'Open note' pill copy") { _ in }
        // "Pick up where you left off" was a leaked internal section-label
        // string, not present in the approved mockup, and rendered
        // unconditionally (outside the `if let note` branch) before task
        // 20260827-dashboard-old-ui-cleanup -- must not render in either state.
        XCTAssertThrowsError(try sut.inspect().find(text: "Pick up where you left off"),
                              "the empty note-resume state must not render the removed section label") { _ in }
    }

    func test_nilNote_tappingCard_invokesOnOpen_soCallerCanOpenANewNoteInstead() throws {
        var opened = false
        let sut = NoteResumeCard(note: nil) { opened = true }
        try sut.inspect().find(ViewType.Button.self).tap()
        XCTAssertTrue(opened)
    }

    // MARK: Happy path — a real recent note (regression guard)
    //
    // Updated for task 20260828-continue-button-circle-implementation: the
    // populated state's bottom control was replaced with a circular icon-only
    // Continue button (design-spec.md's Option 2) — no visible "Continue"
    // text, so `find(button: "Continue")` no longer matches anything. Found
    // instead by its distinct "Continue reading <title>" accessibility label
    // (see NoteResumeCardContinueIslandTests.swift for the full construction
    // coverage — this file only keeps its own pre-existing regression guard
    // that the populated state's control renders at all and the old pill
    // copy doesn't regress back in).
    func test_populatedNote_rendersTitleAndPreview_andContinueControl() throws {
        let note = FSNote(
            id: "note-1", user: "user-1", title: "Sunday Service 06/28",
            text: "Pastor Ed spoke on the courage of faith.", public: false, group_id: "",
            is_reply: false, timestamp: "2026-06-28 20:10:22", verses: [], replies: []
        )
        let sut = NoteResumeCard(note: note) {}

        XCTAssertNoThrow(try sut.inspect().find(text: "Sunday Service 06/28"))
        XCTAssertNoThrow(
            try sut.inspect().find(ViewType.Button.self, where: { button in
                (try? button.accessibilityLabel().string()) == "Continue reading Sunday Service 06/28"
            }),
            "the populated state's control must be the new circular icon-only Continue button"
        )
        XCTAssertThrowsError(try sut.inspect().find(text: "You haven't written a note yet."))
        XCTAssertThrowsError(try sut.inspect().find(text: "Open note"),
                              "the retired 'Open note' pill copy must not regress back in") { _ in }
        XCTAssertThrowsError(try sut.inspect().find(text: "where you left off"),
                              "the retired 'where you left off' pill copy must not regress back in") { _ in }
        // Regression guard: the populated state must not ALSO carry the
        // removed "Pick up where you left off" section label above the card.
        XCTAssertThrowsError(try sut.inspect().find(text: "Pick up where you left off"),
                              "the populated note-resume state must not render the removed section label") { _ in }
    }

    func test_populatedNote_emptyTitle_fallsBackToUntitledNote_insteadOfBlankRow() throws {
        let note = FSNote(
            id: "note-1", user: "user-1", title: "",
            text: "body", public: false, group_id: "",
            is_reply: false, timestamp: "2026-06-28 20:10:22", verses: [], replies: []
        )
        let sut = NoteResumeCard(note: note) {}
        XCTAssertNoThrow(try sut.inspect().find(text: "Untitled note"),
                          "a note with an empty title must render a defined fallback label, never a blank row")
    }
}

// MARK: - HeroHeader (coverage for task 20260827-dashboard-old-ui-cleanup)
//
// Proves the two leaked-jargon strings the mockup never had are gone --
// the "YOUR RHYTHM" eyebrow and the "Last read X · N notes" subtitle line --
// while the existing live time-of-day + username greeting behavior (kept per
// the frontend gate's resolution of the spec's open question) still renders.
final class HeroHeaderTests: XCTestCase {

    func test_rendersGreetingWithUsername_noEyebrow_noSubtitleLine() throws {
        let sut = HeroHeader(username: "Jacey")

        XCTAssertNoThrow(try sut.inspect().find(textWhere: { text, _ in text.contains("Jacey") }),
                          "the greeting line must still include the live username")
        XCTAssertThrowsError(try sut.inspect().find(text: "YOUR RHYTHM"),
                              "the 'YOUR RHYTHM' eyebrow is leaked internal jargon absent from the approved mockup") { _ in }
        XCTAssertThrowsError(try sut.inspect().find(textWhere: { text, _ in text.contains("Last read") }),
                              "the 'Last read X · N notes' subtitle line is leaked internal jargon absent from the approved mockup") { _ in }
    }

    func test_greeting_reflectsOneOfTheThreeTimeOfDayVariants() throws {
        let sut = HeroHeader(username: "Jacey")

        // Exactly one of the three greeting variants renders, proving the
        // live time-of-day logic (not the mockup's static "Good morning,
        // friend" copy) still drives the text.
        let matches = ["Good morning, Jacey", "Good afternoon, Jacey", "Good evening, Jacey"]
            .filter { text in (try? sut.inspect().find(text: text)) != nil }
        XCTAssertEqual(matches.count, 1,
                        "exactly one time-of-day greeting variant must render, got: \(matches)")
    }
}
