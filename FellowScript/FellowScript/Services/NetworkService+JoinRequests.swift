// NetworkService+JoinRequests.swift -- task 20261011-join-requests-ios-email step 2.
// Owner-side clients for api/routes/join_requests.py (flag `join_requests`).
// Behavioural reference: frontend/src/lib/joinRequestsApi.js.
//
// Throw-not-fabricate: every method throws FSJoinRequestsError on any non-2xx,
// transport error, or undecodable body; callers keep what they already show
// (preserve-cache-on-failed-refresh) and surface the error. Applicant names and
// notes are untrusted text: views render them as plain Text only.

import Foundation

enum FSJoinRequestsError: LocalizedError, Equatable {
    case termsReacceptRequired
    case groupFull
    case busy
    case rateLimited
    /// The request is no longer pending / available (someone else decided it).
    case notPending
    case notUndoable
    /// 404: group not published, flag off for the caller, or not the owner.
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .termsReacceptRequired: return "Please review and accept the updated Terms to continue."
        case .groupFull:   return "Group is full. Raise the member limit or remove someone, then approve."
        case .busy:        return "Busy, try again."
        case .rateLimited: return "Too many tries. Wait a moment and try again."
        case .notPending:  return "No longer available."
        case .notUndoable: return "That denial can no longer be undone."
        case .notFound:    return "Join requests aren't available for this group."
        case .failed(let m): return m
        }
    }
}

/// One pending request as the owner sees it. `applicantUserId` is not used by
/// the iOS UI (desktop uses it only for Report/Block).
struct FSJoinRequest: Codable, Equatable, Identifiable {
    let id: String
    let applicantUserId: String?
    let username: String?
    let profilePhotoUrl: String?
    let note: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case applicantUserId = "applicant_user_id"
        case username
        case profilePhotoUrl = "profile_photo_url"
        case note
        case createdAt = "created_at"
    }

    var displayName: String { (username?.isEmpty == false) ? username! : "Someone" }
}

struct FSJoinRequestsList: Codable, Equatable {
    let acceptingRequests: Bool
    let pendingCount: Int
    let requests: [FSJoinRequest]

    enum CodingKeys: String, CodingKey {
        case acceptingRequests = "accepting_requests"
        case pendingCount = "pending_count"
        case requests
    }

    init(acceptingRequests: Bool, pendingCount: Int, requests: [FSJoinRequest]) {
        self.acceptingRequests = acceptingRequests
        self.pendingCount = pendingCount
        self.requests = requests
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `requests` is required: a body without it is malformed, never "empty".
        let rows = try c.decode([FSJoinRequest].self, forKey: .requests)
        self.requests = rows
        self.acceptingRequests = (try c.decodeIfPresent(Bool.self, forKey: .acceptingRequests)) ?? true
        self.pendingCount = (try c.decodeIfPresent(Int.self, forKey: .pendingCount)) ?? rows.count
    }
}

private struct DenyJoinBody: Encodable { let block_reapply: Bool }
private struct AcceptingJoinBody: Encodable { let accepting: Bool }
private struct DenyJoinResponse: Decodable { let undo_seconds: Int? }

extension NetworkService {

    /// Fallback when the server omits `undo_seconds` (matches desktop UNDO_FALLBACK_MS).
    static let joinRequestUndoFallbackSeconds = 10

    private func joinGroupBase(_ userId: String, _ groupId: String) -> String {
        "/join-requests/\(encodeURIComponent(userId))/groups/\(encodeURIComponent(groupId))"
    }

    static func joinRequestsError(status: Int, data: Data, fallback: String) -> FSJoinRequestsError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var code: String?
        var message: String?
        if let detail = body?["detail"] as? [String: Any] {
            code = detail["code"] as? String
            message = detail["message"] as? String
        } else if let detail = body?["detail"] as? String {
            message = detail
        }
        if status == 403, code == "terms_reaccept_required" { return .termsReacceptRequired }
        if status == 429 { return .rateLimited }
        if status == 409 {
            switch code {
            case "group_full": return .groupFull
            case "busy": return .busy
            case "not_pending", "no_longer_available": return .notPending
            case "not_undoable": return .notUndoable
            default: break
            }
        }
        if status == 404 { return .notFound }
        return .failed(message ?? fallback)
    }

    private func joinRequestsSend(_ path: String, method: String, body: Encodable? = nil,
                                  fallback: String) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw FSJoinRequestsError.failed("Couldn't reach FellowScript. Check your connection.")
        }
        guard let http = response as? HTTPURLResponse else { throw FSJoinRequestsError.failed(fallback) }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.joinRequestsError(status: http.statusCode, data: data, fallback: fallback)
        }
        return data
    }

    // GET /join-requests/{u}/groups/{g}/requests
    func fetchJoinRequests(userId: String, groupId: String) async throws -> FSJoinRequestsList {
        let data = try await joinRequestsSend("\(joinGroupBase(userId, groupId))/requests", method: "GET",
                                              fallback: "Couldn't load join requests.")
        guard let list = decode(FSJoinRequestsList.self, from: data, endpoint: "/join-requests/{id}/groups/{id}/requests") else {
            throw FSJoinRequestsError.failed("Couldn't load join requests.")
        }
        return list
    }

    // POST .../requests/{r}/approve  (409 group_full leaves the request pending)
    func approveJoinRequest(userId: String, groupId: String, requestId: String) async throws {
        _ = try await joinRequestsSend(
            "\(joinGroupBase(userId, groupId))/requests/\(encodeURIComponent(requestId))/approve",
            method: "POST", fallback: "Couldn't approve this request.")
    }

    // POST .../requests/{r}/deny  body {block_reapply}; returns the undo window in seconds.
    func denyJoinRequest(userId: String, groupId: String, requestId: String, blockReapply: Bool) async throws -> Int {
        let data = try await joinRequestsSend(
            "\(joinGroupBase(userId, groupId))/requests/\(encodeURIComponent(requestId))/deny",
            method: "POST", body: DenyJoinBody(block_reapply: blockReapply),
            fallback: "Couldn't deny this request.")
        let secs = (try? JSONDecoder().decode(DenyJoinResponse.self, from: data))?.undo_seconds ?? 0
        return secs > 0 ? secs : Self.joinRequestUndoFallbackSeconds
    }

    // POST .../requests/{r}/undo-deny
    func undoDenyJoinRequest(userId: String, groupId: String, requestId: String) async throws {
        _ = try await joinRequestsSend(
            "\(joinGroupBase(userId, groupId))/requests/\(encodeURIComponent(requestId))/undo-deny",
            method: "POST", fallback: "Couldn't undo.")
    }

    // PUT .../accepting  body {accepting}
    func setAcceptingJoinRequests(userId: String, groupId: String, accepting: Bool) async throws {
        _ = try await joinRequestsSend(
            "\(joinGroupBase(userId, groupId))/accepting",
            method: "PUT", body: AcceptingJoinBody(accepting: accepting),
            fallback: "Couldn't update. Try again.")
    }
}

// Default implementations so existing conformers (MockDataService, test
// doubles) keep compiling. They throw rather than invent data.
extension DataServiceProtocol {
    private var joinRequestsUnsupported: FSJoinRequestsError { .failed("Join requests aren't available right now.") }

    func fetchJoinRequests(userId: String, groupId: String) async throws -> FSJoinRequestsList {
        throw joinRequestsUnsupported
    }
    func approveJoinRequest(userId: String, groupId: String, requestId: String) async throws {
        throw joinRequestsUnsupported
    }
    func denyJoinRequest(userId: String, groupId: String, requestId: String, blockReapply: Bool) async throws -> Int {
        throw joinRequestsUnsupported
    }
    func undoDenyJoinRequest(userId: String, groupId: String, requestId: String) async throws {
        throw joinRequestsUnsupported
    }
    func setAcceptingJoinRequests(userId: String, groupId: String, accepting: Bool) async throws {
        throw joinRequestsUnsupported
    }
}
