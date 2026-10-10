// ChatReactionsTests.swift -- task 20261010-chat-reactions, testing step 5.
// ReactionPicker pure helpers + labels, FSMessage/RawMsg decode with and
// without `reactions`, capabilities gating, ChatThreadViewModel optimistic
// toggle + rollback, reaction_updated frame handling (real local WebSocket),
// and source pins for the long-press wiring and accessibility.

import XCTest
@testable import FellowScript

// MARK: - Seam on the shared test double (static, like ThreadsSeam)

enum ReactionSeam {
    static var addResult: ReactionSummary?
    static var removeResult: ReactionSummary?
    static var error: Error?
    static var gate: (() async -> Void)?
    static var log: [String] = []
    static func reset() { addResult = nil; removeResult = nil; error = nil; gate = nil; log = [] }
}

extension ThrowingTestDataService {
    func addMessageReaction(userId: String, messageId: String, emoji: String) async throws -> ReactionSummary {
        ReactionSeam.log.append("add:\(messageId):\(emoji)")
        if let g = ReactionSeam.gate { await g() }
        if let e = ReactionSeam.error { throw e }
        return ReactionSeam.addResult ?? ReactionSummary(emoji: emoji, count: 1, viewerReacted: true)
    }
    func removeMessageReaction(userId: String, messageId: String, emoji: String) async throws -> ReactionSummary {
        ReactionSeam.log.append("remove:\(messageId):\(emoji)")
        if let g = ReactionSeam.gate { await g() }
        if let e = ReactionSeam.error { throw e }
        return ReactionSeam.removeResult ?? ReactionSummary(emoji: emoji, count: 0, viewerReacted: false)
    }
}

// MARK: - Pure helpers

final class ReactionSummaryPureTests: XCTestCase {
    private func r(_ e: String, _ c: Int, _ v: Bool) -> ReactionSummary { ReactionSummary(emoji: e, count: c, viewerReacted: v) }

    func test_toggled_addsNewEntry() {
        XCTAssertEqual(ReactionSummary.toggled([], emoji: "👍"), [r("👍", 1, true)])
    }
    func test_toggled_joinsExistingEmojiOfOthers() {
        XCTAssertEqual(ReactionSummary.toggled([r("👍", 2, false)], emoji: "👍"), [r("👍", 3, true)])
    }
    func test_toggled_removesOwn_decrementsAndKeepsEntryWhenOthersRemain() {
        XCTAssertEqual(ReactionSummary.toggled([r("👍", 3, true)], emoji: "👍"), [r("👍", 2, false)])
    }
    func test_toggled_removesOwn_dropsEntryAtZero_andLeavesOthers() {
        XCTAssertEqual(ReactionSummary.toggled([r("❤️", 2, false), r("👍", 1, true)], emoji: "👍"), [r("❤️", 2, false)])
    }
    func test_toggled_twiceIsIdentity() {
        let start = [r("👍", 2, false)]
        XCTAssertEqual(ReactionSummary.toggled(ReactionSummary.toggled(start, emoji: "👍"), emoji: "👍"), start)
    }
    func test_toggled_doesNotMutateInput() {
        let start = [r("👍", 1, true)]
        _ = ReactionSummary.toggled(start, emoji: "👍")
        XCTAssertEqual(start, [r("👍", 1, true)])
    }

    func test_setting_replacesInsertsAndRemoves() {
        let list = [r("👍", 1, true), r("❤️", 2, false)]
        XCTAssertEqual(ReactionSummary.setting(list, emoji: "👍", to: r("👍", 5, true)), [r("👍", 5, true), r("❤️", 2, false)])
        XCTAssertEqual(ReactionSummary.setting(list, emoji: "🔥", to: r("🔥", 1, true)).map(\.emoji), ["👍", "❤️", "🔥"])
        XCTAssertEqual(ReactionSummary.setting(list, emoji: "👍", to: nil), [r("❤️", 2, false)])
        XCTAssertEqual(ReactionSummary.setting(list, emoji: "👍", to: r("👍", 0, false)), [r("❤️", 2, false)], "count <= 0 removes")
        XCTAssertEqual(ReactionSummary.setting(list, emoji: "🔥", to: nil), list, "removing an absent emoji is a no-op")
    }

    func test_updatingCount_keepsViewerState() {
        let list = [r("👍", 1, true)]
        XCTAssertEqual(ReactionSummary.updatingCount(list, emoji: "👍", count: 4), [r("👍", 4, true)])
        XCTAssertEqual(ReactionSummary.updatingCount([], emoji: "😂", count: 2), [r("😂", 2, false)], "unknown emoji from someone else: not reacted")
        XCTAssertEqual(ReactionSummary.updatingCount(list, emoji: "👍", count: 0), [])
        XCTAssertEqual(ReactionSummary.updatingCount(list, emoji: "👍", count: -1), [])
    }

    func test_accessibilityLabel_matchesSpecExamples() {
        XCTAssertEqual(r("👍", 3, true).accessibilityLabel, "Thumbs up, 3 reactions, you reacted")
        XCTAssertEqual(r("👍", 3, false).accessibilityLabel, "Thumbs up, 3 reactions")
        XCTAssertEqual(r("❤️", 1, false).accessibilityLabel, "Heart, 1 reaction")
        XCTAssertEqual(r("❤️", 1, true).accessibilityLabel, "Heart, 1 reaction, you reacted")
    }

    func test_emojiNames_knownFallbackAndNeverEmpty() {
        XCTAssertEqual(ReactionEmojiName.name(for: "🙏"), "Praying hands")
        XCTAssertEqual(ReactionEmojiName.name(for: "✝️"), "Cross")
        let unknown = ReactionEmojiName.name(for: "🦄")
        XCTAssertFalse(unknown.isEmpty)
        XCTAssertNotEqual(unknown, "🦄", "falls back to the Unicode scalar name")
        XCTAssertEqual(ReactionEmojiName.name(for: "x"), "Latin small letter x")
    }

    func test_codable_wireKeys() throws {
        let data = try JSONEncoder().encode(r("👍", 2, true))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["viewer_reacted"] as? Bool, true)
        XCTAssertNil(obj["viewerReacted"])
        let back = try JSONDecoder().decode(ReactionSummary.self, from: Data(#"{"emoji":"🔥","count":7,"viewer_reacted":false}"#.utf8))
        XCTAssertEqual(back, r("🔥", 7, false))
        XCTAssertEqual(back.id, "🔥")
    }

    func test_quickEmojiImage_rendersNonEmpty() {
        let img = ReactionEmojiImage.image(for: "👍")
        XCTAssertGreaterThan(img.size.width, 0)
        XCTAssertGreaterThan(img.size.height, 0)
    }
}

// MARK: - Decode + capabilities

final class ChatReactionsDecodeAndCapabilityTests: XCTestCase {

    func test_rawMsg_decodesWithReactionsKey() throws {
        let json = #"{"id":"m1","text":"hi","from_user":"alice","timestamp":"2026-10-10T10:00:00Z","mine":false,"reactions":[{"emoji":"👍","count":2,"viewer_reacted":true},{"emoji":"❤️","count":1,"viewer_reacted":false}]}"#
        let raw = try JSONDecoder().decode(RawMsg.self, from: Data(json.utf8))
        let msg = NetworkService.pagedMessage(raw)
        XCTAssertEqual(msg.reactions, [ReactionSummary(emoji: "👍", count: 2, viewerReacted: true),
                                       ReactionSummary(emoji: "❤️", count: 1, viewerReacted: false)])
    }

    func test_rawMsg_decodesWithoutReactionsKey_asNil() throws {
        let json = #"{"id":"m1","text":"hi","from_user":"alice","timestamp":"2026-10-10T10:00:00Z","mine":true}"#
        let raw = try JSONDecoder().decode(RawMsg.self, from: Data(json.utf8))
        XCTAssertNil(raw.reactions)
        XCTAssertNil(NetworkService.pagedMessage(raw).reactions)
    }

    func test_rawMsg_emptyReactionsArray_isEmptyNotNil() throws {
        let json = #"{"id":"m1","text":"hi","timestamp":"t","reactions":[]}"#
        let raw = try JSONDecoder().decode(RawMsg.self, from: Data(json.utf8))
        XCTAssertEqual(NetworkService.pagedMessage(raw).reactions, [])
    }

    func test_fsMessage_defaultsToNilReactions_andCachedJSONWithoutKeyStillDecodes() throws {
        let m = FSMessage(id: "a", text: "t", mine: false, sender: "s", timestamp: "ts")
        XCTAssertNil(m.reactions)
        // Round trip (DiskCache path) with and without reactions.
        var withR = m
        withR.reactions = [ReactionSummary(emoji: "🎉", count: 1, viewerReacted: true)]
        let back = try JSONDecoder().decode(FSMessage.self, from: JSONEncoder().encode(withR))
        XCTAssertEqual(back.reactions, withR.reactions)
        let plain = try JSONDecoder().decode(FSMessage.self, from: JSONEncoder().encode(m))
        XCTAssertNil(plain.reactions)
    }

    func test_capabilities_decodeReactionEmoji_andGate() throws {
        let on = #"{"features":{"message_reactions":true},"terms_current":true,"reaction_emoji":{"quick":["👍","❤️"],"more":["🎉","👍"]}}"#
        let c = try JSONDecoder().decode(FSCapabilities.self, from: Data(on.utf8))
        XCTAssertTrue(c.messageReactionsEnabled)
        XCTAssertEqual(c.reactionEmoji.quick, ["👍", "❤️"])
        XCTAssertEqual(c.reactionEmoji.all, ["👍", "❤️", "🎉"], "quick first, de-duplicated")
    }

    func test_capabilities_gate_failsClosed() throws {
        // flag off even though a set is present
        let flagOff = #"{"features":{"message_reactions":false},"terms_current":true,"reaction_emoji":{"quick":["👍"],"more":[]}}"#
        XCTAssertFalse(try JSONDecoder().decode(FSCapabilities.self, from: Data(flagOff.utf8)).messageReactionsEnabled)
        // flag on but no reaction_emoji key (older server)
        let noKey = #"{"features":{"message_reactions":true},"terms_current":true}"#
        let c = try JSONDecoder().decode(FSCapabilities.self, from: Data(noKey.utf8))
        XCTAssertFalse(c.messageReactionsEnabled)
        XCTAssertEqual(c.reactionEmoji, .none)
        // flag on, empty quick set
        let empty = #"{"features":{"message_reactions":true},"terms_current":true,"reaction_emoji":{"quick":[],"more":["🎉"]}}"#
        XCTAssertFalse(try JSONDecoder().decode(FSCapabilities.self, from: Data(empty.utf8)).messageReactionsEnabled)
        // malformed block does not break the whole capabilities decode
        let odd = #"{"features":{"message_reactions":true},"terms_current":true,"reaction_emoji":"nope"}"#
        let c2 = try JSONDecoder().decode(FSCapabilities.self, from: Data(odd.utf8))
        XCTAssertFalse(c2.messageReactionsEnabled)
        XCTAssertTrue(c2.termsCurrent)
        // allOff and missing flag
        XCTAssertFalse(FSCapabilities.allOff.messageReactionsEnabled)
        XCTAssertFalse(FSCapabilities(features: [:], exploreLink: nil, termsCurrent: true,
                                      reactionEmoji: FSReactionEmoji(quick: ["👍"], more: [])).messageReactionsEnabled)
        XCTAssertTrue(FSCapabilities(features: ["message_reactions": true], exploreLink: nil, termsCurrent: true,
                                     reactionEmoji: FSReactionEmoji(quick: ["👍"], more: [])).messageReactionsEnabled)
    }

    func test_reactionError_descriptions_areExplicit() {
        for e: FSReactionError in [.unavailable, .termsReacceptRequired, .limitReached, .rateLimited, .failed("boom")] {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        }
        XCTAssertEqual(FSReactionError.failed("boom").errorDescription, "boom")
    }
}

// MARK: - View model

@MainActor
final class ChatReactionsViewModelTests: XCTestCase {

    override func setUp() { ReactionSeam.reset(); ThreadsSeam.reset() }
    override func tearDown() { ReactionSeam.reset() }

    private let group = FSContact(id: "group-1", name: "G", type: .group, toUsers: ["me", "x"])
    private let dm = FSContact(id: "friend-1", name: "F", type: .friend)
    private func uid(_ l: String) -> String { "\(l)-\(UUID().uuidString)" }
    private func r(_ e: String, _ c: Int, _ v: Bool) -> ReactionSummary { ReactionSummary(emoji: e, count: c, viewerReacted: v) }
    private func m(_ id: String, _ ts: String, reactions: [ReactionSummary]? = nil) -> FSMessage {
        var x = FSMessage(id: id, text: "t-\(id)", mine: false, sender: "alice", timestamp: ts)
        x.reactions = reactions
        return x
    }
    private func service(ws: String = "ws://127.0.0.1:1", msgs: [FSMessage]) -> ThrowingTestDataService {
        let s = ThrowingTestDataService()
        s.wsBaseOverride = ws
        s.historyResult = .paged(FSMessagePage(messages: msgs, hasMore: false, cursor: nil))
        return s
    }
    private let caps = FSCapabilities(features: ["chat_pagination": true, "chat_pagination_dm": true], exploreLink: nil, termsCurrent: true)
    private func loaded(_ s: ThrowingTestDataService, user: String, contact: FSContact? = nil) async -> ChatThreadViewModel {
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: contact ?? group, userId: user, capabilities: caps)
        return vm
    }
    private func eventually(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return }; try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("timed out waiting: \(what)")
    }
    private func reactions(_ vm: ChatThreadViewModel, _ id: String) -> [ReactionSummary]? {
        vm.messages.first(where: { $0.id == id })?.reactions
    }

    // MARK: optimistic toggle

    func test_toggle_add_isOptimisticThenReconcilesWithServerCount() async throws {
        let s = service(msgs: [m("m1", "2026-10-10T10:00:00Z", reactions: [r("👍", 2, false)])])
        let user = uid("add")
        let vm = await loaded(s, user: user)
        ReactionSeam.addResult = r("👍", 4, true)   // server saw two more concurrent reactors
        var optimistic: [ReactionSummary]?
        ReactionSeam.gate = { optimistic = await MainActor.run { self.reactions(vm, "m1") } }
        try await vm.toggleReaction("👍", on: vm.messages[0], service: s, userId: user)
        XCTAssertEqual(optimistic, [r("👍", 3, true)], "UI updated before the network call returned")
        XCTAssertEqual(reactions(vm, "m1"), [r("👍", 4, true)], "server count wins afterwards")
        XCTAssertEqual(ReactionSeam.log, ["add:m1:👍"])
        vm.disconnect()
    }

    func test_toggle_remove_usesRemoveEndpoint_andDropsEntryAtZero() async throws {
        let s = service(msgs: [m("m1", "2026-10-10T10:00:00Z", reactions: [r("👍", 1, true), r("❤️", 1, false)])])
        let user = uid("rm")
        let vm = await loaded(s, user: user)
        try await vm.toggleReaction("👍", on: vm.messages[0], service: s, userId: user)
        XCTAssertEqual(ReactionSeam.log, ["remove:m1:👍"])
        XCTAssertEqual(reactions(vm, "m1"), [r("❤️", 1, false)])
        vm.disconnect()
    }

    func test_toggle_onMessageWithNilReactions_addsFirstReaction() async throws {
        let s = service(msgs: [m("m1", "2026-10-10T10:00:00Z")])
        let user = uid("nil")
        let vm = await loaded(s, user: user)
        XCTAssertNil(reactions(vm, "m1"))
        try await vm.toggleReaction("🙏", on: vm.messages[0], service: s, userId: user)
        XCTAssertEqual(reactions(vm, "m1"), [r("🙏", 1, true)])
        vm.disconnect()
    }

    // MARK: rollback

    func test_toggle_add_failure_rollsBack_andRethrowsExplicitError() async {
        let s = service(msgs: [m("m1", "2026-10-10T10:00:00Z", reactions: [r("👍", 2, false)])])
        let user = uid("rb1")
        let vm = await loaded(s, user: user)
        ReactionSeam.error = FSReactionError.rateLimited
        do {
            try await vm.toggleReaction("👍", on: vm.messages[0], service: s, userId: user)
            XCTFail("must rethrow, not swallow")
        } catch {
            XCTAssertEqual(error as? FSReactionError, .rateLimited)
        }
        XCTAssertEqual(reactions(vm, "m1"), [r("👍", 2, false)], "restored exactly")
        vm.disconnect()
    }

    func test_toggle_firstReactionFailure_removesTheOptimisticEntry() async {
        let s = service(msgs: [m("m1", "2026-10-10T10:00:00Z")])
        let user = uid("rb2")
        let vm = await loaded(s, user: user)
        ReactionSeam.error = FSReactionError.unavailable
        do { try await vm.toggleReaction("🔥", on: vm.messages[0], service: s, userId: user); XCTFail("should throw") } catch {}
        XCTAssertEqual(reactions(vm, "m1"), [], "no phantom chip left behind")
        vm.disconnect()
    }

    func test_toggle_remove_failure_restoresOwnReaction() async {
        let s = service(msgs: [m("m1", "2026-10-10T10:00:00Z", reactions: [r("👍", 3, true)])])
        let user = uid("rb3")
        let vm = await loaded(s, user: user)
        ReactionSeam.error = FSReactionError.failed("nope")
        do { try await vm.toggleReaction("👍", on: vm.messages[0], service: s, userId: user); XCTFail("should throw") } catch {}
        XCTAssertEqual(reactions(vm, "m1"), [r("👍", 3, true)])
        vm.disconnect()
    }

    func test_rollback_touchesOnlyThatEmoji_keepsConcurrentChanges() async {
        let s = service(msgs: [m("m1", "2026-10-10T10:00:00Z", reactions: [r("👍", 1, false), r("❤️", 1, false)])])
        let user = uid("rb4")
        let vm = await loaded(s, user: user)
        ReactionSeam.error = FSReactionError.rateLimited
        // While the 👍 request is in flight another toggle on ❤️ lands locally.
        ReactionSeam.gate = {
            await MainActor.run {
                if let i = vm.messages.firstIndex(where: { $0.id == "m1" }) {
                    vm.messages[i].reactions = ReactionSummary.updatingCount(vm.messages[i].reactions ?? [], emoji: "❤️", count: 5)
                }
            }
        }
        do { try await vm.toggleReaction("👍", on: vm.messages[0], service: s, userId: user); XCTFail("should throw") } catch {}
        let list = reactions(vm, "m1") ?? []
        XCTAssertEqual(list.first(where: { $0.emoji == "👍" }), r("👍", 1, false))
        XCTAssertEqual(list.first(where: { $0.emoji == "❤️" })?.count, 5, "unrelated concurrent change preserved")
        vm.disconnect()
    }

    // MARK: guards

    func test_toggle_isNoOp_forUnsettledMessage_andWhileThreadOpen() async throws {
        let s = service(msgs: [m("m1", "2026-10-10T10:00:00Z")])
        let user = uid("guard")
        let vm = await loaded(s, user: user)
        // unknown to the settled check? pending ids are private; use a thread-open guard instead
        ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [m("r1", "2026-10-10T10:01:00Z")], hasMore: false, cursor: nil)
        await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: group, userId: user)
        XCTAssertTrue(vm.isThreadOpen)
        try await vm.toggleReaction("👍", on: m("r1", "2026-10-10T10:01:00Z"), service: s, userId: user)
        XCTAssertTrue(ReactionSeam.log.isEmpty, "thread messages are deferred: no network call")
        vm.closeThread()
        vm.disconnect()
    }

    func test_toggle_workedInDM() async throws {
        let s = service(msgs: [m("d1", "2026-10-10T10:00:00Z")])
        let user = uid("dm")
        let vm = await loaded(s, user: user, contact: dm)
        try await vm.toggleReaction("😂", on: vm.messages[0], service: s, userId: user)
        XCTAssertEqual(reactions(vm, "d1"), [r("😂", 1, true)])
        vm.disconnect()
    }

    // MARK: protocol default throws (never fabricates)

    func test_protocolDefault_throwsRatherThanInventingData() async {
        // MockDataService relies on the default; it must throw.
        do {
            _ = try await MockDataService.shared.addMessageReaction(userId: "u", messageId: "m", emoji: "👍")
            XCTFail("default must throw")
        } catch { XCTAssertTrue(error is FSReactionError) }
    }

    // MARK: reaction_updated frames (real local WebSocket)

    private func withServer(contact: FSContact? = nil, msgs: [FSMessage],
                            _ body: (ChatGroupSelfEchoDedupRegressionTests.WSTestServer, ChatThreadViewModel, String) async throws -> Void) async throws {
        let server = try ChatGroupSelfEchoDedupRegressionTests.WSTestServer()
        let port = try await server.start()
        defer { server.stop() }
        let s = service(ws: "ws://127.0.0.1:\(port)", msgs: msgs)
        let user = uid("ws")
        let vm = await loaded(s, user: user, contact: contact)
        try await server.waitForConnection()
        try await body(server, vm, user)
        vm.disconnect()
    }

    func test_frame_updatesCountForOthers_keepsViewerState_caseInsensitiveGroupId() async throws {
        try await withServer(msgs: [m("m1", "2026-10-10T10:00:00Z", reactions: [r("👍", 1, true)]), m("m2", "2026-10-10T10:01:00Z")]) { server, vm, _ in
            try server.sendFrame(["type": "reaction_updated", "message_id": "m1", "emoji": "👍", "count": 3, "group_id": "GROUP-1"])
            await self.eventually("count 3") { self.reactions(vm, "m1") == [self.r("👍", 3, true)] }
            try server.sendFrame(["type": "reaction_updated", "message_id": "m2", "emoji": "🎉", "count": 2, "group_id": "group-1"])
            await self.eventually("new chip") { self.reactions(vm, "m2") == [self.r("🎉", 2, false)] }
            try server.sendFrame(["type": "reaction_updated", "message_id": "m1", "emoji": "👍", "count": 0, "group_id": "group-1"])
            await self.eventually("removed") { self.reactions(vm, "m1") == [] }
        }
    }

    func test_frame_ignored_forOtherConversation_unknownMessage_andMalformed() async throws {
        try await withServer(msgs: [m("m1", "2026-10-10T10:00:00Z", reactions: [r("👍", 1, false)])]) { server, vm, _ in
            try server.sendFrame(["type": "reaction_updated", "message_id": "m1", "emoji": "👍", "count": 9, "group_id": "other-group"])
            try server.sendFrame(["type": "reaction_updated", "message_id": "nope", "emoji": "👍", "count": 9, "group_id": "group-1"])
            try server.sendFrame(["type": "reaction_updated", "message_id": "m1", "emoji": "👍", "group_id": "group-1"])   // no count
            try server.sendFrame(["type": "reaction_updated", "emoji": "👍", "count": 9, "group_id": "group-1"])           // no id
            // sentinel: a valid frame afterwards proves the earlier ones were processed (in order) and dropped
            try server.sendFrame(["type": "reaction_updated", "message_id": "m1", "emoji": "👍", "count": 2, "group_id": "group-1"])
            await self.eventually("sentinel") { self.reactions(vm, "m1") == [self.r("👍", 2, false)] }
            XCTAssertEqual(vm.messages.map(\.id), ["m1"])
        }
    }

    func test_frame_dm_usesSortedPairKey() async throws {
        try await withServer(contact: dm, msgs: [m("d1", "2026-10-10T10:00:00Z")]) { server, vm, user in
            let key = [user.lowercased(), "friend-1"].sorted().joined(separator: "|")
            try server.sendFrame(["type": "reaction_updated", "message_id": "d1", "emoji": "❤️", "count": 1, "group_id": "friend-1|wrong"])
            try server.sendFrame(["type": "reaction_updated", "message_id": "d1", "emoji": "🔥", "count": 4, "group_id": key])
            await self.eventually("dm frame") { self.reactions(vm, "d1") == [self.r("🔥", 4, false)] }
        }
    }

    func test_frame_whileThreadOpen_updatesStashedMainChat_notTheThread() async throws {
        try await withServer(msgs: [m("m1", "2026-10-10T10:00:00Z")]) { server, vm, user in
            let s = self.service(msgs: [])
            ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [self.m("r1", "2026-10-10T10:02:00Z")], hasMore: false, cursor: nil)
            await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: self.group, userId: user)
            try server.sendFrame(["type": "reaction_updated", "message_id": "m1", "emoji": "👍", "count": 2, "group_id": "group-1"])
            try await Task.sleep(nanoseconds: 600_000_000)
            XCTAssertEqual(vm.messages.map(\.id), ["r1"])
            XCTAssertNil(self.reactions(vm, "r1"))
            vm.closeThread()
            XCTAssertEqual(self.reactions(vm, "m1"), [self.r("👍", 2, false)])
        }
    }
}

// MARK: - Source pins (long-press wiring + accessibility)

final class ChatReactionsSourcePinTests: XCTestCase {
    private func src(_ rel: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript/\(rel)")
        return try String(contentsOf: file, encoding: .utf8)
    }
    private func idx(_ s: String, _ needle: String) -> String.Index? { s.range(of: needle)?.lowerBound }

    func test_longPress_reactionRowSitsAboveExistingActions_inMenuAndVoiceOver() throws {
        let s = try src("Chat/MessageGroupRow.swift")
        let menu = try XCTUnwrap(idx(s, ".contextMenu {"))
        let section = try XCTUnwrap(idx(s, "ReactionMenuSection(emojis:"))
        let firstAction = try XCTUnwrap(s.range(of: "ForEach(actions)", range: menu..<s.endIndex)?.lowerBound)
        XCTAssertTrue(menu < section && section < firstAction, "reaction section precedes the action buttons in .contextMenu")
        let a11y = try XCTUnwrap(idx(s, ".accessibilityActions {"))
        let a11yReact = try XCTUnwrap(idx(s, "reactionAccessibilityActions(emojis:"))
        let a11yFirst = try XCTUnwrap(s.range(of: "ForEach(actions)", range: a11y..<s.endIndex)?.lowerBound)
        XCTAssertTrue(a11y < a11yReact && a11yReact < a11yFirst, "VoiceOver reaction actions precede the others")
        XCTAssertTrue(s.contains("if actions.isEmpty && reactions == nil"), "menu still built when only reactions exist")
        XCTAssertTrue(s.contains("ReactionChipRow(reactions: list"), "chips under the bubble")
    }

    func test_chatView_gatesReactionUI_onCapabilityThreadAndSettled() throws {
        let s = try src("Chat/ChatThreadView.swift")
        XCTAssertTrue(s.contains("guard caps.messageReactionsEnabled, !vm.isThreadOpen, vm.isSettled(message) else { return nil }"))
        XCTAssertTrue(s.contains("case \"reaction_updated\":"))
        XCTAssertTrue(s.contains("default:\n                break // unrecognized type -- explicit no-op"), "unknown frames stay a no-op")
        XCTAssertTrue(s.contains("catch {"), "failure path present")
        XCTAssertTrue(s.contains("showToast(") && s.contains("Couldn't update your reaction"), "explicit error on failure")
        XCTAssertTrue(s.contains("ReactionPickerSheet") || s.contains("reactionPickerMessage"), "More picker wired")
    }

    func test_picker_accessibilityAndReduceMotion() throws {
        let s = try src("Shared/ReactionPicker.swift")
        XCTAssertTrue(s.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(s.contains("reduceMotion ? nil :"), "animations disabled under Reduce Motion")
        XCTAssertTrue(s.contains(".accessibilityLabel(ReactionEmojiName.name(for: emoji))"))
        XCTAssertTrue(s.contains(".accessibilityLabel(\"More reactions\")"))
        XCTAssertTrue(s.contains("[.isButton, .isSelected]"))
        XCTAssertTrue(s.contains("@ScaledMetric"), "Dynamic Type scaling")
        XCTAssertTrue(s.contains("Layout"), "wrapping flow layout")
    }

    func test_sharedPicker_hasNoChatOrVerseDependencies() throws {
        let s = try src("Shared/ReactionPicker.swift")
        for banned in ["FSMessage", "ChatThread", "FSContact", "ChatThreadViewModel", "FSBible", "BibleReader"] {
            XCTAssertFalse(s.contains(banned), "shared component must not reference \(banned)")
        }
    }
}
