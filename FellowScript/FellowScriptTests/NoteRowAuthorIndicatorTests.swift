// NoteRowAuthorIndicatorTests.swift — testing gate coverage for task
// 20260828-note-author-indicator-ios, step 3 (testing).
//
// Covers NoteRow's new per-note author indicator (design-notes.md's
// avatar-initial-circle + username-label chip) and the visibility signal's
// move from the retired standalone PUBLIC capsule to a compact globe/lock
// SF Symbol next to the timestamp:
//
//   1. A group-segment note with a captured `username` renders exactly one
//      author-chip circle, with the uppercased first initial and the full
//      username text visible.
//   2. A group-segment note whose username failed to capture (empty string —
//      the honest diagnostic signal this task's design deliberately chose
//      over a placeholder) renders NO chip at all — no Circle, no fallback
//      text.
//   3. Personal-segment notes (`group_id.isEmpty`) never show an author chip,
//      even defensively if a username were somehow present — per design-
//      notes.md, Personal always implies "you" and is NoteRow-local logic
//      driven purely by group_id.
//   4. The visibility cue (now on both segments, unlike the old PUBLIC-only
//      capsule) renders the correct SF Symbol (`globe` for public,
//      `lock.fill` for private) and the timestamp+icon HStack carries one
//      combined VoiceOver-facing accessibility label ("<timestamp>, public"/
//      "<timestamp>, private").
//
// Uses ViewInspector, same technique as NoteResumeCardContinueIslandTests.swift
// (same test target) — NoteRow has no snapshot/UI-test-target coverage
// elsewhere, so this is the only place its actual rendered structure is
// exercised rather than just its underlying data model.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class NoteRowAuthorIndicatorTests: XCTestCase {

    private func groupNote(
        username: String = "alice", groupId: String = "group-abc", isPublic: Bool = true
    ) -> FSNote {
        FSNote(
            id: "note-1", user: "user-alice", username: username, title: "Group note",
            text: "body", public: isPublic, group_id: groupId,
            timestamp: "2026-08-20 10:00:00"
        )
    }

    private func personalNote(username: String = "", isPublic: Bool = false) -> FSNote {
        FSNote(
            id: "note-2", user: "user-1", username: username, title: "Personal note",
            text: "body", public: isPublic, group_id: "",
            timestamp: "2026-08-20 09:00:00"
        )
    }

    /// The number of `Text` nodes ViewInspector finds in a row that is known
    /// to have NO author chip (empty username) -- this is NoteRow's baseline
    /// text-node count (title + preview + timestamp) for these fixtures
    /// (`verses` defaults to empty, so no verse-chip `Text`s either). Used as
    /// a measured reference rather than a hardcoded magic number, since
    /// `glassCard`/`Theme` styling internals are out of this task's scope and
    /// could shift the *shape* tree in ways unrelated to the author chip
    /// (confirmed empirically: `findAll(ViewType.Shape.self)` picks up ~20
    /// shape nodes from card chrome alone, making shape-counting far too
    /// coupled to unrelated styling to use here).
    private func baselineTextCount() throws -> Int {
        try NoteRow(note: groupNote(username: "")).inspect().findAll(ViewType.Text.self).count
    }

    // MARK: 1 — group note with a captured username shows exactly one author chip

    func test_groupNote_withCapturedUsername_showsAuthorChip_withUppercasedInitialAndFullUsername() throws {
        let baseline = try baselineTextCount()
        let sut = NoteRow(note: groupNote(username: "alice"))

        // The chip adds exactly two Text nodes over the no-chip baseline:
        // the initial (inside the circle overlay) and the username label.
        let textCount = try sut.inspect().findAll(ViewType.Text.self).count
        XCTAssertEqual(textCount, baseline + 2,
                        "the author chip must add exactly two Text nodes (initial + username) over the no-chip baseline")

        XCTAssertNoThrow(try sut.inspect().find(text: "alice"),
                          "the author chip must show the note's full captured username")
        XCTAssertNoThrow(try sut.inspect().find(text: "A"),
                          "the author chip's circle must show the uppercased first initial of the username")
    }

    func test_groupNote_withLowercaseUsername_chipInitialIsUppercased() throws {
        let sut = NoteRow(note: groupNote(username: "bob"))
        XCTAssertNoThrow(try sut.inspect().find(text: "bob"))
        XCTAssertNoThrow(try sut.inspect().find(text: "B"),
                          "initial must be uppercased even though the source username is lowercase")
        XCTAssertThrowsError(try sut.inspect().find(text: "b"),
                              "the chip must never show a lowercase initial") { _ in }
    }

    // MARK: 2 — group note with no captured username: no chip, no placeholder

    func test_groupNote_withEmptyUsername_showsNoAuthorChipAtAll() throws {
        let baseline = try baselineTextCount()
        let sut = NoteRow(note: groupNote(username: ""))

        let textCount = try sut.inspect().findAll(ViewType.Text.self).count
        XCTAssertEqual(textCount, baseline,
                        "a group note whose username failed to decode/capture must render NO chip -- not a placeholder, not the viewer's own identity")
    }

    // MARK: 3 — Personal segment never shows an author chip

    func test_personalNote_neverShowsAuthorChip_evenIfUsernameIsPresent() throws {
        // Defensive: even if some future call site stamped a username onto a
        // Personal note, NoteRow's own group_id-driven gate must still
        // suppress the chip -- Personal always implies "you," per
        // design-notes.md's explicit "leaning omit" decision.
        let sut = NoteRow(note: personalNote(username: "alice"))

        XCTAssertThrowsError(try sut.inspect().find(text: "alice"),
                              "no author text should render anywhere on a Personal note's row") { _ in }
        XCTAssertThrowsError(try sut.inspect().find(text: "A"),
                              "no author initial should render anywhere on a Personal note's row") { _ in }
    }

    func test_personalNote_withEmptyUsername_stillRendersWithoutRegression() throws {
        // The common real-world case: Personal notes never carry a username
        // in the first place (only fetchGroupNotes stamps one).
        let sut = NoteRow(note: personalNote())
        XCTAssertNoThrow(try sut.inspect().find(text: "Personal note"),
                          "Personal notes must still render their title/content normally -- no regression from the author-chip changes")
    }

    // MARK: 4 — visibility cue: correct SF Symbol + combined accessibility label

    func test_publicNote_showsGlobeIcon() throws {
        let sut = NoteRow(note: groupNote(isPublic: true))
        let image = try sut.inspect().find(ViewType.Image.self)
        XCTAssertEqual(try image.actualImage().name(), "globe",
                        "a public note must show the globe SF Symbol next to its timestamp")
    }

    func test_privateNote_showsLockIcon() throws {
        let sut = NoteRow(note: groupNote(isPublic: false))
        let image = try sut.inspect().find(ViewType.Image.self)
        XCTAssertEqual(try image.actualImage().name(), "lock.fill",
                        "a private note must show the lock.fill SF Symbol next to its timestamp")
    }

    func test_publicNote_timestampRow_accessibilityLabel_combinesTimestampAndPublicState() throws {
        let note = groupNote(isPublic: true)
        let sut = NoteRow(note: note)
        let row = try sut.inspect().find(ViewType.HStack.self, where: { h in
            (try? h.accessibilityLabel().string())?.hasSuffix("public") ?? false
        })
        XCTAssertEqual(try row.accessibilityLabel().string(), "\(note.formattedTimestamp), public",
                        "VoiceOver must read one coherent phrase for the timestamp+visibility icon, not two fragments")
    }

    func test_privateNote_timestampRow_accessibilityLabel_combinesTimestampAndPrivateState() throws {
        let note = groupNote(isPublic: false)
        let sut = NoteRow(note: note)
        let row = try sut.inspect().find(ViewType.HStack.self, where: { h in
            (try? h.accessibilityLabel().string())?.hasSuffix("private") ?? false
        })
        XCTAssertEqual(try row.accessibilityLabel().string(), "\(note.formattedTimestamp), private")
    }

    func test_personalSegment_visibilityIcon_stillAppliesToo() throws {
        // Per design-notes.md: "visibility icon still applies to Personal
        // notes too (no reason to hide it there -- VisibilityFilter applies
        // across both segments)" -- this is a strict improvement over the old
        // behavior, where only `public` notes had any visible mark at all.
        let sut = NoteRow(note: personalNote(isPublic: true))
        let image = try sut.inspect().find(ViewType.Image.self)
        XCTAssertEqual(try image.actualImage().name(), "globe")
    }
}
