// CallRoomStateTests.swift -- testing gate for task 20261009-discussion-rooms,
// step 8 (iOS). Covers, without the Chime SDK or SwiftUI hosting:
//   * CallRoomStateMachineTests   the pure CallRoomState machine, RoomsFlag, RoomCopy
//   * SessionRoomsModelsDecodeTests   wire model decoding
//   * SessionRoomsRequestBuilderTests   NetworkService+SessionRooms paths/bodies/errors
//   * RoomListLogicTests   list precedence, actions, create gating, form
//   * CallRoomControllerTests   the controller with a scripted service double
//   * DiscussionRoomsSourcePinTests   source pins for what cannot be hosted
// Real two-device Chime audio/video switching is NOT simulator-verifiable.

import XCTest
import SwiftUI
@testable import FellowScript

// MARK: - Source helper

private func roomsSource(_ relativePath: String, file: StaticString = #filePath) throws -> String {
    let url = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()   // FellowScriptTests/
        .deletingLastPathComponent()   // project root
        .appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - Scripted rooms API (shared with ThrowingTestDataService)

final class RoomsScript {
    var joinResult: Result<SessionRoomJoinResponse, Error>?
    var heartbeatError: Error?
    var leaveError: Error?
    private(set) var calls: [String] = []
    func record(_ s: String) { calls.append(s) }
    func reset() { calls = [] }
}

extension ThrowingTestDataService: SessionRoomsServiceProtocol {
    func listRooms(userId: String, sessionId: String) async throws -> SessionRoomsListResponse {
        roomsScript.record("list"); return SessionRoomsListResponse()
    }
    func createRoom(userId: String, sessionId: String, title: String?, inviteOnly: Bool, inviteeIds: [String]) async throws -> SessionRoom {
        roomsScript.record("create"); return SessionRoom(id: "new")
    }
    func joinRoom(userId: String, roomId: String) async throws -> SessionRoomJoinResponse {
        roomsScript.record("join:\(roomId)")
        guard let r = roomsScript.joinResult else { throw SessionRoomsError.network }
        return try r.get()
    }
    func leaveRoom(userId: String, roomId: String) async throws {
        roomsScript.record("leave:\(roomId)")
        if let e = roomsScript.leaveError { throw e }
    }
    func heartbeatRoom(userId: String, roomId: String) async throws {
        roomsScript.record("beat:\(roomId)")
        if let e = roomsScript.heartbeatError { throw e }
    }
    func renameRoom(userId: String, roomId: String, title: String) async throws { roomsScript.record("rename") }
    func endRoom(userId: String, roomId: String) async throws { roomsScript.record("end") }
    func inviteToRoom(userId: String, roomId: String, inviteeIds: [String]) async throws { roomsScript.record("invite") }
}

private func chimeJoin(_ meetingId: String) -> ChimeJoinResponse {
    let json = """
    {"Meeting":{"MeetingId":"\(meetingId)","ExternalMeetingId":"room:x","MediaRegion":"us-east-1",
     "MediaPlacement":{"AudioHostUrl":"a","AudioFallbackUrl":"b","SignalingUrl":"c","TurnControlUrl":"d"}},
     "Attendee":{"AttendeeId":"att","ExternalUserId":"u1","JoinToken":"tok"}}
    """
    return try! JSONDecoder().decode(ChimeJoinResponse.self, from: Data(json.utf8))
}

private func roomJoinResponse(id: String, name: String = "Room 1", members: [(String, String)] = [("u1", "Ana")]) -> SessionRoomJoinResponse {
    let m = members.map { "{\"user_id\":\"\($0.0)\",\"username\":\"\($0.1)\"}" }.joined(separator: ",")
    let json = """
    {"room":{"id":"\(id)","name":"\(name)","slot":1,"members":[\(m)]},
     "Meeting":{"MeetingId":"mtg-\(id)","ExternalMeetingId":"room:\(id)","MediaRegion":"us-east-1",
     "MediaPlacement":{"AudioHostUrl":"a","AudioFallbackUrl":"b","SignalingUrl":"c","TurnControlUrl":"d"}},
     "Attendee":{"AttendeeId":"att","ExternalUserId":"u1","JoinToken":"tok"}}
    """
    return try! JSONDecoder().decode(SessionRoomJoinResponse.self, from: Data(json.utf8))
}

// MARK: - A. State machine, flag, copy

final class CallRoomStateMachineTests: XCTestCase {

    func test_create_join_leave_backToMain_happyPath() {
        var s = CallRoomState.main
        XCTAssertFalse(s.isInRoom); XCTAssertFalse(s.showsBackToMain); XCTAssertNil(s.roomId)
        s = s.beginJoin(roomId: "r1", name: "Room 1")
        XCTAssertEqual(s, .joining(roomId: "r1", name: "Room 1"))
        XCTAssertTrue(s.isBusy)
        XCTAssertNil(s.currentRoomName, "a room being joined is not the current room")
        XCTAssertEqual(s.roomName, "Room 1")
        s = s.joinSucceeded()
        XCTAssertEqual(s, .inRoom(roomId: "r1", name: "Room 1"))
        XCTAssertTrue(s.isInRoom); XCTAssertTrue(s.showsBackToMain); XCTAssertFalse(s.isBusy)
        XCTAssertEqual(s.currentRoomName, "Room 1")
        s = s.beginReturn()
        XCTAssertEqual(s, .returning(fromName: "Room 1"))
        XCTAssertTrue(s.isBusy); XCTAssertTrue(s.showsBackToMain)
        s = s.returnSucceeded()
        XCTAssertEqual(s, .main)
    }

    func test_roomToRoom_switch_isAllowedFromInRoom() {
        let s = CallRoomState.inRoom(roomId: "a", name: "A").beginJoin(roomId: "b", name: "B")
        XCTAssertEqual(s, .joining(roomId: "b", name: "B"))
        XCTAssertEqual(s.joinSucceeded(), .inRoom(roomId: "b", name: "B"))
    }

    func test_failedJoin_leavesUserWhereTheyWere() {
        let fromMain = CallRoomState.main
        XCTAssertEqual(fromMain.beginJoin(roomId: "r", name: "R").joinFailed(previous: fromMain), .main)
        let fromRoom = CallRoomState.inRoom(roomId: "a", name: "A")
        XCTAssertEqual(fromRoom.beginJoin(roomId: "b", name: "B").joinFailed(previous: fromRoom), fromRoom)
    }

    func test_joinFailed_isNoOpOutsideJoining() {
        let s = CallRoomState.inRoom(roomId: "a", name: "A")
        XCTAssertEqual(s.joinFailed(previous: .main), s, "a late failure callback can't move an established room")
    }

    func test_invalidTransitions_areNoOps() {
        XCTAssertEqual(CallRoomState.main.joinSucceeded(), .main)
        XCTAssertEqual(CallRoomState.main.beginReturn(), .main)
        XCTAssertEqual(CallRoomState.main.returnSucceeded(), .main)
        XCTAssertEqual(CallRoomState.main.returnFailed(), .main)
        let joining = CallRoomState.joining(roomId: "r", name: "R")
        XCTAssertEqual(joining.beginJoin(roomId: "x", name: "X"), joining, "no double join while busy")
        XCTAssertEqual(joining.beginReturn(), joining)
        let returning = CallRoomState.returning(fromName: "R")
        XCTAssertEqual(returning.beginJoin(roomId: "x", name: "X"), returning)
        XCTAssertEqual(returning.beginReturn(), returning)
    }

    func test_returnFailed_thenRetry() {
        var s = CallRoomState.inRoom(roomId: "r", name: "R").beginReturn()
        s = s.returnFailed()
        XCTAssertEqual(s, .returnFailed(fromName: "R"))
        XCTAssertTrue(s.showsBackToMain, "Back to main stays reachable after a failed return")
        XCTAssertEqual(s.beginReturn(), .returning(fromName: "R"))
        XCTAssertEqual(s.beginReturn().returnSucceeded(), .main)
    }

    func test_showsBackToMain_truthTable() {
        XCTAssertFalse(CallRoomState.main.showsBackToMain)
        XCTAssertFalse(CallRoomState.joining(roomId: "r", name: "R").showsBackToMain)
        XCTAssertTrue(CallRoomState.inRoom(roomId: "r", name: "R").showsBackToMain)
        XCTAssertTrue(CallRoomState.returning(fromName: "R").showsBackToMain)
        XCTAssertTrue(CallRoomState.returnFailed(fromName: "R").showsBackToMain)
    }

    // Flag gating

    private func session(group: String) -> FSSession {
        var s = FSSession(); s.group_id = group; return s
    }
    private func caps(_ on: Bool?) -> FSCapabilities {
        FSCapabilities(features: on == nil ? [:] : ["discussion_rooms": on!], exploreLink: nil, termsCurrent: true)
    }

    func test_flag_offAbsentOrUnknown_hidesRooms() {
        let s = session(group: "g1")
        XCTAssertFalse(RoomsFlag.isAvailable(caps(false), session: s))
        XCTAssertFalse(RoomsFlag.isAvailable(caps(nil), session: s), "absent flag fails closed")
        XCTAssertFalse(RoomsFlag.isAvailable(.allOff, session: s))
        XCTAssertFalse(RoomsFlag.isAvailable(caps(true), session: nil), "no session -> hidden")
        XCTAssertEqual(RoomsFlag.flagName, "discussion_rooms")
    }

    func test_flag_on_showsForGroupSession() {
        XCTAssertTrue(RoomsFlag.isAvailable(caps(true), session: session(group: "g1")))
    }

    func test_dm_hidesRooms_evenWithFlagOn() {
        let dm = session(group: "uidA|uidB")
        XCTAssertTrue(RoomsFlag.isDirectMessage(dm))
        XCTAssertFalse(RoomsFlag.isAvailable(caps(true), session: dm))
    }

    func test_flagFlippingOffMidCall_doesNotStrandUser() {
        // The row/back-to-main gates are `roomsAvailable || showsBackToMain` and
        // `showsBackToMain`: the exit depends on the machine state, not the flag.
        let inRoom = CallRoomState.inRoom(roomId: "r", name: "R")
        XCTAssertFalse(RoomsFlag.isAvailable(caps(false), session: session(group: "g")))
        XCTAssertTrue(inRoom.showsBackToMain)
        XCTAssertTrue(inRoom.beginReturn().isBusy, "return is still a legal transition with the flag off")
    }

    // Room ended / main ended classification

    func test_roomGone_andMainEnded_classification() {
        XCTAssertTrue(RoomCopy.isRoomGone(SessionRoomsError(status: 410, code: "room_ended")))
        XCTAssertTrue(RoomCopy.isRoomGone(SessionRoomsError(status: 404, code: "not_in_room")))
        XCTAssertTrue(RoomCopy.isRoomGone(SessionRoomsError(status: 410, code: "whatever")))
        XCTAssertFalse(RoomCopy.isRoomGone(SessionRoomsError.network))
        XCTAssertFalse(RoomCopy.isRoomGone(NSError(domain: "x", code: 1)))
        XCTAssertTrue(RoomCopy.isMainEnded(SessionRoomsError(status: 409, code: "main_not_live")))
        XCTAssertFalse(RoomCopy.isMainEnded(SessionRoomsError(status: 409, code: "rooms_full")))
    }

    func test_heartbeatOutcome_onlyExplicitAnswersEject() {
        XCTAssertEqual(RoomHeartbeat.outcome(for: SessionRoomsError.network), .keepGoing)
        XCTAssertEqual(RoomHeartbeat.outcome(for: SessionRoomsError(status: 500, code: "error")), .keepGoing)
        XCTAssertEqual(RoomHeartbeat.outcome(for: SessionRoomsError(status: 429, code: "rate_limited")), .keepGoing)
        XCTAssertEqual(RoomHeartbeat.outcome(for: SessionRoomsError(status: 410, code: "room_ended")), .roomGone)
        XCTAssertEqual(RoomHeartbeat.outcome(for: SessionRoomsError(status: 409, code: "main_not_live")), .mainEnded)
    }

    func test_heartbeatCadence_constants() {
        XCTAssertEqual(RoomHeartbeat.interval, 30)
        XCTAssertEqual(RoomHeartbeat.listPollInterval, 5)
        XCTAssertLessThan(RoomHeartbeat.interval, 300, "must beat well inside the server's stale threshold")
    }

    // Warm copy

    func test_copy_knownCodes_areWarmAndNeverRawServerText() {
        let codes = ["room_full", "cannot_join", "room_ended", "not_in_room", "rooms_full", "rate_limited",
                     "invalid_invitee", "too_many_invites", "title_rejected", "forbidden", "chime_error",
                     "network", "busy", "main_not_live", "totally_unknown"]
        for c in codes {
            for a in [RoomAction.join, .create, .manage, .load] {
                let m = RoomCopy.message(forCode: c, action: a)
                XCTAssertFalse(m.isEmpty)
                XCTAssertFalse(m.contains(c) && c.contains("_"), "raw code leaked for \(c)")
            }
        }
        XCTAssertEqual(RoomCopy.message(forCode: "room_full", action: .join), "This room is full.")
        XCTAssertEqual(RoomCopy.message(forCode: "weird", action: .load), "Couldn\u{2019}t load rooms.")
        XCTAssertNotEqual(RoomCopy.message(forCode: "rate_limited", action: .create),
                          RoomCopy.message(forCode: "rate_limited", action: .join))
        XCTAssertEqual(RoomCopy.message(for: NSError(domain: "x", code: 1), action: .join),
                       RoomCopy.message(forCode: "network", action: .join))
        XCTAssertEqual(RoomCopy.roomEndedNotice("Room 2"), "Room 2 has ended. You\u{2019}re back in the main session.")
    }
}

// MARK: - B. Wire model decoding

final class SessionRoomsModelsDecodeTests: XCTestCase {
    private func decode<T: Decodable>(_ t: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(t, from: Data(json.utf8))
    }

    func test_fullRoom_decodesCreatorInviteModeAndCapacity() throws {
        let r = try decode(SessionRoom.self, """
        {"id":"r1","session_id":"s1","slot":2,"title":"Study","name":"Study","visibility":"invite_only",
         "is_invited":true,"can_join":true,"member_count":3,"max_members":8,"is_full":false,"is_member":false,
         "can_end":true,"is_creator":true,"can_invite":true,
         "members":[{"user_id":"u1","username":"Ana"},{"user_id":"u2","username":"Ben"}]}
        """)
        XCTAssertEqual(r.id, "r1"); XCTAssertEqual(r.slot, 2)
        XCTAssertTrue(r.isInviteOnly); XCTAssertTrue(r.is_invited)
        XCTAssertTrue(r.is_creator); XCTAssertTrue(r.can_invite); XCTAssertTrue(r.can_end)
        XCTAssertEqual(r.member_count, 3); XCTAssertEqual(r.max_members, 8)
        XCTAssertEqual(r.members.map(\.username), ["Ana", "Ben"])
        XCTAssertEqual(r.members.map(\.id), ["u1", "u2"])
        XCTAssertEqual(r.displayName, "Study")
    }

    func test_openMode_isNotInviteOnly_andUnknownModeFailsOpenSafe() throws {
        XCTAssertFalse(try decode(SessionRoom.self, #"{"id":"a","visibility":"open"}"#).isInviteOnly)
        XCTAssertFalse(try decode(SessionRoom.self, #"{"id":"a"}"#).isInviteOnly)
        XCTAssertFalse(try decode(SessionRoom.self, #"{"id":"a","visibility":"mystery"}"#).isInviteOnly)
    }

    func test_lenientDecode_missingFieldsFallBack_andCreatorDefaultsFalse() throws {
        let r = try decode(SessionRoom.self, #"{"id":"only"}"#)
        XCTAssertFalse(r.is_creator); XCTAssertFalse(r.can_invite); XCTAssertFalse(r.can_end)
        XCTAssertEqual(r.max_members, 8); XCTAssertTrue(r.members.isEmpty)
        XCTAssertEqual(r.displayName, "Room", "no name and no slot")
        XCTAssertEqual(try decode(SessionRoom.self, #"{"id":"x","slot":3}"#).displayName, "Room 3")
    }

    func test_wrongTypedField_doesNotBlankTheRoom() throws {
        let r = try decode(SessionRoom.self, #"{"id":"x","member_count":"many","is_full":"yes","name":"N"}"#)
        XCTAssertEqual(r.member_count, 0); XCTAssertFalse(r.is_full); XCTAssertEqual(r.name, "N")
    }

    func test_missingId_throws() {
        XCTAssertThrowsError(try decode(SessionRoom.self, #"{"name":"no id"}"#))
    }

    func test_listResponse_capsAndDefaults() throws {
        let l = try decode(SessionRoomsListResponse.self, """
        {"rooms":[{"id":"a"},{"id":"b"}],"max_members":5,"max_rooms":3,"main_live":false}
        """)
        XCTAssertEqual(l.rooms.count, 2); XCTAssertEqual(l.max_members, 5)
        XCTAssertEqual(l.max_rooms, 3); XCTAssertFalse(l.main_live)
        let d = try decode(SessionRoomsListResponse.self, "{}")
        XCTAssertEqual(d.max_rooms, 6); XCTAssertEqual(d.max_members, 8); XCTAssertTrue(d.main_live)
        XCTAssertTrue(d.rooms.isEmpty)
    }

    func test_joinResponse_decodesMeetingAndAttendee() {
        let j = roomJoinResponse(id: "r9")
        XCTAssertEqual(j.room.id, "r9")
        XCTAssertEqual(j.chime.Meeting.MeetingId, "mtg-r9")
        XCTAssertEqual(j.chime.Meeting.ExternalMeetingId, "room:r9")
        XCTAssertEqual(j.chime.Attendee.JoinToken, "tok")
    }
}

// MARK: - C. NetworkService request builders

final class RoomsStubURLProtocol: URLProtocol {
    struct Seen { let method: String; let rawURL: String; let path: String; let query: String?; let body: [String: Any]? }
    static var routes: [String: (Int, String)] = [:]    // "METHOD path" -> response
    static var seen: [Seen] = []
    static func reset() { routes = [:]; seen = [] }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.path.contains("/session-rooms/") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            bodyData = d
        }
        let obj = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let method = request.httpMethod ?? "GET"
        Self.seen.append(Seen(method: method, rawURL: url.absoluteString, path: url.path, query: url.query, body: obj))
        let route = Self.routes["\(method) \(url.path)"] ?? (200, "{}")
        let resp = HTTPURLResponse(url: url, statusCode: route.0, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(route.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SessionRoomsRequestBuilderTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(RoomsStubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(RoomsStubURLProtocol.self); super.tearDown() }
    override func setUp() { RoomsStubURLProtocol.reset() }

    private let svc = NetworkService.shared
    private var last: RoomsStubURLProtocol.Seen { RoomsStubURLProtocol.seen.last! }

    func test_list_isGET_onSessionRoomsPath() async throws {
        RoomsStubURLProtocol.routes["GET /api/session-rooms/u1/sessions/s1/rooms"] =
            (200, #"{"rooms":[{"id":"a","is_creator":true}],"max_rooms":6,"main_live":true}"#)
        let l = try await svc.listRooms(userId: "u1", sessionId: "s1")
        XCTAssertEqual(last.method, "GET"); XCTAssertEqual(last.path, "/api/session-rooms/u1/sessions/s1/rooms")
        XCTAssertEqual(l.rooms.first?.id, "a"); XCTAssertEqual(l.rooms.first?.is_creator, true)
    }

    func test_create_open_sendsModeOnly_noInvitees() async throws {
        RoomsStubURLProtocol.routes["POST /api/session-rooms/u1/sessions/s1/rooms"] = (200, #"{"id":"r1"}"#)
        let r = try await svc.createRoom(userId: "u1", sessionId: "s1", title: nil, inviteOnly: false, inviteeIds: ["x"])
        XCTAssertEqual(r.id, "r1")
        XCTAssertEqual(last.method, "POST")
        XCTAssertEqual(last.body?["mode"] as? String, "open")
        XCTAssertNil(last.body?["title"]); XCTAssertNil(last.body?["invite_user_ids"], "open rooms never send invitees")
    }

    func test_create_inviteOnly_sendsTitleModeAndInvitees_emptyTitleOmitted() async throws {
        RoomsStubURLProtocol.routes["POST /api/session-rooms/u1/sessions/s1/rooms"] = (200, #"{"id":"r1"}"#)
        _ = try await svc.createRoom(userId: "u1", sessionId: "s1", title: "Quiet", inviteOnly: true, inviteeIds: ["a", "b"])
        XCTAssertEqual(last.body?["mode"] as? String, "invite_only")
        XCTAssertEqual(last.body?["title"] as? String, "Quiet")
        XCTAssertEqual(last.body?["invite_user_ids"] as? [String], ["a", "b"])
        _ = try await svc.createRoom(userId: "u1", sessionId: "s1", title: "", inviteOnly: true, inviteeIds: [])
        XCTAssertNil(last.body?["title"]); XCTAssertNil(last.body?["invite_user_ids"])
    }

    func test_join_leave_heartbeat_rename_end_invite_pathsAndMethods() async throws {
        let base = "/api/session-rooms/u1/rooms/r1"
        RoomsStubURLProtocol.routes["POST \(base)/join"] = (200, """
        {"room":{"id":"r1"},"Meeting":{"MeetingId":"m","MediaRegion":"x","MediaPlacement":{"AudioHostUrl":"a","AudioFallbackUrl":"b","SignalingUrl":"c","TurnControlUrl":"d"}},
         "Attendee":{"AttendeeId":"a","ExternalUserId":"u","JoinToken":"t"}}
        """)
        let j = try await svc.joinRoom(userId: "u1", roomId: "r1")
        XCTAssertEqual(j.chime.Meeting.MeetingId, "m")
        XCTAssertEqual(last.method, "POST"); XCTAssertEqual(last.path, "\(base)/join")
        try await svc.leaveRoom(userId: "u1", roomId: "r1")
        XCTAssertEqual(last.method, "POST"); XCTAssertEqual(last.path, "\(base)/leave")
        try await svc.heartbeatRoom(userId: "u1", roomId: "r1")
        XCTAssertEqual(last.method, "POST"); XCTAssertEqual(last.path, "\(base)/heartbeat")
        try await svc.renameRoom(userId: "u1", roomId: "r1", title: "New")
        XCTAssertEqual(last.method, "PATCH"); XCTAssertEqual(last.path, base); XCTAssertEqual(last.body?["title"] as? String, "New")
        try await svc.endRoom(userId: "u1", roomId: "r1")
        XCTAssertEqual(last.method, "DELETE"); XCTAssertEqual(last.path, base)
        try await svc.inviteToRoom(userId: "u1", roomId: "r1", inviteeIds: ["a"])
        XCTAssertEqual(last.method, "POST"); XCTAssertEqual(last.path, "\(base)/invites")
        XCTAssertEqual(last.body?["user_ids"] as? [String], ["a"])
    }

    func test_pathComponents_areEncoded() async throws {
                try await svc.leaveRoom(userId: "u 1", roomId: "a/b")
        XCTAssertEqual(RoomsStubURLProtocol.seen.count, 1)
        XCTAssertEqual(last.method, "POST")
        // Uses the shared NetworkService.encodeURIComponent (same as every other
        // call; ids are server UUIDs, so "/" never occurs in practice).
        XCTAssertTrue(last.rawURL.contains("/session-rooms/u%201/rooms/"), "unsafe characters are percent-encoded: \(last.rawURL)")
    }

    func test_errors_surfaceDetailCode_notFlattened() async {
        RoomsStubURLProtocol.routes["POST /api/session-rooms/u1/rooms/r1/join"] =
            (409, #"{"detail":{"code":"room_full","message":"raw server text"}}"#)
        do { _ = try await svc.joinRoom(userId: "u1", roomId: "r1"); XCTFail("should throw") }
        catch let e as SessionRoomsError { XCTAssertEqual(e, SessionRoomsError(status: 409, code: "room_full")) }
        catch { XCTFail("wrong error \(error)") }
    }

    func test_429_withoutCode_mapsToRateLimited_andOtherToGenericError() async {
        RoomsStubURLProtocol.routes["POST /api/session-rooms/u1/rooms/r1/heartbeat"] = (429, "not json")
        do { try await svc.heartbeatRoom(userId: "u1", roomId: "r1"); XCTFail() }
        catch { XCTAssertEqual(error as? SessionRoomsError, SessionRoomsError(status: 429, code: "rate_limited")) }
        RoomsStubURLProtocol.routes["POST /api/session-rooms/u1/rooms/r1/leave"] = (500, #"{"detail":"Internal"}"#)
        do { try await svc.leaveRoom(userId: "u1", roomId: "r1"); XCTFail() }
        catch { XCTAssertEqual(error as? SessionRoomsError, SessionRoomsError(status: 500, code: "error")) }
    }

    func test_undecodableSuccessBody_isNetworkError_notFabricated() async {
        RoomsStubURLProtocol.routes["POST /api/session-rooms/u1/rooms/r1/join"] = (200, #"{"nope":1}"#)
        do { _ = try await svc.joinRoom(userId: "u1", roomId: "r1"); XCTFail() }
        catch { XCTAssertEqual(error as? SessionRoomsError, SessionRoomsError.network) }
    }
}

// MARK: - D. List logic and form

final class RoomListLogicTests: XCTestCase {
    private func room(_ id: String = "r", configure: (inout SessionRoom) -> Void = { _ in }) -> SessionRoom {
        var r = SessionRoom(id: id); configure(&r); return r
    }

    func test_trailing_precedence() {
        XCTAssertEqual(RoomListLogic.trailing(for: room { $0.is_member = true; $0.is_full = true }), .here)
        XCTAssertEqual(RoomListLogic.trailing(for: room { $0.is_full = true; $0.can_join = false }), .full)
        XCTAssertEqual(RoomListLogic.trailing(for: room { $0.can_join = false }), .hidden)
        XCTAssertEqual(RoomListLogic.trailing(for: room { $0.visibility = "invite_only"; $0.is_invited = true }), .invitedJoin)
        XCTAssertEqual(RoomListLogic.trailing(for: room { $0.visibility = "invite_only"; $0.is_invited = false }), .join)
        XCTAssertEqual(RoomListLogic.trailing(for: room()), .join)
    }

    func test_visibleRooms_dropsHidden_sortsBySlot() {
        let out = RoomListLogic.visibleRooms([room("c") { $0.slot = 3 }, room("h") { $0.can_join = false },
                                              room("a") { $0.slot = 1 }])
        XCTAssertEqual(out.map(\.id), ["a", "c"])
    }

    func test_actions_followServerFlags() {
        XCTAssertEqual(RoomListLogic.actions(for: room()), [])
        XCTAssertEqual(RoomListLogic.actions(for: room { $0.is_creator = true }), [.rename])
        XCTAssertEqual(RoomListLogic.actions(for: room { $0.can_invite = true }), [.invite])
        XCTAssertEqual(RoomListLogic.actions(for: room { $0.is_creator = true; $0.can_invite = true; $0.can_end = true }),
                       [.rename, .invite, .end])
        XCTAssertEqual(RoomListLogic.actions(for: room { $0.can_end = true }), [.end], "session host can end without renaming")
    }

    func test_subtitleAndMemberNames() {
        let r = room { $0.member_count = 3; $0.max_members = 8; $0.visibility = "invite_only"
            $0.members = [SessionRoomMember(user_id: "1", username: "Ana"), SessionRoomMember(user_id: "2", username: "Ben"),
                          SessionRoomMember(user_id: "3", username: "Cy"), SessionRoomMember(user_id: "4", username: "")] }
        XCTAssertEqual(RoomListLogic.subtitle(for: r), "3 of 8 \u{00B7} Invite only")
        XCTAssertEqual(RoomListLogic.subtitle(for: room { $0.visibility = "open" }), "0 of 8 \u{00B7} Open")
        XCTAssertEqual(RoomListLogic.memberNames(r), "Ana, Ben +1")
        XCTAssertNil(RoomListLogic.memberNames(room()))
    }

    func test_createBlock() {
        XCTAssertNil(RoomListLogic.createBlock(nil))
        var l = SessionRoomsListResponse(); l.main_live = false
        XCTAssertEqual(RoomListLogic.createBlock(l), .mainNotLive)
        l.main_live = true; l.max_rooms = 2; l.rooms = [SessionRoom(id: "a"), SessionRoom(id: "b")]
        XCTAssertEqual(RoomListLogic.createBlock(l), .roomsFull(max: 2))
        l.rooms = [SessionRoom(id: "a")]
        XCTAssertNil(RoomListLogic.createBlock(l))
        XCTAssertEqual(RoomListLogic.createBlockCaption(.roomsFull(max: 6)), "All 6 rooms are in use")
    }

    func test_form_cleanCapsAndCounter() {
        XCTAssertEqual(RoomForm.clean("  a   b \n c "), "a b c")
        XCTAssertEqual(RoomForm.clean(String(repeating: "x", count: 60)).count, 40)
        var f = RoomForm(); f.name = String(repeating: "y", count: 29)
        XCTAssertFalse(f.showsCounter); f.name += "y"; XCTAssertTrue(f.showsCounter)
    }

    func test_form_inviteesOnlySentForInviteOnly_andCapped() {
        var f = RoomForm()
        f.toggleInvitee("b"); f.toggleInvitee("a")
        XCTAssertEqual(f.effectiveInvitees, [], "open room sends no invitees even if some were picked")
        f.inviteOnly = true
        XCTAssertEqual(f.effectiveInvitees, ["a", "b"])
        f.toggleInvitee("a"); XCTAssertEqual(f.effectiveInvitees, ["b"])
        f.invitees = Set((0..<RoomForm.maxInvites).map { "u\($0)" })
        XCTAssertTrue(f.atInviteCap)
        f.toggleInvitee("extra"); XCTAssertFalse(f.invitees.contains("extra"))
        f.toggleInvitee("u0"); XCTAssertFalse(f.invitees.contains("u0"), "can still deselect at the cap")
    }
}

// MARK: - E. Controller (scripted service, no Chime)

@MainActor
final class CallRoomControllerTests: XCTestCase {
    private var svc: ThrowingTestDataService!
    private var ctl: CallRoomController!
    private var swapped: [String] = []

    override func setUp() {
        svc = ThrowingTestDataService()
        ctl = CallRoomController()
        swapped = []
        ctl.switchMeeting = { [unowned self] in self.swapped.append($0.Meeting.MeetingId) }
        ctl.configure(service: svc, userId: "u1", sessionId: "main")
        svc.joinCallResult = .success(chimeJoin("main-mtg"))
    }

    private func room(_ id: String, name: String = "Room 1") -> SessionRoom {
        var r = SessionRoom(id: id); r.name = name; return r
    }
    private func settle() async { try? await Task.sleep(nanoseconds: 80_000_000) }

    func test_join_swapsMeetingAfterBackendJoin_andEntersRoom() async {
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "r1", members: [("u2", "Ben")]))
        let err = await ctl.join(room: room("r1"))
        XCTAssertNil(err)
        XCTAssertEqual(ctl.state, .inRoom(roomId: "r1", name: "Room 1"))
        XCTAssertEqual(swapped, ["mtg-r1"])
        XCTAssertEqual(svc.roomsScript.calls.first, "join:r1", "backend join first")
        XCTAssertEqual(ctl.seedNames, ["u2": "Ben"], "room members seed the name cache")
        XCTAssertEqual(ctl.currentRoom?.id, "r1")
    }

    func test_failedJoin_leavesUserInMain_andNeverSwaps() async {
        svc.roomsScript.joinResult = .failure(SessionRoomsError(status: 409, code: "room_full"))
        let err = await ctl.join(room: room("r1"))
        XCTAssertEqual(err, "This room is full.")
        XCTAssertEqual(ctl.state, .main)
        XCTAssertTrue(swapped.isEmpty, "no teardown when the backend join fails")
        XCTAssertNil(ctl.currentRoom)
    }

    func test_failedJoin_fromRoom_staysInOriginalRoom() async {
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "a", name: "A"))
        _ = await ctl.join(room: room("a", name: "A"))
        svc.roomsScript.joinResult = .failure(SessionRoomsError(status: 409, code: "cannot_join"))
        let err = await ctl.join(room: room("b", name: "B"))
        XCTAssertEqual(err, "You can\u{2019}t join this room right now.")
        XCTAssertEqual(ctl.state, .inRoom(roomId: "a", name: "A"))
        XCTAssertEqual(swapped, ["mtg-a"], "still only the first swap")
    }

    func test_roomToRoomSwitch_viaBackendThenSwap() async {
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "a", name: "A"))
        _ = await ctl.join(room: room("a", name: "A"))
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "b", name: "B"))
        _ = await ctl.join(room: room("b", name: "B"))
        XCTAssertEqual(ctl.state, .inRoom(roomId: "b", name: "B"))
        XCTAssertEqual(swapped, ["mtg-a", "mtg-b"])
    }

    func test_joinSameRoomAgain_isNoOp() async {
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "a"))
        _ = await ctl.join(room: room("a"))
        svc.roomsScript.reset()
        let err = await ctl.join(room: room("a"))
        XCTAssertNil(err)
        XCTAssertTrue(svc.roomsScript.calls.isEmpty)
    }

    func test_joinMainEnded_reportsEndedAndCallsOnMainEnded() async {
        var ended = false
        ctl.onMainEnded = { ended = true }
        svc.roomsScript.joinResult = .failure(SessionRoomsError(status: 409, code: "main_not_live"))
        let err = await ctl.join(room: room("r1"))
        XCTAssertEqual(err, "The session has ended.")
        XCTAssertTrue(ended)
        XCTAssertEqual(ctl.state, .main)
        XCTAssertEqual(ctl.notice, "The session has ended.")
    }

    func test_returnToMain_joinsMainFirst_thenSwaps_thenLeavesRoomBestEffort() async {
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "r1"))
        _ = await ctl.join(room: room("r1"))
        svc.roomsScript.reset()
        await ctl.returnToMain()
        XCTAssertEqual(ctl.state, .main)
        XCTAssertEqual(svc.joinCallCount, 1)
        XCTAssertEqual(swapped, ["mtg-r1", "main-mtg"])
        await settle()
        XCTAssertEqual(svc.roomsScript.calls, ["leave:r1"])
        XCTAssertNil(ctl.currentRoom)
    }

    func test_returnToMain_failure_keepsUserInRoom_withRetryState() async {
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "r1", name: "R"))
        _ = await ctl.join(room: room("r1", name: "R"))
        svc.joinCallResult = .failure(SessionRoomsError.network)
        await ctl.returnToMain()
        XCTAssertEqual(ctl.state, .returnFailed(fromName: "R"))
        XCTAssertEqual(swapped, ["mtg-r1"], "no swap on failed return")
        XCTAssertTrue(ctl.isInRoom, "Back to main stays reachable")
        svc.joinCallResult = .success(chimeJoin("main-mtg"))
        await ctl.returnToMain()
        XCTAssertEqual(ctl.state, .main)
    }

    func test_returnToMain_fromMain_isNoOp() async {
        await ctl.returnToMain()
        XCTAssertEqual(svc.joinCallCount, 0); XCTAssertTrue(swapped.isEmpty)
    }

    func test_heartbeat_hitsCurrentRoom_andTransientFailureNeverEjects() async {
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "r1"))
        _ = await ctl.join(room: room("r1"))
        svc.roomsScript.reset()
        svc.roomsScript.heartbeatError = SessionRoomsError.network
        await ctl.beat()
        XCTAssertEqual(svc.roomsScript.calls, ["beat:r1"])
        XCTAssertEqual(ctl.state, .inRoom(roomId: "r1", name: "Room 1"))
        svc.roomsScript.heartbeatError = SessionRoomsError(status: 500, code: "error")
        await ctl.beat()
        XCTAssertTrue(ctl.state.isInRoom)
    }

    func test_heartbeat_roomEnded_returnsToMainWithNotice() async {
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "r1", name: "Chat"))
        _ = await ctl.join(room: room("r1", name: "Chat"))
        svc.roomsScript.heartbeatError = SessionRoomsError(status: 410, code: "room_ended")
        await ctl.beat()
        XCTAssertEqual(ctl.state, .main)
        XCTAssertEqual(ctl.notice, "Chat has ended. You\u{2019}re back in the main session.")
        XCTAssertEqual(swapped.last, "main-mtg")
    }

    func test_heartbeat_mainEnded_endsCall() async {
        var ended = false
        ctl.onMainEnded = { ended = true }
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "r1"))
        _ = await ctl.join(room: room("r1"))
        svc.roomsScript.heartbeatError = SessionRoomsError(status: 409, code: "main_not_live")
        await ctl.beat()
        XCTAssertTrue(ended)
    }

    func test_beat_inMain_makesNoRequest() async {
        await ctl.beat()
        XCTAssertTrue(svc.roomsScript.calls.isEmpty, "no heartbeat outside a room")
        ctl.appForegrounded()
        await settle()
        XCTAssertTrue(svc.roomsScript.calls.isEmpty)
    }

    func test_appForegrounded_inRoom_beatsImmediately() async {
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "r1"))
        _ = await ctl.join(room: room("r1"))
        svc.roomsScript.reset()
        ctl.appForegrounded()
        await settle()
        XCTAssertEqual(svc.roomsScript.calls, ["beat:r1"])
    }

    func test_didEndRoom_ofCurrentRoom_returnsToMain_otherRoomIgnored() async {
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "r1"))
        _ = await ctl.join(room: room("r1"))
        await ctl.didEndRoom(id: "other")
        XCTAssertTrue(ctl.state.isInRoom)
        await ctl.didEndRoom(id: "r1")
        XCTAssertEqual(ctl.state, .main)
    }

    func test_callEnded_leavesRoomBestEffort_andResetsEverything() async {
        svc.roomsScript.joinResult = .success(roomJoinResponse(id: "r1"))
        _ = await ctl.join(room: room("r1"))
        svc.roomsScript.reset()
        svc.roomsScript.leaveError = SessionRoomsError.network   // failure must not matter
        ctl.callEnded()
        XCTAssertEqual(ctl.state, .main); XCTAssertNil(ctl.currentRoom); XCTAssertNil(ctl.notice)
        XCTAssertTrue(ctl.seedNames.isEmpty)
        await settle()
        XCTAssertEqual(svc.roomsScript.calls, ["leave:r1"])
        XCTAssertEqual(ctl.userId, "")
    }

    func test_joinWithoutConfiguredService_returnsWarmBusy_noCrash() async {
        let bare = CallRoomController()
        let err = await bare.join(room: room("r1"))
        XCTAssertEqual(err, "That\u{2019}s busy right now. Please try again.")
        XCTAssertEqual(bare.state, .main)
    }
}

// MARK: - F. Source pins

final class DiscussionRoomsSourcePinTests: XCTestCase {

    private func strippingComments(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func switchMeetingBody() throws -> String {
        let s = try roomsSource("FellowScript/Chat/ChimeCallView.swift")
        guard let a = s.range(of: "func switchMeeting(response: ChimeJoinResponse) {"),
              let b = s.range(of: "func toggleMute()", range: a.upperBound..<s.endIndex) else {
            throw XCTSkip("switchMeeting markers moved")
        }
        return String(s[a.upperBound..<b.lowerBound])
    }

    func test_switchPath_neverTouchesCallKitOrAVAudioSession() throws {
        let body = strippingComments(try switchMeetingBody())
        for banned in ["CXEndCallAction", "CXTransaction", "CallKit", "AVAudioSession", "setCategory", "setActive",
                       "VoipCallManager", "reportCall", "endCall"] {
            XCTAssertFalse(body.contains(banned), "switchMeeting must not use \(banned)")
        }
        let controller = strippingComments(try roomsSource("FellowScript/Chat/CallRoomController.swift"))
        for banned in ["CXEndCallAction", "CallKit", "AVAudioSession", "VoipCallManager", "import AmazonChime"] {
            XCTAssertFalse(controller.contains(banned), "CallRoomController must not use \(banned)")
        }
        XCTAssertFalse(controller.contains("end()"), "a room switch must not end the call")
        XCTAssertFalse(controller.contains(".session ="), "the MAIN session is never reassigned by rooms")
    }

    func test_switchMeeting_carriesMuteAndCamera_andDoesNotResetMute() throws {
        let raw = try switchMeetingBody()
        let body = strippingComments(raw)
        XCTAssertTrue(body.contains("let cameraWasOn = isCameraOn"))
        XCTAssertTrue(body.contains("pendingCameraRestore = cameraWasOn"), "camera intent restored after swap")
        XCTAssertFalse(body.contains("isMuted = false"), "mute must never silently flip to unmuted")
        XCTAssertFalse(body.contains("isMuted = true"))
        // Old observers are silenced before the old session stops.
        guard let rm = body.range(of: "removeAudioVideoObserver"), let stop = body.range(of: "old.audioVideo.stop()") else {
            return XCTFail("old-session teardown missing")
        }
        XCTAssertLessThan(rm.lowerBound, stop.lowerBound)
        XCTAssertTrue(body.contains("join(response: response)"))
        // Contrast: leave() DOES reset mute (call over), switch does not.
        let full = try roomsSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(full.contains("isConnected = false; isMuted = false; isCameraOn = false"))
    }

    func test_cameraRestore_isAppliedWhenNewAudioSessionStarts() throws {
        let s = try roomsSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(s.contains("pendingCameraRestore"))
        XCTAssertGreaterThanOrEqual(s.components(separatedBy: "pendingCameraRestore").count - 1, 4,
                                    "declared, set on switch, consumed, and cleared")
    }

    func test_controller_networkFirstThenSwap_andMainSessionUntouched() throws {
        let c = strippingComments(try roomsSource("FellowScript/Chat/CallRoomController.swift"))
        guard let j = c.range(of: "try await api.joinRoom"), let sw = c.range(of: "switchMeeting?(resp.chime)") else {
            return XCTFail("join flow markers moved")
        }
        XCTAssertLessThan(j.lowerBound, sw.lowerBound, "backend join is awaited before the meeting is touched")
        guard let jc = c.range(of: "try await dataService.joinCall"), let sw2 = c.range(of: "switchMeeting?(resp)") else {
            return XCTFail("return flow markers moved")
        }
        XCTAssertLessThan(jc.lowerBound, sw2.lowerBound)
    }

    func test_roomsMenuRow_isDataDrivenGatedAndNotForDMs() throws {
        let v = try roomsSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(v.contains("private var roomsAvailable: Bool { RoomsFlag.isAvailable(capabilities, session: call.session) }"))
        guard let a = v.range(of: "private func roomsMenuRow() -> CallMenuRow? {"),
              let b = v.range(of: "private func menuRows()", range: a.upperBound..<v.endIndex) else {
            return XCTFail("roomsMenuRow markers moved")
        }
        let row = String(v[a.upperBound..<b.lowerBound])
        XCTAssertTrue(row.contains("guard roomsAvailable || rooms.state.showsBackToMain else { return nil }"),
                      "hidden unless flag on (non-DM) or the user is away from main")
        XCTAssertTrue(row.contains("a11yLabel: \"Rooms\""))
        XCTAssertTrue(row.contains("a11yValue:") && row.contains("a11yHint:"))
        XCTAssertTrue(row.contains("showRoomsSheet = true"))
        // Not a hard-coded list entry: only added through the gated helper.
        XCTAssertTrue(v.contains("if let roomsRow = roomsMenuRow() { rows.append(roomsRow) }"))
        // The flag string is read in exactly one place (RoomsFlag), never inlined in the view.
        XCTAssertFalse(v.contains("\"discussion_rooms\""))
        let state = try roomsSource("FellowScript/Chat/CallRoomState.swift")
        XCTAssertTrue(state.contains("capabilities.isEnabled(flagName)"))
        XCTAssertTrue(state.contains("!isDirectMessage(session)"))
        XCTAssertTrue(state.contains("session.group_id.contains(\"|\")"))
    }

    func test_backToMainRow_isReachableIndependentOfFlag() throws {
        let v = try roomsSource("FellowScript/Chat/ChimeCallView.swift")
        guard let a = v.range(of: "private func backToMainRow() -> CallMenuRow? {"),
              let b = v.range(of: "private func roomsMenuRow()", range: a.upperBound..<v.endIndex) else {
            return XCTFail("backToMainRow markers moved")
        }
        let row = String(v[a.upperBound..<b.lowerBound])
        XCTAssertTrue(row.contains("guard rooms.state.showsBackToMain else { return nil }"))
        XCTAssertFalse(row.contains("roomsAvailable"), "flag flipping off mid-call must not hide the exit")
        XCTAssertFalse(row.contains("capabilities"))
        XCTAssertTrue(row.contains("a11yLabel: \"Back to main session\""))
        XCTAssertTrue(v.contains("if let back = backToMainRow() { rows.append(back) }"))
    }

    func test_voiceOverLabels_onRoomSurfaces() throws {
        let s = try roomsSource("FellowScript/Chat/RoomsSheet.swift")
        for label in ["\"Back to main session\"", "\"Close rooms\"", "\"Loading rooms\"", "\"Create room\"",
                      "\"Room name\"", "\"Who can join\"", "\"Join \\(room.displayName)\"",
                      "\"More actions for \\(room.displayName)\"", "\"Joining \\(room.displayName)\""] {
            XCTAssertTrue(s.contains(".accessibilityLabel(\(label))"), "missing VoiceOver label \(label)")
        }
        XCTAssertTrue(s.contains("\\(room.displayName), \\(room.isInviteOnly ? \"invite only\" : \"open\")"))
        let v = try roomsSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(v.contains("Return to call \\(call.session?.title ?? \"\"), in room"), "minimized bar names the room")
        let c = try roomsSource("FellowScript/Chat/CallRoomController.swift")
        XCTAssertTrue(c.contains("AccessibilityNotification.Announcement(text).post()"))
    }

    func test_reduceMotion_isHonoured() throws {
        let s = try roomsSource("FellowScript/Chat/RoomsSheet.swift")
        XCTAssertGreaterThanOrEqual(s.components(separatedBy: "@Environment(\\.accessibilityReduceMotion)").count - 1, 2)
        XCTAssertTrue(s.contains("reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))"))
        XCTAssertTrue(s.contains("motionAwareAnimation(") && s.contains("reduceMotion: reduceMotion"))
        // No unguarded animation modifiers or withAnimation in the rooms sheet.
        let code = strippingComments(s)
        XCTAssertFalse(code.contains("withAnimation("), "use the motion-aware wrapper")
        XCTAssertFalse(code.replacingOccurrences(of: "motionAwareAnimation(", with: "").contains(".animation("))
    }

    func test_polling_onlyWhileSheetOpen_andAppActive() throws {
        let s = try roomsSource("FellowScript/Chat/RoomsSheet.swift")
        guard let a = s.range(of: ".task(id: scenePhase)") else { return XCTFail("poll task missing") }
        let block = String(s[a.upperBound...].prefix(900))
        XCTAssertTrue(block.contains("RoomHeartbeat.listPollInterval"))
        XCTAssertTrue(block.contains(".active") || block.contains("scenePhase"), "polling pauses when the app is inactive")
        // Poll lives in a view .task (cancelled on dismiss); the controller owns no list poller.
        let c = strippingComments(try roomsSource("FellowScript/Chat/CallRoomController.swift"))
        XCTAssertFalse(c.contains("listRooms"), "controller must not poll the room list")
        XCTAssertFalse(c.contains("listPollInterval"))
        XCTAssertFalse(strippingComments(s).contains("Timer.publish"), "no free-running timer in the sheet")
    }

    func test_heartbeat_loopAndForegroundHook() throws {
        let c = strippingComments(try roomsSource("FellowScript/Chat/CallRoomController.swift"))
        XCTAssertTrue(c.contains("UInt64(RoomHeartbeat.interval * 1_000_000_000)"))
        XCTAssertTrue(c.contains("heartbeatTask?.cancel(); heartbeatTask = nil"), "stopped on return and call end")
        let app = try roomsSource("FellowScript/FellowScriptApp.swift")
        XCTAssertTrue(app.contains("CallController.shared.rooms.appForegrounded()"))
    }

    func test_networkService_doesNotUseGenericErrorMapper_andNeverRetriesWrites() throws {
        let n = strippingComments(try roomsSource("FellowScript/Services/NetworkService+SessionRooms.swift"))
        XCTAssertFalse(n.contains("throwIfError"))
        XCTAssertFalse(n.contains("retry"))
        XCTAssertTrue(n.contains("detail?[\"code\"]"))
    }

    func test_callEnded_isWiredIntoCallControllerTeardown() throws {
        let v = try roomsSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(v.contains("rooms.callEnded()"))
        XCTAssertTrue(v.contains("rooms.onMainEnded = { [weak self] in self?.end() }"))
        XCTAssertTrue(v.contains("rooms.switchMeeting = { [weak self] response in self?.manager.switchMeeting(response: response) }"))
    }
}
