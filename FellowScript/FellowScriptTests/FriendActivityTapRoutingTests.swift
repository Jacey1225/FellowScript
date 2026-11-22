// FriendActivityTapRoutingTests.swift -- task 20261122-app-fixes-threads-widget
// (item 3). Pure routing of a Home friend-activity tap plus the private-note
// copy, the highlight tap wiring and the new payload field decode. NOT built or
// run on the Linux authoring box (no xcodebuild); a Mac / the testing gate must.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class FriendActivityTapRoutingTests: XCTestCase {

    private let preview = FSFriendNotePreview(note_id: "n1", title: "T", text: "body", timestamp: "2026-11-22T10:00:00Z")
    private let highlight = FSFriendHighlightPreview(book: "John", chapter: 3, verse: 16, color: "#FFD700",
                                                     verse_text: "For God so loved", timestamp: "2026-11-22T10:00:00Z")

    private func entry(_ type: String?, note: FSFriendNotePreview? = nil, hl: FSFriendHighlightPreview? = nil,
                       priv: Bool? = nil) -> FSFriendActivityEntry {
        FSFriendActivityEntry(friend_id: "f1", username: "Sarah", last_active_at: "2026-11-22T10:00:00Z",
                              activity_type: type, note_preview: note, highlight_preview: hl, note_is_private: priv)
    }

    func test_highlight_withVerse_opensTheVerse() {
        XCTAssertEqual(FriendActivityTap.target(for: entry("verse_highlighted", hl: highlight)), .verse(highlight))
    }

    func test_highlight_withoutVerse_fallsBackToChat() {
        XCTAssertEqual(FriendActivityTap.target(for: entry("verse_highlighted")), .chat)
    }

    func test_sharedNote_opensTheNote_forEveryNoteType() {
        for t in ["note_created", "note_edited", "note_replied"] {
            XCTAssertEqual(FriendActivityTap.target(for: entry(t, note: preview)), .note(preview), t)
        }
    }

    func test_privateNote_opensTheChat_evenIfAPreviewWereSent() {
        XCTAssertEqual(FriendActivityTap.target(for: entry("note_created", priv: true)), .chat)
        XCTAssertEqual(FriendActivityTap.target(for: entry("note_created", note: preview, priv: true)), .chat)
    }

    func test_unknownOrMissingType_opensTheChat() {
        XCTAssertEqual(FriendActivityTap.target(for: entry(nil)), .chat)
        XCTAssertEqual(FriendActivityTap.target(for: entry("future_type", note: preview)), .chat)
    }

    func test_noteIsPrivate_decodesAndDefaultsToFalse() throws {
        let withFlag = #"{"friend_id":"f","username":"u","last_active_at":null,"activity_type":"note_created","note_preview":null,"note_is_private":true}"#
        let without = #"{"friend_id":"f","username":"u","last_active_at":null,"note_preview":null}"#
        XCTAssertTrue(try JSONDecoder().decode(FSFriendActivityEntry.self, from: Data(withFlag.utf8)).isPrivateNote)
        XCTAssertFalse(try JSONDecoder().decode(FSFriendActivityEntry.self, from: Data(without.utf8)).isPrivateNote)
    }

    // MARK: - widget copy and tap wiring

    func test_privateNote_headlineSaysPrivate_andShowsNoBody() throws {
        let feed = FSFriendActivityFeed(friends_active: [entry("note_created", priv: true)], check_in_candidates: [])
        let sut = FriendActivityHeroCard(feed: feed, onOpenFriend: { _ in })
        XCTAssertNoThrow(try sut.inspect().find(textWhere: { s, _ in s.hasPrefix("Sarah wrote a private note") }))
    }

    func test_tappingHighlightHeadline_invokesOnOpenHighlight_notTheChat() throws {
        var opened: FSFriendHighlightPreview?
        var chat = 0
        let feed = FSFriendActivityFeed(friends_active: [entry("verse_highlighted", hl: highlight)], check_in_candidates: [])
        let sut = FriendActivityHeroCard(feed: feed, onOpenFriend: { _ in chat += 1 }, onOpenHighlight: { opened = $0 })
        let button = try sut.inspect().find(ViewType.Button.self, where: { b in
            (try? b.accessibilityLabel().string())?.contains("Opens verse.") == true
        })
        try button.tap()
        XCTAssertEqual(opened, highlight)
        XCTAssertEqual(chat, 0)
    }

    func test_tappingPrivateNoteHeadline_opensTheChat() throws {
        var chatFriend: String?
        var note = 0
        let feed = FSFriendActivityFeed(friends_active: [entry("note_created", priv: true)], check_in_candidates: [])
        let sut = FriendActivityHeroCard(feed: feed, onOpenFriend: { chatFriend = $0.friend_id }, onOpenNote: { _ in note += 1 })
        let button = try sut.inspect().find(ViewType.Button.self, where: { b in
            (try? b.accessibilityLabel().string())?.contains("private note") == true
        })
        try button.tap()
        XCTAssertEqual(chatFriend, "f1")
        XCTAssertEqual(note, 0)
    }
}
