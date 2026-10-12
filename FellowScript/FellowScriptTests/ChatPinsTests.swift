// ChatPinsTests.swift -- task 20261012-message-pins, iOS (REVISION 1: no banner,
// no cap; pin icon in the chat header opens the Pinned list).
// Wire decode, capability fail-closed, action policy, system-line grouping and
// text, view model optimistic pin/unpin + rollback, list paging, jump-to-pin
// paging, and source pins for the header button and menu wiring.
// These are plain unit tests; no simulator-only behavior beyond XCTest.

import XCTest
@testable import FellowScript

// MARK: - Seam on the shared test double (static, like ReactionSeam)

enum PinSeam {
    static var pinError: Error?
    static var listResults: [FSPinPage] = []
    static var listError: Error?
    static var log: [String] = []
    static func reset() { pinError = nil; listResults = []; listError = nil; log = [] }
}

extension ThrowingTestDataService {
    func pinMessage(userId: String, messageId: String) async throws {
        PinSeam.log.append("pin:\(messageId)")
        if let e = PinSeam.pinError { throw e }
    }
    func unpinMessage(userId: String, messageId: String) async throws {
        PinSeam.log.append("unpin:\(messageId)")
        if let e = PinSeam.pinError { throw e }
    }
    func fetchPins(userId: String, contactId: String, isGroup: Bool, limit: Int, offset: Int) async throws -> FSPinPage {
        PinSeam.log.append("list:\(isGroup ? "group" : "dm"):\(contactId):\(limit):\(offset)")
        if let e = PinSeam.listError { throw e }
        if PinSeam.listResults.isEmpty { return FSPinPage(pins: [], hasMore: false, count: 0) }
        return PinSeam.listResults.removeFirst()
    }
}

// MARK: - Decode, capability, copy

final class ChatPinsDecodeTests: XCTestCase {

    func test_rawMsg_decodesPinnedAndSystemKind() throws {
        let json = #"{"id":"m1","text":"pinned a message","from_user":"alice","timestamp":"2026-10-12T10:00:00Z","mine":false,"pinned":true,"system_kind":"pin"}"#
        let raw = try JSONDecoder().decode(RawMsg.self, from: Data(json.utf8))
        let msg = NetworkService.pagedMessage(raw)
        XCTAssertEqual(msg.pinned, true)
        XCTAssertEqual(msg.systemKind, "pin")
    }

    func test_rawMsg_withoutKeys_isNil() throws {
        let json = #"{"id":"m1","text":"hi","timestamp":"t","mine":true}"#
        let msg = NetworkService.pagedMessage(try JSONDecoder().decode(RawMsg.self, from: Data(json.utf8)))
        XCTAssertNil(msg.pinned)
        XCTAssertNil(msg.systemKind)
    }

    func test_fsMessage_cachedJSONWithoutPinKeysStillDecodes() throws {
        let m = FSMessage(id: "a", text: "t", mine: false, sender: "s", timestamp: "ts")
        var pinned = m
        pinned.pinned = true
        let back = try JSONDecoder().decode(FSMessage.self, from: JSONEncoder().encode(pinned))
        XCTAssertEqual(back.pinned, true)
        let plain = try JSONDecoder().decode(FSMessage.self, from: JSONEncoder().encode(m))
        XCTAssertNil(plain.pinned)
    }

    func test_pinPage_decodesServerShape() throws {
        let json = #"{"pins":[{"message_id":"m1","pinned_by_id":"u1","pinned_by":"Ann","pinned_at":"2026-10-12T10:00:00","message":{"id":"m1","from_user_id":"u2","from_user":"Bob","text":"hello","timestamp":"2026-10-12T09:00:00Z","attachment_kind":null}}],"has_more":true,"count":7}"#
        let page = try JSONDecoder().decode(FSPinPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.count, 7)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.pins.first?.id, "m1")
        XCTAssertEqual(page.pins.first?.pinnedBy, "Ann")
        XCTAssertEqual(page.pins.first?.message.fromUser, "Bob")
        XCTAssertEqual(page.pins.first?.previewText, "hello")
    }

    func test_pinPage_malformedBodyThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode(FSPinPage.self, from: Data(#"{"nope":1}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(FSPinPage.self, from: Data(#"{"pins":[{"message_id":"m"}]}"#.utf8)))
    }

    func test_previewText_attachmentOnlyUsesLabel() {
        func pin(_ kind: String?, _ text: String = "") -> FSPinnedMessage {
            FSPinnedMessage(messageId: "m", message: FSPinnedMessageBody(id: "m", text: text, attachmentKind: kind))
        }
        XCTAssertEqual(pin("image").previewText, "Photo")
        XCTAssertEqual(pin("video").previewText, "Video")
        XCTAssertEqual(pin("gif").previewText, "GIF")
        XCTAssertEqual(pin("file").previewText, "File")
        XCTAssertEqual(pin(nil).previewText, "Message")
        XCTAssertEqual(pin("image", "caption").previewText, "caption")
    }

    func test_capabilities_messagePins_failsClosed() throws {
        let on = #"{"features":{"message_pins":true},"terms_current":true}"#
        XCTAssertTrue(try JSONDecoder().decode(FSCapabilities.self, from: Data(on.utf8)).messagePinsEnabled)
        let off = #"{"features":{"message_pins":false},"terms_current":true}"#
        XCTAssertFalse(try JSONDecoder().decode(FSCapabilities.self, from: Data(off.utf8)).messagePinsEnabled)
        let missing = #"{"features":{},"terms_current":true}"#
        XCTAssertFalse(try JSONDecoder().decode(FSCapabilities.self, from: Data(missing.utf8)).messagePinsEnabled)
        XCTAssertFalse(FSCapabilities.allOff.messagePinsEnabled)
        // A non-boolean value or a missing features object is malformed: the decode throws,
        // which AppState maps to allOff.
        XCTAssertThrowsError(try JSONDecoder().decode(FSCapabilities.self, from: Data(#"{"features":{"message_pins":"yes"},"terms_current":true}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(FSCapabilities.self, from: Data(#"{"terms_current":true}"#.utf8)))
    }

    func test_pinError_statusMapping() {
        XCTAssertEqual(NetworkService.pinError(status: 404, data: Data()), .unavailable)
        XCTAssertEqual(NetworkService.pinError(status: 429, data: Data()), .rateLimited)
        XCTAssertEqual(NetworkService.pinError(status: 403, data: Data(#"{"detail":{"code":"terms_reaccept_required"}}"#.utf8)), .termsReacceptRequired)
        XCTAssertEqual(NetworkService.pinError(status: 403, data: Data()), .failed(FSPinError.fallback))
        XCTAssertEqual(NetworkService.pinError(status: 500, data: Data()), .failed(FSPinError.fallback))
        for e: FSPinError in [.unavailable, .termsReacceptRequired, .rateLimited, .failed("x")] {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        }
    }

    func test_listCopy() {
        let pin = FSPinnedMessage(messageId: "m", pinnedById: "ME", pinnedBy: "Ann", message: FSPinnedMessageBody(id: "m"))
        XCTAssertEqual(FSPinnedListCopy.pinnedByLine(pin, viewerId: "me"), "Pinned by You")
        XCTAssertEqual(FSPinnedListCopy.pinnedByLine(pin, viewerId: "other"), "Pinned by Ann")
        XCTAssertEqual(FSPinnedListCopy.pinnedByLine(pin, viewerId: nil), "Pinned by Ann")
        XCTAssertNil(FSPinnedListCopy.buttonValue(count: 0))
        XCTAssertEqual(FSPinnedListCopy.buttonValue(count: 3), "3 pinned")
        XCTAssertNil(FSPinnedListCopy.badgeText(count: 0))
        XCTAssertEqual(FSPinnedListCopy.badgeText(count: 5), "5")
        XCTAssertEqual(FSPinnedListCopy.badgeText(count: 150), "99+")
        XCTAssertEqual(FSPinnedListCopy.message(for: FSPinError.rateLimited), FSPinError.rateLimited.errorDescription)
        XCTAssertEqual(FSPinnedListCopy.message(for: FSPinError.failed("raw server text")), FSPinnedListCopy.actionError,
                       "raw error text is never shown")
    }
}

// MARK: - Action policy and system line

final class ChatPinsPolicyTests: XCTestCase {
    private func ctx(pins: Bool, inThread: Bool = false, settled: Bool = true) -> FSMessageActionContext {
        FSMessageActionContext(isGroup: true, inThread: inThread, threadsEnabled: false, messageDeleteEnabled: false,
                               isSettled: settled, senderUserId: nil, pinsEnabled: pins)
    }
    private func msg(pinned: Bool? = nil, kind: String? = nil, mine: Bool = false) -> FSMessage {
        var m = FSMessage(id: "m", text: "hi", mine: mine, sender: "a", timestamp: "t")
        m.pinned = pinned
        m.systemKind = kind
        return m
    }

    func test_pinOffered_forUnpinned_unpinForPinned_forAnyone() {
        XCTAssertTrue(FSMessageActionPolicy.actions(for: msg(), in: ctx(pins: true)).contains(.pin))
        XCTAssertTrue(FSMessageActionPolicy.actions(for: msg(pinned: true), in: ctx(pins: true)).contains(.unpin))
        XCTAssertFalse(FSMessageActionPolicy.actions(for: msg(pinned: true), in: ctx(pins: true)).contains(.pin))
        XCTAssertTrue(FSMessageActionPolicy.actions(for: msg(mine: true), in: ctx(pins: true)).contains(.pin))
    }

    func test_pinHidden_whenFlagOff_inThread_unsettled_orSystemLine() {
        XCTAssertFalse(FSMessageActionPolicy.actions(for: msg(), in: ctx(pins: false)).contains(.pin))
        XCTAssertFalse(FSMessageActionPolicy.actions(for: msg(), in: ctx(pins: true, inThread: true)).contains(.pin))
        XCTAssertFalse(FSMessageActionPolicy.actions(for: msg(), in: ctx(pins: true, settled: false)).contains(.pin))
        XCTAssertFalse(FSMessageActionPolicy.actions(for: msg(kind: "pin"), in: ctx(pins: true)).contains(.pin))
    }

    func test_titlesAndIcons() {
        XCTAssertEqual(FSMessageActionKind.pin.title, "Pin message")
        XCTAssertEqual(FSMessageActionKind.unpin.title, "Unpin message")
        XCTAssertEqual(FSMessageActionKind.pin.systemImage, "pin")
        XCTAssertEqual(FSMessageActionKind.unpin.systemImage, "pin.slash")
        XCTAssertFalse(FSMessageActionKind.pin.isDestructive)
        XCTAssertFalse(FSMessageActionKind.unpin.isDestructive)
    }

    func test_systemLine_isItsOwnGroup_andNeverMerges() {
        var line = FSMessage(id: "s", text: "pinned a message", mine: false, sender: "alice", timestamp: "2026-10-12T10:00:00Z")
        line.systemKind = "pin"
        let a = FSMessage(id: "a", text: "1", mine: false, sender: "alice", timestamp: "2026-10-12T09:59:00Z")
        let b = FSMessage(id: "b", text: "2", mine: false, sender: "alice", timestamp: "2026-10-12T10:01:00Z")
        let groups = MessageDisplayGroup.grouped(from: [a, line, b], me: nil)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map(\.isSystem), [false, true, false])
    }

    func test_systemLineText_isClientBuilt() {
        var line = FSMessage(id: "s", text: "ignore me <b>", mine: false, sender: "alice", timestamp: "t")
        line.systemKind = "pin"
        XCTAssertEqual(MessageGroupRow.systemLineText(for: line, senderName: "Alice"), "Alice pinned a message")
        var mine = FSMessage(id: "s", text: "x", mine: true, sender: "", timestamp: "t")
        mine.systemKind = "pin"
        XCTAssertEqual(MessageGroupRow.systemLineText(for: mine, senderName: "You"), "You pinned a message")
        XCTAssertEqual(MessageGroupRow.systemLineText(for: line, senderName: ""), "Someone pinned a message")
    }
}

// MARK: - View model

@MainActor
final class ChatPinsViewModelTests: XCTestCase {

    override func setUp() { PinSeam.reset(); ThreadsSeam.reset() }
    override func tearDown() { PinSeam.reset() }

    private let group = FSContact(id: "group-1", name: "G", type: .group, toUsers: ["me", "x"])
    private let dm = FSContact(id: "friend-1", name: "F", type: .friend)
    private func uid(_ l: String) -> String { "\(l)-\(UUID().uuidString)" }
    private func m(_ id: String, _ ts: String, pinned: Bool? = nil) -> FSMessage {
        var x = FSMessage(id: id, text: "t-\(id)", mine: false, sender: "alice", timestamp: ts)
        x.pinned = pinned
        return x
    }
    private func pin(_ id: String) -> FSPinnedMessage {
        FSPinnedMessage(messageId: id, pinnedById: "u", pinnedBy: "Ann", message: FSPinnedMessageBody(id: id, text: "t-\(id)"))
    }
    private func service(msgs: [FSMessage], hasMore: Bool = false, cursor: FSMessageCursor? = nil) -> ThrowingTestDataService {
        let s = ThrowingTestDataService()
        s.wsBaseOverride = "ws://127.0.0.1:1"
        s.historyResult = .paged(FSMessagePage(messages: msgs, hasMore: hasMore, cursor: cursor))
        return s
    }
    private let caps = FSCapabilities(features: ["chat_pagination": true, "chat_pagination_dm": true], exploreLink: nil, termsCurrent: true)
    private func loaded(_ s: ThrowingTestDataService, user: String, contact: FSContact? = nil) async -> ChatThreadViewModel {
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: contact ?? group, userId: user, capabilities: caps)
        return vm
    }
    private func pinned(_ vm: ChatThreadViewModel, _ id: String) -> Bool? { vm.messages.first(where: { $0.id == id })?.pinned }

    func test_togglePin_pins_optimisticallyAndBumpsBadge() async throws {
        let s = service(msgs: [m("m1", "2026-10-12T10:00:00Z")])
        let user = uid("pin")
        let vm = await loaded(s, user: user)
        try await vm.togglePin(vm.messages[0], service: s, userId: user)
        XCTAssertEqual(pinned(vm, "m1"), true)
        XCTAssertEqual(vm.pinCount, 1)
        XCTAssertEqual(PinSeam.log, ["pin:m1"])
        vm.disconnect()
    }

    func test_togglePin_unpins_andRemovesFromList() async throws {
        let s = service(msgs: [m("m1", "2026-10-12T10:00:00Z", pinned: true)])
        let user = uid("unpin")
        PinSeam.listResults = [FSPinPage(pins: [pin("m1")], hasMore: false, count: 1)]
        let vm = await loaded(s, user: user)
        await vm.loadPins(service: s, contact: group, userId: user, reset: true)
        XCTAssertEqual(vm.pinCount, 1)
        try await vm.togglePin(vm.messages[0], service: s, userId: user)
        XCTAssertEqual(pinned(vm, "m1"), false)
        XCTAssertEqual(vm.pinCount, 0)
        XCTAssertTrue(vm.pins.isEmpty)
        XCTAssertTrue(PinSeam.log.contains("unpin:m1"))
        vm.disconnect()
    }

    func test_togglePin_failureRollsBackFlagAndBadge_andRethrows() async {
        let s = service(msgs: [m("m1", "2026-10-12T10:00:00Z")])
        let user = uid("fail")
        let vm = await loaded(s, user: user)
        PinSeam.pinError = FSPinError.rateLimited
        do {
            try await vm.togglePin(vm.messages[0], service: s, userId: user)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? FSPinError, .rateLimited)
        }
        XCTAssertEqual(pinned(vm, "m1"), false)
        XCTAssertEqual(vm.pinCount, 0)
        vm.disconnect()
    }

    func test_togglePin_ignoresSystemLines() async throws {
        var line = m("s1", "2026-10-12T10:00:00Z")
        line.systemKind = "pin"
        let s = service(msgs: [line])
        let user = uid("sys")
        let vm = await loaded(s, user: user)
        try await vm.togglePin(vm.messages[0], service: s, userId: user)
        XCTAssertTrue(PinSeam.log.isEmpty)
        vm.disconnect()
    }

    func test_unpinFromList_restoresRowAtSamePositionOnFailure() async {
        let s = service(msgs: [m("m1", "2026-10-12T10:00:00Z", pinned: true), m("m2", "2026-10-12T10:01:00Z", pinned: true)])
        let user = uid("restore")
        PinSeam.listResults = [FSPinPage(pins: [pin("m2"), pin("m1")], hasMore: false, count: 2)]
        let vm = await loaded(s, user: user)
        await vm.loadPins(service: s, contact: group, userId: user, reset: true)
        PinSeam.pinError = FSPinError.failed("x")
        do { try await vm.unpin(vm.pins[0], service: s, userId: user); XCTFail("expected throw") } catch {}
        XCTAssertEqual(vm.pins.map(\.id), ["m2", "m1"])
        XCTAssertEqual(vm.pinCount, 2)
        XCTAssertEqual(pinned(vm, "m2"), true)
        vm.disconnect()
    }

    func test_loadPins_usesGroupAndDmScopes_andPages() async {
        let s = service(msgs: [])
        let user = uid("scope")
        let vm = await loaded(s, user: user)
        PinSeam.listResults = [FSPinPage(pins: [pin("a"), pin("b")], hasMore: true, count: 3),
                               FSPinPage(pins: [pin("b"), pin("c")], hasMore: false, count: 3)]
        await vm.loadPins(service: s, contact: group, userId: user, reset: true)
        XCTAssertTrue(vm.pinsHasMore)
        XCTAssertEqual(vm.pinCount, 3)
        await vm.loadPins(service: s, contact: group, userId: user, reset: false)
        XCTAssertEqual(vm.pins.map(\.id), ["a", "b", "c"], "second page merged without duplicates")
        XCTAssertFalse(vm.pinsHasMore)
        XCTAssertEqual(PinSeam.log, ["list:group:group-1:\(ChatThreadViewModel.pinsPageLimit):0",
                                     "list:group:group-1:\(ChatThreadViewModel.pinsPageLimit):2"])
        PinSeam.reset()
        await vm.loadPins(service: s, contact: dm, userId: user, reset: true)
        XCTAssertEqual(PinSeam.log, ["list:dm:friend-1:\(ChatThreadViewModel.pinsPageLimit):0"])
        vm.disconnect()
    }

    func test_loadPins_failure_setsFailedState_andQuietKeepsList() async {
        let s = service(msgs: [])
        let user = uid("loaderr")
        let vm = await loaded(s, user: user)
        PinSeam.listError = FSPinError.failed("x")
        await vm.loadPins(service: s, contact: group, userId: user, reset: true)
        XCTAssertEqual(vm.pinsState, .failed)
        PinSeam.listError = nil
        PinSeam.listResults = [FSPinPage(pins: [pin("a")], hasMore: false, count: 1)]
        await vm.loadPins(service: s, contact: group, userId: user, reset: true)
        XCTAssertEqual(vm.pinsState, .loaded)
        PinSeam.listError = FSPinError.failed("x")
        await vm.loadPins(service: s, contact: group, userId: user, reset: true, quiet: true)
        XCTAssertEqual(vm.pinsState, .loaded, "a failed background refresh keeps the shown list")
        XCTAssertEqual(vm.pins.map(\.id), ["a"])
        vm.disconnect()
    }

    func test_loadPins_404_marksUnavailable_soUIHides() async {
        let s = service(msgs: [])
        let user = uid("404")
        let vm = await loaded(s, user: user)
        PinSeam.listError = FSPinError.unavailable
        await vm.loadPins(service: s, contact: group, userId: user, reset: true)
        XCTAssertEqual(vm.pinsState, .unavailable)
        vm.disconnect()
    }

    func test_ensureLoaded_alreadyPresent_isTrueWithoutPaging() async {
        let s = service(msgs: [m("m1", "2026-10-12T10:00:00Z")])
        let user = uid("present")
        let vm = await loaded(s, user: user)
        let ok = await vm.ensureLoaded("m1", service: s, contact: group, userId: user)
        XCTAssertTrue(ok)
        vm.disconnect()
    }

    func test_ensureLoaded_missingWithNoMoreHistory_isFalse() async {
        let s = service(msgs: [m("m1", "2026-10-12T10:00:00Z")])
        let user = uid("missing")
        let vm = await loaded(s, user: user)
        let ok = await vm.ensureLoaded("gone", service: s, contact: group, userId: user)
        XCTAssertFalse(ok)
        vm.disconnect()
    }

    func test_removeStalePin_dropsRowAndFlag() async {
        let s = service(msgs: [m("m1", "2026-10-12T10:00:00Z", pinned: true)])
        let user = uid("stale")
        PinSeam.listResults = [FSPinPage(pins: [pin("m1")], hasMore: false, count: 1)]
        let vm = await loaded(s, user: user)
        await vm.loadPins(service: s, contact: group, userId: user, reset: true)
        vm.removeStalePin("m1")
        XCTAssertTrue(vm.pins.isEmpty)
        XCTAssertEqual(vm.pinCount, 0)
        XCTAssertEqual(pinned(vm, "m1"), false)
        vm.disconnect()
    }
}

// MARK: - Source pins

final class ChatPinsSourcePinTests: XCTestCase {
    private func src(_ rel: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript/\(rel)")
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_pinButton_sitsInRowBelowHeader_andIsFlagGated() throws {
        let s = try src("Chat/ChatThreadView.swift")
        let header = try XCTUnwrap(s.range(of: "header.modifier(pinsPresentation)")?.lowerBound)
        let pinRow = try XCTUnwrap(s.range(of: "Color.clear.frame(height: 0)")?.lowerBound)
        XCTAssertTrue(header < pinRow, "pin button floats over the messages after the header (zero-height layer), not in the top bar or its own row")
        XCTAssertFalse(s.contains("if pinsAvailable { pinButton }"), "no longer in the header bar")
        XCTAssertTrue(s.contains("appState.capabilities.messagePinsEnabled && !vm.isThreadOpen && vm.pinsState != .unavailable"),
                      "fail closed: flag, main chat, and not turned off mid-session")
        XCTAssertTrue(s.contains(".accessibilityLabel(\"Pinned messages\")"))
        XCTAssertFalse(s.localizedCaseInsensitiveContains("pinned banner"), "REVISION 1: no banner")
    }

    func test_pinUpdatedFrame_andMenuWiring() throws {
        let s = try src("Chat/ChatThreadView.swift")
        XCTAssertTrue(s.contains("case \"pin_updated\":"))
        XCTAssertTrue(s.contains("case .pin, .unpin:"))
        XCTAssertTrue(s.contains("pinsEnabled: pinsAvailable"))
        XCTAssertTrue(s.contains("json[\"system_kind\"] as? String"), "live system lines carry their kind")
    }

    func test_pinnedSheet_hasNoUnboundedErrorText_andAccessibilityActions() throws {
        let s = try src("Chat/PinnedMessagesSheet.swift")
        XCTAssertTrue(s.contains("accessibilityAction(named: \"Unpin\")"))
        XCTAssertTrue(s.contains("Unpin message from"))
        XCTAssertFalse(s.contains("localizedDescription"), "raw error text is never shown")
    }
}
