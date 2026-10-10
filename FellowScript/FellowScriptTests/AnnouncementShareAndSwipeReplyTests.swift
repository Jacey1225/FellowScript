// Task 20261010-announcement-share-swipe-left-reply: share text builder and the
// leftward swipe-to-reply direction/threshold rules.
import XCTest
@testable import FellowScript

final class AnnouncementShareTextTests: XCTestCase {
    private func make(title: String = "Youth night", publishAt: String = "2026-10-12T18:30:00+00:00",
                      published: Bool = true, location: String? = nil) -> FSGroupAnnouncement {
        FSGroupAnnouncement(id: "a", group_id: "g", creator_id: nil, creator_username: "sam", title: title,
                            description: "d", banner_url: nil, publish_at: publishAt,
                            created_at: publishAt, updated_at: publishAt, published: published,
                            can_edit: false, location: location)
    }
    private var expectedDate: String { FSAnnouncementDates.display("2026-10-12T18:30:00+00:00") }

    func test_titleAndDate_noLocation() {
        let t = GroupAnnouncementDetailView.shareText(for: make())
        XCTAssertEqual(t, "Youth night\n\(expectedDate)")
        XCTAssertFalse(expectedDate.isEmpty)
    }
    func test_locationIncludedWhenSet_trimmed() {
        let t = GroupAnnouncementDetailView.shareText(for: make(location: "  Fellowship Hall \n"))
        XCTAssertEqual(t, "Youth night\n\(expectedDate)\nFellowship Hall")
    }
    func test_locationOmittedWhenNilEmptyOrWhitespace() {
        for loc in [nil, "", "   \n"] as [String?] {
            let t = GroupAnnouncementDetailView.shareText(for: make(location: loc))
            XCTAssertEqual(t.components(separatedBy: "\n").count, 2, "loc=\(String(describing: loc))")
        }
    }
    func test_unpublishedPrefixesScheduledFor() {
        let t = GroupAnnouncementDetailView.shareText(for: make(published: false))
        XCTAssertEqual(t, "Youth night\nScheduled for \(expectedDate)")
    }
    func test_publishedHasNoScheduledPrefix_andNoLink() {
        let t = GroupAnnouncementDetailView.shareText(for: make(location: "Hall"))
        XCTAssertFalse(t.contains("Scheduled"))
        XCTAssertFalse(t.contains("http"))
    }
    func test_unparseableDateOmitsDateLine() {
        let t = GroupAnnouncementDetailView.shareText(for: make(publishAt: "garbage", location: "Hall"))
        XCTAssertEqual(t, "Youth night\nHall")
    }
}

final class SwipeToReplyLogicTests: XCTestCase {
    func test_leftwardHorizontalDragIsReply() {
        XCTAssertTrue(SwipeToReplyLogic.isReplyDrag(width: -40, height: 5))
    }
    func test_rightwardDragIsNotReply() {
        XCTAssertFalse(SwipeToReplyLogic.isReplyDrag(width: 80, height: 0))
        XCTAssertFalse(SwipeToReplyLogic.isReplyDrag(width: 0, height: 0))
    }
    func test_verticalDominantDragIsNotReply() {
        XCTAssertFalse(SwipeToReplyLogic.isReplyDrag(width: -30, height: 30))
        XCTAssertFalse(SwipeToReplyLogic.isReplyDrag(width: -30, height: 25))
        XCTAssertTrue(SwipeToReplyLogic.isReplyDrag(width: -31, height: 20))
    }
    func test_offsetIsNegativeAndClamped() {
        XCTAssertEqual(SwipeToReplyLogic.offset(forWidth: -10), -10)
        XCTAssertEqual(SwipeToReplyLogic.offset(forWidth: -500), -SwipeToReplyLogic.threshold * 1.3, accuracy: 0.001)
    }
    func test_armedOnlyPastThresholdLeftward() {
        XCTAssertFalse(SwipeToReplyLogic.isArmed(width: -55))
        XCTAssertTrue(SwipeToReplyLogic.isArmed(width: -56))
        XCTAssertFalse(SwipeToReplyLogic.isArmed(width: 200))
    }
    func test_fireRequiresArmedAndHorizontalDominance() {
        XCTAssertTrue(SwipeToReplyLogic.shouldFire(armed: true, width: -60, height: 10))
        XCTAssertFalse(SwipeToReplyLogic.shouldFire(armed: false, width: -60, height: 10))
        XCTAssertFalse(SwipeToReplyLogic.shouldFire(armed: true, width: -60, height: 60))
    }
}
