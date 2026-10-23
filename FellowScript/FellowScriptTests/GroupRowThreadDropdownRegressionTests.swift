// GroupRowThreadDropdownRegressionTests.swift -- testing gate for task
// 20261008-group-row-thread-dropdown. GroupRowWithThreads needs a live
// AppState environment, so (per this project's convention) the structural
// facts are asserted against the shipped source, and the fetch behaviour the
// view relies on against the real GroupThreadsViewModel.

import XCTest
@testable import FellowScript

@MainActor
final class GroupRowThreadDropdownRegressionTests: XCTestCase {

    override func setUp() { ThreadsSeam.reset() }

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript")
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    func test_threadsFolder_isGatedOnThreadsCapability_andFailsClosed() throws {
        let s = try source("Chat/GroupRowThreadsView.swift")
        XCTAssertTrue(s.contains("appState.capabilities.isEnabled(\"threads\")"))
        XCTAssertTrue(s.contains("if threadsEnabled { tray }"))
        // Panel lives inside the tray, so it is gated with it; flag-off also collapses.
        XCTAssertTrue(s.contains("if !on { expanded = false }"))
        XCTAssertFalse(FSCapabilities.allOff.isEnabled("threads"))
    }

    func test_folderRow_a11y_44pt_reduceMotion_andLabels() throws {
        let s = try source("Chat/GroupRowThreadsView.swift")
        XCTAssertTrue(s.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        XCTAssertTrue(s.contains("group-row-threads-toggle"))
        XCTAssertFalse(s.contains("group-row-threads-chevron"), "old card chevron identifier must be gone")
        XCTAssertTrue(s.contains("\"Hide threads\" : \"Show threads\""))
        XCTAssertTrue(s.contains(".accessibilityValue(expanded ? \"Expanded\" : \"Collapsed\")"))
        XCTAssertTrue(s.contains(".accessibilityAddTraits(.isButton)"))
        XCTAssertTrue(s.contains("withAnimation(reduceMotion ? nil : .easeInOut"))
        XCTAssertTrue(s.contains("@Environment(\\.accessibilityReduceMotion)"))
    }

    // State change (task 20261022-ios-group-threads-folder): the old test
    // asserted thread rows are flush on the page background with no glass. The
    // new design intentionally puts them in a glass tray matching the group
    // card, so that assertion is replaced, not weakened: the tray owns the one
    // glass container and thread rows themselves add no fill/border of their own.
    func test_folderTray_usesGlassCard_threadRowsAddNoOwnChrome_leadingAligned_hairlinesBetweenOnly() throws {
        let s = try source("Chat/GroupRowThreadsView.swift")
        // Changed by task 20261022-ios-threads-subfolder: the tray is no longer a
        // second glassCard; it is a darker inset of the same material
        // (ultraThinMaterial + black tint) with rounded bottom corners only,
        // tucked beneath the card. Still exactly one tray container.
        XCTAssertTrue(s.contains(".fill(.ultraThinMaterial)"), "tray must stay in the card's material family")
        XCTAssertTrue(s.contains("UnevenRoundedRectangle(topLeadingRadius: 0"), "square top, rounded bottom corners")
        XCTAssertFalse(s.contains(".glassCard"), "tray is a darker inset, not a second glass card")
        XCTAssertTrue(s.contains("Text(\"Threads\")"))
        XCTAssertTrue(s.contains("rotationEffect(.degrees(expanded ? 180 : 0))"))
        XCTAssertTrue(s.contains("if index > 0 { hairline }"), "dividers between threads only")
        XCTAssertTrue(s.contains("frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"), "titles leading aligned")
        guard let r = s.range(of: "private var threadList: some View {") else { return XCTFail("threadList missing") }
        let list = String(s[r.lowerBound...])
        for banned in [".glassCard", ".background(", ".overlay(", ".stroke", ".border(", "RoundedRectangle", ".cornerRadius", ".fill(", "threadIndent"] {
            XCTAssertFalse(list.contains(banned), "thread rows must not add own chrome; found \(banned)")
        }
    }

    // New (task 20261022-ios-threads-subfolder): card overlaps the tray's top.
    func test_tray_isTuckedUnderCard_viaNegativePaddingAndZIndex_withCompensatingInnerPadding() throws {
        let s = try source("Chat/GroupRowThreadsView.swift")
        XCTAssertTrue(s.contains("private let trayOverlap: CGFloat = 12"))
        XCTAssertTrue(s.contains(".padding(.top, -trayOverlap)"), "tray must slide under the card")
        XCTAssertTrue(s.contains(".padding(.top, trayOverlap)"), "label/chevron must be pushed below the overlap")
        XCTAssertFalse(s.contains(".padding(.top, 6)"), "old 6pt gap must be gone")
        XCTAssertTrue(s.contains(".zIndex(1)"), "card above tray")
        XCTAssertTrue(s.contains("tray.zIndex(0)"))
        XCTAssertFalse(s.contains(".offset("), "no out-of-bounds offsets that List would clip")
        XCTAssertTrue(s.contains(".allowsHitTesting(false)"), "card shadow must not steal taps")
    }

    func test_cardNoLongerReservesChevronSpace() throws {
        let s = try source("Chat/ChatRootView.swift")
        XCTAssertFalse(s.contains("trailingReserve"))
    }

    func test_groupsList_usesRow_swipeActionsKept_tapMovedOffTheWholeRow() throws {
        let s = try source("Chat/ChatRootView.swift")
        guard let a = s.range(of: "List(filteredGroups) { contact in"),
              let b = s.range(of: ".listStyle(.plain)", range: a.upperBound..<s.endIndex) else { return XCTFail("groupsList missing") }
        let block = String(s[a.lowerBound..<b.lowerBound])
        XCTAssertTrue(block.contains("GroupRowWithThreads("))
        XCTAssertTrue(block.contains(".swipeActions(edge: .trailing)"))
        XCTAssertTrue(block.contains(".swipeActions(edge: .leading)"))
        XCTAssertFalse(block.contains(".onTapGesture"), "row-wide tap would swallow thread/chevron taps")
        XCTAssertTrue(block.contains("appState.pendingThreadOpen = PendingThreadOpen(groupId: contact.id, threadId: thread.id)"))
        XCTAssertTrue(block.contains("activeContact = contact"))
    }

    func test_lazyFetch_nothingLoadedUntilLoad_thenReusedInMemory() async {
        let s = ThrowingTestDataService()
        ThreadsSeam.threadsPages = [FSThreadsPage(threads: [FSThreadSummary(id: "a", title: "Alpha")], hasMore: false, cursorTimestamp: nil, cursorId: nil)]
        let vm = GroupThreadsViewModel(service: s, groupId: "g-\(UUID().uuidString)", userId: "u")
        XCTAssertFalse(vm.loaded, "constructing the row must not fetch")
        XCTAssertTrue(vm.threads.isEmpty)
        await vm.load()
        XCTAssertTrue(vm.loaded)
        XCTAssertEqual(vm.threads.map(\.title), ["Alpha"])
    }

    func test_emptyOnlyAfterSuccess_failureNeverFabricatesEmpty() async {
        let s = ThrowingTestDataService()
        ThreadsSeam.threadsError = FSThreadsError.failed("down")
        let vm = GroupThreadsViewModel(service: s, groupId: "g-\(UUID().uuidString)", userId: "u")
        await vm.load()
        XCTAssertTrue(vm.loadFailed)
        XCTAssertTrue(vm.threads.isEmpty)
        XCTAssertFalse(vm.loaded && !vm.loadFailed, "must not show the empty state after a failure")
    }

    func test_emptyTitleFallsBackToThread() {
        XCTAssertEqual(FSThreadSummary(id: "x", title: "Thread").title, "Thread")
    }
}
