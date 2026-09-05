// NotesViewModelFilteredNotesMemoizationRegressionTests.swift — testing-gate
// coverage for task 20260904-compliance-performance-fixes, step 2 (Medium
// optimization #5): NotesViewModel.filteredNotes used to be a plain computed
// property, re-filtering + re-sorting the full `notes` dict on every SwiftUI
// render of NotesListView. It's now a cached, published value recomputed
// only by recomputeFilteredNotes(), invoked from the didSet of its three
// real dependencies (notes/sortOrder/currentGroupId).
//
// These tests exercise the real NotesViewModel directly and prove two
// things a naive "just cache it and never invalidate" mistake would break:
//   1. filteredNotes reflects the correct filter/sort result at all.
//   2. filteredNotes actually recomputes (immediately, not on some later
//      render) the moment any of its three dependencies changes — the
//      memoization must never go stale.
import XCTest
@testable import FellowScript

@MainActor
final class NotesViewModelFilteredNotesMemoizationRegressionTests: XCTestCase {

    private func note(id: String, groupId: String = "", timestamp: String) -> FSNote {
        FSNote(id: id, group_id: groupId, timestamp: timestamp)
    }

    func test_filteredNotes_scopesToPersonalSegment_sortedNewestFirstByDefault() {
        let vm = NotesViewModel()
        vm.notes = [
            "n1": note(id: "n1", timestamp: "2026-01-01 00:00:00.000000"),
            "n2": note(id: "n2", timestamp: "2026-03-01 00:00:00.000000"),
            "n3": note(id: "n3", groupId: "g1", timestamp: "2026-02-01 00:00:00.000000"),
        ]
        XCTAssertEqual(vm.filteredNotes.map { $0.0 }, ["n2", "n1"],
                       "Personal segment only (group note n3 excluded), newest first by default sortOrder")
    }

    func test_filteredNotes_recomputesImmediately_whenSortOrderChanges() {
        let vm = NotesViewModel()
        vm.notes = [
            "n1": note(id: "n1", timestamp: "2026-01-01 00:00:00.000000"),
            "n2": note(id: "n2", timestamp: "2026-03-01 00:00:00.000000"),
        ]
        XCTAssertEqual(vm.filteredNotes.map { $0.0 }, ["n2", "n1"])

        vm.sortOrder = .oldest
        XCTAssertEqual(vm.filteredNotes.map { $0.0 }, ["n1", "n2"],
                       "changing sortOrder must recompute filteredNotes immediately via didSet, not require any other trigger")
    }

    func test_filteredNotes_recomputesImmediately_whenCurrentGroupIdChanges() {
        let vm = NotesViewModel()
        vm.notes = [
            "n1": note(id: "n1", timestamp: "2026-01-01 00:00:00.000000"),
            "n2": note(id: "n2", groupId: "g1", timestamp: "2026-02-01 00:00:00.000000"),
        ]
        XCTAssertEqual(vm.filteredNotes.map { $0.0 }, ["n1"])

        vm.currentGroupId = "g1"
        XCTAssertEqual(vm.filteredNotes.map { $0.0 }, ["n2"],
                       "switching segments must recompute filteredNotes to the newly-selected group immediately")
    }

    func test_filteredNotes_recomputesImmediately_whenNotesDictionaryChanges() {
        let vm = NotesViewModel()
        vm.notes = ["n1": note(id: "n1", timestamp: "2026-01-01 00:00:00.000000")]
        XCTAssertEqual(vm.filteredNotes.count, 1)

        vm.notes["n2"] = note(id: "n2", timestamp: "2026-04-01 00:00:00.000000")
        XCTAssertEqual(vm.filteredNotes.map { $0.0 }, ["n2", "n1"],
                       "a note merged into `notes` (e.g. loadMoreIfNeeded's .merge, or saveNote's optimistic write) must be reflected in filteredNotes immediately, not go stale until some unrelated recompute")
    }

    func test_filteredNotes_recomputesImmediately_whenCurrentGroupIdSetToSameValue_doesNotBreak() {
        // The didSet guards `currentGroupId != oldValue` before recomputing
        // (also gates the search re-run) -- confirm a genuine no-op set
        // still leaves filteredNotes correct (doesn't wipe or duplicate it).
        let vm = NotesViewModel()
        vm.notes = ["n1": note(id: "n1", timestamp: "2026-01-01 00:00:00.000000")]
        XCTAssertEqual(vm.filteredNotes.map { $0.0 }, ["n1"])

        vm.currentGroupId = nil // already nil -- same value
        XCTAssertEqual(vm.filteredNotes.map { $0.0 }, ["n1"])
    }
}
