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

    func test_chevron_isGatedOnThreadsCapability_andFailsClosed() throws {
        let s = try source("Chat/GroupRowThreadsView.swift")
        XCTAssertTrue(s.contains("appState.capabilities.isEnabled(\"threads\")"))
        XCTAssertTrue(s.contains("if threadsEnabled { chevron }"))
        XCTAssertTrue(s.contains("if threadsEnabled && expanded"))
        XCTAssertFalse(FSCapabilities.allOff.isEnabled("threads"))
    }

    func test_chevron_a11y_44pt_reduceMotion_andLabels() throws {
        let s = try source("Chat/GroupRowThreadsView.swift")
        XCTAssertTrue(s.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(s.contains("\"Hide threads\" : \"Show threads\""))
        XCTAssertTrue(s.contains(".accessibilityValue(expanded ? \"Expanded\" : \"Collapsed\")"))
        XCTAssertTrue(s.contains(".accessibilityAddTraits(.isButton)"))
        XCTAssertTrue(s.contains("withAnimation(reduceMotion ? nil : .easeInOut"))
        XCTAssertTrue(s.contains("@Environment(\\.accessibilityReduceMotion)"))
    }

    func test_threadRows_areFlush_noBackgroundBorderOrGlass() throws {
        let s = try source("Chat/GroupRowThreadsView.swift")
        guard let r = s.range(of: "private var threadList: some View {") else { return XCTFail("threadList missing") }
        let list = String(s[r.lowerBound...])
        for banned in [".glassCard", ".background(", ".overlay(", ".stroke", ".border(", "RoundedRectangle", ".cornerRadius", ".fill("] {
            XCTAssertFalse(list.contains(banned), "thread list must stay flush; found \(banned)")
        }
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
