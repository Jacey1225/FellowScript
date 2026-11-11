// ChatAnnouncementsTests.swift -- testing gate for task 20261030-chat-announcements.
// Covers: FSMessageAnnouncement tolerant decoding, the never-throwing RawMsg
// wrapper, history mapping (paged + legacy), old-cache FSMessage decode,
// card -> FSGroupAnnouncement adapter, announcement_updated frame parsing,
// delete/edit/restore line merge, timeline copy, and the post_to_chat draft key.

import XCTest
@testable import FellowScript

@MainActor
final class ChatAnnouncementsTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }
    private func card(_ json: String) throws -> FSMessageAnnouncement {
        try JSONDecoder().decode(FSMessageAnnouncement.self, from: data(json))
    }
    private func line(_ id: String, ts: String, card: FSMessageAnnouncement? = nil) -> FSMessage {
        var m = FSMessage(id: id, text: "posted an announcement", mine: false, sender: "ann", timestamp: ts)
        m.systemKind = "announcement"
        m.announcement = card
        return m
    }

    // MARK: card decoding

    func testDecodesFullHistoryCard() throws {
        let c = try card("""
        {"id":"a1","title":"Potluck","description":"Bring food","banner_url":"https://x/b.png",
         "creator_username":"ann","title_color":"#FFC61A","title_font":"serif","bg_theme":"dusk",
         "publish_at":"2026-10-30T10:00:00+00:00","created_at":"2026-10-30T09:00:00+00:00",
         "updated_at":"2026-10-30T11:00:00+00:00","edited":true,"can_edit":true,"extra":[1,2]}
        """)
        XCTAssertEqual(c.id, "a1"); XCTAssertEqual(c.title, "Potluck"); XCTAssertEqual(c.description, "Bring food")
        XCTAssertEqual(c.creator_username, "ann"); XCTAssertEqual(c.edited, true); XCTAssertEqual(c.bg_theme, "dusk")
    }

    func testDecodesMinimalLiveFrameCard() throws {
        let c = try card(#"{"id":"a1","title":"Potluck"}"#)
        XCTAssertEqual(c.description, "")
        XCTAssertNil(c.banner_url); XCTAssertNil(c.edited); XCTAssertNil(c.publish_at)
    }

    func testMissingIdOrTitleThrows() {
        XCTAssertThrowsError(try card(#"{"title":"x"}"#))
        XCTAssertThrowsError(try card(#"{"id":"a1"}"#))
        XCTAssertThrowsError(try card(#"{"id":5,"title":"x"}"#))
    }

    func testWrongTypedOptionalsAreToleratedNotFatal() throws {
        let c = try card(#"{"id":"a1","title":"T","description":5,"banner_url":7,"edited":"yes","title_color":{}}"#)
        XCTAssertEqual(c.description, "")
        XCTAssertNil(c.banner_url); XCTAssertNil(c.edited); XCTAssertNil(c.title_color)
    }

    func testParseLiveFrameObject() {
        XCTAssertEqual(FSMessageAnnouncement.parse(["id": "a1", "title": "T"])?.id, "a1")
        XCTAssertNil(FSMessageAnnouncement.parse(nil))
        XCTAssertNil(FSMessageAnnouncement.parse("nope"))
        XCTAssertNil(FSMessageAnnouncement.parse(["title": "T"]))
        XCTAssertNil(FSMessageAnnouncement.parse(["id": "a1", "title": Date()]), "non-JSON value must not crash")
    }

    // MARK: RawMsg / FSMessage

    func testRawMsgWithMalformedAnnouncementStillDecodesTheMessage() throws {
        let raw = try JSONDecoder().decode(RawMsg.self, from: data(
            #"{"id":"m1","text":"posted an announcement","timestamp":"2026-10-30T10:00:00Z","system_kind":"announcement","announcement":{"title":"no id"}}"#))
        XCTAssertEqual(raw.id, "m1")
        XCTAssertNil(raw.announcement?.value)
        let ok = try JSONDecoder().decode(RawMsg.self, from: data(
            #"{"id":"m2","timestamp":"2026-10-30T10:00:00Z","system_kind":"announcement","announcement":{"id":"a1","title":"T"}}"#))
        XCTAssertEqual(ok.announcement?.value?.id, "a1")
    }

    func testRawMsgAnnouncementWrongShapeDoesNotThrow() throws {
        for bad in ["\"str\"", "[1]", "5", "null"] {
            XCTAssertNoThrow(try JSONDecoder().decode(RawMsg.self, from: data(
                #"{"id":"m1","timestamp":"t","announcement":\#(bad)}"#)), bad)
        }
    }

    func testPagedMessageCarriesTheCardAndPlainMessagesDoNot() throws {
        let withCard = try JSONDecoder().decode(RawMsg.self, from: data(
            #"{"id":"m1","text":"posted an announcement","from_user":"ann","timestamp":"t","system_kind":"announcement","announcement":{"id":"a1","title":"T","edited":true}}"#))
        let m = NetworkService.pagedMessage(withCard)
        XCTAssertEqual(m.systemKind, "announcement")
        XCTAssertEqual(m.announcement?.id, "a1")
        XCTAssertEqual(m.announcement?.edited, true)
        let plain = try JSONDecoder().decode(RawMsg.self, from: data(#"{"id":"m2","text":"hi","timestamp":"t"}"#))
        XCTAssertNil(NetworkService.pagedMessage(plain).announcement)
    }

    func testOldCachedMessageWithoutAnnouncementKeyStillDecodes() throws {
        let old = try JSONEncoder().encode(FSMessage(id: "m", text: "hi", mine: true, sender: "", timestamp: "t"))
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        obj.removeValue(forKey: "announcement")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let m = try JSONDecoder().decode(FSMessage.self, from: stripped)
        XCTAssertNil(m.announcement)
    }

    func testMessageWithCardRoundTripsThroughCache() throws {
        var m = line("m1", ts: "t", card: FSMessageAnnouncement(id: "a1", title: "T", edited: true))
        m.systemKind = "announcement"
        let back = try JSONDecoder().decode(FSMessage.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.announcement, m.announcement)
    }

    // MARK: adapter

    func testCardItemUsesStructuralDefaultsOnlyAndNeverInventsContent() {
        let c = FSMessageAnnouncement(id: "a1", title: "T", description: "D", creator_username: "ann",
                                      title_color: "#FFC61A", bg_theme: "dusk", publish_at: "2026-10-30T10:00:00+00:00")
        let item = c.cardItem(groupId: "g1")
        XCTAssertEqual(item.id, "a1"); XCTAssertEqual(item.group_id, "g1")
        XCTAssertEqual(item.title, "T"); XCTAssertEqual(item.description, "D")
        XCTAssertTrue(item.published); XCTAssertFalse(item.can_edit, "row never grants edit rights")
        XCTAssertEqual(item.bg_theme, "dusk")
        XCTAssertNil(item.banner_url)
        XCTAssertEqual(item.publish_at, "2026-10-30T10:00:00+00:00")
    }

    func testCardItemFallsBackThroughTimestamps() {
        let c = FSMessageAnnouncement(id: "a", title: "T", created_at: "C")
        let item = c.cardItem(groupId: "g")
        XCTAssertEqual(item.publish_at, "C"); XCTAssertEqual(item.created_at, "C"); XCTAssertEqual(item.updated_at, "C")
    }

    // MARK: sync frame

    func testSyncFrameParsing() {
        for (raw, action) in [("updated", FSAnnouncementSync.Action.updated), ("deleted", .deleted), ("restored", .restored)] {
            let s = FSAnnouncementSync(frame: ["type": "announcement_updated", "announcement_id": "a1", "action": raw])
            XCTAssertEqual(s?.announcementId, "a1"); XCTAssertEqual(s?.action, action)
        }
        XCTAssertNil(FSAnnouncementSync(frame: ["announcement_id": "a1", "action": "purged"]))
        XCTAssertNil(FSAnnouncementSync(frame: ["announcement_id": "", "action": "updated"]))
        XCTAssertNil(FSAnnouncementSync(frame: ["action": "updated"]))
        XCTAssertNil(FSAnnouncementSync(frame: ["announcement_id": 3, "action": "updated"]))
    }

    // MARK: row view model (merge / removal)

    func testRemoveAnnouncementLinesOnlyRemovesMatching() {
        var list = [line("m1", ts: "2026-10-30T10:00:00Z", card: .init(id: "a1", title: "A")),
                    line("m2", ts: "2026-10-30T10:01:00Z", card: .init(id: "a2", title: "B")),
                    FSMessage(id: "m3", text: "hi", mine: false, sender: "x", timestamp: "2026-10-30T10:02:00Z")]
        list.removeAnnouncementLines(announcementId: "a1")
        XCTAssertEqual(list.map(\.id), ["m2", "m3"])
        list.removeAnnouncementLines(announcementId: "nope")
        XCTAssertEqual(list.count, 2)
    }

    func testMergeReplacesEditedCardInPlace() {
        let cur = [line("m1", ts: "2026-10-30T10:00:00Z", card: .init(id: "a1", title: "Old")),
                   FSMessage(id: "x", text: "hi", mine: false, sender: "y", timestamp: "2026-10-30T10:05:00Z")]
        let out = AnnouncementLineMerge.merge(cur, fetched: [line("m1", ts: "2026-10-30T10:00:00Z", card: .init(id: "a1", title: "New", edited: true))])
        XCTAssertEqual(out.map(\.id), ["m1", "x"])
        XCTAssertEqual(out[0].announcement?.title, "New")
        XCTAssertEqual(out[0].announcement?.edited, true)
    }

    func testMergeInsertsRestoredLineAtTimePosition() {
        let cur = [FSMessage(id: "a", text: "1", mine: false, sender: "y", timestamp: "2026-10-30T10:00:00Z"),
                   FSMessage(id: "c", text: "3", mine: false, sender: "y", timestamp: "2026-10-30T12:00:00Z")]
        let out = AnnouncementLineMerge.merge(cur, fetched: [line("m2", ts: "2026-10-30T11:00:00Z", card: .init(id: "a2", title: "Back"))])
        XCTAssertEqual(out.map(\.id), ["a", "m2", "c"])
    }

    func testMergeLeavesLinesOutsideFreshWindowAndIsIdempotent() {
        let old = line("old", ts: "2026-01-01T00:00:00Z", card: .init(id: "a0", title: "Old page"))
        XCTAssertEqual(AnnouncementLineMerge.merge([old], fetched: []).map(\.id), ["old"])
        let again = AnnouncementLineMerge.merge([old], fetched: [old])
        XCTAssertEqual(again.count, 1)
    }

    func testLinesInHistoryKeepsOnlyAnnouncementLinesWithCards() {
        let withCard = line("m1", ts: "t", card: .init(id: "a1", title: "T"))
        let noCard = line("m2", ts: "t", card: nil)
        let plain = FSMessage(id: "m3", text: "hi", mine: false, sender: "y", timestamp: "t")
        XCTAssertEqual(AnnouncementLineMerge.lines(in: .legacy([withCard, noCard, plain])).map(\.id), ["m1"])
        let page = FSMessagePage(messages: [plain, withCard], hasMore: false, cursor: nil)
        XCTAssertEqual(AnnouncementLineMerge.lines(in: .paged(page)).map(\.id), ["m1"])
    }

    // MARK: copy

    func testTimelineCopy() {
        XCTAssertEqual(AnnouncementTimelineCopy.label(poster: "ann", edited: false), "Announcement by ann")
        XCTAssertEqual(AnnouncementTimelineCopy.label(poster: "ann", edited: true), "Announcement by ann \u{00B7} edited")
        XCTAssertEqual(AnnouncementTimelineCopy.label(poster: "", edited: false), "Announcement by A member")
        XCTAssertEqual(AnnouncementTimelineCopy.errorMessage(for: AppError.networkError("Announcement not found")),
                       AnnouncementTimelineCopy.goneError)
        XCTAssertEqual(AnnouncementTimelineCopy.errorMessage(for: AppError.networkError("boom")),
                       AnnouncementTimelineCopy.openError)
        XCTAssertEqual(AnnouncementTimelineCopy.errorMessage(for: URLError(.notConnectedToInternet)),
                       AnnouncementTimelineCopy.openError)
    }

    // MARK: draft

    func testDraftSendsPostToChatOnlyWhenOptedIn() {
        var d = FSAnnouncementDraft(title: "T", description: "D")
        XCTAssertNil(d.jsonObject["post_to_chat"], "key must be absent unless opted in")
        d.postToChat = true
        XCTAssertEqual(d.jsonObject["post_to_chat"] as? Bool, true)
        XCTAssertEqual(d.jsonObject["title"] as? String, "T")
    }
}
