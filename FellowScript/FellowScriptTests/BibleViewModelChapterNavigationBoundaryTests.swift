// BibleViewModelChapterNavigationBoundaryTests.swift — testing-gate coverage
// for task 20260923-bible-tap-chapter-nav.
//
// The frontend gate replaced BibleReaderView's swipe DragGesture with
// left/right tap zones, but deliberately reused
// BibleViewModel.nextChapter()/prevChapter() unchanged — changeChapter(forward:)
// (BibleReaderView.swift:717) is a thin wrapper that just calls one of these
// two methods inside an .easeInOut cross-fade. That wrapper and the tap
// zones themselves are covered by source-pin regression tests in
// InteractionPolishSharedMechanismsTests.swift (ViewInspector can't reliably
// traverse this view's NavigationStack/ScrollViewReader/GeometryReader
// nesting, so this codebase's established convention for BibleReaderView is
// source-pin, not render-and-tap).
//
// What was still genuinely untested anywhere in the suite — confirmed via
// codegraph ("no covering tests found" for nextChapter/prevChapter/
// changeChapter) — is the chapter/book *boundary rollover logic itself*:
// the exact behavior the intake spec's acceptance criteria calls out
// ("boundary behavior ... matches existing nextChapter()/prevChapter()
// semantics"). These tests close that gap directly against BibleViewModel,
// which is where the logic actually lives and is fully reachable without
// rendering the view: `curBook`/`curChapter`/`chapterCounts` are all
// internal (non-private) @Published/var properties, so a test can pin a
// book's chapter count deterministically without depending on whether the
// real bundled bible.json is present in the test host (it deliberately is
// not, in this same file's sibling
// BibleViewModelLazyContentLoadRegressionTests.swift).
import XCTest
@testable import FellowScript

@MainActor
final class BibleViewModelChapterNavigationBoundaryTests: XCTestCase {

    // MARK: - nextChapter()

    func test_nextChapter_advancesWithinBook_whenChaptersRemain() {
        let vm = BibleViewModel()
        vm.curBook = "Genesis"
        vm.chapterCounts["Genesis"] = 50
        vm.curChapter = 3

        vm.nextChapter()

        XCTAssertEqual(vm.curBook, "Genesis", "advancing mid-book must not change the book")
        XCTAssertEqual(vm.curChapter, 4)
    }

    func test_nextChapter_atLastChapterOfBook_rollsOverToNextBooksFirstChapter() {
        let vm = BibleViewModel()
        vm.curBook = "Genesis"
        vm.chapterCounts["Genesis"] = 5
        vm.curChapter = 5

        vm.nextChapter()

        XCTAssertEqual(vm.curBook, "Exodus", "the book immediately after Genesis in BibleData.bookNames")
        XCTAssertEqual(vm.curChapter, 1, "rolling into a new book must land on its chapter 1")
    }

    func test_nextChapter_atLastChapterOfLastBook_doesNotAdvancePastRevelation() {
        let vm = BibleViewModel()
        vm.curBook = "Revelation"
        vm.chapterCounts["Revelation"] = 22
        vm.curChapter = 22

        vm.nextChapter()

        XCTAssertEqual(vm.curBook, "Revelation", "there is no book after the last book to roll into")
        XCTAssertEqual(vm.curChapter, 22, "must stay pinned at the final chapter, not overshoot")
    }

    // MARK: - prevChapter()

    func test_prevChapter_goesBackWithinBook_whenNotAtChapterOne() {
        let vm = BibleViewModel()
        vm.curBook = "Exodus"
        vm.curChapter = 4

        vm.prevChapter()

        XCTAssertEqual(vm.curBook, "Exodus", "going back mid-book must not change the book")
        XCTAssertEqual(vm.curChapter, 3)
    }

    func test_prevChapter_atChapterOne_rollsBackToPriorBooksLastChapter() {
        let vm = BibleViewModel()
        vm.chapterCounts["Genesis"] = 50
        vm.curBook = "Exodus"
        vm.curChapter = 1

        vm.prevChapter()

        XCTAssertEqual(vm.curBook, "Genesis", "the book immediately before Exodus in BibleData.bookNames")
        XCTAssertEqual(vm.curChapter, 50, "rolling back into the prior book must land on its last chapter, not chapter 1")
    }

    func test_prevChapter_atChapterOneOfFirstBook_doesNotGoBackPastGenesis() {
        let vm = BibleViewModel()
        vm.curBook = "Genesis"
        vm.curChapter = 1

        vm.prevChapter()

        XCTAssertEqual(vm.curBook, "Genesis", "there is no book before the first book to roll back into")
        XCTAssertEqual(vm.curChapter, 1, "must stay pinned at chapter 1, not undershoot")
    }
}
