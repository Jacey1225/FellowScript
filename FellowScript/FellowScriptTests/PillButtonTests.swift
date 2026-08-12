// PillButtonTests.swift — coverage for task
// 20260809-chat-schedule-migrate-fellowscript, step 5 (testing).
//
// PillButton/RoundIconButton (Chat/PillButton.swift) back the real,
// restyled ChatThreadView header's back button and "Schedule" pill, and
// SessionCreatorSheet's header "Schedule" pill, which all wire straight from
// a tap to a bare action closure with no intermediate logic (e.g. the
// "Schedule" pill's action calls scheduleSession(), which builds/saves the
// real FSSession — see SessionDurationTests for that formula's own
// coverage). This confirms the tap -> action wiring itself is intact after
// the restyle, using ViewInspector's real Button tap simulation.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class PillButtonTests: XCTestCase {

    func testTappingThePillButtonInvokesItsAction() throws {
        var tapped = false
        let sut = PillButton(title: "Schedule") { tapped = true }
        try sut.inspect().find(button: "Schedule").tap()
        XCTAssertTrue(tapped)
    }

    func testTappingThePillButtonWithAnIconStillInvokesItsAction() throws {
        var tapped = false
        let sut = PillButton(title: "Schedule", systemIcon: "calendar") { tapped = true }
        try sut.inspect().find(ViewType.Button.self).tap()
        XCTAssertTrue(tapped)
    }

    func testTappingARoundIconButtonInvokesItsAction() throws {
        var tapped = false
        let sut = RoundIconButton(systemIcon: "chevron.left") { tapped = true }
        try sut.inspect().find(ViewType.Button.self).tap()
        XCTAssertTrue(tapped)
    }

    func testEachPillButtonTapIsIndependent() throws {
        var firstTapped = false
        var secondTapped = false
        let cancel = PillButton(title: "Cancel") { firstTapped = true }
        let schedule = PillButton(title: "Schedule") { secondTapped = true }

        try cancel.inspect().find(button: "Cancel").tap()

        XCTAssertTrue(firstTapped)
        XCTAssertFalse(secondTapped, "tapping one pill button must not invoke a sibling's action")
    }
}
