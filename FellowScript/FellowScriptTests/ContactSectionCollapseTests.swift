// ContactSectionCollapseTests.swift — task 20261021-ipad-note-bg-collapsible-contacts.
import XCTest
@testable import FellowScript

final class ContactSectionCollapseTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "ContactSectionCollapseTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func test_defaultsToExpanded() {
        XCTAssertTrue(ContactSectionCollapse.collapsedSections(userId: "u1", defaults: freshDefaults()).isEmpty)
    }

    func test_persistsPerSectionAndPerUser() {
        let d = freshDefaults()
        ContactSectionCollapse.setCollapsed(.groups, true, userId: "u1", defaults: d)
        XCTAssertEqual(ContactSectionCollapse.collapsedSections(userId: "u1", defaults: d), [.groups])
        XCTAssertTrue(ContactSectionCollapse.collapsedSections(userId: "u2", defaults: d).isEmpty)
        ContactSectionCollapse.setCollapsed(.groups, false, userId: "u1", defaults: d)
        XCTAssertTrue(ContactSectionCollapse.collapsedSections(userId: "u1", defaults: d).isEmpty)
    }
}
