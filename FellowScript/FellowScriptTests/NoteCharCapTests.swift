// NoteCharCapTests.swift — testing gate coverage for task
// 20260929-free-note-char-cap, step 5.
//
// Covers the client side of the per-note character cap:
//   - NoteLength counting parity with the server's Python len() (Unicode
//     scalars of the string as sent, NOT grapheme clusters)
//   - warn (>= 90%) / over (> limit) state and the shrink-only save rule
//   - FSUsage / FSNoteChars decoding of the server usage payload
//   - NetworkService.throwIfError mapping a 403 note_chars body to
//     AppError.limitReached, and the note_chars-specific error message
//     (no weekly-limit wording; no upgrade wording)
//
// Pure logic tests; no simulator UI, no network.

import XCTest
@testable import FellowScript

final class NoteCharCapTests: XCTestCase {

    // ── counting ────────────────────────────────────────────────────────────
    func test_count_asciiAndEmpty() {
        XCTAssertEqual(NoteLength.count(""), 0)
        XCTAssertEqual(NoteLength.count("abc"), 3)
    }

    func test_count_emojiIsOneScalar() {
        XCTAssertEqual(NoteLength.count("\u{1F600}"), 1)
        XCTAssertEqual(NoteLength.count("a\u{1F600}\u{1F64F}b"), 4)
    }

    func test_count_zwjFamilyCountsEveryScalarNotOneGrapheme() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(family.count, 1, "precondition: one grapheme cluster")
        XCTAssertEqual(NoteLength.count(family), 5, "server len() counts 5 code points")
    }

    func test_count_combiningMarkCountsSeparately() {
        let s = "e\u{0301}"
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(NoteLength.count(s), 2)
    }

    func test_count_crlfIsTwo_noNormalization() {
        // Swift String.count treats CRLF as ONE grapheme; the server counts 2.
        XCTAssertEqual("a\r\nb".count, 3)
        XCTAssertEqual(NoteLength.count("a\r\nb"), 4)
    }

    func test_count_cjk() {
        XCTAssertEqual(NoteLength.count("\u{4F60}\u{597D}\u{4E16}\u{754C}"), 4)
    }

    func test_count_includesHTMLTagsAsSent() {
        XCTAssertEqual(NoteLength.count("<b>hi</b>"), 9)
    }

    func test_count_thirtyThousandBoundaries() {
        XCTAssertEqual(NoteLength.count(String(repeating: "x", count: 30_000)), 30_000)
        XCTAssertEqual(NoteLength.count(String(repeating: "\u{1F600}", count: 30_000)), 30_000)
    }

    func test_approxWords_stripsTags() {
        XCTAssertEqual(NoteLength.approxWords("<p>Hello <b>brave</b> new world</p>"), 4)
        XCTAssertEqual(NoteLength.approxWords(""), 0)
        XCTAssertEqual(NoteLength.approxWords("<p>   </p>"), 0)
    }

    // ── state ───────────────────────────────────────────────────────────────
    func test_state_unknownLimitIsOk() {
        XCTAssertEqual(NoteLength.state(count: 999_999, limit: nil), .ok)
        XCTAssertEqual(NoteLength.state(count: 5, limit: 0), .ok)
    }

    func test_state_freeLimitBoundaries() {
        XCTAssertEqual(NoteLength.state(count: 0, limit: 30_000), .ok)
        XCTAssertEqual(NoteLength.state(count: 26_999, limit: 30_000), .ok)
        XCTAssertEqual(NoteLength.state(count: 27_000, limit: 30_000), .warn)
        XCTAssertEqual(NoteLength.state(count: 30_000, limit: 30_000), .warn)
        XCTAssertEqual(NoteLength.state(count: 30_001, limit: 30_000), .over)
    }

    func test_state_paidLimitBoundaries() {
        XCTAssertEqual(NoteLength.state(count: 90_000, limit: 100_000), .warn)
        XCTAssertEqual(NoteLength.state(count: 100_000, limit: 100_000), .warn)
        XCTAssertEqual(NoteLength.state(count: 100_001, limit: 100_000), .over)
    }

    // ── shrink-only save rule ───────────────────────────────────────────────
    func test_saveBlocked_withinLimitNeverBlocked() {
        XCTAssertFalse(NoteLength.isSaveBlocked(count: 30_000, limit: 30_000, originalCount: 0, isEdit: false))
        XCTAssertFalse(NoteLength.isSaveBlocked(count: 30_000, limit: 30_000, originalCount: 10, isEdit: true))
    }

    func test_saveBlocked_unknownLimitNeverBlocks() {
        XCTAssertFalse(NoteLength.isSaveBlocked(count: 999_999, limit: nil, originalCount: 0, isEdit: false))
        XCTAssertFalse(NoteLength.isSaveBlocked(count: 999_999, limit: 0, originalCount: 0, isEdit: false))
    }

    func test_saveBlocked_newNoteOverLimit() {
        XCTAssertTrue(NoteLength.isSaveBlocked(count: 30_001, limit: 30_000, originalCount: 0, isEdit: false))
    }

    func test_saveBlocked_existingOverLimit_shorterAndSameAllowed_growBlocked() {
        XCTAssertFalse(NoteLength.isSaveBlocked(count: 34_000, limit: 30_000, originalCount: 35_000, isEdit: true))
        XCTAssertFalse(NoteLength.isSaveBlocked(count: 35_000, limit: 30_000, originalCount: 35_000, isEdit: true))
        XCTAssertTrue(NoteLength.isSaveBlocked(count: 35_001, limit: 30_000, originalCount: 35_000, isEdit: true))
    }

    func test_saveBlocked_existingUnderLimitPushedOver() {
        XCTAssertTrue(NoteLength.isSaveBlocked(count: 30_001, limit: 30_000, originalCount: 29_000, isEdit: true))
    }

    func test_saveBlocked_paidLimit() {
        XCTAssertTrue(NoteLength.isSaveBlocked(count: 100_001, limit: 100_000, originalCount: 0, isEdit: false))
        XCTAssertFalse(NoteLength.isSaveBlocked(count: 100_000, limit: 100_000, originalCount: 0, isEdit: false))
        XCTAssertFalse(NoteLength.isSaveBlocked(count: 100_500, limit: 100_000, originalCount: 101_000, isEdit: true))
    }

    func test_format_usesGroupingSeparators() {
        // Locale-dependent separator, so assert digits only survive and length grew.
        let s = NoteLength.format(30_000)
        XCTAssertEqual(s.filter(\.isNumber), "30000")
        XCTAssertGreaterThan(s.count, 5)
    }

    // ── FSUsage / FSNoteChars decoding ──────────────────────────────────────
    private func decodeUsage(_ json: String) throws -> FSUsage {
        try JSONDecoder().decode(FSUsage.self, from: Data(json.utf8))
    }

    func test_decode_freeUsageWithNoteChars() throws {
        let u = try decodeUsage("""
        {"subscribed": false, "plan_type": "free", "window_days": 7,
         "resources": {"notes": {"unlimited": false, "used": 2, "limit": 10, "remaining": 8}},
         "note_chars": {"unlimited": false, "limit": 30000}}
        """)
        XCTAssertEqual(u.note_chars?.limit, 30_000)
        XCTAssertEqual(u.note_chars?.unlimited, false)
        XCTAssertFalse(u.subscribed)
        XCTAssertEqual(u.notes.used, 2)
    }

    func test_decode_paidUsageWithNoteChars() throws {
        let u = try decodeUsage("""
        {"subscribed": true, "plan_type": "plus", "window_days": 7, "resources": {},
         "note_chars": {"unlimited": false, "limit": 100000}}
        """)
        XCTAssertEqual(u.note_chars?.limit, 100_000)
        XCTAssertTrue(u.subscribed)
    }

    func test_decode_olderServerWithoutNoteCharsIsNil() throws {
        let u = try decodeUsage("""
        {"subscribed": false, "plan_type": "free", "window_days": 7, "resources": {}}
        """)
        XCTAssertNil(u.note_chars, "absent field must decode to nil (no counter shown), not fail")
    }

    func test_decode_noteCharsWithoutUnlimitedKey() throws {
        let u = try decodeUsage("""
        {"subscribed": false, "plan_type": "free", "window_days": 7, "resources": {},
         "note_chars": {"limit": 30000}}
        """)
        XCTAssertEqual(u.note_chars?.limit, 30_000)
        XCTAssertNil(u.note_chars?.unlimited)
    }

    // ── 403 mapping + message ───────────────────────────────────────────────
    private func mapped403(_ json: String) -> Error? {
        let url = URL(string: "https://example.test/notes/u1")!
        let resp = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        do { try NetworkService.shared.throwIfError(resp, Data(json.utf8)); return nil } catch { return error }
    }

    func test_throwIfError_403NoteChars_mapsToLimitReached() {
        let err = mapped403("""
        {"detail": {"resource": "note_chars", "allowed": false, "unlimited": false,
                    "used": 30500, "limit": 30000, "remaining": 0}}
        """)
        guard case AppError.limitReached(let resource, let used, let limit)? = err else {
            return XCTFail("expected .limitReached, got \(String(describing: err))")
        }
        XCTAssertEqual(resource, "note_chars")
        XCTAssertEqual(used, 30_500)
        XCTAssertEqual(limit, 30_000)
    }

    func test_limitReached_noteChars_message_hasLimitAndOverCount_noWeeklyOrUpgradeWording() {
        let msg = AppError.limitReached(resource: "note_chars", used: 30_500, limit: 30_000).errorDescription ?? ""
        XCTAssertTrue(msg.contains("too long to save"))
        XCTAssertEqual(msg.filter(\.isNumber).contains("30000"), true)
        XCTAssertTrue(msg.contains("500"), "shows characters over")
        XCTAssertTrue(msg.contains("Your text is kept"))
        XCTAssertFalse(msg.lowercased().contains("upgrade"), "upgrade line is appended only by the editor for free users")
        XCTAssertFalse(msg.lowercased().contains("free plan"))
    }

    func test_limitReached_noteChars_paidLimit_message() {
        let msg = AppError.limitReached(resource: "note_chars", used: 100_200, limit: 100_000).errorDescription ?? ""
        XCTAssertTrue(msg.filter(\.isNumber).contains("100000"))
        XCTAssertTrue(msg.contains("200"))
        XCTAssertFalse(msg.lowercased().contains("upgrade"))
    }

    func test_limitReached_noteChars_zeroOverOmitsOverPart() {
        let msg = AppError.limitReached(resource: "note_chars", used: 0, limit: 30_000).errorDescription ?? ""
        XCTAssertFalse(msg.contains("over)"))
    }

    func test_limitReached_notesCount_wordingUnchanged() {
        let msg = AppError.limitReached(resource: "notes", used: 10, limit: 10).errorDescription ?? ""
        XCTAssertEqual(msg, "You've reached your free plan limit for notes (max 10). Upgrade to a Group plan for unlimited access.")
    }
}
