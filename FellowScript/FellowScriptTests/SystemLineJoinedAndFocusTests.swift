// SystemLineJoinedAndFocusTests.swift -- task 20261016-push-notifications-and-ui,
// gaps G1 (join_request tap focus) and G2 (member_joined system line).

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - G2 text + icon

final class MemberJoinedSystemLineTests: XCTestCase {
    private func msg(kind: String?, mine: Bool, text: String = "") -> FSMessage {
        var m = FSMessage(id: "m", text: text, mine: mine, sender: mine ? "" : "alice", timestamp: "2026-10-16T12:00:00.000Z")
        m.systemKind = kind
        return m
    }

    func test_memberJoined_own_saysYouJoined() {
        XCTAssertEqual(MessageGroupRow.systemLineText(for: msg(kind: "member_joined", mine: true), senderName: "Me"),
                       "You joined the group")
    }
    func test_memberJoined_other_usesName() {
        XCTAssertEqual(MessageGroupRow.systemLineText(for: msg(kind: "member_joined", mine: false), senderName: "Alice"),
                       "Alice joined the group")
    }
    func test_memberJoined_emptyName_fallsBackToSomeone() {
        XCTAssertEqual(MessageGroupRow.systemLineText(for: msg(kind: "member_joined", mine: false), senderName: ""),
                       "Someone joined the group")
    }
    func test_memberJoined_ignoresServerText() {
        XCTAssertEqual(MessageGroupRow.systemLineText(for: msg(kind: "member_joined", mine: false, text: "<script>x"), senderName: "Bob"),
                       "Bob joined the group")
    }
    func test_pin_text_unchanged() {
        XCTAssertEqual(MessageGroupRow.systemLineText(for: msg(kind: "pin", mine: true), senderName: "Me"), "You pinned a message")
        XCTAssertEqual(MessageGroupRow.systemLineText(for: msg(kind: "pin", mine: false), senderName: "Al"), "Al pinned a message")
    }
    func test_icons_memberJoined_isNotPin() {
        XCTAssertEqual(MessageGroupRow.systemLineIcon(for: "member_joined"), "person.badge.plus")
        XCTAssertNotEqual(MessageGroupRow.systemLineIcon(for: "member_joined"), "pin.fill")
        XCTAssertEqual(MessageGroupRow.systemLineIcon(for: "pin"), "pin.fill")
        XCTAssertNil(MessageGroupRow.systemLineIcon(for: "other"))
        XCTAssertNil(MessageGroupRow.systemLineIcon(for: nil))
    }

    // ViewInspector row inspection is broken in this environment (MessageGroupRowBaselineTests
    // fail at HEAD), so the render wiring is source-pinned instead.
    func test_row_usesPerKindIcon_andNoBubble() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: root.appendingPathComponent("FellowScript/Chat/MessageGroupRow.swift"), encoding: .utf8)
        XCTAssertTrue(s.contains("Self.systemLineIcon(for: message.systemKind)"))
        XCTAssertTrue(s.contains("Self.systemLineText(for: message, senderName: group.senderName)"))
        let start = try XCTUnwrap(s.range(of: "private func systemLine(")?.lowerBound)
        let end = try XCTUnwrap(s.range(of: "static func systemLineText")?.lowerBound)
        XCTAssertFalse(s[start..<end].contains("pin.fill"), "pin glyph must not be hard-coded in the system line")
    }
}

// MARK: - G2 include_system query scoping

final class IncludeSystemQueryTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(PagingStubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(PagingStubURLProtocol.self); super.tearDown() }
    override func setUp() { PagingStubURLProtocol.reset() }
    private let svc = NetworkService.shared
    private let body = #"{"messages":[],"page":{"limit":30,"has_more":false}}"#

    func test_constant() { XCTAssertEqual(NetworkService.includeSystemQuery, "include_system=1") }

    func test_groupHistory_paged_includesSystem() async throws {
        PagingStubURLProtocol.routes["/api/groups/u1/g1"] = (200, body)
        _ = try await svc.fetchMessageHistory(userId: "u1", contactId: "g1", isGroup: true, limit: 30)
        XCTAssertTrue(PagingStubURLProtocol.urls.last!.contains("include_system=1"))
    }
    func test_groupHistory_legacy_includesSystem() async throws {
        PagingStubURLProtocol.routes["/api/groups/u1/g1"] = (200, #"{"host_msgs":[],"other_msgs":[]}"#)
        _ = try await svc.fetchMessageHistory(userId: "u1", contactId: "g1", isGroup: true, limit: nil)
        XCTAssertTrue(PagingStubURLProtocol.urls.last!.contains("include_system=1"))
    }
    func test_groupOlderPage_includesSystem() async throws {
        PagingStubURLProtocol.routes["/api/groups/u1/g1/messages"] = (200, body)
        _ = try await svc.fetchOlderMessages(userId: "u1", contactId: "g1", isGroup: true, limit: 30,
                                             cursor: FSMessageCursor(timestamp: "2026-10-01T10:00:00+00:00", seq: 1, id: "m1"))
        XCTAssertTrue(PagingStubURLProtocol.urls.last!.contains("include_system=1"))
    }
    func test_dmHistory_neverIncludesSystem() async throws {
        PagingStubURLProtocol.routes["/api/friends/u1/f1"] = (200, body)
        PagingStubURLProtocol.routes["/api/friends/u1/f1/messages"] = (200, body)
        _ = try await svc.fetchMessageHistory(userId: "u1", contactId: "f1", isGroup: false, limit: 30)
        _ = try await svc.fetchOlderMessages(userId: "u1", contactId: "f1", isGroup: false, limit: 30,
                                             cursor: FSMessageCursor(timestamp: "t", seq: nil, id: "m1"))
        XCTAssertFalse(PagingStubURLProtocol.urls.contains { $0.contains("include_system") })
    }
    func test_fetchContacts_neverIncludesSystem() async throws {
        let caps = FSCapabilities(features: ["chat_pagination": true, "chat_pagination_dm": true], exploreLink: nil, termsCurrent: true)
        PagingStubURLProtocol.routes["/api/user/me"] =
            (200, #"{"user_id":"me","username":"Me","email":"m@x.com","friends":[],"groups":["g1"]}"#)
        PagingStubURLProtocol.routes["/api/groups/me/g1"] = (200, #"{"group":{"title":"G","users":["me"]},"members":[],"messages":[],"page":{"limit":1,"has_more":false}}"#)
        _ = try? await svc.fetchContacts(userId: "me", capabilities: caps)
        let groupCalls = PagingStubURLProtocol.urls.filter { $0.contains("/groups/me/g1") }
        XCTAssertFalse(groupCalls.isEmpty, "fetchContacts must have fetched the group preview")
        XCTAssertTrue(groupCalls.allSatisfy { !$0.contains("include_system") })
        XCTAssertTrue(PagingStubURLProtocol.urls.allSatisfy { !$0.contains("include_system") })
    }
}

// MARK: - G1 focus routing

final class JoinRequestFocusRoutingTests: XCTestCase {
    private struct Host: View {
        let isOwner: Bool
        let focus: Bool
        @State var show = false
        var body: some View {
            Text(show ? "OPEN" : "CLOSED")
                .opensHostToolsForJoinRequests(isOwner: isOwner, showHostTools: $show)
                .environment(\.fsFocusJoinRequests, focus)
        }
    }

    func test_environmentDefault_isFalse() {
        XCTAssertFalse(EnvironmentValues().fsFocusJoinRequests)
    }
    func test_sectionId_matchesJoinRequests() {
        XCTAssertEqual(GroupInfoJoinRequestsFocus.sectionId, "join_requests")
    }

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FellowScript/" + rel), encoding: .utf8)
    }

    // Behavioural: the modifier's gate is `focus && isOwner`, once. Source-pinned
    // because a ViewModifier's @State/onAppear cannot be driven outside a live host.
    func test_modifier_gatesOnFocusAndOwner_once() throws {
        let s = try source("Chat/GroupInfo+JoinRequestsFocus.swift")
        XCTAssertTrue(s.contains("guard focus, isOwner, !handled else { return }"))
        XCTAssertTrue(s.contains(".onChange(of: isOwner)"), "owner flag arriving late must still open Host tools")
        XCTAssertTrue(s.contains("showHostTools = true"))
    }
    func test_groupInfoSheet_wiresOwnerFlagToHostTools() throws {
        let s = try source("Chat/GroupInfoSheet.swift")
        XCTAssertTrue(s.contains(".opensHostToolsForJoinRequests(isOwner: isOwner, showHostTools: $showHostTools)"))
    }
    func test_hostTools_scrollsToJoinRequestsSection() throws {
        let s = try source("Chat/GroupHostToolsView.swift")
        XCTAssertTrue(s.contains("scrollsToJoinRequestsIfRequested(proxy, focus: focusJoinRequests)"))
        XCTAssertTrue(s.contains("ScrollViewReader"))
    }
    func test_chatThread_setsFlagOnJoinRequestAndResetsOnDismiss() throws {
        let s = try source("Chat/ChatThreadView.swift")
        XCTAssertTrue(s.contains("focusJoinRequests = true"))
        XCTAssertTrue(s.contains("onDismiss: { focusJoinRequests = false }"))
        XCTAssertTrue(s.contains(".environment(\\.fsFocusJoinRequests, focusJoinRequests)"))
    }
    func test_hostFlagOff_nonOwnerStaysOnGroupInfo_viewRenders() throws {
        // Non-owner / flag-off hosts render without any exception and stay closed.
        XCTAssertEqual(try Host(isOwner: false, focus: true).inspect().find(ViewType.Text.self).string(), "CLOSED")
        XCTAssertEqual(try Host(isOwner: true, focus: false).inspect().find(ViewType.Text.self).string(), "CLOSED")
    }
}
