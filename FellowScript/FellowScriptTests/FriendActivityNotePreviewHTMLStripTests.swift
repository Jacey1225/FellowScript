// FriendActivityNotePreviewHTMLStripTests.swift — minimal coverage for task
// 20260916-friend-activity-note-preview-html (Lightweight spec, frontend
// gate only -- no separate testing gate for this task, per that pipeline's
// own rule that the implementing gate writes minimal coverage itself).
//
// Bug: FSFriendNotePreview.text is raw, unstripped HTML (same convention as
// FSNote.text) but FriendActivityHeroCard.notePreviewRow rendered it
// verbatim, leaking literal `<p>`/`<i>` tags into the friend-activity
// widget. Fix: FSFriendNotePreview.previewText strips tags via the new
// shared stripHTMLTags(_:) helper (also now backing FSNote.preview /
// FSNote.textForSpeech), and notePreviewRow renders that instead of
// preview.text directly.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class FriendActivityNotePreviewHTMLStripTests: XCTestCase {

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    // MARK: - Model-level: FSFriendNotePreview.previewText strips tags

    func test_previewText_stripsHTMLTags_matchingScreenshotRepro() {
        let preview = FSFriendNotePreview(
            note_id: "n1",
            title: "T",
            text: "<p>Colossians 3:1-4 calls us to a heavenly perspective:</p><p><i>\"Since, then, you have been raised with Christ, set your h...\"</i></p>",
            timestamp: isoNow()
        )

        XCTAssertFalse(preview.previewText.contains("<"),
                        "previewText must not leak any literal HTML tag characters")
        XCTAssertTrue(preview.previewText.contains("Colossians 3:1-4 calls us to a heavenly perspective:"),
                       "the underlying text content must still be present after stripping")
    }

    func test_previewText_plainTextWithNoTags_isUnchangedAsideFromTrimming() {
        let preview = FSFriendNotePreview(note_id: "n1", title: "T", text: "  Just plain text, no markup.  ", timestamp: isoNow())
        XCTAssertEqual(preview.previewText, "Just plain text, no markup.")
    }

    // MARK: - View-level: notePreviewRow renders the stripped text, not raw HTML

    func test_notePreviewRow_rendersStrippedText_notRawHTML() throws {
        let preview = FSFriendNotePreview(
            note_id: "n1", title: "T",
            text: "<p><i>Raw markup should not appear.</i></p>",
            timestamp: isoNow()
        )
        let feed = FSFriendActivityFeed(
            friends_active: [
                FSFriendActivityEntry(friend_id: "f1", username: "Sarah", last_active_at: isoNow(), note_preview: preview)
            ],
            check_in_candidates: []
        )
        let sut = FriendActivityHeroCard(feed: feed, onOpenFriend: { _ in }, onOpenNote: { _ in })

        let text = try sut.inspect().find(ViewType.Text.self, where: { t in
            (try? t.string())?.contains("Raw markup should not appear.") == true
        })
        let rendered = try text.string()

        XCTAssertFalse(rendered.contains("<"), "the rendered Text must not contain literal HTML tag characters")
        XCTAssertEqual(rendered, "Raw markup should not appear.")
    }
}
