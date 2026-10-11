// GroupActivityTests.swift -- task 20261011-home-group-activity-announcements.
// Ordering, cap, filtering, merge/cache-preserve and state logic for the Home
// "Group activity" row.

import XCTest
@testable import FellowScript

final class GroupActivityTests: XCTestCase {

    private func ann(_ id: String, group: String = "g1", publishAt: String, published: Bool = true,
                     title: String = "T") -> FSGroupAnnouncement {
        FSGroupAnnouncement(id: id, group_id: group, creator_id: nil, creator_username: nil,
                            title: title, description: "", banner_url: nil, publish_at: publishAt,
                            created_at: publishAt, updated_at: publishAt, published: published, can_edit: false)
    }

    private func item(_ id: String, group: String = "g1", at: String, published: Bool = true) -> GroupActivityItem {
        GroupActivityItem(groupId: group, groupName: "Group \(group)",
                          announcement: ann(id, group: group, publishAt: at, published: published))
    }

    func test_select_newestFirst() {
        let r = GroupActivity.select([
            item("a", at: "2026-10-01T10:00:00+00:00"),
            item("b", at: "2026-10-03T10:00:00+00:00"),
            item("c", at: "2026-10-02T10:00:00+00:00"),
        ], allowedGroupIds: ["g1"])
        XCTAssertEqual(r.map { $0.announcement.id }, ["b", "c", "a"])
    }

    func test_select_capsAtMaxItems() {
        let many = (0..<25).map { item("n\($0)", at: String(format: "2026-10-01T10:%02d:00+00:00", $0)) }
        XCTAssertEqual(GroupActivity.select(many, allowedGroupIds: ["g1"]).count, GroupActivity.maxItems)
    }

    func test_select_dropsUnpublishedAndDisallowedGroups() {
        let r = GroupActivity.select([
            item("a", at: "2026-10-01T10:00:00+00:00", published: false),
            item("b", group: "left", at: "2026-10-02T10:00:00+00:00"),
            item("c", at: "2026-10-03T10:00:00+00:00"),
        ], allowedGroupIds: ["g1"])
        XCTAssertEqual(r.map { $0.announcement.id }, ["c"])
    }

    func test_merge_failedGroupKeepsCache_successReplaces() {
        let cached = [item("old1", group: "g1", at: "2026-10-01T10:00:00+00:00"),
                      item("old2", group: "g2", at: "2026-10-02T10:00:00+00:00")]
        // g1 refreshed successfully (now empty); g2 failed (absent from fresh).
        let r = GroupActivity.merge(cached: cached, fresh: ["g1": []], allowedGroupIds: ["g1", "g2"])
        XCTAssertEqual(r.map { $0.announcement.id }, ["old2"])
    }

    func test_merge_dropsCachedForLeftGroup() {
        let cached = [item("x", group: "gone", at: "2026-10-02T10:00:00+00:00")]
        XCTAssertTrue(GroupActivity.merge(cached: cached, fresh: [:], allowedGroupIds: ["g1"]).isEmpty)
    }

    func test_itemsFromPage_limitsPerGroup() {
        let page = FSAnnouncementsPage(announcements: (0..<6).map {
            ann("p\($0)", publishAt: String(format: "2026-10-01T10:%02d:00+00:00", $0))
        }, truncated: nil, gate: nil)
        let r = GroupActivity.items(from: page, group: FSContact(id: "g1", name: "G", type: .group))
        XCTAssertEqual(r.count, GroupActivity.perGroupLimit)
        XCTAssertEqual(r.first?.announcement.id, "p5")
    }

    func test_state_matrix() {
        let one = [item("a", at: "2026-10-01T10:00:00+00:00")]
        XCTAssertEqual(GroupActivity.state(items: one, hasSucceeded: false, isLoading: true), .content)
        XCTAssertEqual(GroupActivity.state(items: [], hasSucceeded: true, isLoading: false), .empty)
        XCTAssertEqual(GroupActivity.state(items: [], hasSucceeded: false, isLoading: true), .loading)
        XCTAssertEqual(GroupActivity.state(items: [], hasSucceeded: false, isLoading: false), .hidden)
    }

    func test_dateLabelAndAccessibilityLabel() {
        let i = item("a", at: "2026-10-03T10:00:00+00:00")
        XCTAssertFalse(GroupActivity.dateLabel(i.announcement).isEmpty)
        let label = GroupActivity.accessibilityLabel(i)
        XCTAssertTrue(label.hasPrefix("Group g1, T, "))
    }

    func test_cacheKey_isPerUser() {
        XCTAssertNotEqual(GroupActivity.cacheKey(userId: "u1"), GroupActivity.cacheKey(userId: "u2"))
    }

    // Source-scan wiring checks (task 20261011-home-group-activity-announcements).
    private func readSource(_ rel: String) throws -> String {
        let f = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(rel)
        return try String(contentsOf: f, encoding: .utf8)
    }

    func test_source_homeShowsOnlyAnnouncementRow_noHeaderNoNewNoteButton() throws {
        let home = try readSource("FellowScript/Dashboard/DashboardView.swift")
        XCTAssertTrue(home.contains("GroupActivitySection("))
        XCTAssertTrue(home.contains("appState.openAnnouncement(groupId:"))
        XCTAssertFalse(home.contains("home-new-note-button"))
        XCTAssertFalse(home.contains("showNewNote"))
        XCTAssertFalse(home.contains("NoteResumeCard"))
        XCTAssertFalse(home.contains("showResumeNote"))
        let section = try readSource("FellowScript/Dashboard/GroupActivitySection.swift")
        XCTAssertFalse(section.contains("group-activity-heading"))
        XCTAssertFalse(section.contains("Text(\"Group activity\")"))
    }

    func test_source_waysToExploreHasNoDismissControl() throws {
        let src = try readSource("FellowScript/Dashboard/WaysToExploreSection.swift")
        XCTAssertFalse(src.contains("Button(\"Maybe later\""))
        XCTAssertFalse(src.contains("func dismissSection"))
        XCTAssertFalse(src.contains("func isDismissed"))
    }
}
