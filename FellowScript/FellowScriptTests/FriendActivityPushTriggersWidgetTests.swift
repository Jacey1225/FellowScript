// FriendActivityPushTriggersWidgetTests.swift — coverage for task
// 20260904-friend-activity-push-triggers, testing step 4 (widget rendering).
//
// Backend step 1 added `activity_type` (NOTE_CREATED/NOTE_EDITED/
// NOTE_REPLIED/VERSE_HIGHLIGHTED) and `highlight_preview` to
// GET /friends/{user_id}/activity; frontend step 3 taught
// FriendActivityHeroCard.headline() to switch on activity_type per-type, and
// added highlightPreviewRow (real verse content + a friend-attribution
// capsule) shown instead of notePreviewRow for a verse_highlighted entry.
//
// This file proves each of the four activity_type headlines renders its own
// distinct copy (not just the pre-existing note_preview-presence fallback),
// that highlightPreviewRow renders real verse text plus its
// book/chapter/verse reference and the friend's username, that it degrades
// to a bare reference on a verse_text lookup miss (nil, matching a backend
// bible_text miss) without dropping the row, and that an unrecognized/future
// activity_type value still degrades to the existing safe generic fallback
// rather than crashing or failing to render — mirroring
// DashboardEmptyStateTests.swift's existing conventions for this stateless
// component (`.inspect()` directly, no ViewHosting needed).

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class FriendActivityPushTriggersWidgetTests: XCTestCase {

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private func feed(_ entry: FSFriendActivityEntry) -> FSFriendActivityFeed {
        FSFriendActivityFeed(friends_active: [entry], check_in_candidates: [])
    }

    // MARK: - Per-activity-type headline wording

    func test_headline_noteCreated_rendersWroteANote() throws {
        let entry = FSFriendActivityEntry(friend_id: "f1", username: "Sarah", last_active_at: isoNow(),
                                           activity_type: "note_created", note_preview: nil)
        let sut = FriendActivityHeroCard(feed: feed(entry)) { _ in }
        XCTAssertNoThrow(try sut.inspect().find(text: "Sarah wrote a note today"))
    }

    func test_headline_noteEdited_rendersEditedANote() throws {
        let entry = FSFriendActivityEntry(friend_id: "f1", username: "Sarah", last_active_at: isoNow(),
                                           activity_type: "note_edited", note_preview: nil)
        let sut = FriendActivityHeroCard(feed: feed(entry)) { _ in }
        XCTAssertNoThrow(try sut.inspect().find(text: "Sarah edited a note today"))
    }

    func test_headline_noteReplied_rendersRepliedToANote() throws {
        let entry = FSFriendActivityEntry(friend_id: "f1", username: "Sarah", last_active_at: isoNow(),
                                           activity_type: "note_replied", note_preview: nil)
        let sut = FriendActivityHeroCard(feed: feed(entry)) { _ in }
        XCTAssertNoThrow(try sut.inspect().find(text: "Sarah replied to a note today"))
    }

    func test_headline_verseHighlighted_rendersHighlightedAVerse() throws {
        let entry = FSFriendActivityEntry(friend_id: "f1", username: "Sarah", last_active_at: isoNow(),
                                           activity_type: "verse_highlighted", note_preview: nil)
        let sut = FriendActivityHeroCard(feed: feed(entry)) { _ in }
        XCTAssertNoThrow(try sut.inspect().find(text: "Sarah highlighted a verse today"))
    }

    func test_headline_unrecognizedFutureActivityType_degradesToSafeGenericFallback() throws {
        // A build that doesn't yet know about some future activity_type
        // value must not crash or fail to decode -- it degrades to the
        // existing note_preview-presence-based fallback exactly as a nil
        // activity_type already does.
        let entryWithPreview = FSFriendActivityEntry(
            friend_id: "f1", username: "Sarah", last_active_at: isoNow(),
            activity_type: "some_future_activity_type",
            note_preview: FSFriendNotePreview(note_id: "n1", title: "T", text: "body", timestamp: isoNow())
        )
        let sutWithPreview = FriendActivityHeroCard(feed: feed(entryWithPreview)) { _ in }
        XCTAssertNoThrow(try sutWithPreview.inspect().find(text: "Sarah wrote a note today"))

        let entryNoPreview = FSFriendActivityEntry(
            friend_id: "f2", username: "Marcus", last_active_at: isoNow(),
            activity_type: "some_future_activity_type", note_preview: nil
        )
        let sutNoPreview = FriendActivityHeroCard(feed: feed(entryNoPreview)) { _ in }
        XCTAssertNoThrow(try sutNoPreview.inspect().find(text: "Marcus was active today"))
    }

    // MARK: - highlightPreviewRow: real verse content + attribution

    func test_verseHighlighted_withResolvedVerseText_rendersRealTextAndReferenceAndAttribution() throws {
        let entry = FSFriendActivityEntry(
            friend_id: "f1", username: "Marcus", last_active_at: isoNow(),
            activity_type: "verse_highlighted", note_preview: nil,
            highlight_preview: FSFriendHighlightPreview(
                book: "John", chapter: 3, verse: 16, color: "#00FF00",
                verse_text: "For God so loved the world...", timestamp: isoNow())
        )
        let sut = FriendActivityHeroCard(feed: feed(entry)) { _ in }

        XCTAssertNoThrow(try sut.inspect().find(text: "For God so loved the world..."),
                          "the real verse text must render, not a generic placeholder")
        XCTAssertNoThrow(try sut.inspect().find(text: "John 3:16"),
                          "the book/chapter/verse reference must render alongside the verse text")
        XCTAssertNoThrow(try sut.inspect().find(text: "Marcus"),
                          "an attribution affordance naming the highlighting friend must render")
        // notePreviewRow must NOT also render for a highlight entry -- the
        // two preview rows are mutually exclusive per activity_type.
        XCTAssertThrowsError(try sut.inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string())?.contains("Tap to open note.") == true
        }), "a verse_highlighted entry must not also render the note-preview tap target") { _ in }
    }

    func test_verseHighlighted_withNilVerseText_degradesToBareReference_rowStillRenders() throws {
        // nil verse_text mirrors a backend bible_text.verse_text lookup miss
        // (bad/unrecognized reference) -- the row must still render with the
        // bare book/chapter/verse reference rather than being dropped or
        // showing a blank/crashing state.
        let entry = FSFriendActivityEntry(
            friend_id: "f1", username: "Marcus", last_active_at: isoNow(),
            activity_type: "verse_highlighted", note_preview: nil,
            highlight_preview: FSFriendHighlightPreview(
                book: "Obadiah", chapter: 1, verse: 5, color: "#00FF00",
                verse_text: nil, timestamp: isoNow())
        )
        let sut = FriendActivityHeroCard(feed: feed(entry)) { _ in }

        // Two "Obadiah 1:5" Texts render (the fallback body line + the small
        // reference line) -- findAll rather than find, since .find would
        // throw on more than one match.
        let matches = try sut.inspect().findAll(ViewType.Text.self).filter {
            (try? $0.string()) == "Obadiah 1:5"
        }
        XCTAssertFalse(matches.isEmpty, "must fall back to the bare book/chapter/verse reference when verse_text is nil")
    }

    func test_activityTypeVerseHighlighted_butNoHighlightPreview_fallsBackToNotePreviewOrNothing() throws {
        // Defensive: activity_type says verse_highlighted but highlight_preview
        // is nil (e.g. an older cached response, or a friend whose highlight
        // itself couldn't be resolved server-side) -- must not crash, and
        // must not render a blank/garbage highlight row.
        let entry = FSFriendActivityEntry(
            friend_id: "f1", username: "Marcus", last_active_at: isoNow(),
            activity_type: "verse_highlighted", note_preview: nil, highlight_preview: nil
        )
        let sut = FriendActivityHeroCard(feed: feed(entry)) { _ in }
        XCTAssertNoThrow(try sut.inspect().find(text: "Marcus highlighted a verse today"))
    }

    // MARK: - note_preview still wins for non-highlight activity types

    func test_noteReplied_withNotePreview_stillRendersNotePreviewRow_notHighlightRow() throws {
        let entry = FSFriendActivityEntry(
            friend_id: "f1", username: "Sarah", last_active_at: isoNow(),
            activity_type: "note_replied",
            note_preview: FSFriendNotePreview(note_id: "n1", title: "T", text: "Reply preview text", timestamp: isoNow())
        )
        let sut = FriendActivityHeroCard(feed: feed(entry)) { _ in }
        XCTAssertNoThrow(try sut.inspect().find(text: "Reply preview text"))
    }
}
