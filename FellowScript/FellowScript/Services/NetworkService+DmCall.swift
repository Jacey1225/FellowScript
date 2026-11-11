// NetworkService+DmCall.swift: POST /devotions/dm-call (task
// 20261028-dm-direct-call). Prepares the ad hoc call row for a 1:1 DM; the
// caller then uses the existing joinCall / ringMembers (single Chime path).
// Kept as its own protocol (like SessionRoomsServiceProtocol) so adding it
// does not force every DataServiceProtocol test double to change.
//
// Throw-not-fabricate: any failure throws a DmCallError; a call is never
// reported as started without a server-issued session id.

import Foundation

protocol DmCallServiceProtocol {
    /// Returns the (server-issued) session backing the DM call with `peerId`.
    func startDmCall(userId: String, peerId: String) async throws -> FSSession
}

/// Warm, user-facing failure copy (design-notes.md "Error"). Raw server text
/// is never surfaced.
enum DmCallError: LocalizedError, Equatable {
    /// Not friends / blocked / unauthorized (the server merges these).
    case notAllowed
    case network
    case failed

    var errorDescription: String? {
        switch self {
        case .notAllowed: return "You can't call this person right now."
        case .network:    return "Couldn't start the call. Check your connection and try again."
        case .failed:     return "Couldn't start the call. Please try again in a moment."
        }
    }
}

private struct DmCallResponse: Decodable {
    let id: String?
    let session: FSSession?
}

extension NetworkService: DmCallServiceProtocol {
    func startDmCall(userId: String, peerId: String) async throws -> FSSession {
        let body: [String: Any] = ["user_id": userId, "peer_id": peerId]
        let data: Data
        do {
            data = try await checkedRequestRaw("/devotions/dm-call", method: "POST", jsonObject: body)
        } catch let error as AppError {
            if case .networkError(let detail) = error, detail == "Not authorized" || detail == "Forbidden" {
                throw DmCallError.notAllowed
            }
            if case .networkError(let detail) = error, detail.hasPrefix("Server error 403") {
                throw DmCallError.notAllowed
            }
            throw DmCallError.failed
        } catch {
            throw DmCallError.network
        }
        guard let response = decode(DmCallResponse.self, from: data, endpoint: "/devotions/dm-call"),
              let id = response.id, !id.isEmpty else {
            throw DmCallError.failed
        }
        var session = response.session ?? FSSession()
        session.id = id
        if session.group_id.isEmpty {
            session.group_id = [userId, peerId].sorted().joined(separator: "|")
        }
        return session
    }
}
