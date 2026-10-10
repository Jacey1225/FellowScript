// Discussion rooms (task 20261009-discussion-rooms, frontend step 7): wire
// models for /session-rooms/*, no Amazon Chime SDK dependency. Property names
// mirror the backend JSON exactly (snake_case, like FSSession) so the shared
// decoder needs no key strategy.

import Foundation

struct SessionRoomMember: Codable, Equatable, Identifiable {
    var user_id: String
    var username: String
    var id: String { user_id }
}

struct SessionRoom: Codable, Equatable, Identifiable {
    var id: String
    var session_id: String = ""
    var slot: Int = 0
    var title: String = ""
    /// Server-resolved display name ("Room N" when no title was given).
    var name: String = ""
    /// "open" | "invite_only"
    var visibility: String = "open"
    var is_invited: Bool = false
    var can_join: Bool = true
    var member_count: Int = 0
    var members: [SessionRoomMember] = []
    var max_members: Int = 8
    var is_full: Bool = false
    var is_member: Bool = false
    var can_end: Bool = false
    var is_creator: Bool = false
    var can_invite: Bool = false

    var isInviteOnly: Bool { visibility == "invite_only" }
    var displayName: String { name.isEmpty ? (slot > 0 ? "Room \(slot)" : "Room") : name }

    init(id: String) { self.id = id }

    // Lenient decode: every field except `id` falls back, so a server that adds
    // or omits a field never blanks the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        session_id = (try? c.decode(String.self, forKey: .session_id)) ?? ""
        slot = (try? c.decode(Int.self, forKey: .slot)) ?? 0
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        visibility = (try? c.decode(String.self, forKey: .visibility)) ?? "open"
        is_invited = (try? c.decode(Bool.self, forKey: .is_invited)) ?? false
        can_join = (try? c.decode(Bool.self, forKey: .can_join)) ?? true
        member_count = (try? c.decode(Int.self, forKey: .member_count)) ?? 0
        members = (try? c.decode([SessionRoomMember].self, forKey: .members)) ?? []
        max_members = (try? c.decode(Int.self, forKey: .max_members)) ?? 8
        is_full = (try? c.decode(Bool.self, forKey: .is_full)) ?? false
        is_member = (try? c.decode(Bool.self, forKey: .is_member)) ?? false
        can_end = (try? c.decode(Bool.self, forKey: .can_end)) ?? false
        is_creator = (try? c.decode(Bool.self, forKey: .is_creator)) ?? false
        can_invite = (try? c.decode(Bool.self, forKey: .can_invite)) ?? false
    }
}

struct SessionRoomsListResponse: Codable, Equatable {
    var rooms: [SessionRoom] = []
    var max_members: Int = 8
    var max_rooms: Int = 6
    var main_live: Bool = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rooms = (try? c.decode([SessionRoom].self, forKey: .rooms)) ?? []
        max_members = (try? c.decode(Int.self, forKey: .max_members)) ?? 8
        max_rooms = (try? c.decode(Int.self, forKey: .max_rooms)) ?? 6
        main_live = (try? c.decode(Bool.self, forKey: .main_live)) ?? true
    }
}

/// POST /session-rooms/{user}/rooms/{room}/join -> {room, Meeting, Attendee}.
struct SessionRoomJoinResponse: Decodable {
    let room: SessionRoom
    let Meeting: ChimeMeetingInfo
    let Attendee: ChimeAttendeeInfo

    var chime: ChimeJoinResponse { ChimeJoinResponse(Meeting: Meeting, Attendee: Attendee) }
}

/// A rooms API failure. `code` is the backend's machine code (never shown to
/// the user; UI copy comes from `RoomCopy`). `code == "network"` covers
/// transport failures and undecodable bodies.
struct SessionRoomsError: Error, Equatable {
    let status: Int
    let code: String

    static let network = SessionRoomsError(status: 0, code: "network")
}

/// Kept separate from DataServiceProtocol on purpose: adding requirements to
/// that protocol would force every test double to change. Only NetworkService
/// conforms; a mock/nil service simply means "no rooms".
protocol SessionRoomsServiceProtocol {
    func listRooms(userId: String, sessionId: String) async throws -> SessionRoomsListResponse
    func createRoom(userId: String, sessionId: String, title: String?, inviteOnly: Bool, inviteeIds: [String]) async throws -> SessionRoom
    func joinRoom(userId: String, roomId: String) async throws -> SessionRoomJoinResponse
    func leaveRoom(userId: String, roomId: String) async throws
    func heartbeatRoom(userId: String, roomId: String) async throws
    func renameRoom(userId: String, roomId: String, title: String) async throws
    func endRoom(userId: String, roomId: String) async throws
    func inviteToRoom(userId: String, roomId: String, inviteeIds: [String]) async throws
}
