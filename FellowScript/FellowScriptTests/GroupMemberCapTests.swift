// GroupMemberCapTests.swift — task 20261001-group-invite-permanent-member-cap
// (testing gate).
//
// Covers: invite models decode a null / missing `expires_at` (permanent group
// links) and still decode legacy ISO expiries; expiry label for nil; group
// create body omits expires_in_days while subscription create still sends it;
// FSGroupInfo lenient decoding of the new cap fields; the member-limit
// network call (PUT body, explicit null to clear, throw-not-fabricate); the
// GroupInfoViewModel set-cap state machine (success, clear, 403/422 errors,
// preserve-last-confirmed-value on failure, double-tap guard); and the
// "group is full" failure copy for the join flow.
//
// Uses the shared StubURLProtocol harness from
// NetworkServiceGetErrorHandlingTests.swift against the real NetworkService.

import XCTest
@testable import FellowScript

// MARK: - Models: permanent links + cap fields

final class PermanentInviteDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func test_inviteItem_decodesNullExpiresAt() throws {
        let item = try decode(FSInviteItem.self, """
        {"invite_id":"i1","created_by_username":"ann","is_mine":true,"created_at":"2026-09-30T00:00:00Z","expires_at":null,"max_uses":25,"use_count":3,"remaining_uses":22}
        """)
        XCTAssertNil(item.expires_at)
    }

    func test_inviteItem_decodesMissingExpiresAt() throws {
        let item = try decode(FSInviteItem.self, """
        {"invite_id":"i1","created_by_username":null,"is_mine":false,"created_at":"2026-09-30T00:00:00Z","max_uses":25,"use_count":0,"remaining_uses":25}
        """)
        XCTAssertNil(item.expires_at)
    }

    func test_inviteItem_stillDecodesLegacyExpiry() throws {
        let item = try decode(FSInviteItem.self, """
        {"invite_id":"i1","created_by_username":"ann","is_mine":false,"created_at":"2026-09-30T00:00:00Z","expires_at":"2026-10-07T00:00:00Z","max_uses":25,"use_count":3,"remaining_uses":22}
        """)
        XCTAssertEqual(item.expires_at, "2026-10-07T00:00:00Z")
    }

    func test_inviteCreated_decodesNullAndPresentExpiresAt() throws {
        let perm = try decode(FSInviteCreated.self, """
        {"invite_id":"n1","token":"t","url":"https://fellowscript.com/join/t","created_at":"2026-09-30T00:00:00Z","expires_at":null,"max_uses":25,"use_count":0}
        """)
        XCTAssertNil(perm.expires_at)
        let sub = try decode(FSInviteCreated.self, """
        {"invite_id":"n2","token":"t","url":"u","created_at":"2026-09-30T00:00:00Z","expires_at":"2026-10-07T00:00:00Z","max_uses":5,"use_count":0}
        """)
        XCTAssertEqual(sub.expires_at, "2026-10-07T00:00:00Z")
    }

    func test_inviteItem_roundTripsThroughDiskCacheEncoding_withNil() throws {
        let item = FSInviteItem(invite_id: "i1", created_by_username: nil, is_mine: true,
                                created_at: "2026-09-30T00:00:00Z", expires_at: nil,
                                max_uses: 25, use_count: 0, remaining_uses: 25)
        let back = try JSONDecoder().decode(FSInviteItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back, item)
        XCTAssertNil(back.expires_at)
    }

    func test_expiryLabel_nilIsNeverExpires_andLegacyStillLabelled() {
        XCTAssertEqual(InviteLinkSection.expiryLabel(nil), "Never expires")
        let now = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        XCTAssertTrue(InviteLinkSection.expiryLabel("2026-10-07T00:00:00Z", now: now).hasPrefix("Expires"))
        XCTAssertEqual(InviteLinkSection.expiryLabel("2026-10-01T05:00:00Z", now: now), "Expires in 5 hours")
    }
}

final class GroupInfoCapDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> FSGroupInfo {
        try JSONDecoder().decode(FSGroupInfo.self, from: Data(json.utf8))
    }

    func test_decodesCapFields() throws {
        let i = try decode(#"{"group_id":"g1","title":"T","photo_url":null,"muted":false,"members":["a","b"],"max_members":10,"member_count":2,"is_owner":true,"max_members_ceiling":250}"#)
        XCTAssertEqual(i.max_members, 10)
        XCTAssertEqual(i.member_count, 2)
        XCTAssertTrue(i.is_owner)
        XCTAssertEqual(i.max_members_ceiling, 250)
    }

    func test_nullCap_meansUnlimited() throws {
        let i = try decode(#"{"group_id":"g1","title":"T","photo_url":null,"muted":false,"members":["a"],"max_members":null,"member_count":1,"is_owner":false,"max_members_ceiling":250}"#)
        XCTAssertNil(i.max_members)
        XCTAssertFalse(i.is_owner)
    }

    func test_legacyCachedInfoWithoutCapKeys_stillDecodes_notOwner_noCap() throws {
        let i = try decode(#"{"group_id":"g1","title":"T","muted":true,"members":["a"]}"#)
        XCTAssertNil(i.max_members)
        XCTAssertNil(i.member_count)
        XCTAssertNil(i.max_members_ceiling)
        XCTAssertFalse(i.is_owner, "fail closed: owner controls hidden when the server didn't say")
        XCTAssertTrue(i.muted)
    }

    func test_roundTripPreservesCapFields() throws {
        let i = FSGroupInfo(group_id: "g1", title: "T", muted: false, members: ["a"],
                            max_members: 7, member_count: 1, is_owner: true, max_members_ceiling: 250)
        let back = try JSONDecoder().decode(FSGroupInfo.self, from: JSONEncoder().encode(i))
        XCTAssertEqual(back, i)
    }
}

// MARK: - Network + view model

@MainActor
final class GroupMemberCapNetworkTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(StubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(StubURLProtocol.self); super.tearDown() }
    override func setUp() { super.setUp(); StubURLProtocol.resetRequestLog() }

    private func stub(_ status: Int, _ body: String) {
        StubURLProtocol.stubStatusCode = status
        StubURLProtocol.stubBody = Data(body.utf8)
    }
    private let infoJSON = #"{"group_id":"g1","title":"T","photo_url":null,"muted":false,"members":["u1","u2"],"max_members":null,"member_count":2,"is_owner":true,"max_members_ceiling":250}"#

    private func vm() -> GroupInfoViewModel {
        GroupInfoViewModel(service: NetworkService.shared, groupId: "g-\(UUID().uuidString)", userId: "u1")
    }

    // Network layer
    func test_setGroupMaxMembers_putsIntegerBody() async throws {
        stub(200, #"{"group_id":"g1","max_members":12}"#)
        let v = try await NetworkService.shared.setGroupMaxMembers(userId: "u1", groupId: "g1", maxMembers: 12)
        XCTAssertEqual(v, 12)
        let req = StubURLProtocol.requestLog.last
        XCTAssertEqual(req?.method, "PUT")
        XCTAssertEqual(req?.path, "/api/groups/u1/g1/max-members")
        XCTAssertEqual(req?.bodyJSON?["max_members"] as? Int, 12)
    }

    func test_setGroupMaxMembers_nilSendsExplicitNull_toClear() async throws {
        stub(200, #"{"group_id":"g1","max_members":null}"#)
        let v = try await NetworkService.shared.setGroupMaxMembers(userId: "u1", groupId: "g1", maxMembers: nil)
        XCTAssertNil(v)
        let body = StubURLProtocol.requestLog.last?.bodyJSON
        XCTAssertNotNil(body)
        XCTAssertTrue(body?.keys.contains("max_members") ?? false, "nil must be sent as explicit null, not omitted")
        XCTAssertTrue(body?["max_members"] is NSNull)
    }

    func test_setGroupMaxMembers_serverRejection_throws_notFabricated() async {
        stub(403, #"{"detail":"Only the group owner can change this"}"#)
        do {
            _ = try await NetworkService.shared.setGroupMaxMembers(userId: "u1", groupId: "g1", maxMembers: 5)
            XCTFail("403 must throw")
        } catch {}
        stub(200, #"{"unexpected":true}"#)
        do {
            let v = try await NetworkService.shared.setGroupMaxMembers(userId: "u1", groupId: "g1", maxMembers: 5)
            // `max_members` is optional so a body without it decodes as nil; the
            // contract that matters is the server-confirmed value, not the request.
            XCTAssertNil(v)
        } catch {}
    }

    // View model
    func test_setMaxMembers_success_updatesInfoToConfirmedValue() async {
        stub(200, infoJSON)
        let m = vm()
        await m.loadInfo()
        XCTAssertNil(m.info?.max_members)
        stub(200, #"{"group_id":"g1","max_members":10}"#)
        let ok = await m.setMaxMembers(10)
        XCTAssertTrue(ok)
        XCTAssertEqual(m.info?.max_members, 10)
        XCTAssertTrue(m.capSaved)
        XCTAssertNil(m.capError)
        XCTAssertFalse(m.savingCap)
    }

    func test_setMaxMembers_clear_setsNil() async {
        stub(200, infoJSON.replacingOccurrences(of: #""max_members":null"#, with: #""max_members":10"#))
        let m = vm()
        await m.loadInfo()
        XCTAssertEqual(m.info?.max_members, 10)
        stub(200, #"{"group_id":"g1","max_members":null}"#)
        let ok = await m.setMaxMembers(nil)
        XCTAssertTrue(ok)
        XCTAssertNil(m.info?.max_members)
    }

    func test_setMaxMembers_422_showsError_keepsLastConfirmedValue() async {
        stub(200, infoJSON.replacingOccurrences(of: #""max_members":null"#, with: #""max_members":10"#))
        let m = vm()
        await m.loadInfo()
        stub(422, #"{"detail":"This group already has 2 members; the limit can't be lower"}"#)
        let ok = await m.setMaxMembers(1)
        XCTAssertFalse(ok)
        XCTAssertEqual(m.info?.max_members, 10, "a rejected save must not change the displayed cap")
        XCTAssertFalse(m.capSaved)
        XCTAssertNotNil(m.capError)
        XCTAssertFalse(m.removedFromGroup)
    }

    func test_setMaxMembers_403_owner_only_showsError_notRemoved() async {
        stub(200, infoJSON.replacingOccurrences(of: #""is_owner":true"#, with: #""is_owner":false"#))
        let m = vm()
        await m.loadInfo()
        stub(403, #"{"detail":"Only the group owner can change this"}"#)
        let ok = await m.setMaxMembers(5)
        XCTAssertFalse(ok)
        XCTAssertNil(m.info?.max_members)
        XCTAssertNotNil(m.capError)
        XCTAssertFalse(m.removedFromGroup, "owner-only 403 is not a removal from the group")
    }

    func test_setMaxMembers_403_notAMember_flagsRemoved() async {
        stub(200, infoJSON)
        let m = vm()
        await m.loadInfo()
        stub(403, #"{"detail":"Not a member of this group"}"#)
        let ok = await m.setMaxMembers(5)
        XCTAssertFalse(ok)
        XCTAssertTrue(m.removedFromGroup)
    }

    func test_setMaxMembers_ignoredWhileAlreadySaving() async {
        stub(200, infoJSON)
        let m = vm()
        await m.loadInfo()
        StubURLProtocol.resetRequestLog()
        m.savingCap = true
        let ok = await m.setMaxMembers(5)
        XCTAssertFalse(ok)
        XCTAssertTrue(StubURLProtocol.requestLog.isEmpty, "double tap must not send a second PUT")
    }

    func test_setMaxMembers_retryClearsPreviousError() async {
        stub(200, infoJSON)
        let m = vm()
        await m.loadInfo()
        stub(422, #"{"detail":"nope"}"#)
        _ = await m.setMaxMembers(1)
        XCTAssertNotNil(m.capError)
        stub(200, #"{"group_id":"g1","max_members":5}"#)
        _ = await m.setMaxMembers(5)
        XCTAssertNil(m.capError)
        XCTAssertEqual(m.info?.max_members, 5)
    }
}

// MARK: - Create body: group omits expiry, subscription still sends it

@MainActor
final class InviteCreateBodyExpiryTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(StubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(StubURLProtocol.self); super.tearDown() }
    override func setUp() { super.setUp(); StubURLProtocol.resetRequestLog() }

    private let createdJSON = #"{"invite_id":"n1","token":"t","url":"https://fellowscript.com/join/t","created_at":"2026-09-30T00:00:00Z","expires_at":null,"max_uses":25,"use_count":0}"#

    func test_groupCreate_omitsExpiresInDays_andDecodesNullExpiry() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = Data(createdJSON.utf8)
        let c = try await NetworkService.shared.createGroupInvite(userId: "u1", groupId: "g1", expiresInDays: nil, maxUses: 25)
        XCTAssertNil(c.expires_at)
        let body = StubURLProtocol.requestLog.last?.bodyJSON
        XCTAssertNil(body?["expires_in_days"])
        XCTAssertEqual(body?["max_uses"] as? Int, 25)
    }

    func test_subscriptionCreate_stillSendsExpiresInDays() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = Data(#"{"invite_id":"n2","token":"t","url":"u","created_at":"2026-09-30T00:00:00Z","expires_at":"2026-10-07T00:00:00Z","max_uses":5,"use_count":0}"#.utf8)
        let c = try await NetworkService.shared.createSubscriptionInvite(userId: "u1", subscriptionId: "s1", expiresInDays: 7, maxUses: 5)
        XCTAssertNotNil(c.expires_at)
        XCTAssertEqual(StubURLProtocol.requestLog.last?.bodyJSON?["expires_in_days"] as? Int, 7)
    }
}

// MARK: - Join: group full copy

final class GroupFullFailureTests: XCTestCase {
    func test_groupFull_copy_isWarm_andTerminal() {
        XCTAssertEqual(InviteFailure.groupFull.title, "This group is full.")
        XCTAssertNotNil(InviteFailure.groupFull.body)
        XCTAssertFalse(InviteFailure.groupFull.isRetryable)
        XCTAssertEqual(InviteFailure(InviteAPIError(status: 409, code: "group_full", message: "m")), .groupFull)
        XCTAssertEqual(InviteFailure(InviteAPIError(status: 409, code: nil, message: "m")), .full,
                       "a 409 with no code stays the link-exhausted copy")
    }
}
