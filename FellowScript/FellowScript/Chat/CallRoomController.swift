// Discussion rooms: call-side controller (task 20261009-discussion-rooms,
// frontend step 7, design-notes.md sections 4-6).
//
// Owns the room-switch state machine and the heartbeat. It deliberately knows
// nothing about the Chime SDK: the actual media swap is an injected closure
// (`switchMeeting`) set by CallController, which keeps this file buildable and
// testable without the SDK.
//
// HARD CONSTRAINTS (acceptance 6), pinned by source-pin tests:
//  * CallController.session (the MAIN FSSession) never changes here.
//  * No CallKit / VoipCallManager / CXEndCallAction, no AVAudioSession
//    category or activation calls, and no CallController.end() on a switch.
//    A room is invisible to CallKit; the one CXCall belongs to the main session.
//  * Network first, teardown second: the backend join (or main join-call) is
//    awaited BEFORE the current meeting is touched, so a failure leaves the
//    user exactly where they were.

import SwiftUI
import Combine

@MainActor
final class CallRoomController: ObservableObject {
    @Published private(set) var state: CallRoomState = .main
    /// Warm, self-dismissing banner text shown under the header stack.
    @Published private(set) var notice: String? = nil
    /// Members of the room just joined, keyed by user_id, to seed the name cache.
    @Published private(set) var seedNames: [String: String] = [:]
    /// The room I am in (for "n of max" and the header); nil in main.
    @Published private(set) var currentRoom: SessionRoom? = nil

    /// Swaps the Chime meeting (set by CallController; SDK-gated there).
    var switchMeeting: ((ChimeJoinResponse) -> Void)?
    /// Ends the whole call (main ended); set by CallController.
    var onMainEnded: (() -> Void)?

    private(set) var userId = ""
    private(set) var sessionId = ""
    private var dataService: DataServiceProtocol?
    private var activeRoomId: String?
    private var heartbeatTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    var api: SessionRoomsServiceProtocol? { dataService as? SessionRoomsServiceProtocol }
    var isInRoom: Bool { state.showsBackToMain }

    // MARK: Lifecycle

    func configure(service: DataServiceProtocol, userId: String, sessionId: String) {
        self.dataService = service
        self.userId = userId
        self.sessionId = sessionId
    }

    /// Call teardown. Best-effort room leave first; failure never blocks ending.
    func callEnded() {
        if let roomId = activeRoomId, let api, !userId.isEmpty {
            let uid = userId
            Task { try? await api.leaveRoom(userId: uid, roomId: roomId) }
        }
        heartbeatTask?.cancel(); heartbeatTask = nil
        noticeTask?.cancel(); noticeTask = nil
        state = .main; notice = nil; currentRoom = nil; activeRoomId = nil
        seedNames = [:]
        dataService = nil; userId = ""; sessionId = ""
    }

    // MARK: Join / switch

    /// Joins `room`. Returns a warm error message on failure (nil on success);
    /// on failure nothing was torn down and the user stays where they were.
    @discardableResult
    func join(room: SessionRoom) async -> String? {
        guard !state.isBusy, let api, !userId.isEmpty else { return RoomCopy.message(forCode: "busy", action: .join) }
        if state.roomId == room.id { return nil }
        let previous = state
        let uid = userId
        state = state.beginJoin(roomId: room.id, name: room.displayName)
        do {
            let resp = try await api.joinRoom(userId: userId, roomId: room.id)
            // The call may have ended while the request was in flight.
            guard dataService != nil, !sessionId.isEmpty else {
                Task { try? await api.leaveRoom(userId: uid, roomId: room.id) }
                return nil
            }
            switchMeeting?(resp.chime)
            activeRoomId = room.id
            currentRoom = resp.room
            state = .inRoom(roomId: room.id, name: resp.room.displayName)
            seedNames = Dictionary(resp.room.members.map { ($0.user_id, $0.username) },
                                   uniquingKeysWith: { a, _ in a })
            startHeartbeat()
            announce("Joined \(resp.room.displayName)")
            return nil
        } catch {
            state = state.joinFailed(previous: previous)
            if RoomCopy.isMainEnded(error) { mainEnded(); return RoomCopy.mainEnded }
            let message = RoomCopy.message(for: error, action: .join)
            announce(message)
            return message
        }
    }

    // MARK: Back to main

    /// Network first (main join-call), then swap, then a best-effort room leave.
    func returnToMain() async {
        guard state.showsBackToMain, let dataService, !userId.isEmpty else { return }
        if case .returning = state { return }
        let roomId = activeRoomId
        state = state.beginReturn()
        do {
            let resp = try await dataService.joinCall(userId: userId, sessionId: sessionId)
            guard self.dataService != nil else { return }   // call ended meanwhile
            switchMeeting?(resp)
            heartbeatTask?.cancel(); heartbeatTask = nil
            state = state.returnSucceeded()
            currentRoom = nil; activeRoomId = nil
            if let roomId, let api {
                let uid = userId
                Task { try? await api.leaveRoom(userId: uid, roomId: roomId) }
            }
            announce("Back in the main session")
        } catch {
            state = state.returnFailed()
            announce(RoomCopy.returnFailed)
        }
    }

    // MARK: Room management used by the sheets

    /// Best-effort refresh of my own room view (capacity line); never throws.
    func noteRoomsList(_ list: SessionRoomsListResponse) {
        if let id = activeRoomId, let r = list.rooms.first(where: { $0.id == id }) {
            currentRoom = r
        }
    }

    /// A room I administer was ended (maybe my own current one).
    func didEndRoom(id: String) async {
        if id == activeRoomId { await roomGone(fallbackName: currentRoom?.displayName) }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(RoomHeartbeat.interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.beat()
            }
        }
    }

    /// One heartbeat. Also called right away on foreground.
    func beat() async {
        guard let api, let roomId = activeRoomId, state.showsBackToMain, !userId.isEmpty else { return }
        do {
            try await api.heartbeatRoom(userId: userId, roomId: roomId)
        } catch {
            switch RoomHeartbeat.outcome(for: error) {
            case .keepGoing: break
            case .mainEnded: mainEnded()
            case .roomGone: await roomGone(fallbackName: currentRoom?.displayName)
            }
        }
    }

    func appForegrounded() {
        guard activeRoomId != nil else { return }
        Task { @MainActor in await self.beat() }
    }

    // MARK: Ended states

    private func roomGone(fallbackName: String?) async {
        let name = state.roomName ?? fallbackName ?? "The room"
        announce("\(name) has ended, returning to the main session")
        if case .returnFailed = state { await returnToMain(); return }
        if case .returning = state { return }
        await returnToMain()
        if state == .main { showNotice(RoomCopy.roomEndedNotice(name)) }
    }

    private func mainEnded() {
        showNotice(RoomCopy.mainEnded)
        onMainEnded?()
    }

    // MARK: Notices

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.notice == text { self.notice = nil }
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
