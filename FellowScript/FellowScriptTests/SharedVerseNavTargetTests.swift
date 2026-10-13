// SharedVerseNavTargetTests.swift — task 20261013-ios-gradient-bg-and-shared-verse-nav.
// Source-pinned wiring checks (the views' consume logic is private) plus
// the AppState hand-off the fix relies on.
import XCTest
@testable import FellowScript

@MainActor
final class SharedVerseNavTargetTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_appState_pendingBibleNav_roundTrips() {
        let appState = AppState(service: MockDataService.shared)
        XCTAssertNil(appState.pendingBibleNav)
        appState.pendingBibleNav = BibleNavTarget(book: "John", chapter: 3, verse: 16)
        XCTAssertEqual(appState.pendingBibleNav, BibleNavTarget(book: "John", chapter: 3, verse: 16))
    }

    func test_source_openVerse_setsPendingBibleNav() throws {
        let s = try readSource("FellowScript/Chat/SharedObjectViews.swift")
        XCTAssertTrue(s.contains("appState.pendingBibleNav = BibleNavTarget(book: book, chapter: ch, verse: v)"))
    }

    func test_source_bibleReader_consumesOnChangeAndOnFirstMount() throws {
        let s = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(s.contains("private func consumePendingBibleNav()"))
        XCTAssertTrue(s.contains("pendingScrollVerse = t.verse"))
        XCTAssertTrue(s.contains("appState.pendingBibleNav = nil"))
        // Both the onChange path (mounted tab) and the .task path (lazy-mounted tab).
        XCTAssertTrue(s.contains(".onChange(of: appState.pendingBibleNav) { _, target in\n            guard target != nil else { return }\n            consumePendingBibleNav()"))
        XCTAssertTrue(s.contains("await vm.loadBibleContent()"))
        let taskRange = try XCTUnwrap(s.range(of: "await vm.loadBibleContent()"))
        XCTAssertTrue(s[taskRange.upperBound...].prefix(700).contains("consumePendingBibleNav()"),
                      "regression: unmounted Bible tab never saw a pre-set pendingBibleNav")
    }

    func test_source_chatRoot_dismissesThreadSheetOnBibleNav() throws {
        let s = try readSource("FellowScript/Chat/ChatRootView.swift")
        XCTAssertTrue(s.contains("if target != nil { activeContact = nil }"),
                      "regression: thread sheet stayed over Chat tab, hiding the Bible tab switch")
    }

    func test_source_contentView_switchesToBibleTab() throws {
        let s = try readSource("FellowScript/ContentView.swift")
        let r = try XCTUnwrap(s.range(of: ".onChange(of: appState.pendingBibleNav)"))
        XCTAssertTrue(s[r.upperBound...].prefix(400).contains(".bible"))
    }

    func test_source_warmBloomBackground_onBothScreens() throws {
        let n = try readSource("FellowScript/Account/NotificationSettingsView.swift")
        XCTAssertTrue(n.contains(".warmBloomBackground()"))
        XCTAssertFalse(n.contains(".background(Theme.bgPage)"))
        let c = try readSource("FellowScript/Chat/SharedObjectViews.swift")
        XCTAssertTrue(c.contains(".warmBloomBackground()"))
    }
}
