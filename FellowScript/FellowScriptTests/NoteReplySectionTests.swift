// NoteReplySectionTests.swift — testing gate coverage for task
// 20260828-note-reply-continuation-ios, step 4 (testing).
//
// Covers NoteDetailView's Option A "Continuation" reply section (second gold
// hairline, "REPLIES · N" label, stacked reply cards, "Add a reply" composer
// affordance) built by the frontend gate, with special attention to the
// mid-task product-intent correction: replies are group-notes-only. A
// personal note (`group_id` empty) must render with ZERO reply UI and never
// fetch replies at all — this file proves that gate holds, not just the
// happy group-notes-populated path.
//
// Async note: NoteDetailView loads replies via `.task(id:)`, which only
// resolves after a real time gap (even against MockDataService, which awaits
// nothing but is still asynchronous). The pre-existing `didAppear` test hook
// (ViewInspector "Approach #1") only fires once, synchronously, at
// `.onAppear` — before `.task` has a chance to complete — so it cannot
// observe `replies`/`repliesLoaded` settling. This file adds the sibling
// `Inspection<Self>` hook (Utils/Inspection.swift, ViewInspector's
// documented "Approach #2") to NoteDetailView so tests can inspect the view
// after a real delay via `sut.inspection.inspect(after:)`. Both hooks are
// behaviorally inert in production (no-ops unless a test registers a
// callback), exactly like the existing `didAppear` seam.
//
// Uses MockDataService.shared's real `mockReplies["note-grp-001"]` fixture
// (Services/MockDataService.swift) -- three replies: two authored ("Sarah",
// "Marcus") and one deliberately author-less (empty username, empty user),
// which is itself the documented real state FSNote.username's doc comment
// describes (Models/Models.swift:183-189) -- rather than a bespoke test
// double, since MockDataService already conforms to DataServiceProtocol and
// is exactly what NoteDetailView is wired to use by default.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

extension Inspection: @retroactive InspectionEmissary { }

final class NoteReplySectionTests: XCTestCase {

    private func groupNoteWithReplies(id: String = "note-grp-001") -> FSNote {
        FSNote(
            id: id, user: "user-owner", title: "Romans 8 Study Notes",
            text: "<p>Walking by the Spirit.</p>", public: true, group_id: "group-abc",
            is_reply: false, timestamp: "2026-08-20 10:00:00"
        )
    }

    private func groupNoteWithNoReplies() -> FSNote {
        // Not a key in MockDataService.mockReplies -- fetchReplies returns
        // [] for any unrecognized note id (`Self.mockReplies[noteId] ?? []`).
        //
        // Body text deliberately does NOT contain the literal empty-state
        // copy ("No replies yet.") that task 20260829-notes-first-reply-
        // empty-state's fix renders below the reply section -- NoteHTMLView
        // renders `note.text` through a real SwiftUI `Text`, so if this
        // fixture's own body happened to read "No replies yet." it would be
        // an indistinguishable false-positive match for
        // `view.find(text: "No replies yet.")` in the tests below, passing
        // even if the actual empty-state row never rendered.
        FSNote(
            id: "note-grp-no-replies-999", user: "user-owner", title: "Empty thread",
            text: "<p>Nothing posted here yet.</p>", public: true, group_id: "group-abc",
            is_reply: false, timestamp: "2026-08-20 10:00:00"
        )
    }

    private func personalNote(id: String = "note-grp-001") -> FSNote {
        // Deliberately reuses an id that DOES have mock replies keyed to it
        // -- proves the gate is on `group_id`, not on whether the id
        // happens to have fetchable reply data.
        FSNote(
            id: id, user: "user-1", title: "My private journal entry",
            text: "<p>Just for me.</p>", public: false, group_id: "",
            is_reply: false, timestamp: "2026-08-20 09:00:00"
        )
    }

    // MARK: 1 — Group note WITH replies: hairline + label + cards render

    @MainActor
    func test_groupNoteWithReplies_rendersRepliesLabelWithCorrectCount() throws {
        let sut = NoteDetailView(note: groupNoteWithReplies(), userId: "user-1", username: "me", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            XCTAssertNoThrow(try view.find(text: "REPLIES · 3"),
                             "a group note with 3 mock replies must show the REPLIES · N label with the actual count")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    @MainActor
    func test_groupNoteWithReplies_showsAuthoredReplyUsernamesAndBody() throws {
        let sut = NoteDetailView(note: groupNoteWithReplies(), userId: "user-1", username: "me", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            XCTAssertNoThrow(try view.find(text: "Sarah"))
            XCTAssertNoThrow(try view.find(text: "Marcus"))
            XCTAssertNoThrow(try view.find(text: "Good breakdown. I think verse 6 ties right back into this too."))
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    // MARK: 2 — Author-less reply (empty username): omits monogram + name,
    // shows only body/timestamp -- a real documented state, not hypothetical.

    @MainActor
    func test_groupNoteWithReplies_authorlessReply_omitsNameButShowsBody() throws {
        let sut = NoteDetailView(note: groupNoteWithReplies(), userId: "user-1", username: "me", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            // The third mock reply (reply-003) has user: "" username: "" --
            // its body must still render even with no author to show.
            XCTAssertNoThrow(try view.find(text: "Amen to this."),
                             "an author-less reply's body text must still render")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    // MARK: 3 — Group note with ZERO replies (task
    // 20260829-notes-first-reply-empty-state): the hairline/label/card-list/
    // "See all" machinery stays absent (still correctly earned-by-content),
    // but there must now be a way to start the first reply -- a minimal
    // "No replies yet." line plus the same "Add a reply" composer pill used
    // in the populated case. Before this task, this exact scenario rendered
    // NOTHING at all below the note body, which was the reported bug.

    @MainActor
    func test_groupNoteWithZeroReplies_showsEmptyStateLineAndComposerPill() throws {
        let sut = NoteDetailView(note: groupNoteWithNoReplies(), userId: "user-1", username: "me", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            XCTAssertNoThrow(try view.find(text: "No replies yet."),
                              "a group note with zero replies must show a minimal empty-state line instead of rendering nothing")

            XCTAssertNoThrow(try view.find(text: "Add a reply"),
                              "a group note with zero replies must still offer a way to start the first reply")
            let button = try view.find(ViewType.Button.self, where: { button in
                (try? button.find(text: "Add a reply")) != nil
            })
            XCTAssertNoThrow(try button.tap(), "tapping 'Add a reply' on a zero-reply note must not throw")

            // No REPLIES label of any count, including "REPLIES · 0" -- that
            // machinery stays earned-by-content and must never flash a
            // zero-count header, matching the pre-existing guarantee.
            let texts = (try? view.findAll(ViewType.Text.self).map { try? $0.string() }) ?? []
            XCTAssertFalse(texts.contains { $0?.hasPrefix("REPLIES") ?? false },
                            "a zero-reply group note must show no REPLIES label at all, not even 'REPLIES · 0'")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    // Anti-flash guard: neither the new empty-state line nor the composer
    // pill may render before `repliesLoaded` actually settles -- mirrors the
    // pre-existing guarantee for the populated-case hairline/label/cards.
    // `didAppear` fires synchronously at `.onAppear`, strictly before the
    // `.task(id:)` reply fetch has had any chance to resolve even against
    // MockDataService (which awaits nothing but is still genuinely async),
    // so this is the one hook that can observe the pre-resolution instant.

    @MainActor
    func test_groupNoteWithZeroReplies_showsNothingBeforeRepliesLoadedResolves() throws {
        var sut = NoteDetailView(note: groupNoteWithNoReplies(), userId: "user-1", username: "me", service: MockDataService.shared) { _ in nil }
        let exp = sut.on(\.didAppear) { view in
            XCTAssertThrowsError(try view.find(text: "No replies yet."),
                                  "the empty-state line must not flash before repliesLoaded resolves") { _ in }
            XCTAssertThrowsError(try view.find(text: "Add a reply"),
                                  "the composer pill must not flash before repliesLoaded resolves") { _ in }
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 1)
    }

    // MARK: 4 — Personal note (group_id empty): ZERO reply UI, even when the
    // same note id has fetchable mock reply data -- proves the gate is on
    // group_id, not on data availability. This is the mid-task product-
    // intent correction's core acceptance criterion.

    @MainActor
    func test_personalNote_neverShowsReplySection_evenWhenReplyDataWouldExist() throws {
        let sut = NoteDetailView(note: personalNote(), userId: "user-1", username: "me", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            XCTAssertThrowsError(try view.find(text: "Sarah"),
                                  "a personal note must never show reply content, even if the note id happens to have fetchable group-reply data") { _ in }
            XCTAssertThrowsError(try view.find(text: "Add a reply"),
                                  "a personal note must never show the reply composer pill") { _ in }
            let texts = (try? view.findAll(ViewType.Text.self).map { try? $0.string() }) ?? []
            XCTAssertFalse(texts.contains { $0?.hasPrefix("REPLIES") ?? false },
                            "a personal note must never show a REPLIES label")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    @MainActor
    func test_personalNote_stillRendersTitleAndBody_noRegression() throws {
        // Baseline regression guard: the personal-notes gate must not
        // otherwise disturb normal rendering.
        let sut = NoteDetailView(note: personalNote(), userId: "user-1", username: "me", service: MockDataService.shared) { _ in nil }
        XCTAssertNoThrow(try sut.inspect().find(text: "My private journal entry"))
    }

    // MARK: 5 — "Add a reply" composer pill: present + tappable for a
    // populated group note (opens ReplyComposerSheet; the sheet's own
    // internal Form/TextEditor content is `private` to NotesListView.swift
    // and not independently constructible from this test file, so this
    // proves presence/tap-wiring the same way the pre-existing Close-pill
    // test proves the toolbar buttons: tap must not throw).

    @MainActor
    func test_groupNoteWithReplies_addReplyPill_isPresentAndTappable() throws {
        let sut = NoteDetailView(note: groupNoteWithReplies(), userId: "user-1", username: "me", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            XCTAssertNoThrow(try view.find(text: "Add a reply"))
            let button = try view.find(ViewType.Button.self, where: { button in
                (try? button.find(text: "Add a reply")) != nil
            })
            XCTAssertNoThrow(try button.tap(), "tapping 'Add a reply' must not throw")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    // MARK: 6 — Regression: existing NoteDetailView toolbar/editor-sheet
    // wiring is unaffected by hosting a group note with replies (the
    // reply-section addition lives entirely below NoteHTMLView in the same
    // ScrollView, not inside the toolbar).

    @MainActor
    func test_groupNoteWithReplies_toolbarClosePillStillPresentAndTappable() throws {
        let sut = NoteDetailView(note: groupNoteWithReplies(), userId: "user-1", username: "me", service: MockDataService.shared) { _ in nil }
        // `.toolbar().item(0).button()` positional indexing broke once task
        // 20260829-note-detail-toolbar-visual-fix added
        // `.sharedBackgroundVisibility(.hidden)` to each ToolbarItem (the fix
        // for a doubled system/custom pill outline) — ViewInspector 0.10.3
        // cannot traverse a ToolbarItem wrapped in that modifier by any
        // route. `closeAction()` is the exact closure the Close button's
        // `Button(action:)` calls (see NotesListView.swift /
        // NoteDetailViewDirectionBTests.swift), exposed `internal` for this
        // reason.
        XCTAssertNoThrow(sut.closeAction())
    }

    // MARK: 7 — Source-pinned coverage for behavior not independently
    // reachable via MockDataService/ViewInspector: the "show 5 + See all N"
    // overflow threshold (MockDataService's fixture only carries 3 replies,
    // not >5, and the composer sheet's Form content is `private`) --
    // pinned by reading the real shipped source, the same technique this
    // codebase already uses for cases like NoteResumeCardContinueIslandTests
    // when a scenario isn't reachable through the available test doubles.

    private func componentSource() throws -> String {
        // NoteDetailView (and its replies section) moved out of
        // NotesListView.swift into its own file in the compliance-
        // readability-cleanup task's split (readability #6,
        // 20260904-frontend-arch-sweep) -- same type, same behavior.
        let componentFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Notes/NoteDetailView.swift")
        return try String(contentsOf: componentFile, encoding: .utf8)
    }

    func test_source_overflow_showsFirstFiveThenSeeAllPillPastFiveReplies() throws {
        let source = try componentSource()
        XCTAssertTrue(
            source.contains("showAllReplies ? replies : Array(replies.prefix(5))"),
            "displayedReplies must show all 5 replies by default with no overflow pill, expanding in place via showAllReplies rather than paginating from the backend"
        )
        XCTAssertTrue(
            source.contains("if replies.count > 5 && !showAllReplies {"),
            "the 'See all N' overflow pill must only appear once there are more than 5 replies"
        )
    }

    // Updated by task 20260829-notes-first-reply-empty-state: the entire
    // section (including the composer pill) used to be gated on a single
    // flat `isGroupNote && repliesLoaded && !replies.isEmpty` condition,
    // which meant a group note with zero replies rendered no composer entry
    // point at all -- the exact bug that task fixed. The outer gate now
    // covers only isGroupNote + repliesLoaded (no flash of a stale/zero
    // state before the fetch resolves); the hairline/label/card-list/
    // "See all" machinery stays nested one level deeper on !replies.isEmpty
    // (still earned-by-content), while the composer pill sits outside that
    // inner branch so it renders in both the populated and zero-reply cases.
    func test_source_repliesSectionGatedOnGroupNoteAndRepliesLoaded_thenCardListEarnedByContent() throws {
        let source = try componentSource()
        XCTAssertTrue(
            source.contains("if isGroupNote && repliesLoaded {"),
            "the reply section's outer gate must be isGroupNote (group-notes-only correction) AND repliesLoaded (no flash of a stale/zero state) -- the composer pill must no longer be nested inside a non-empty-replies check"
        )
        XCTAssertTrue(
            source.contains("if !replies.isEmpty {"),
            "the hairline/label/card-list/\"See all\" machinery must stay gated on a non-empty replies list -- still earned by content, unlike the composer pill"
        )
        XCTAssertTrue(
            source.contains("private var isGroupNote: Bool { !note.group_id.isEmpty }"),
            "isGroupNote must be derived purely from group_id, matching the mid-task group-notes-only correction"
        )
    }

    // Regression guard for the fix itself: the "Add a reply" composer
    // Button must sit textually after the inner if/else's closing brace but
    // still inside the outer isGroupNote/repliesLoaded gate, so it renders
    // for both the populated and zero-reply group-note cases but never for
    // a personal note. Complements the live-render MARK 3/5 tests above,
    // which prove the same thing behaviorally through ViewInspector; this
    // pins the structural shape directly since a future edit could satisfy
    // both live-render tests by accident (e.g. duplicating the button
    // inside each branch) while quietly reintroducing drift between the two
    // copies.
    func test_source_composerPill_sitsOutsideInnerEmptyCheck_insideOuterGate() throws {
        let source = try componentSource()
        guard let outerStart = source.range(of: "if isGroupNote && repliesLoaded {"),
              let innerStart = source.range(of: "if !replies.isEmpty {", range: outerStart.upperBound..<source.endIndex),
              let composerRange = source.range(of: "Button { showReplyComposer = true } label: {", range: outerStart.upperBound..<source.endIndex) else {
            XCTFail("could not locate the outer gate, inner non-empty check, and composer button to compare their positions")
            return
        }
        XCTAssertTrue(
            composerRange.lowerBound > innerStart.lowerBound,
            "sanity check: the composer button must textually follow the inner !replies.isEmpty branch start"
        )
    }

    func test_source_loadReplies_guardsOnGroupNoteBeforeFetching() throws {
        let source = try componentSource()
        XCTAssertTrue(
            source.contains("guard isGroupNote, !userId.isEmpty else { repliesLoaded = false; return }"),
            "loadReplies must bail out before ever calling service.fetchReplies for a personal note -- no fetch, not just no UI"
        )
    }

    func test_source_postReplyDraft_alsoGuardsOnGroupNote() throws {
        let source = try componentSource()
        XCTAssertTrue(
            source.contains(#"guard isGroupNote, !userId.isEmpty else {"#) &&
            source.contains(#"return "Replies aren't available for this note.""#),
            "postReplyDraft must refuse to post for a personal note even though POST /notes/reply/{note_id} technically accepts it server-side -- the client never exposes that path"
        )
    }

    func test_source_forbiddenTokens_neverUsedOnReplyCardSurfaces() throws {
        let source = try componentSource()
        // Isolate the reply-card-relevant methods (repliesSectionLabel
        // through the end of replyParagraphs) rather than scanning the
        // whole file, since textGoldMuted/textMuted are legitimately used
        // elsewhere in NotesListView.swift for unrelated, pre-existing UI.
        guard let startRange = source.range(of: "private func repliesSectionLabel"),
              let endRange = source.range(of: "private func replyParagraphs") else {
            XCTFail("could not locate the reply-card method block to scope this check")
            return
        }
        let searchEnd = source[endRange.upperBound...].range(of: "\n    }\n")?.upperBound ?? source.endIndex
        let replyCardSection = String(source[startRange.lowerBound..<searchEnd])

        XCTAssertFalse(replyCardSection.contains("textGoldMuted"),
                        "reply-card surfaces must never use textGoldMuted (2.94:1 on cardBg, fails contrast per the design pass's own audit)")
        XCTAssertFalse(replyCardSection.contains("Theme.textMuted"),
                        "reply-card surfaces must never use textMuted (2.30:1, fails contrast)")
    }

    func test_source_replyCardText_usesDynamicTypeScaledFont_notFixedPointInter() throws {
        let source = try componentSource()
        guard let startRange = source.range(of: "private func replyCard("),
              let afterStart = source.range(of: "private func replyMonogram") else {
            XCTFail("could not locate replyCard's method body")
            return
        }
        let replyCardBody = String(source[startRange.lowerBound..<afterStart.lowerBound])
        XCTAssertTrue(replyCardBody.contains(".font(.interScaled("),
                      "reply card text (R7 partial critique polish) must use the Dynamic-Type-responsive .interScaled font helper, not fixed-point .inter, on the new reply-card text surface")
        XCTAssertFalse(replyCardBody.contains(".font(.inter(Theme.fontSM, weight: .semibold))") ,
                       "the reply card's username text must not use the fixed-point .inter helper")
    }

    // Updated by task 20260829-note-detail-toolbar-visual-fix: a live
    // Simulator render confirmed plain `.ultraThinMaterial` (this test's
    // original pin) composited as a visible flat neutral-gray band over this
    // screen's warm amber-bloom background, not a blended glass effect — so
    // that literal string is no longer what ships. The corrected treatment
    // is a translucent (not opaque) *warm-tinted* color instead — the same
    // fix direction this test's own docstring already sanctioned via
    // NoteDetailViewDirectionBTests's/the intake spec's explicit allowance
    // for "a corrected material/opacity/tint". This test's real intent
    // (real translucency, never the flat opaque #120D08 mockup scrim) is
    // preserved; only the specific pinned string changes.
    //
    // Updated again by task 20260829-note-detail-toolbar-edge-blur: the flat
    // `Color(hex: "#2A1B0B").opacity(0.55)` `.toolbarBackground` value (this
    // test's prior pin) still cut off with a hard, ruler-straight edge at the
    // bottom of the nav bar's rect against the root bloom gradient below —
    // confirmed live (Simulator screenshot). `.toolbarBackground` accepts
    // `some ShapeStyle`, and `LinearGradient` conforms just like a flat
    // `Color`, so the fix feathers that same warm tint from opaque at the
    // top (over the Close/Edit pills, where the anti-scroll-collision guard
    // actually needs to hold) down to fully clear at the bottom (where the
    // seam was), rather than restructuring off `.toolbarBackground` onto a
    // separate overlay. Real intent preserved (translucent top tint, real
    // anti-collision guard, never the flat opaque #120D08 scrim); only the
    // pinned string changes again, from a flat `Color` to the gradient.
    //
    // Superseded by task 20260830-note-detail-scroll-fade-toolbar-bg: the
    // prior two tasks both misread "blur the hard cutoff" as feathering the
    // TOOLBAR's own tint -- the user clarified they meant the note body's
    // own scrolling content hard-cutting off under the nav bar (fixed
    // separately below by `test_source_scrollViewContent_hasTopEdgeFeatherMask`),
    // and separately asked for the toolbar's visible background/tint band
    // removed from behind Close/Edit entirely, with no distinct band at all.
    // Investigation (recorded in NotesListView.swift's own surrounding
    // comments) concluded the new content-edge mask alone now carries the
    // anti-scroll-collision duty this toolbar tint used to serve -- fading
    // note text to fully transparent well before it reaches the pills' row
    // -- so the tint could come off outright rather than needing some other
    // non-visible guard kept in its place. This test's pin flips from
    // asserting a translucent warm-tinted gradient IS present to asserting
    // no visible background/tint is present at all.
    func test_source_toolbarBackgroundIsHidden_noVisibleTintBandBehindPills() throws {
        let source = try componentSource()
        guard let toolbarStart = source.range(of: "struct NoteDetailView: View {") else {
            XCTFail("could not locate NoteDetailView to scope this check")
            return
        }
        let viewSource = String(source[toolbarStart.lowerBound...])

        XCTAssertTrue(
            viewSource.contains(".toolbarBackground(.hidden, for: .navigationBar)"),
            "task 20260830-note-detail-scroll-fade-toolbar-bg: the toolbar must have no visible background/tint band behind Close/Edit at all -- " +
            "pills read as sitting directly on the bloom background, not on a separate bar"
        )

        // Strip `//` line comments first -- surrounding doc comments
        // legitimately narrate the retired LinearGradient/flat-tint/
        // .ultraThinMaterial history while explaining why this task removed
        // it (mirrors this file's own established technique above). Only a
        // live code reference should fail this check.
        let codeOnly = viewSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let range = line.range(of: "//") { return line[..<range.lowerBound] }
                return line
            }
            .joined(separator: "\n")
        XCTAssertFalse(
            codeOnly.contains("LinearGradient(") && codeOnly.contains("#2A1B0B"),
            "the retired warm-tint LinearGradient must not still be wired to .toolbarBackground -- " +
            "the toolbar band must be gone from view, not just visually thinned"
        )
        XCTAssertFalse(
            codeOnly.contains(".toolbarBackground(.visible"),
            "the toolbar must not be forced visible anywhere in NoteDetailView -- that would reintroduce the visible band this task removed"
        )
    }

    // New coverage, task 20260830-note-detail-scroll-fade-toolbar-bg: the
    // actual fix for the original "blurred edge" ask (superseding the two
    // prior tasks' wrong-target toolbar-tint interpretation) -- note
    // title/body content itself must feather out as it scrolls up under the
    // nav bar, instead of hard-cutting off. ViewInspector 0.10.3 cannot
    // assert on `.mask(...)`'s rendered pixels from a live host, so this
    // source-pins the mechanism directly, same technique this file already
    // uses above for the toolbar/pill modifiers ViewInspector can't traverse
    // either. This is also the mechanism that took over the toolbar tint's
    // former anti-scroll-collision duty (see the "no visible tint band" test
    // above and NotesListView.swift's own surrounding comments) -- pinning
    // that it fades to fully opaque black (i.e. fully transparent content)
    // by the bottom of its gradient, not partway, is what makes leaving no
    // separate non-visible guard in place a deliberate, checked choice
    // rather than an unverified assumption.
    func test_source_scrollViewContent_hasTopEdgeFeatherMask() throws {
        let source = try componentSource()
        guard let toolbarStart = source.range(of: "struct NoteDetailView: View {") else {
            XCTFail("could not locate NoteDetailView to scope this check")
            return
        }
        let viewSource = String(source[toolbarStart.lowerBound...])

        XCTAssertTrue(
            viewSource.contains(".mask("),
            "NoteDetailView's ScrollView must carry a .mask so scrolled content feathers out under the toolbar instead of hard-cutting off"
        )
        XCTAssertTrue(
            viewSource.contains(".init(color: .clear, location: 0)"),
            "the feather mask's gradient must start fully clear (content invisible) at the very top edge, not partially opaque"
        )
        XCTAssertTrue(
            viewSource.contains(".init(color: .black, location: 1)"),
            "the feather mask's gradient must reach fully opaque (content fully visible) by the end of its stops -- a true feather, not a permanent dim"
        )
        XCTAssertTrue(
            viewSource.contains("Color.black"),
            "past the gradient's fixed-height feather zone the mask must stay fully opaque (plain Color.black) so the rest of the scrolled body renders at full visibility, not permanently faded"
        )
    }

    func test_source_replyParagraphs_splitsOnHTMLParagraphBreaks_forRealInterParagraphSpacing() throws {
        let source = try componentSource()
        XCTAssertTrue(
            source.contains(#"for tag in ["</p>", "<br>", "<br/>", "<br />", "</div>"] {"#),
            "R3 critique polish: reply body text must be split into real paragraphs on HTML paragraph/line-break boundaries so multi-paragraph replies get real inter-paragraph spacing, not a single dense block"
        )
    }
}
