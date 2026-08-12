// SegmentedDurationControlTests.swift — coverage for task
// 20260809-chat-schedule-migrate-fellowscript, step 5 (testing).
//
// Interactive/stateful logic tests for the real, migrated
// SegmentedDurationControl (Chat/SegmentedDurationControl.swift), the
// component behind the spec's "segmented duration control responds to tap
// and updates selection" acceptance criterion, ported here from the
// standalone ChatSchedule prototype's own SegmentedDurationControlTests
// (task 20260809-chat-schedule-ios-swiftui) using the same ViewInspector
// technique — added here as a test-only SPM package dependency on the
// FellowScriptTests target (FellowScript.xcodeproj), not linked into the
// shipping FellowScript app target.
//
// These simulate the actual tap via ViewInspector's `callOnTapGesture()` —
// invoking the exact `.onTapGesture { ... }` closure wired up in the real,
// restyled SegmentedDurationControl.swift — rather than re-implementing the
// component's logic separately, so a regression in the real tap handler
// would be caught here.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class SegmentedDurationControlTests: XCTestCase {

    private func makeBoundControl(initial: SessionDuration) -> (SegmentedDurationControl, () -> SessionDuration) {
        var current = initial
        let binding = Binding<SessionDuration>(
            get: { current },
            set: { current = $0 }
        )
        let sut = SegmentedDurationControl(selection: binding)
        return (sut, { current })
    }

    func testTappingASegmentUpdatesBoundSelection() throws {
        let (sut, currentValue) = makeBoundControl(initial: .thirty)
        try sut.inspect().find(text: "60m").callOnTapGesture()
        XCTAssertEqual(currentValue(), .sixty)
    }

    func testTappingEverySegmentInTurnEndsOnTheLastTapped() throws {
        let (sut, currentValue) = makeBoundControl(initial: .fifteen)
        try sut.inspect().find(text: "45m").callOnTapGesture()
        XCTAssertEqual(currentValue(), .fortyFive)
        try sut.inspect().find(text: "15m").callOnTapGesture()
        XCTAssertEqual(currentValue(), .fifteen)
    }

    func testTappingTheAlreadyActiveSegmentIsANoOp() throws {
        let (sut, currentValue) = makeBoundControl(initial: .thirty)
        try sut.inspect().find(text: "30m").callOnTapGesture()
        XCTAssertEqual(currentValue(), .thirty)
    }

    func testOnlyTheTappedSegmentsLabelExistsForEachDuration() throws {
        // Guards against the label/case mapping silently drifting (e.g. if
        // SessionDuration.label's string interpolation were ever changed).
        let (sut, _) = makeBoundControl(initial: .thirty)
        for duration in SessionDuration.allCases {
            XCTAssertNoThrow(
                try sut.inspect().find(text: duration.label),
                "expected a rendered segment labeled \(duration.label)"
            )
        }
    }
}
