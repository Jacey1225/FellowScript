// ChatRepliesAndAnnouncementLocationTests.swift -- testing gate (iOS half) for task
// 20261010-announcement-location-chat-replies.
//
// Part B (chat replies): FSReplyRef wire decoding (incl. reply_to_deleted and
// "no text/author when deleted"), RawMsg/FSMessage decode with and without reply
// keys (back-compat), label/snippet helpers, action policy gating, and the
// ChatThreadViewModel frame handling (live reply frame, ack reconcile,
// reply_invalid strips the quote and bumps the signal).
// Part A (announcement location): decode, draft normalization/cap/clear, payload
// rules gated on the capability, blocking validation, badge count, Maps URL.

import XCTest
@testable import FellowScript

// MARK: - Part B: pure reply model

final class FSReplyRefTests: XCTestCase {

    func test_wireInit_nilWithoutId() {
        XCTAssertNil(FSReplyRef(wireId: nil, text: "x", author: "a", authorId: nil, deleted: nil))
        XCTAssertNil(FSReplyRef(wireId: "", text: "x", author: "a", authorId: nil, deleted: nil))
    }

    func test_wireInit_normalReply_keepsTextAndAuthor() {
        let r = FSReplyRef(wireId: "m1", text: "hello", author: "alice", authorId: "u1", deleted: false)
        XCTAssertEqual(r?.id, "m1")
        XCTAssertEqual(r?.text, "hello")
        XCTAssertEqual(r?.author, "alice")
        XCTAssertEqual(r?.deleted, false)
    }

    func test_wireInit_deleted_dropsTextAuthorAndAuthorId_evenIfServerSentThem() {
        let r = FSReplyRef(wireId: "m1", text: "leak", author: "alice", authorId: "u1", deleted: true)
        XCTAssertEqual(r?.deleted, true)
        XCTAssertNil(r?.text)
        XCTAssertNil(r?.author)
        XCTAssertNil(r?.authorId)
        XCTAssertEqual(r?.snippet(), "Original message unavailable")
    }

    func test_frameInit_readsAllKeys_andIsNilWithoutReplyToId() {
        let r = FSReplyRef(frame: ["reply_to_id": "m9", "reply_to_text": "t", "reply_to_author": "bob", "reply_to_author_id": "u2"])
        XCTAssertEqual(r?.id, "m9"); XCTAssertEqual(r?.author, "bob"); XCTAssertEqual(r?.authorId, "u2")
        XCTAssertNil(FSReplyRef(frame: ["text": "plain"]))
        let d = FSReplyRef(frame: ["reply_to_id": "m9", "reply_to_deleted": true, "reply_to_text": "x"])
        XCTAssertEqual(d?.deleted, true); XCTAssertNil(d?.text)
    }

    func test_authorLabel_youWhenViewerIsAuthor_caseInsensitive_elseNameElseSomeone() {
        let own = FSReplyRef(id: "m", text: "t", author: "me", authorId: "ABC")
        XCTAssertEqual(own.authorLabel(viewerId: "abc"), "You")
        XCTAssertEqual(own.authorLabel(viewerId: "other"), "me")
        XCTAssertEqual(own.authorLabel(viewerId: nil), "me")
        XCTAssertEqual(FSReplyRef(id: "m", text: "t", author: nil).authorLabel(viewerId: "x"), "Someone")
        XCTAssertEqual(FSReplyRef(id: "m", text: "t", author: "").authorLabel(viewerId: "x"), "Someone")
    }

    func test_snippet_trimsAndFallsBack() {
        XCTAssertEqual(FSReplyRef(id: "m", text: "  hi \n", author: "a").snippet(), "hi")
        XCTAssertEqual(FSReplyRef(id: "m", text: "   ", author: "a").snippet(), "Message")
        XCTAssertEqual(FSReplyRef(id: "m", text: nil, author: "a").snippet(), "Message")
    }

    func test_replyPreviewText_capsAt200_andNamesAttachments() {
        let long = FSMessage(id: "1", text: String(repeating: "a", count: 500), mine: true, sender: "", timestamp: "t")
        XCTAssertEqual(long.replyPreviewText.count, 200)
        func att(_ k: String) -> FSMessage { FSMessage(id: "1", text: " ", mine: false, sender: "x", timestamp: "t", attachmentKind: k) }
        XCTAssertEqual(att("image").replyPreviewText, "Photo")
        XCTAssertEqual(att("video").replyPreviewText, "Video")
        XCTAssertEqual(att("gif").replyPreviewText, "GIF")
        XCTAssertEqual(att("file").replyPreviewText, "File")
        XCTAssertEqual(FSMessage(id: "1", text: "", mine: false, sender: "x", timestamp: "t").replyPreviewText, "Message")
    }

    func test_replyAuthorName() {
        XCTAssertEqual(FSMessage(id: "1", text: "a", mine: true, sender: "", timestamp: "t").replyAuthorName, "You")
        XCTAssertEqual(FSMessage(id: "1", text: "a", mine: false, sender: "alice", timestamp: "t").replyAuthorName, "alice")
        XCTAssertEqual(FSMessage(id: "1", text: "a", mine: false, sender: "", timestamp: "t").replyAuthorName, "Them")
    }

    // MARK: RawMsg decode

    private func raw(_ extra: String) throws -> RawMsg {
        let json = "{\"id\":\"m2\",\"text\":\"body\",\"timestamp\":\"2026-10-10T10:00:00Z\",\"from_user\":\"bob\"\(extra)}"
        return try JSONDecoder().decode(RawMsg.self, from: Data(json.utf8))
    }

    func test_rawMsg_oldPayloadWithoutReplyKeys_decodesWithNilReply() throws {
        XCTAssertNil(try raw("").reply)
    }

    func test_rawMsg_replyKeys_decode() throws {
        let m = try raw(",\"reply_to_id\":\"m1\",\"reply_to_text\":\"orig\",\"reply_to_author\":\"alice\",\"reply_to_author_id\":\"u1\"")
        XCTAssertEqual(m.reply, FSReplyRef(id: "m1", text: "orig", author: "alice", authorId: "u1"))
    }

    func test_rawMsg_replyToDeleted_decodesAsUnavailable_withNoTextOrAuthor() throws {
        let m = try raw(",\"reply_to_id\":\"m1\",\"reply_to_deleted\":true")
        XCTAssertEqual(m.reply?.deleted, true)
        XCTAssertNil(m.reply?.text); XCTAssertNil(m.reply?.author)
    }

    func test_rawMsg_nullReplyKeys_meanNoReply() throws {
        XCTAssertNil(try raw(",\"reply_to_id\":null,\"reply_to_text\":null,\"reply_to_deleted\":null").reply)
    }

    func test_fsMessage_cachedJsonWithoutReply_stillDecodes_andReplyRoundTrips() throws {
        let old = "{\"id\":\"a\",\"text\":\"t\",\"mine\":true,\"sender\":\"\",\"timestamp\":\"x\"}"
        XCTAssertNil(try JSONDecoder().decode(FSMessage.self, from: Data(old.utf8)).reply)
        var m = FSMessage(id: "a", text: "t", mine: true, sender: "", timestamp: "x")
        m.reply = FSReplyRef(id: "o", text: "orig", author: "al")
        let back = try JSONDecoder().decode(FSMessage.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.reply, m.reply)
    }
}

// MARK: - Part B: action policy

final class ChatReplyActionPolicyTests: XCTestCase {
    private func msg(mine: Bool = false) -> FSMessage {
        FSMessage(id: "m", text: "hello", mine: mine, sender: mine ? "" : "alice", timestamp: "t")
    }
    private func ctx(group: Bool = true, thread: Bool = false, replies: Bool = true, jump: Bool = false, settled: Bool = true) -> FSMessageActionContext {
        FSMessageActionContext(isGroup: group, inThread: thread, threadsEnabled: false, messageDeleteEnabled: false,
                               isSettled: settled, senderUserId: "u-alice", repliesEnabled: replies, canJumpToOriginal: jump)
    }

    func test_flagOff_noReplyOrJumpActions() {
        let a = FSMessageActionPolicy.actions(for: msg(), in: ctx(replies: false))
        XCTAssertFalse(a.contains(.reply))
    }
    func test_flagOn_replyListedFirst_forGroupAndDm() {
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(), in: ctx()).first, .reply)
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: true), in: ctx(group: false)).first, .reply)
    }
    func test_unsettledMessage_cannotBeRepliedTo() {
        XCTAssertFalse(FSMessageActionPolicy.actions(for: msg(), in: ctx(settled: false)).contains(.reply))
    }
    func test_inThread_neverReplyOrJump() {
        let a = FSMessageActionPolicy.actions(for: msg(), in: ctx(thread: true, jump: true))
        XCTAssertFalse(a.contains(.reply)); XCTAssertFalse(a.contains(.goToOriginal))
    }
    func test_goToOriginal_onlyWhenLoaded() {
        XCTAssertTrue(FSMessageActionPolicy.actions(for: msg(), in: ctx(jump: true)).contains(.goToOriginal))
        XCTAssertFalse(FSMessageActionPolicy.actions(for: msg(), in: ctx(jump: false)).contains(.goToOriginal))
    }
    func test_existingActions_unchangedWhenFlagOff() {
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: true), in: ctx(replies: false)), [.copy])
    }
    func test_titles() {
        XCTAssertEqual(FSMessageActionKind.reply.title, "Reply")
        XCTAssertFalse(FSMessageActionKind.goToOriginal.title.isEmpty)
    }
}

// MARK: - Part B: view model frames

@MainActor
final class ChatRepliesViewModelTests: XCTestCase {

    override func setUp() { ReactionSeam.reset(); ThreadsSeam.reset() }

    private let group = FSContact(id: "group-1", name: "G", type: .group, toUsers: ["me", "x"])
    private func uid() -> String { "ws-\(UUID().uuidString)" }
    private let caps = FSCapabilities(features: ["chat_pagination": true, "chat_pagination_dm": true], exploreLink: nil, termsCurrent: true)

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return }; try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("timed out waiting: \(what)")
    }

    private func withServer(msgs: [FSMessage],
                            _ body: (ChatGroupSelfEchoDedupRegressionTests.WSTestServer, ChatThreadViewModel, String) async throws -> Void) async throws {
        let server = try ChatGroupSelfEchoDedupRegressionTests.WSTestServer()
        let port = try await server.start()
        defer { server.stop() }
        let s = ThrowingTestDataService()
        s.wsBaseOverride = "ws://127.0.0.1:\(port)"
        s.historyResult = .paged(FSMessagePage(messages: msgs, hasMore: false, cursor: nil))
        let user = uid()
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: group, userId: user, capabilities: caps)
        try await server.waitForConnection()
        try await body(server, vm, user)
        vm.disconnect()
    }

    private func orig() -> FSMessage { FSMessage(id: "m1", text: "original", mine: false, sender: "alice", timestamp: "2026-10-10T10:00:00Z") }

    func test_liveFrame_withReplyKeys_carriesQuote() async throws {
        try await withServer(msgs: [orig()]) { server, vm, _ in
            try server.sendFrame(["id": "m2", "text": "re", "from_user": "bob", "timestamp": "2026-10-10T10:01:00Z",
                                  "reply_to_id": "m1", "reply_to_text": "original", "reply_to_author": "alice", "reply_to_author_id": "u1"])
            await self.eventually("reply bubble") { vm.messages.first(where: { $0.id == "m2" })?.reply?.id == "m1" }
            XCTAssertEqual(vm.messages.first(where: { $0.id == "m2" })?.reply?.text, "original")
        }
    }

    func test_liveFrame_replyToDeleted_hasNoTextOrAuthor() async throws {
        try await withServer(msgs: []) { server, vm, _ in
            try server.sendFrame(["id": "m2", "text": "re", "from_user": "bob", "timestamp": "2026-10-10T10:01:00Z",
                                  "reply_to_id": "gone", "reply_to_deleted": true])
            await self.eventually("bubble") { vm.messages.contains { $0.id == "m2" } }
            let r = vm.messages.first(where: { $0.id == "m2" })?.reply
            XCTAssertEqual(r?.deleted, true); XCTAssertNil(r?.text); XCTAssertNil(r?.author)
        }
    }

    func test_liveFrame_withoutReplyKeys_hasNilReply_backCompat() async throws {
        try await withServer(msgs: []) { server, vm, _ in
            try server.sendFrame(["id": "m2", "text": "plain", "from_user": "bob", "timestamp": "2026-10-10T10:01:00Z"])
            await self.eventually("bubble") { vm.messages.contains { $0.id == "m2" } }
            XCTAssertNil(vm.messages.first(where: { $0.id == "m2" })?.reply)
        }
    }

    func test_send_withReply_showsOptimisticQuote_andAckKeepsItAndUsesServerQuote() async throws {
        try await withServer(msgs: [orig()]) { server, vm, user in
            let ref = FSReplyRef(id: "m1", text: "original", author: "alice")
            vm.sendMessage(text: "answer", attachment: nil, contact: self.group, userId: user, reply: ref)
            guard let local = vm.messages.last, local.text == "answer" else { return XCTFail("no optimistic bubble") }
            XCTAssertEqual(local.reply, ref)
            try server.sendFrame(["type": "ack", "client_ref": local.id, "id": "srv-1", "timestamp": "2026-10-10T10:02:00Z",
                                  "reply_to_id": "m1", "reply_to_text": "edited original", "reply_to_author": "alice"])
            await self.eventually("ack") { vm.messages.contains { $0.id == "srv-1" } }
            XCTAssertEqual(vm.messages.first(where: { $0.id == "srv-1" })?.reply?.text, "edited original")
        }
    }

    func test_send_withoutReply_hasNilReply() async throws {
        try await withServer(msgs: []) { _, vm, user in
            vm.sendMessage(text: "plain", attachment: nil, contact: self.group, userId: user)
            XCTAssertNil(vm.messages.last?.reply)
        }
    }

    func test_replyInvalidErrorFrame_stripsQuote_bumpsSignal_andMarksFailed() async throws {
        try await withServer(msgs: [orig()]) { server, vm, user in
            vm.sendMessage(text: "answer", attachment: nil, contact: self.group, userId: user,
                           reply: FSReplyRef(id: "m1", text: "original", author: "alice"))
            guard let local = vm.messages.last else { return XCTFail("no bubble") }
            let before = vm.replyInvalidSignal
            try server.sendFrame(["type": "error", "reason": "reply_invalid", "detail": "x"])
            await self.eventually("signal") { vm.replyInvalidSignal == before + 1 }
            XCTAssertNil(vm.messages.first(where: { $0.id == local.id })?.reply)
            XCTAssertTrue(vm.failedMessageIds.contains(local.id))
        }
    }

    func test_otherErrorReason_doesNotTouchReplySignal() async throws {
        try await withServer(msgs: []) { server, vm, user in
            vm.sendMessage(text: "x", attachment: nil, contact: self.group, userId: user)
            let before = vm.replyInvalidSignal
            try server.sendFrame(["type": "error", "reason": "rate_limited"])
            await self.eventually("failed") { !vm.failedMessageIds.isEmpty }
            XCTAssertEqual(vm.replyInvalidSignal, before)
        }
    }
}

// MARK: - Part A: announcement location

final class AnnouncementLocationTests: XCTestCase {

    private func decode(_ extra: String) throws -> FSGroupAnnouncement {
        let json = """
        {"id":"a","group_id":"g","creator_id":"u","creator_username":"ann","title":"T","description":"D",
         "banner_url":null,"publish_at":"2026-01-01T00:00:00+00:00","created_at":"2026-01-01T00:00:00+00:00",
         "updated_at":"2026-01-01T00:00:00+00:00","published":true,"can_edit":true\(extra)}
        """
        return try JSONDecoder().decode(FSGroupAnnouncement.self, from: Data(json.utf8))
    }
    private func apply(_ d: AnnouncementExtrasDraft, original: FSGroupAnnouncement? = nil, location: Bool = true) -> FSAnnouncementDraft {
        var out = FSAnnouncementDraft(title: "t", description: "d")
        d.apply(to: &out, original: original, links: false, gallery: false, payments: false, rsvp: false, location: location)
        return out
    }
    private func body(_ d: FSAnnouncementDraft) -> [String: Any] { d.jsonObject }

    func test_decode_absentLocation_isNil_oldPayload() throws {
        XCTAssertNil(try decode("").location)
    }
    func test_decode_location_present() throws {
        XCTAssertEqual(try decode(",\"location\":\"Room 4\"").location, "Room 4")
    }
    func test_decode_nullLocation_isNil() throws {
        XCTAssertNil(try decode(",\"location\":null").location)
    }

    func test_draftInit_seedsFromAnnouncement() throws {
        XCTAssertEqual(AnnouncementExtrasDraft(from: try decode(",\"location\":\"Hall\"")).location, "Hall")
        XCTAssertEqual(AnnouncementExtrasDraft(from: nil).location, "")
    }

    func test_cleanedLocation_trims_andCapsAt120() {
        var d = AnnouncementExtrasDraft(from: nil)
        d.location = "  Main Hall \n"
        XCTAssertEqual(d.cleanedLocation, "Main Hall")
        d.location = String(repeating: "x", count: 300)
        XCTAssertEqual(d.cleanedLocation.count, AnnouncementExtrasLimits.maxLocationLength)
        XCTAssertEqual(AnnouncementExtrasLimits.maxLocationLength, 120)
    }

    func test_apply_setsLocation_whenChanged_andFlagOn() {
        var d = AnnouncementExtrasDraft(from: nil)
        d.location = " Church "
        let b = body(apply(d))
        XCTAssertEqual(b["location"] as? String, "Church")
    }
    func test_apply_flagOff_neverSendsLocationKey() {
        var d = AnnouncementExtrasDraft(from: nil)
        d.location = "Church"
        XCTAssertNil(body(apply(d, location: false))["location"])
    }
    func test_apply_unchanged_sendsNothing() throws {
        let a = try decode(",\"location\":\"Hall\"")
        var d = AnnouncementExtrasDraft(from: a)
        d.location = "  Hall  "
        XCTAssertNil(body(apply(d, original: a))["location"])
    }
    func test_apply_cleared_sendsNull() throws {
        let a = try decode(",\"location\":\"Hall\"")
        var d = AnnouncementExtrasDraft(from: a)
        d.location = "   "
        let b = body(apply(d, original: a))
        XCTAssertTrue(b["location"] is NSNull)
    }
    func test_apply_emptyOnCreate_sendsNothing() {
        XCTAssertNil(body(apply(AnnouncementExtrasDraft(from: nil)))["location"])
    }

    func test_blockingError_controlCharacters_onlyWhenFlagOn() {
        var d = AnnouncementExtrasDraft(from: nil)
        d.location = "bad\u{07}place"
        XCTAssertNotNil(d.blockingError(links: false, payments: false, location: true))
        XCTAssertNil(d.blockingError(links: false, payments: false, location: false))
        d.location = "fine place"
        XCTAssertNil(d.blockingError(links: false, payments: false, location: true))
    }

    func test_count_includesLocation_onlyWhenFlagOn_andNonEmpty() {
        var d = AnnouncementExtrasDraft(from: nil)
        XCTAssertEqual(d.count(links: false, gallery: false, payments: false, rsvp: false, location: true), 0)
        d.location = "Hall"
        XCTAssertEqual(d.count(links: false, gallery: false, payments: false, rsvp: false, location: true), 1)
        XCTAssertEqual(d.count(links: false, gallery: false, payments: false, rsvp: false, location: false), 0)
        XCTAssertEqual(d.count(links: false, gallery: false, payments: false, rsvp: false), 0)   // default param
    }

    func test_flagName() { XCTAssertEqual(AnnouncementExtrasFlag.location, "announcement_location") }

    func test_mapsURL_isSearchQuery_encoded_andNilWhenEmpty() {
        XCTAssertNil(AnnouncementLocationMaps.url(for: "   "))
        let u = AnnouncementLocationMaps.url(for: "  Café & Bar #1 ")
        XCTAssertEqual(u?.host, "maps.apple.com")
        XCTAssertEqual(u?.scheme, "https")
        let items = URLComponents(url: u!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "q" })?.value, "Café & Bar #1")
        XCTAssertFalse(u!.absoluteString.contains(" "))
    }
}
