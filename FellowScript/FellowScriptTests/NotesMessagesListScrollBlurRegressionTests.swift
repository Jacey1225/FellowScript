// NotesMessagesListScrollBlurRegressionTests.swift — regression coverage for
// task 20260831-notes-messages-list-scroll-blur.
//
// The bug: NotesListView's notesTab/highlightsTab and ChatRootView's
// friendsList/groupsList/agentsList each sit as a plain VStack sibling
// directly under a custom header/toggle/chip row (no NavigationStack
// toolbar), with no top-edge treatment at all -- scrolled rows hit a hard,
// unblurred clip flush against that header, and (per a live coordinator
// screenshot mid-task) a scrolled row's card visibly collided with/read as
// overlapping the header/chip row above it, not just "lacking blur."
//
// The fix has two structurally distinct halves, both required (frontend.json
// mid-task correction, and Theme.swift's own doc comment on
// scrollTopEdgeFeather):
//   1. `scrollTopEdgeFeather()` (Theme.swift) -- a `.mask` on the List itself
//      (never a separate overlay/background/material panel) so scrolled rows
//      fade out smoothly under the header instead of hard-clipping.
//   2. A genuine, scroll-independent `.padding(.top, Theme.spacingLG)`
//      applied OUTSIDE/AFTER the mask -- `.contentMargins(.top:)` alone only
//      offsets the list's AT-REST scroll position, it does not create a
//      persistent buffer once scrolled, since content still travels all the
//      way to the List's own top-edge frame boundary during a real scroll
//      gesture. Only the outer `.padding(.top:)` moves that frame boundary
//      itself away from the header, which is what actually prevents the
//      real collision bug shown live.
//
// These are source-pin tests (ViewInspector 0.10.3 cannot traverse a `.mask`
// composited List's alpha in a snapshot the way it can text/buttons, and a
// `List`'s own `.mask` isn't something XCTest can assert pixel-level alpha
// on either) -- mirrors NoteReplySectionTests's
// test_source_scrollViewContent_hasTopEdgeFeatherMask precedent for
// NoteDetailView's analogous ScrollView `.mask`. The live, on-device
// scrolled-state collision confirmation lives in
// NotesMessagesListScrollBlurUITests.swift (XCUITest, screenshots + a real
// drag-scroll gesture) -- this file proves the mechanism is actually wired
// into source for all five target Lists, so a future edit can't silently
// drop the outer padding (or reorder it back inside the mask) while still
// leaving `scrollTopEdgeFeather()` present and this file's sibling UI test
// green by coincidence of insufficient mock data to reproduce the collision.
import XCTest
@testable import FellowScript

final class NotesMessagesListScrollBlurRegressionTests: XCTestCase {

    private func themeSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Theme/Theme.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func notesListViewSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Notes/NotesListView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func chatRootViewSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Chat/ChatRootView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Slices `source` from the first occurrence of `startMarker` up to
    /// (not including) whichever of `endMarkers` occurs first after it --
    /// scopes an assertion to one specific computed-var body rather than the
    /// whole file, mirroring NoteReplySectionTests' componentSource-plus-
    /// range(of:) pattern.
    private func scoped(_ source: String, from startMarker: String, to endMarkers: [String]) -> String {
        guard let start = source.range(of: startMarker) else {
            XCTFail("could not locate '\(startMarker)' to scope this check")
            return ""
        }
        let rest = source[start.upperBound...]
        var end = rest.endIndex
        for marker in endMarkers {
            if let r = rest.range(of: marker), r.lowerBound < end {
                end = r.lowerBound
            }
        }
        return String(rest[..<end])
    }

    // MARK: - 1. Theme.swift's shared modifier: mask-only, clear→opaque, no separate panel

    func test_source_scrollTopEdgeFeather_isMaskOnly_withClearToOpaqueGradient() throws {
        let source = try themeSource()
        let body = scoped(source,
                           from: "func scrollTopEdgeFeather(height: CGFloat = 56) -> some View {",
                           to: ["extension Theme {", "// ── Gold gradient"])

        XCTAssertTrue(
            body.contains("mask("),
            "scrollTopEdgeFeather must apply a .mask so List content fades under the header instead of hard-clipping"
        )
        XCTAssertTrue(
            body.contains(".init(color: .clear, location: 0)"),
            "the feather's gradient must start fully clear (content invisible) at the List's own top edge -- a true fade, not a partial dim"
        )
        XCTAssertTrue(
            body.contains(".init(color: .black, location: 1)"),
            "the feather's gradient must reach fully opaque by the end of its stops so rows below the feather zone render at full visibility"
        )
        XCTAssertTrue(
            body.contains("Color.black"),
            "past the fixed-height gradient zone the mask must stay fully opaque, matching NoteDetailView's ScrollView precedent"
        )
        // Must alter the List's own alpha compositing only -- never draw a
        // separate overlay/background/material layer (mid-task coordinator
        // clarification, frontend.json): a mask-only implementation can
        // never itself introduce a visible panel behind/in front of the list.
        XCTAssertFalse(
            body.contains(".overlay(") || body.contains(".background("),
            "scrollTopEdgeFeather must remain mask-only -- no overlay/background panel, per the mid-task 'no background overlay' clarification"
        )
    }

    // MARK: - 2. Each of the 5 target Lists: feather + persistent outer padding, correctly ordered

    private func assertListHasBothHalvesOfFix(
        _ source: String, varName: String, endMarkers: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let body = scoped(source, from: "private var \(varName): some View {", to: endMarkers)

        XCTAssertTrue(
            body.contains(".scrollTopEdgeFeather()"),
            "\(varName) must apply the shared scrollTopEdgeFeather() modifier so its List's scrolled rows fade under the header",
            file: file, line: line
        )
        XCTAssertTrue(
            body.contains(".contentMargins(.top, Theme.spacingSM, for: .scrollContent)"),
            "\(varName) must keep a small at-rest .contentMargins(.top:) inset so the first row isn't flush against the List's own (now further-away) top edge",
            file: file, line: line
        )
        XCTAssertTrue(
            body.contains(".padding(.top, Theme.spacingLG)"),
            "\(varName) must apply a genuine, scroll-independent .padding(.top, Theme.spacingLG) -- .contentMargins alone only offsets the at-rest position, it does not create a persistent buffer once scrolled",
            file: file, line: line
        )

        // Structural ordering: the outer padding must come AFTER
        // scrollTopEdgeFeather() in the modifier chain (i.e. outside the
        // mask), not before it -- a `.padding` applied BEFORE `.mask` would
        // be masked away/absorbed rather than moving the List's own clipping
        // frame, which is the exact distinction the mid-task correction
        // (frontend.json) called out as the real fix.
        guard let featherRange = body.range(of: ".scrollTopEdgeFeather()"),
              let paddingRange = body.range(of: ".padding(.top, Theme.spacingLG)") else {
            XCTFail("expected both .scrollTopEdgeFeather() and .padding(.top, Theme.spacingLG) to be present in \(varName)", file: file, line: line)
            return
        }
        XCTAssertTrue(
            paddingRange.lowerBound > featherRange.lowerBound,
            "\(varName)'s .padding(.top, Theme.spacingLG) must come AFTER (outside) .scrollTopEdgeFeather() in the modifier chain -- padding applied before the mask would be masked away instead of moving the List's own clipping frame away from the header",
            file: file, line: line
        )
    }

    func test_source_notesTab_hasFeatherAndPersistentOuterPadding_correctlyOrdered() throws {
        let source = try notesListViewSource()
        assertListHasBothHalvesOfFix(
            source, varName: "notesTab",
            endMarkers: ["private var highlightsTab: some View {"]
        )
    }

    func test_source_highlightsTab_hasFeatherAndPersistentOuterPadding_correctlyOrdered() throws {
        let source = try notesListViewSource()
        assertListHasBothHalvesOfFix(
            source, varName: "highlightsTab",
            endMarkers: ["private var notesEmptyState: some View {"]
        )
    }

    func test_source_friendsList_hasFeatherAndPersistentOuterPadding_correctlyOrdered() throws {
        let source = try chatRootViewSource()
        assertListHasBothHalvesOfFix(
            source, varName: "friendsList",
            endMarkers: ["private var groupsList: some View {"]
        )
    }

    func test_source_groupsList_hasFeatherAndPersistentOuterPadding_correctlyOrdered() throws {
        let source = try chatRootViewSource()
        assertListHasBothHalvesOfFix(
            source, varName: "groupsList",
            endMarkers: ["private var agentsList: some View {"]
        )
    }

    func test_source_agentsList_hasFeatherAndPersistentOuterPadding_correctlyOrdered() throws {
        let source = try chatRootViewSource()
        assertListHasBothHalvesOfFix(
            source, varName: "agentsList",
            endMarkers: ["private var loadingView: some View {"]
        )
    }

    // MARK: - 3. Out-of-scope guard: NoteDetailView's own already-fixed ScrollView untouched

    func test_source_noteDetailView_stillUsesItsOwnMask_notTheSharedListModifier() throws {
        // NoteDetailView (NotesListView.swift, same file) uses a bare
        // ScrollView, not a List, and was explicitly out of bounds for this
        // task (intake spec) -- it must keep its own pre-existing `.mask`
        // rather than being switched to scrollTopEdgeFeather(), which is a
        // List-shaped modifier (masks the List's own frame) never intended
        // for a bare ScrollView call site.
        let source = try notesListViewSource()
        let body = scoped(source, from: "struct NoteDetailView: View {", to: [])
        XCTAssertFalse(
            body.contains(".scrollTopEdgeFeather()"),
            "NoteDetailView was out of bounds for task 20260831-notes-messages-list-scroll-blur -- it must keep its own existing ScrollView .mask, not be switched to the new List-oriented scrollTopEdgeFeather() modifier"
        )
        XCTAssertTrue(
            body.contains(".mask("),
            "NoteDetailView's own pre-existing content-edge mask (task 20260830-note-detail-scroll-fade-toolbar-bg) must still be present, unmodified by this task"
        )
    }
}
