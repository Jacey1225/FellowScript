// GroupInfoRowTests.swift -- task 20261023-group-info-row (iOS). Pure gating, copy,
// layout and mapping tests plus source pins for the chat wiring. Written by the
// frontend gate; run by the iOS testing step (serially).

import XCTest
@testable import FellowScript

final class GroupInfoRowTests: XCTestCase {

    // MARK: gating

    func test_visible_ordersFourChips() {
        XCTAssertEqual(GroupInfoCategory.visible(announcements: true, threads: true, pins: true, media: true),
                       [.announcements, .threads, .pinned, .media])
    }

    func test_visible_hidesEachChipWhenItsFeatureIsOff() {
        XCTAssertEqual(GroupInfoCategory.visible(announcements: true, threads: false, pins: true, media: false), [.announcements, .pinned])
        XCTAssertEqual(GroupInfoCategory.visible(announcements: false, threads: true, pins: false, media: true), [.threads, .media])
    }

    func test_row_notRenderedWhenNoneShow_inDMs_orInsideAThread() {
        XCTAssertFalse(GroupInfoCategory.rowShows(isGroup: true, isThreadOpen: false, categories: []))
        XCTAssertFalse(GroupInfoCategory.rowShows(isGroup: false, isThreadOpen: false, categories: [.threads]))
        XCTAssertFalse(GroupInfoCategory.rowShows(isGroup: true, isThreadOpen: true, categories: [.threads]))
        XCTAssertTrue(GroupInfoCategory.rowShows(isGroup: true, isThreadOpen: false, categories: [.threads]))
    }

    func test_groupMediaCapability_failsClosed() {
        XCTAssertFalse(FSCapabilities.allOff.groupMediaEnabled)
        XCTAssertTrue(FSCapabilities(features: ["group_media": true], exploreLink: nil, termsCurrent: true).groupMediaEnabled)
        XCTAssertFalse(FSCapabilities(features: ["group_media": false], exploreLink: nil, termsCurrent: true).groupMediaEnabled)
    }

    // MARK: selection + labels

    func test_toggle_closesActiveChip_andSwapsOthers() {
        XCTAssertNil(GroupInfoCategory.toggled(.threads, tapped: .threads))
        XCTAssertEqual(GroupInfoCategory.toggled(.threads, tapped: .media), .media)
        XCTAssertEqual(GroupInfoCategory.toggled(nil, tapped: .pinned), .pinned)
    }

    func test_chipLabel_onlyPinnedCarriesCount_hiddenAtZero() {
        XCTAssertEqual(GroupInfoCategory.pinned.chipLabel(pinCount: 3), "Pinned  3")
        XCTAssertEqual(GroupInfoCategory.pinned.chipLabel(pinCount: 0), "Pinned")
        XCTAssertEqual(GroupInfoCategory.pinned.chipLabel(pinCount: 120), "Pinned  99+")
        XCTAssertEqual(GroupInfoCategory.threads.chipLabel(pinCount: 3), "Threads")
        XCTAssertEqual(GroupInfoCategory.media.chipLabel(pinCount: 3), "Media")
    }

    // MARK: copy

    func test_copy_errorAndEmptyLines() {
        XCTAssertEqual(GroupInfoCopy.loadError(.announcements), "We couldn't load announcements just now.")
        XCTAssertEqual(GroupInfoCopy.loadError(.pinned), "We couldn't load pins just now.")
        XCTAssertEqual(GroupInfoCopy.empty(.media).title, "No photos or videos yet.")
        XCTAssertEqual(GroupInfoCopy.empty(.pinned).title, FSPinnedListCopy.empty)
        XCTAssertEqual(GroupInfoCopy.refreshNote, "Couldn't refresh. Showing what we had.")
    }

    // MARK: panel metrics + motion

    func test_panelHeight_is45Percent_clampedTo240And420() {
        XCTAssertEqual(GroupInfoPanelMetrics.height(forAvailable: 600), 270, accuracy: 0.01)
        XCTAssertEqual(GroupInfoPanelMetrics.height(forAvailable: 300), 240)   // short screen: min wins
        XCTAssertEqual(GroupInfoPanelMetrics.height(forAvailable: 2000), 420)
    }

    func test_swipeDown_dismissesAt80ptOrFlick() {
        XCTAssertTrue(GroupInfoPanelMotion.shouldDismiss(translation: 80, predicted: 0))
        XCTAssertTrue(GroupInfoPanelMotion.shouldDismiss(translation: 30, predicted: 250))
        XCTAssertFalse(GroupInfoPanelMotion.shouldDismiss(translation: 40, predicted: 100))
    }

    // MARK: threads + announcements mapping

    func test_threadDetail_repliesAndRelativeTime() {
        XCTAssertEqual(GroupInfoThreadsCopy.detail(FSThreadSummary(id: "t", replyCount: 0)), "No replies yet")
        XCTAssertEqual(GroupInfoThreadsCopy.detail(FSThreadSummary(id: "t", replyCount: 1)), "1 reply")
        XCTAssertEqual(GroupInfoThreadsCopy.detail(FSThreadSummary(id: "t", replyCount: 4)), "4 replies")
    }

    func test_announcements_publishedOnly_newestFirst() throws {
        func make(_ id: String, _ at: String, published: Bool) throws -> FSGroupAnnouncement {
            let json = """
            {"id":"\(id)","group_id":"g","title":"T\(id)","description":"","publish_at":"\(at)",
             "created_at":"\(at)","updated_at":"\(at)","published":\(published),"can_edit":false}
            """
            return try JSONDecoder().decode(FSGroupAnnouncement.self, from: Data(json.utf8))
        }
        let items = [try make("a", "2026-10-01T10:00:00+00:00", published: true),
                     try make("b", "2026-10-19T10:00:00+00:00", published: true),
                     try make("c", "2026-10-20T10:00:00+00:00", published: false)]
        XCTAssertEqual(GroupInfoAnnouncementsPolicy.ordered(items).map(\.id), ["b", "a"])
    }

    // MARK: media

    func test_mediaColumns_byPanelWidth() {
        XCTAssertEqual(FSGroupMediaLayout.columns(forWidth: 320), 3)
        XCTAssertEqual(FSGroupMediaLayout.columns(forWidth: 599), 3)
        XCTAssertEqual(FSGroupMediaLayout.columns(forWidth: 600), 4)
        XCTAssertEqual(FSGroupMediaLayout.columns(forWidth: 899), 4)
        XCTAssertEqual(FSGroupMediaLayout.columns(forWidth: 900), 5)
    }

    func test_mediaDuration_andLabels() {
        XCTAssertEqual(FSGroupMediaLayout.durationText(65), "1:05")
        XCTAssertNil(FSGroupMediaLayout.durationText(nil))
        XCTAssertNil(FSGroupMediaLayout.durationText(0))
        let item = FSGroupMediaItem(messageId: "m", kind: .video, senderName: "Sam", createdAt: "2026-10-19T19:55:00.000000Z")
        XCTAssertTrue(FSGroupMediaLayout.accessibilityLabel(item).hasPrefix("Video from Sam"))
        XCTAssertEqual(FSGroupMediaLayout.accessibilityLabel(FSGroupMediaItem(messageId: "m", kind: .gif)), "GIF from someone")
    }

    func test_mediaItem_decodesContract_andToleratesUnknownKind() throws {
        let json = """
        {"message_id":"m1","kind":"video","thumb_url":null,"url":"https://x/v.mp4","width":1920,"height":1080,
         "duration":12.5,"sender_id":"u1","sender_name":"Sam","created_at":"2026-10-19T19:55:00.000000Z"}
        """
        let item = try JSONDecoder().decode(FSGroupMediaItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.kind, .video)
        XCTAssertNil(item.thumbURL)
        XCTAssertEqual(item.duration, 12.5)
        let odd = try JSONDecoder().decode(FSGroupMediaItem.self, from: Data(#"{"message_id":"m2","kind":"hologram"}"#.utf8))
        XCTAssertEqual(odd.kind, .image)
        XCTAssertEqual(odd.senderName, "")
    }

    // MARK: source pins

    private func src(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FellowScript/\(rel)"), encoding: .utf8)
    }

    func test_chatThreadView_hasRowInGroupsOnly_noBanner_noGroupPinButton() throws {
        let s = try src("Chat/ChatThreadView.swift")
        XCTAssertTrue(s.contains("GroupInfoCategory.rowShows(isGroup: contact.type == .group, isThreadOpen: vm.isThreadOpen"))
        XCTAssertTrue(s.contains("GroupInfoChipRow("))
        XCTAssertFalse(s.contains("GroupAnnouncementWidgetView("), "announcement banner removed from chats")
        XCTAssertTrue(s.contains("if pinsAvailable && contact.type != .group {"), "pin button stays in DMs only")
        XCTAssertTrue(s.contains(".overlay { groupInfoPanelHost }"), "submenu is laid out inside the message area (pane width)")
    }

    func test_mediaChipGatedByCapability_andRowOrder() throws {
        let s = try src("Chat/ChatThreadView.swift")
        XCTAssertTrue(s.contains("media: appState.capabilities.groupMediaEnabled"))
        let order = try src("Chat/GroupInfoCategory.swift")
        let a = try XCTUnwrap(order.range(of: "out.append(.announcements)")?.lowerBound)
        let t = try XCTUnwrap(order.range(of: "out.append(.threads)")?.lowerBound)
        let p = try XCTUnwrap(order.range(of: "out.append(.pinned)")?.lowerBound)
        let m = try XCTUnwrap(order.range(of: "out.append(.media)")?.lowerBound)
        XCTAssertTrue(a < t && t < p && p < m)
    }

    func test_chatThreadView_wasNotGrownByTheFeature() throws {
        let lines = try src("Chat/ChatThreadView.swift").split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertLessThan(lines, 4100, "new views live in their own small files")
    }

    func test_mediaRequestUsesContractPathAndKinds() throws {
        let s = try src("Services/NetworkService+GroupMedia.swift")
        XCTAssertTrue(s.contains("/media?"))
        XCTAssertTrue(s.contains("kind=image,video,gif"))
        XCTAssertTrue(s.contains("cursor_seq"))
    }
}
