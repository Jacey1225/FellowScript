// ChipToggleTests.swift — coverage for task
// 20260809-chat-schedule-migrate-fellowscript, step 5 (testing).
//
// Interactive/stateful logic tests for the real, migrated ChipToggle
// (Chat/ChipToggle.swift), backing the spec's "toggle chips respond to tap"
// acceptance criterion for SessionCreatorSheet's "Repeat weekly" /
// "Summarize with agent" Session Options row. Ported from the standalone
// ChatSchedule prototype's own ChipToggleTests (task
// 20260809-chat-schedule-ios-swiftui) using the same ViewInspector
// tap-simulation technique against the real, restyled component.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class ChipToggleTests: XCTestCase {

    private func makeBoundChip(title: String, initial: Bool) -> (ChipToggle, () -> Bool) {
        var current = initial
        let binding = Binding<Bool>(
            get: { current },
            set: { current = $0 }
        )
        let sut = ChipToggle(title: title, isOn: binding)
        return (sut, { current })
    }

    func testTappingAnOffChipTurnsItOn() throws {
        let (sut, isOn) = makeBoundChip(title: "Repeat weekly", initial: false)
        try sut.inspect().find(ViewType.HStack.self).callOnTapGesture()
        XCTAssertTrue(isOn())
    }

    func testTappingAnOnChipTurnsItOff() throws {
        let (sut, isOn) = makeBoundChip(title: "Summarize with agent", initial: true)
        try sut.inspect().find(ViewType.HStack.self).callOnTapGesture()
        XCTAssertFalse(isOn())
    }

    func testTappingTwiceReturnsToTheOriginalState() throws {
        let (sut, isOn) = makeBoundChip(title: "Repeat weekly", initial: false)
        try sut.inspect().find(ViewType.HStack.self).callOnTapGesture()
        try sut.inspect().find(ViewType.HStack.self).callOnTapGesture()
        XCTAssertFalse(isOn())
    }

    func testTwoChipsToggleIndependently() throws {
        // Mirrors SessionCreatorSheet's sessionOptionsSection: two separate
        // ChipToggle instances bound to two separate @State booleans
        // (recurring, summarize). Tapping one must not affect the other.
        let (repeatChip, isRepeatOn) = makeBoundChip(title: "Repeat weekly", initial: false)
        let (summarizeChip, isSummarizeOn) = makeBoundChip(title: "Summarize with agent", initial: true)

        try repeatChip.inspect().find(ViewType.HStack.self).callOnTapGesture()

        XCTAssertTrue(isRepeatOn(), "the tapped chip should have flipped")
        XCTAssertTrue(isSummarizeOn(), "the untapped chip must retain its own state")
        try summarizeChip.inspect().find(ViewType.HStack.self).callOnTapGesture()
        XCTAssertFalse(isSummarizeOn())
    }
}
