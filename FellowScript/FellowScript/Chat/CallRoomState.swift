// Pure, SDK-free logic for discussion rooms (task 20261009-discussion-rooms,
// frontend step 7, design-notes.md). Everything here is a plain value type or
// static function so it can be unit tested without the Chime SDK, SwiftUI
// hosting, or a network. The room controller and sheets only wire these up.

import Foundation

// MARK: - Feature gate

enum RoomsFlag {
    static let flagName = "discussion_rooms"

    /// Fail-closed: absent / false / unknown means hidden. A DM session
    /// (group_id holds "uidA|uidB") has nobody to split from: hide, don't disable.
    static func isAvailable(_ capabilities: FSCapabilities, session: FSSession?) -> Bool {
        guard capabilities.isEnabled(flagName), let session else { return false }
        return !isDirectMessage(session)
    }

    static func isDirectMessage(_ session: FSSession) -> Bool { session.group_id.contains("|") }
}

// MARK: - Room-switch state machine (design-notes.md section 4)

enum CallRoomState: Equatable {
    case main
    case joining(roomId: String, name: String)
    case inRoom(roomId: String, name: String)
    case returning(fromName: String)
    /// Return-to-main failed; the call screen shows Try again / End call.
    case returnFailed(fromName: String)

    var isInRoom: Bool { if case .inRoom = self { return true } else { return false } }
    var isBusy: Bool {
        switch self {
        case .joining, .returning: return true
        default: return false
        }
    }
    /// True while the user is, or is about to be, away from the main meeting:
    /// the Back to main exits must stay reachable.
    var showsBackToMain: Bool {
        switch self {
        case .inRoom, .returning, .returnFailed: return true
        default: return false
        }
    }
    var roomId: String? {
        switch self {
        case .inRoom(let id, _), .joining(let id, _): return id
        default: return nil
        }
    }
    var roomName: String? {
        switch self {
        case .inRoom(_, let n), .joining(_, let n), .returning(let n), .returnFailed(let n): return n
        case .main: return nil
        }
    }
    /// Name of the room the user currently sits in (not one being joined).
    var currentRoomName: String? {
        switch self {
        case .inRoom(_, let n), .returning(let n), .returnFailed(let n): return n
        default: return nil
        }
    }

    // Transitions. Each returns the new state; invalid ones are no-ops so a
    // late callback can never corrupt the machine.

    func beginJoin(roomId: String, name: String) -> CallRoomState {
        switch self {
        case .main, .inRoom: return .joining(roomId: roomId, name: name)
        default: return self
        }
    }
    func joinSucceeded() -> CallRoomState {
        if case .joining(let id, let n) = self { return .inRoom(roomId: id, name: n) }
        return self
    }
    /// The backend join failed BEFORE anything was torn down: stay exactly
    /// where we were (`previous`).
    func joinFailed(previous: CallRoomState) -> CallRoomState {
        if case .joining = self { return previous }
        return self
    }
    func beginReturn() -> CallRoomState {
        switch self {
        case .inRoom(_, let n), .returnFailed(let n): return .returning(fromName: n)
        default: return self
        }
    }
    func returnSucceeded() -> CallRoomState {
        switch self {
        case .returning: return .main
        default: return self
        }
    }
    func returnFailed() -> CallRoomState {
        if case .returning(let n) = self { return .returnFailed(fromName: n) }
        return self
    }
}

// MARK: - Failures and warm copy (design-notes.md sections 2, 3, 6)

enum RoomAction { case join, create, manage, load }

enum RoomCopy {
    /// Backend `code` -> warm on-brand copy. Raw `detail`/`message` strings are
    /// never shown. Unknown codes fall back to a neutral retry line.
    static func message(forCode code: String, action: RoomAction) -> String {
        switch code {
        case "room_full": return "This room is full."
        case "cannot_join": return "You can\u{2019}t join this room right now."
        case "room_ended", "not_in_room": return "That room has ended."
        case "rooms_full": return "All rooms are in use. Try again once one ends."
        case "rate_limited": return action == .create
            ? "You\u{2019}re opening rooms too quickly. Try again in a minute."
            : "That\u{2019}s busy right now. Please try again."
        case "invalid_invitee", "too_many_invites", "invite_limit":
            return "Some of those people couldn\u{2019}t be invited. Adjust your choices."
        case "title_rejected", "title_too_long": return "Please choose a different name."
        case "forbidden": return "Only the person who made this room can do that."
        case "chime_error", "network":
            return action == .join ? "Couldn\u{2019}t start the room call. Please try again."
                                   : "That\u{2019}s busy right now. Please try again."
        case "busy": return "That\u{2019}s busy right now. Please try again."
        case "main_not_live": return "The session has ended."
        default:
            return action == .load ? "Couldn\u{2019}t load rooms." : "That\u{2019}s busy right now. Please try again."
        }
    }

    static func message(for error: Error, action: RoomAction) -> String {
        let code = (error as? SessionRoomsError)?.code ?? "network"
        return message(forCode: code, action: action)
    }

    /// True when the failure means the main session itself is gone.
    static func isMainEnded(_ error: Error) -> Bool {
        (error as? SessionRoomsError)?.code == "main_not_live"
    }

    /// True when the room is gone (ended, swept, or I was dropped from it).
    static func isRoomGone(_ error: Error) -> Bool {
        guard let e = error as? SessionRoomsError else { return false }
        return e.code == "room_ended" || e.code == "not_in_room" || e.status == 410
    }

    static func roomEndedNotice(_ name: String) -> String {
        "\(name) has ended. You\u{2019}re back in the main session."
    }
    static let screenShareStopped = "Screen sharing stopped because you changed rooms."
    static let returnFailed = "Couldn\u{2019}t reach the main session."
    static let mainEnded = "The session has ended."
}

// MARK: - Room list presentation (design-notes.md section 2)

enum RoomTrailingState: Equatable {
    case here           // "You're here", not tappable
    case full           // "Full", dimmed, not tappable
    case invitedJoin    // "Invited" badge + Join
    case join
    case hidden         // !can_join: defensive, row not rendered
}

enum RoomListLogic {
    /// Precedence: is_member, then is_full, then !can_join, then invited, else join.
    static func trailing(for room: SessionRoom) -> RoomTrailingState {
        if room.is_member { return .here }
        if room.is_full { return .full }
        if !room.can_join { return .hidden }
        if room.isInviteOnly && room.is_invited { return .invitedJoin }
        return .join
    }

    static func visibleRooms(_ rooms: [SessionRoom]) -> [SessionRoom] {
        rooms.filter { trailing(for: $0) != .hidden }.sorted { $0.slot < $1.slot }
    }

    /// Menu actions that apply to a room (overflow menu is hidden when empty).
    enum Action: Equatable { case rename, invite, end }
    static func actions(for room: SessionRoom) -> [Action] {
        var out: [Action] = []
        if room.is_creator { out.append(.rename) }
        if room.can_invite { out.append(.invite) }
        if room.can_end { out.append(.end) }
        return out
    }

    static func subtitle(for room: SessionRoom) -> String {
        "\(room.member_count) of \(room.max_members) \u{00B7} " + (room.isInviteOnly ? "Invite only" : "Open")
    }

    /// "Ana, Ben +2" (first names, at most two shown).
    static func memberNames(_ room: SessionRoom, limit: Int = 2) -> String? {
        let names = room.members.map { $0.username }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(limit).joined(separator: ", ")
        let extra = names.count - limit
        return extra > 0 ? "\(shown) +\(extra)" : shown
    }

    enum CreateBlock: Equatable { case roomsFull(max: Int), mainNotLive }

    /// Why Create is unavailable (nil = enabled).
    static func createBlock(_ list: SessionRoomsListResponse?) -> CreateBlock? {
        guard let list else { return nil }
        if !list.main_live { return .mainNotLive }
        // Invite-only rooms I cannot see still count server-side; this is a
        // best-effort pre-check, `rooms_full` from the server is authoritative.
        if list.rooms.count >= list.max_rooms { return .roomsFull(max: list.max_rooms) }
        return nil
    }

    static func createBlockCaption(_ block: CreateBlock) -> String {
        switch block {
        case .roomsFull(let max): return "All \(max) rooms are in use"
        case .mainNotLive: return "The session call isn\u{2019}t running right now"
        }
    }
}

// MARK: - Create / rename form (design-notes.md section 3)

struct RoomForm: Equatable {
    static let maxNameLength = 40
    static let counterThreshold = 30
    static let maxInvites = 50

    var name = ""
    var inviteOnly = false
    var invitees: Set<String> = []
    var joinAfterCreate = true

    /// Whitespace-collapsed, capped.
    static func clean(_ raw: String) -> String {
        String(raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(maxNameLength))
    }
    var cleanName: String { Self.clean(name) }
    var showsCounter: Bool { name.count >= Self.counterThreshold }
    var atInviteCap: Bool { invitees.count >= Self.maxInvites }

    /// Only an invite-only room sends invitees.
    var effectiveInvitees: [String] { inviteOnly ? Array(invitees).sorted() : [] }

    mutating func toggleInvitee(_ id: String) {
        if invitees.contains(id) { invitees.remove(id) }
        else if !atInviteCap { invitees.insert(id) }
    }
}

// MARK: - Heartbeat (design-notes.md section 5)

enum RoomHeartbeat {
    static let interval: TimeInterval = 30
    static let listPollInterval: TimeInterval = 5

    enum Outcome: Equatable { case keepGoing, roomGone, mainEnded }

    /// Heartbeat failures never eject a user on their own: only the server's
    /// explicit "room is gone" / "main is gone" answers do.
    static func outcome(for error: Error) -> Outcome {
        if RoomCopy.isMainEnded(error) { return .mainEnded }
        if RoomCopy.isRoomGone(error) { return .roomGone }
        return .keepGoing
    }
}
