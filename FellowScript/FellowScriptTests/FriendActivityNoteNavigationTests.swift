// FriendActivityNoteNavigationTests.swift — testing gate coverage for task
// 20260903-friend-activity-note-navigation, step 4 (testing).
//
// Covers the iOS side of the tap-to-open flow per the workflow's step 4
// instructions:
//   1. FriendActivityHeroCard's new notePreviewRow tap target invokes
//      onOpenNote with the tapped preview, distinct from activityRow's
//      onOpenFriend (headline-row chat behavior unchanged) -- both wired
//      independently, tapping one must never fire the other.
//   2. The two tap targets carry distinct, non-colliding accessibility
//      labels (activityRow's pre-existing "...Tap to open chat." vs.
//      notePreviewRow's new "...Tap to open note.").
//   3. isLoadingNotePreview shows a ProgressView and disables the note tap
//      target while a fetch is in flight (minimal-feedback loading state).
//   4. NetworkService.fetchNote — the real client method wired into
//      DashboardView.openFriendNote — hits the correct endpoint/method,
//      decodes a real success response (including the owner "username"
//      field NoteDetailView.canEdit depends on), and throws a user-visible
//      AppError.networkError for the identical `{"error": "cannot find
//      note"}` body the server returns for BOTH a missing note and a
//      not-visible one (mirrors post_reply's own IDOR-safe client-side
//      handling, tested the same way in NoteReplyNetworkServiceTests.swift)
//      -- this is the "deleted/no-longer-visible between preview-load and
//      tap time" failure path DashboardView's friendNoteLoadError alert
//      surfaces.
//
// Uses ViewInspector for the stateless FriendActivityHeroCard component
// (same technique as DashboardEmptyStateTests.swift/
// DashboardFriendRandomizationTests.swift) and StubURLProtocol for the real
// NetworkService.fetchNote call (same technique as
// NoteReplyNetworkServiceTests.swift / NotesLoadFailureHardeningTests.swift).
// DashboardView's own @State (friendNote/isLoadingFriendNote/
// friendNoteLoadError/openFriendNote) is private and not independently
// inspectable without ViewHosting, which no existing Dashboard test in this
// target uses -- consistent with that, this file proves the two seams that
// actually carry the new logic (the reusable child component's tap wiring,
// and the real network/decode/error-mapping contract), matching this
// codebase's established coverage boundary for SwiftUI screens.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - 1-3: FriendActivityHeroCard tap-target wiring

final class FriendActivityNotePreviewTapTests: XCTestCase {

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private func feedWithPreview(preview: FSFriendNotePreview, friendId: String = "f1", username: String = "Sarah") -> FSFriendActivityFeed {
        FSFriendActivityFeed(
            friends_active: [
                FSFriendActivityEntry(friend_id: friendId, username: username, last_active_at: isoNow(), note_preview: preview)
            ],
            check_in_candidates: []
        )
    }

    // MARK: 1a — tapping the note-preview row invokes onOpenNote with the
    // tapped preview, not onOpenFriend.

    func test_tappingNotePreviewRow_invokesOnOpenNote_withTheTappedPreview_notOnOpenFriend() throws {
        let preview = FSFriendNotePreview(note_id: "note-abc", title: "Morning reflection",
                                           text: "Started reading Psalm 23 again this morning.", timestamp: isoNow())
        var openedNote: FSFriendNotePreview?
        var openedFriendCount = 0
        let feed = feedWithPreview(preview: preview)
        let sut = FriendActivityHeroCard(
            feed: feed,
            onOpenFriend: { _ in openedFriendCount += 1 },
            onOpenNote: { openedNote = $0 }
        )

        // Two Buttons exist in this render tree: activityRow (headline) and
        // notePreviewRow (preview text). Find the one carrying the new
        // "Tap to open note." accessibility label specifically, so this
        // assertion can't accidentally pass by tapping the wrong button.
        let noteButton = try sut.inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string())?.contains("Tap to open note.") == true
        })
        try noteButton.tap()

        XCTAssertEqual(openedNote?.note_id, "note-abc",
                        "tapping the note-preview row must invoke onOpenNote with the tapped preview")
        XCTAssertEqual(openedFriendCount, 0,
                        "tapping the note-preview row must NOT also invoke onOpenFriend -- distinct tap targets")
    }

    // MARK: 1b — the existing headline-row tap behavior (open chat) is
    // unchanged: it still invokes onOpenFriend, and does NOT invoke onOpenNote.

    func test_tappingHeadlineRow_stillInvokesOnOpenFriend_onOpenNoteUntouched() throws {
        let preview = FSFriendNotePreview(note_id: "note-abc", title: "T", text: "body", timestamp: isoNow())
        var openedFriend: FSFriendActivityEntry?
        var openedNoteCount = 0
        let feed = feedWithPreview(preview: preview)
        let sut = FriendActivityHeroCard(
            feed: feed,
            onOpenFriend: { openedFriend = $0 },
            onOpenNote: { _ in openedNoteCount += 1 }
        )

        let headlineButton = try sut.inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string())?.contains("Opens chat.") == true
        })
        try headlineButton.tap()

        XCTAssertEqual(openedFriend?.friend_id, "f1",
                        "the headline row's existing chat-open behavior must be unchanged")
        XCTAssertEqual(openedNoteCount, 0,
                        "tapping the headline row must NOT also invoke onOpenNote")
    }

    // MARK: 2 — distinct, non-colliding accessibility labels

    // NOTE (task 20260906-friend-activity-avatar-row): the render tree now
    // also includes the horizontally-scrolling avatar-tile row, and that
    // task's own intake spec explicitly directs the new tile's chat button
    // to reuse the *identical* label as activityRow's headline button
    // ("\(headline(entry)). Opens chat.") -- both trigger the exact same
    // onOpenFriend action, just from two different tap targets, so sharing
    // wording there is deliberate, not a collision. This test's real
    // purpose -- proving notePreviewRow's label is distinguishable from any
    // chat-opening button's label, so VoiceOver users can tell "open chat"
    // and "open note" apart -- no longer holds if checked via a blanket
    // set-uniqueness assertion across every button in the tree.
    func test_activityRowAndNotePreviewRow_haveDistinctAccessibilityLabels() throws {
        let preview = FSFriendNotePreview(note_id: "note-abc", title: "T", text: "body", timestamp: isoNow())
        let feed = feedWithPreview(preview: preview)
        let sut = FriendActivityHeroCard(feed: feed, onOpenFriend: { _ in }, onOpenNote: { _ in })

        let buttons = try sut.inspect().findAll(ViewType.Button.self)
        let labels = buttons.compactMap { try? $0.accessibilityLabel().string() }
        let chatLabels = labels.filter { $0.contains("Opens chat.") }
        let noteLabels = labels.filter { $0.contains("Tap to open note.") }

        XCTAssertFalse(chatLabels.isEmpty,
                      "activityRow's existing label must still be present")
        XCTAssertEqual(noteLabels.count, 1,
                       "notePreviewRow must carry its own sibling label, present exactly once")
        XCTAssertFalse(chatLabels.contains(noteLabels[0]),
                       "notePreviewRow's label must not collide with any chat-opening button's label")
    }

    // MARK: 3 — loading state disables the note tap target and shows a spinner

    func test_isLoadingNotePreview_true_disablesNoteButton_andShowsProgressView() throws {
        let preview = FSFriendNotePreview(note_id: "note-abc", title: "T", text: "body", timestamp: isoNow())
        let feed = feedWithPreview(preview: preview)
        let sut = FriendActivityHeroCard(feed: feed, onOpenFriend: { _ in }, onOpenNote: { _ in }, isLoadingNotePreview: true)

        XCTAssertNoThrow(try sut.inspect().find(ViewType.ProgressView.self),
                          "a spinner must render next to the preview text while a fetch is in flight")

        let noteButton = try sut.inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string())?.contains("Tap to open note.") == true
        })
        XCTAssertTrue(try noteButton.isDisabled(),
                      "the note tap target must be disabled while isLoadingNotePreview is true, to guard against a duplicate fetch")
    }

    func test_isLoadingNotePreview_defaultsFalse_noSpinner_buttonEnabled() throws {
        let preview = FSFriendNotePreview(note_id: "note-abc", title: "T", text: "body", timestamp: isoNow())
        let feed = feedWithPreview(preview: preview)
        // Deliberately omits isLoadingNotePreview/onOpenNote to prove the
        // default keeps every pre-existing call site (that only supplies
        // onOpenFriend) compiling and behaving as before.
        let sut = FriendActivityHeroCard(feed: feed) { _ in }

        XCTAssertThrowsError(try sut.inspect().find(ViewType.ProgressView.self),
                              "no spinner should render when a fetch is not in flight") { _ in }

        let noteButton = try sut.inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string())?.contains("Tap to open note.") == true
        })
        XCTAssertFalse(try noteButton.isDisabled())
    }
}

// MARK: - 4: NetworkService.fetchNote — real request/decode/error contract

final class FetchNoteNetworkServiceTests: XCTestCase {

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

    func test_fetchNote_hitsCorrectEndpoint_decodesRealSuccessBody_includingOwnerUsername() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {
          "user": "friend-001", "username": "Sarah", "title": "Morning reflection",
          "text": "Started reading Psalm 23 again this morning.", "public": true,
          "group_id": "group-abc", "is_reply": false,
          "timestamp": "2026-08-20T11:00:00.000Z",
          "created_at": "2026-08-20T11:00:00.000000+00",
          "verses": [], "replies": []
        }
        """#.data(using: .utf8)!

        let note = try await NetworkService.shared.fetchNote(userId: "viewer-1", noteId: "note-abc")

        XCTAssertEqual(note.user, "friend-001")
        XCTAssertEqual(note.username, "Sarah",
                        "the owner's username must decode -- NoteDetailView.canEdit needs it to compare against the viewer's own username")
        XCTAssertEqual(note.text, "Started reading Psalm 23 again this morning.")
        XCTAssertEqual(note.group_id, "group-abc")
        XCTAssertEqual(note.id, "note-abc", "fetchNote must stamp the requested noteId onto the decoded note")

        let last = try XCTUnwrap(StubURLProtocol.requestLog.last)
        XCTAssertEqual(last.path, "/api/notes/viewer-1/note/note-abc",
                       "must call GET /notes/{user_id}/note/{note_id} with the viewer's own userId, got: \(last.path)")
        XCTAssertEqual(last.method, "GET")
    }

    func test_fetchNote_notVisibleErrorBody_throwsUserVisibleNetworkError_notGarbageEmptyNote() async throws {
        // Server returns the identical body for a missing note and a
        // found-but-not-visible one -- this client-side check must catch
        // BOTH via the same error body, since it never sees which case
        // actually happened server-side either.
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"error": "cannot find note"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.fetchNote(userId: "viewer-1", noteId: "note-gone")
            XCTFail("fetchNote must throw on the server's identical missing/not-visible error body, not silently decode a garbage empty note")
        } catch let error as AppError {
            guard case .networkError(let message) = error else {
                XCTFail("expected AppError.networkError, got \(error)")
                return
            }
            XCTAssertFalse(message.isEmpty, "the thrown error must carry a user-visible message for DashboardView's failure alert")
        }
    }

    func test_fetchNote_missingNoteId_andNotVisibleNoteId_produceTheSameThrownMessage() async throws {
        // Proves the client-side handling doesn't invent a distinction the
        // server deliberately doesn't make -- both branches hit the exact
        // same code path (the "error" key check), so their thrown messages
        // must be identical, preserving the IDOR-safe contract client-side.
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"error": "cannot find note"}"#.data(using: .utf8)!

        var messages: [String] = []
        for noteId in ["note-truly-missing", "note-exists-but-not-visible"] {
            do {
                _ = try await NetworkService.shared.fetchNote(userId: "viewer-1", noteId: noteId)
                XCTFail("expected a throw for \(noteId)")
            } catch let error as AppError {
                if case .networkError(let message) = error { messages.append(message) }
            }
        }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0], messages[1],
                       "identical server error bodies must produce an identical client-thrown message for both the missing and not-visible cases")
    }
}
