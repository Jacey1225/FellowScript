// BibleViewModelLazyContentLoadRegressionTests.swift — testing-gate coverage
// for task 20260904-compliance-performance-fixes, step 1 (Critical C2):
// bible.json (4.2MB) must no longer be decoded eagerly at cold launch (or
// merely moved off the main actor while still running at launch) — it must
// be decoded lazily, the first time the Bible tab is actually opened.
//
// BibleViewModel now splits this into two independently-guarded entry
// points:
//   - load(service:userId:)   — StartupCoordinator's cold-launch call.
//                                Lightweight (highlights/bookmarks only).
//                                Must NEVER touch bible.json.
//   - loadBibleContent()      — called only from BibleReaderView's own
//                                `.task`, i.e. only once the Bible tab has
//                                actually appeared. This is the one and only
//                                trigger for the 4.2MB decode.
//
// These tests exercise the real BibleViewModel directly (no ViewInspector
// needed — the split is a ViewModel-level property, not view-render timing)
// and assert on the two observable signals of "was bible.json content
// loaded": `books` (populated only by loadBibleContent()/loadMockContent())
// and `isLoading` (cleared only by those same two paths).
import XCTest
@testable import FellowScript

@MainActor
final class BibleViewModelLazyContentLoadRegressionTests: XCTestCase {

    private func freshUserId() -> String { "bible-lazy-\(UUID().uuidString)" }

    func test_load_neverTouchesBibleContent_booksStaysEmpty_isLoadingStaysTrue() async {
        let vm = BibleViewModel()
        await vm.load(service: MockDataService.shared, userId: freshUserId())

        XCTAssertTrue(vm.books.isEmpty,
                       "load() is StartupCoordinator's cold-launch call — it must never populate books, which would mean bible.json was decoded eagerly at launch")
        XCTAssertTrue(vm.isLoading,
                       "load() must never flip isLoading false — only loadBibleContent()/loadMockContent() may do that, and neither runs from load()")
    }

    func test_load_calledTwice_stillNeverTouchesBibleContent() async {
        // hasLoadedOnce guards load() itself against a duplicate call (it's
        // shared between StartupCoordinator's race and BibleReaderView's own
        // `.task`) — neither call should ever reach bible.json either way.
        let vm = BibleViewModel()
        let uid = freshUserId()
        await vm.load(service: MockDataService.shared, userId: uid)
        await vm.load(service: MockDataService.shared, userId: uid)

        XCTAssertTrue(vm.books.isEmpty)
        XCTAssertTrue(vm.isLoading)
    }

    func test_loadBibleContent_populatesBooksAndClearsIsLoading() async {
        let vm = BibleViewModel()
        await vm.loadBibleContent()

        XCTAssertFalse(vm.books.isEmpty,
                        "loadBibleContent() must populate books once the Bible tab actually opens (either the real bundled bible.json, or the mock fallback if the resource can't be found in this test host)")
        XCTAssertFalse(vm.isLoading, "loadBibleContent() must clear isLoading once content is ready")
    }

    func test_loadBibleContent_isIdempotent_secondCallDoesNotReDecode() async {
        let vm = BibleViewModel()
        await vm.loadBibleContent()
        let firstBooks = vm.books
        XCTAssertFalse(firstBooks.isEmpty)

        await vm.loadBibleContent()
        XCTAssertEqual(vm.books, firstBooks,
                        "a second loadBibleContent() call must no-op via the hasLoadedBibleContent guard, not re-decode/re-derive books")
    }

    func test_load_thenLoadBibleContent_bothRun_independentGuards() async {
        // Regression guard for the exact bug this task fixed: load() and
        // loadBibleContent() must be independently guarded (hasLoadedOnce vs
        // hasLoadedBibleContent) so calling load() first (as
        // StartupCoordinator always does) never blocks loadBibleContent()
        // from later running once the Bible tab actually opens.
        let vm = BibleViewModel()
        await vm.load(service: MockDataService.shared, userId: freshUserId())
        XCTAssertTrue(vm.books.isEmpty, "sanity check: load() alone must not have populated books")

        await vm.loadBibleContent()
        XCTAssertFalse(vm.books.isEmpty,
                        "loadBibleContent() must still run and populate books even after load() already ran once")
    }
}
