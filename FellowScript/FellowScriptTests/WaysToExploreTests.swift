// WaysToExploreTests.swift -- task 20261010-home-ways-to-explore.
// Dismissal persistence/per-user scoping and card/section visibility logic.

import XCTest
@testable import FellowScript

final class WaysToExploreTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "WaysToExploreTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func test_key_isScopedByUserId() {
        XCTAssertEqual(WaysToExplore.dismissedKey(userId: "u1"), "home.waysToExplore.dismissed.u1")
        XCTAssertNotEqual(WaysToExplore.dismissedKey(userId: "u1"), WaysToExplore.dismissedKey(userId: "u2"))
    }

    func test_notDismissedByDefault() {
        XCTAssertFalse(WaysToExplore.isDismissed(userId: "u1", defaults: freshDefaults()))
    }

    func test_dismiss_persistsForThatUserOnly() {
        let d = freshDefaults()
        WaysToExplore.dismiss(userId: "u1", defaults: d)
        XCTAssertTrue(WaysToExplore.isDismissed(userId: "u1", defaults: d))
        XCTAssertFalse(WaysToExplore.isDismissed(userId: "u2", defaults: d))
    }

    func test_visibleCards_exploreHiddenWithoutURL() {
        XCTAssertEqual(WaysToExplore.visibleCards(exploreURL: nil), [.createGroup])
    }

    func test_visibleCards_bothWhenExploreAvailable() {
        let url = URL(string: "https://example.com/explore")
        XCTAssertEqual(WaysToExplore.visibleCards(exploreURL: url), [.createGroup, .exploreGroups])
    }

    func test_showsSection_hiddenWhenDismissedOrNoCards() {
        XCTAssertTrue(WaysToExplore.showsSection(dismissed: false, cards: [.createGroup]))
        XCTAssertFalse(WaysToExplore.showsSection(dismissed: true, cards: [.createGroup]))
        XCTAssertFalse(WaysToExplore.showsSection(dismissed: false, cards: []))
    }

    func test_exploreCardHiddenWhenCapabilityOff() {
        // .allOff capabilities fail closed: no browse URL, so no Explore card.
        let url = ExploreEntry.browseURL(from: .allOff, expectedHost: "example.com")
        XCTAssertNil(url)
        XCTAssertFalse(WaysToExplore.visibleCards(exploreURL: url).contains(.exploreGroups))
    }

    func test_source_dashboardMountsSection_andContentViewInjectsChatVM() throws {
        func read(_ rel: String) throws -> String {
            let f = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(rel)
            return try String(contentsOf: f, encoding: .utf8)
        }
        XCTAssertTrue(try read("FellowScript/Dashboard/DashboardView.swift").contains("WaysToExploreSection("))
        XCTAssertTrue(try read("FellowScript/ContentView.swift").contains(".environmentObject(startup.chatVM)"))
    }

    @MainActor
    func test_groupError_isPresentedByOriginatingSurfaceOnly() {
        let vm = ChatViewModel()
        vm.groupError = "boom"
        vm.groupErrorFromHome = true
        XCTAssertTrue(vm.showsGroupError(onHome: true))
        XCTAssertFalse(vm.showsGroupError(onHome: false))
        vm.groupErrorFromHome = false
        XCTAssertFalse(vm.showsGroupError(onHome: true))
        XCTAssertTrue(vm.showsGroupError(onHome: false))
        vm.groupError = nil
        XCTAssertFalse(vm.showsGroupError(onHome: true))
        XCTAssertFalse(vm.showsGroupError(onHome: false))
    }
}
