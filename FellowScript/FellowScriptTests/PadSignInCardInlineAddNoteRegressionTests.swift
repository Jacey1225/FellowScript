// PadSignInCardInlineAddNoteRegressionTests.swift — testing gate for task
// 20261015-ipad-signin-card-inline-add-note.
//
// Pins: (1) AppState.pendingNoteDraft lifecycle (in-memory, cleared on signOut),
// (2) compact-vs-regular width gating for the sign-in card, (3) the iPad-only
// routing of Bible "Add to Note" (embedded -> pendingNoteDraft, phone -> sheet),
// (4) NotesListView consumes+clears the draft only when embedded and not on the
// highlights tab, (5) the Google G asset exists and is referenced.

import XCTest
@testable import FellowScript

private func padSource(_ rel: String, from file: StaticString = #filePath) throws -> String {
    let root = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("FellowScript")
    return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

@MainActor
final class PendingNoteDraftLifecycleTests: XCTestCase {
    private func makeState() -> AppState { AppState(service: ThrowingTestDataService()) }

    func test_pendingNoteDraft_startsNil() {
        XCTAssertNil(makeState().pendingNoteDraft)
    }

    func test_signOut_clearsPendingNoteDraft() {
        let s = makeState()
        s.pendingNoteDraft = VerseNoteDraft(book: "John", chapter: 3, verse: 16, text: "For God so loved")
        XCTAssertNotNil(s.pendingNoteDraft)
        s.signOut()
        XCTAssertNil(s.pendingNoteDraft, "verse draft must not outlive the session")
    }

    func test_draftCarriesVerseAndHasDistinctIds() {
        let a = VerseNoteDraft(book: "John", chapter: 3, verse: 16, text: "x")
        let b = VerseNoteDraft(book: "John", chapter: 3, verse: 16, text: "x")
        XCTAssertNotEqual(a.id, b.id, "re-adding the same verse must still trigger onChange(of: id)")
    }

    func test_pendingNoteDraft_isNotPersisted() throws {
        let src = try padSource("Services/AppState.swift")
        let lines = src.split(separator: "\n").filter { $0.contains("pendingNoteDraft") }
        for l in lines {
            XCTAssertFalse(l.contains("UserDefaults") || l.contains("Keychain"), "draft must stay in memory: \(l)")
        }
    }
}

final class PadGatingSourcePinTests: XCTestCase {
    func test_authView_gatesCardOnRegularHorizontalSizeClass() throws {
        let src = try padSource("Auth/AuthView.swift")
        XCTAssertTrue(src.contains("if horizontalSizeClass == .regular { padCard } else { phoneBody }"))
        XCTAssertFalse(src.contains("userInterfaceIdiom"), "gating must be size-class based so Slide Over falls back to phone")
    }

    func test_authCardView_isPresentationOnly_noNetworkOrLogging() throws {
        let src = try padSource("Auth/AuthCardView.swift")
        for banned in ["NetworkService", "URLSession", "print(", "NSLog", "UserDefaults", "Keychain"] {
            XCTAssertFalse(src.contains(banned), "AuthCardView must not contain \(banned)")
        }
        XCTAssertTrue(src.contains("Image(\"GoogleG\")"))
    }

    func test_googleGAsset_exists() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Assets.xcassets/GoogleG.imageset")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Contents.json").path))
        XCTAssertNotNil(UIImage(named: "GoogleG", in: Bundle(for: AppState.self), compatibleWith: nil))
    }

    func test_bibleReader_routesAddToNoteByEmbedded() throws {
        let src = try padSource("Bible/BibleReaderView.swift")
        XCTAssertTrue(src.contains("if embedded { appState.pendingNoteDraft = draft } else { addToNoteTarget = draft }"))
    }

    func test_notesList_consumesDraftOnlyWhenEmbeddedAndNotHighlights_andClears() throws {
        let src = try padSource("Notes/NotesListView.swift")
        XCTAssertTrue(src.contains("guard embedded, fixedTab != .highlights, let draft = appState.pendingNoteDraft"))
        XCTAssertTrue(src.contains("appState.pendingNoteDraft = nil"))
        XCTAssertTrue(src.contains("inlineDraft = nil"), "inline editor close must drop the draft")
        XCTAssertTrue(src.contains(".onAppear { consumePendingNoteDraft() }"))
    }

    func test_workspace_focusesNotesPanelOnDraft() throws {
        let src = try padSource("Workspace/WorkspaceView.swift")
        XCTAssertTrue(src.contains("onChange(of: appState.pendingNoteDraft?.id)"))
        XCTAssertTrue(src.contains("state.select(.notes)"))
    }
}
