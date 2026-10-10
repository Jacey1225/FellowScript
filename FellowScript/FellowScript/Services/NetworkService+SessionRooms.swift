// NetworkService+SessionRooms.swift: /session-rooms/* calls (task
// 20261009-discussion-rooms, frontend step 7). Deliberately NOT routed through
// request()/throwIfError(): rooms need the backend's machine `detail.code`
// (room_full, main_not_live, ...) which the generic mapper flattens into
// "Server error N". Raw server text is never surfaced; the UI maps `code` to
// warm copy (RoomCopy). Writes are never retried.

import Foundation

extension NetworkService: SessionRoomsServiceProtocol {

    private func roomsCall(_ path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw SessionRoomsError.network
        }
        guard let http = response as? HTTPURLResponse else { throw SessionRoomsError.network }
        if http.statusCode >= 400 {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = obj?["detail"] as? [String: Any]
            let code = (detail?["code"] as? String) ?? (http.statusCode == 429 ? "rate_limited" : "error")
            throw SessionRoomsError(status: http.statusCode, code: code)
        }
        return data
    }

    private func roomsPath(_ userId: String, _ tail: String) -> String {
        "/session-rooms/\(encodeURIComponent(userId))/\(tail)"
    }

    func listRooms(userId: String, sessionId: String) async throws -> SessionRoomsListResponse {
        let data = try await roomsCall(roomsPath(userId, "sessions/\(encodeURIComponent(sessionId))/rooms"), method: "GET")
        guard let r = decode(SessionRoomsListResponse.self, from: data) else { throw SessionRoomsError.network }
        return r
    }

    func createRoom(userId: String, sessionId: String, title: String?, inviteOnly: Bool, inviteeIds: [String]) async throws -> SessionRoom {
        var body: [String: Any] = ["mode": inviteOnly ? "invite_only" : "open"]
        if let title, !title.isEmpty { body["title"] = title }
        if inviteOnly, !inviteeIds.isEmpty { body["invite_user_ids"] = inviteeIds }
        let data = try await roomsCall(roomsPath(userId, "sessions/\(encodeURIComponent(sessionId))/rooms"), method: "POST", body: body)
        guard let r = decode(SessionRoom.self, from: data) else { throw SessionRoomsError.network }
        return r
    }

    func joinRoom(userId: String, roomId: String) async throws -> SessionRoomJoinResponse {
        let data = try await roomsCall(roomsPath(userId, "rooms/\(encodeURIComponent(roomId))/join"), method: "POST")
        guard let r = decode(SessionRoomJoinResponse.self, from: data) else { throw SessionRoomsError.network }
        return r
    }

    func leaveRoom(userId: String, roomId: String) async throws {
        _ = try await roomsCall(roomsPath(userId, "rooms/\(encodeURIComponent(roomId))/leave"), method: "POST")
    }

    func heartbeatRoom(userId: String, roomId: String) async throws {
        _ = try await roomsCall(roomsPath(userId, "rooms/\(encodeURIComponent(roomId))/heartbeat"), method: "POST")
    }

    func renameRoom(userId: String, roomId: String, title: String) async throws {
        _ = try await roomsCall(roomsPath(userId, "rooms/\(encodeURIComponent(roomId))"), method: "PATCH", body: ["title": title])
    }

    func endRoom(userId: String, roomId: String) async throws {
        _ = try await roomsCall(roomsPath(userId, "rooms/\(encodeURIComponent(roomId))"), method: "DELETE")
    }

    func inviteToRoom(userId: String, roomId: String, inviteeIds: [String]) async throws {
        _ = try await roomsCall(roomsPath(userId, "rooms/\(encodeURIComponent(roomId))/invites"), method: "POST",
                                body: ["user_ids": inviteeIds])
    }
}
