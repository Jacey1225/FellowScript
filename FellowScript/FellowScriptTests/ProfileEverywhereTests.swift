// ProfileEverywhereTests.swift -- task 20261030-profile-everywhere (step 10).
// Pure-logic tests: the .profileTap gate (ProfileTapGuard), the chat sender id
// resolver (including username matching and the no-match case), senderId on
// FSMessage (Codable, grouping), and mention link parsing. No network.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class ProfileTapGuardTests: XCTestCase {
    private let id = "123e4567-e89b-42d3-a456-426614174000"

    func test_validUUIDAndRealName_isTappable() {
        XCTAssertTrue(ProfileTapGuard.isTappable(userId: id, username: "Ada"))
        XCTAssertTrue(ProfileTapGuard.isTappable(userId: id.uppercased(), username: "ada"))
    }

    func test_missingOrMalformedId_isNotTappable() {
        for bad in [nil, "", "ada", "123e4567", id + "x", "../" + id] as [String?] {
            XCTAssertFalse(ProfileTapGuard.isTappable(userId: bad, username: "Ada"), "\(String(describing: bad))")
        }
    }

    func test_placeholderNames_areNotTappable_evenWithValidId() {
        for name in ["Someone", "A member", "Them", "You", "system", "Announcement", "", "   ", "  YOU "] {
            XCTAssertFalse(ProfileTapGuard.isTappable(userId: id, username: name), name)
        }
        XCTAssertFalse(ProfileTapGuard.isTappable(userId: id, username: nil))
    }

    func test_realNameContainingPlaceholderWord_isStillTappable() {
        XCTAssertTrue(ProfileTapGuard.isTappable(userId: id, username: "Someone Else"))
    }
}

final class ChatProfileResolverTests: XCTestCase {
    private let peer = "123e4567-e89b-42d3-a456-426614174000"
    private let other = "223e4567-e89b-42d3-a456-426614174001"
    private let third = "323e4567-e89b-42d3-a456-426614174002"

    private func msg(_ id: String = "m1", mine: Bool = false, sender: String = "ada",
                     senderId: String? = nil, systemKind: String? = nil) -> FSMessage {
        var m = FSMessage(id: id, text: "hi", mine: mine, sender: sender, timestamp: "2026-10-30T10:00:00.000Z")
        m.senderId = senderId
        m.systemKind = systemKind
        return m
    }

    private func group(_ msgs: [FSMessage]) -> MessageDisplayGroup {
        let g = MessageDisplayGroup.grouped(from: msgs, me: nil)
        XCTAssertEqual(g.count, 1)
        return g[0]
    }

    func test_dmPeer_returnsPeerId() {
        let l = ChatProfileLookup(dmPeerId: peer)
        XCTAssertEqual(ChatProfileResolver.senderProfileId(group: group([msg()]), lookup: l), peer)
    }

    func test_dmPeerNotUUID_isNil_andDoesNotFallThrough() {
        let l = ChatProfileLookup(dmPeerId: "ada", idByUsername: ["ada": other])
        XCTAssertNil(ChatProfileResolver.senderProfileId(group: group([msg(senderId: other)]), lookup: l))
    }

    func test_groupRow_usesMessageSenderId() {
        let g = group([msg(senderId: other)])
        XCTAssertEqual(ChatProfileResolver.senderProfileId(group: g, lookup: .none), other)
    }

    func test_groupRow_skipsNonUUIDSenderId_usesLaterMessageId() {
        let g = group([msg("m1", senderId: "ada"), msg("m2", senderId: third)])
        XCTAssertEqual(ChatProfileResolver.senderProfileId(group: g, lookup: .none), third)
    }

    func test_messageSenderId_winsOverUsernameMap() {
        let l = ChatProfileLookup(idByUsername: ["ada": other])
        let g = group([msg(senderId: third)])
        XCTAssertEqual(ChatProfileResolver.senderProfileId(group: g, lookup: l), third)
    }

    func test_groupRow_withoutId_matchesIdByUsername() {
        let l = ChatProfileLookup(idByUsername: ["ada": other, "bob": third])
        XCTAssertEqual(ChatProfileResolver.senderProfileId(group: group([msg(sender: "ada")]), lookup: l), other)
        XCTAssertEqual(ChatProfileResolver.senderProfileId(group: group([msg(sender: "bob")]), lookup: l), third)
    }

    func test_groupRow_noMatch_isNil() {
        let l = ChatProfileLookup(idByUsername: ["bob": third])
        XCTAssertNil(ChatProfileResolver.senderProfileId(group: group([msg(sender: "ada")]), lookup: l))
        XCTAssertNil(ChatProfileResolver.senderProfileId(group: group([msg(sender: "ada")]), lookup: .none))
    }

    func test_usernameMapValueNotUUID_isNil() {
        let l = ChatProfileLookup(idByUsername: ["ada": "not-a-uuid"])
        XCTAssertNil(ChatProfileResolver.senderProfileId(group: group([msg(sender: "ada")]), lookup: l))
    }

    func test_usernameMatch_isExact_notCaseFolded() {
        let l = ChatProfileLookup(idByUsername: ["Ada": other])
        XCTAssertNil(ChatProfileResolver.senderProfileId(group: group([msg(sender: "ada")]), lookup: l))
    }

    func test_outgoingGroup_isNil_evenInDM() {
        let g = group([msg(mine: true, sender: "")])
        XCTAssertNil(ChatProfileResolver.senderProfileId(group: g, lookup: ChatProfileLookup(dmPeerId: peer)))
    }

    func test_systemGroup_isNil() {
        let g = group([msg(sender: "ada", senderId: other, systemKind: "pin")])
        XCTAssertTrue(g.isSystem)
        XCTAssertNil(ChatProfileResolver.senderProfileId(group: g, lookup: ChatProfileLookup(dmPeerId: peer)))
    }
}

final class FSMessageSenderIdTests: XCTestCase {
    func test_oldCachedJSONWithoutSenderId_decodesWithNil() throws {
        let json = #"{"id":"m","text":"hi","mine":false,"sender":"ada","timestamp":"t"}"#
        let m = try JSONDecoder().decode(FSMessage.self, from: Data(json.utf8))
        XCTAssertNil(m.senderId)
        XCTAssertEqual(m.sender, "ada")
    }

    func test_senderId_roundTrips() throws {
        var m = FSMessage(id: "m", text: "hi", mine: false, sender: "ada", timestamp: "t")
        m.senderId = "123e4567-e89b-42d3-a456-426614174000"
        let back = try JSONDecoder().decode(FSMessage.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.senderId, m.senderId)
        XCTAssertEqual(back.sender, "ada", "displayed sender is unchanged by the id")
    }

    func test_memberwiseInit_acceptsSenderId() {
        let m = FSMessage(id: "m", text: "hi", mine: false, sender: "ada", timestamp: "t",
                          senderId: "123e4567-e89b-42d3-a456-426614174000")
        XCTAssertEqual(m.senderId, "123e4567-e89b-42d3-a456-426614174000")
    }

    func test_grouping_preservesSenderIdOnMessages() {
        let a = FSMessage(id: "1", text: "a", mine: false, sender: "ada", timestamp: "2026-10-30T10:00:00.000Z",
                          senderId: "123e4567-e89b-42d3-a456-426614174000")
        let b = FSMessage(id: "2", text: "b", mine: false, sender: "ada", timestamp: "2026-10-30T10:00:05.000Z",
                          senderId: "123e4567-e89b-42d3-a456-426614174000")
        let groups = MessageDisplayGroup.grouped(from: [a, b], me: nil)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].messages.map(\.senderId), [a.senderId, b.senderId])
    }
}

final class MentionProfileLinkTests: XCTestCase {
    private let id = "123E4567-E89B-42D3-A456-426614174000"

    func test_validMention_linksToLowercasedUUID() {
        let m = FSMention(userId: id, start: 0, length: 4, username: "Ada")
        let url = MentionProfileLink.url(for: m, shownName: "@Ada")
        XCTAssertEqual(url?.absoluteString, "fsprofile://123e4567-e89b-42d3-a456-426614174000")
        XCTAssertEqual(url.flatMap(MentionProfileLink.userId(from:)), "123e4567-e89b-42d3-a456-426614174000")
    }

    func test_nonUUIDMention_hasNoLink() {
        let m = FSMention(userId: "u1", start: 0, length: 4, username: "Ada")
        XCTAssertNil(MentionProfileLink.url(for: m, shownName: "@Ada"))
    }

    func test_placeholderName_hasNoLink() {
        let m = FSMention(userId: id, start: 0, length: 8)
        XCTAssertNil(MentionProfileLink.url(for: m, shownName: "@Someone"))
        XCTAssertNil(MentionProfileLink.url(for: m, shownName: "@"))
    }

    func test_userIdFrom_rejectsOtherSchemesAndBadHosts() {
        XCTAssertNil(MentionProfileLink.userId(from: URL(string: "https://example.com")!))
        XCTAssertNil(MentionProfileLink.userId(from: URL(string: "https://123e4567-e89b-42d3-a456-426614174000")!))
        XCTAssertNil(MentionProfileLink.userId(from: URL(string: "fsprofile://not-a-uuid")!))
        XCTAssertNil(MentionProfileLink.userId(from: URL(string: "fsprofile://")!))
    }

    func test_attributed_linksOnlyValidMentionRuns_inOrder() {
        let text = "hi @Ada and @bob!"
        let mentions = [
            FSMention(userId: id, start: 3, length: 4, username: "Ada"),
            FSMention(userId: "bad-id", start: 12, length: 4, username: "bob"),
        ]
        let runs = MentionRender.runs(text: text, mentions: mentions)
        let attr = MentionText.attributed(runs, linking: MentionRender.validRanges(mentions, in: text))
        let links = attr.runs.compactMap { run in run.link.map { (String(attr[run.range].characters), $0) } }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].0, "@Ada")
        XCTAssertEqual(links[0].1.absoluteString, "fsprofile://123e4567-e89b-42d3-a456-426614174000")
    }

    func test_attributed_withoutRanges_hasNoLinks() {
        let attr = MentionText.attributed(MentionRender.runs(text: "hi @Ada", mentions: nil), linking: [])
        XCTAssertTrue(attr.runs.allSatisfy { $0.link == nil })
    }
}

// The modifier itself: a real button only when the guard passes.
@MainActor
final class ProfileTapModifierRenderTests: XCTestCase {
    private let id = "123e4567-e89b-42d3-a456-426614174000"

    private func state() -> AppState { AppState(service: MockDataService.shared) }

    func test_validIdAndName_wrapsContentInLabelledButton() throws {
        let sut = Text("Ada").profileTap(userId: id, username: "Ada").environmentObject(state())
        let button = try sut.inspect().find(ViewType.Button.self)
        XCTAssertEqual(try button.accessibilityLabel().string(), "View Ada's profile")
        XCTAssertNoThrow(try sut.inspect().find(text: "Ada"))
    }

    func test_noId_returnsPlainContent() throws {
        let sut = Text("Ada").profileTap(userId: nil, username: "Ada").environmentObject(state())
        XCTAssertThrowsError(try sut.inspect().find(ViewType.Button.self))
        XCTAssertNoThrow(try sut.inspect().find(text: "Ada"))
    }

    func test_malformedId_returnsPlainContent() throws {
        let sut = Text("Ada").profileTap(userId: "ada", username: "Ada").environmentObject(state())
        XCTAssertThrowsError(try sut.inspect().find(ViewType.Button.self))
    }

    func test_placeholderName_returnsPlainContent() throws {
        for name in ["Someone", "A member", "You"] {
            let sut = Text(name).profileTap(userId: id, username: name).environmentObject(state())
            XCTAssertThrowsError(try sut.inspect().find(ViewType.Button.self), name)
        }
    }

    func test_profileLinkedAvatar_isTappableOnlyWithRealUser() throws {
        let ok = ProfileLinkedAvatar(userId: id, username: "Ada").environmentObject(state())
        XCTAssertNoThrow(try ok.inspect().find(ViewType.Button.self))
        let bad = ProfileLinkedAvatar(userId: "", username: "Ada").environmentObject(state())
        XCTAssertThrowsError(try bad.inspect().find(ViewType.Button.self))
    }
}
