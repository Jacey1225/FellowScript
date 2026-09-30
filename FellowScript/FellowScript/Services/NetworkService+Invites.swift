// NetworkService+Invites.swift — group invite links (task
// 20260929-group-invite-links, api/routes/invites.py). Every method throws
// InviteAPIError on any failure (throw-not-fabricate); callers keep their
// cached value and surface the error. The plaintext token only ever travels
// in a POST body (preview/redeem) and is never logged.

import Foundation

// ── Models ───────────────────────────────────────────────────────────────────

struct FSInvitePreview: Decodable, Equatable {
    let kind: String
    let group_name: String
    let photo_url: String?
    let inviter_username: String
    let member_count: Int
}

struct FSInviteOptions: Codable, Equatable {
    let default_expiry_days: Int
    let allowed_expiry_days: [Int]
    let default_max_uses: Int
    let allowed_max_uses: [Int]
    let max_active_links_per_user_per_group: Int
}

/// Metadata only -- the list endpoint never returns a token.
struct FSInviteItem: Codable, Identifiable, Equatable {
    let invite_id: String
    let created_by_username: String?
    let is_mine: Bool
    let created_at: String
    let expires_at: String
    let max_uses: Int
    let use_count: Int
    let remaining_uses: Int
    var id: String { invite_id }
}

struct FSInviteList: Codable, Equatable {
    var invites: [FSInviteItem]
    let options: FSInviteOptions
}

/// Returned once, at creation. `url` is the only place the plaintext exists.
struct FSInviteCreated: Decodable {
    let invite_id: String
    let token: String
    let url: String
    let created_at: String
    let expires_at: String
    let max_uses: Int
    let use_count: Int
}

struct FSInviteRedeemResult: Decodable, Equatable {
    let kind: String
    let target_id: String
    let joined: Bool
    let already_member: Bool
}

/// `status` 0 = the request never got a response (network). `code` is the
/// backend's machine value when it sent one (not_found | expired | revoked |
/// full | blocked | link_limit | forbidden ...).
struct InviteAPIError: LocalizedError, Equatable {
    let status: Int
    let code: String?
    let message: String
    var errorDescription: String? { message }
}

private struct InviteTokenBody: Encodable { let token: String }
private struct InviteCreateBody: Encodable {
    let expires_in_days: Int
    let max_uses: Int
}
private struct InviteResetResponse: Decodable { let revoked: Int }

// ── Client ───────────────────────────────────────────────────────────────────

extension NetworkService {

    private func inviteCall(_ path: String, method: String, body: Encodable? = nil, fallback: String) async throws -> Data {
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
            throw InviteAPIError(status: 0, code: nil, message: "Could not reach the server.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw InviteAPIError(status: 0, code: nil, message: fallback)
        }
        if http.statusCode >= 400 {
            var code: String?
            var message = fallback
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let d = obj["detail"] as? [String: Any] {
                    code = d["code"] as? String
                    if let m = d["message"] as? String { message = m }
                } else if let s = obj["detail"] as? String {
                    message = s
                }
            }
            throw InviteAPIError(status: http.statusCode, code: code, message: message)
        }
        return data
    }

    private func decodeInvite<T: Decodable>(_ type: T.Type, _ data: Data, fallback: String) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw InviteAPIError(status: 0, code: nil, message: fallback)
        }
        return value
    }

    // POST /invites/preview -- public. Any unusable token is a uniform 404.
    func previewInvite(token: String) async throws -> FSInvitePreview {
        let fallback = "This invite link isn't valid anymore."
        let data = try await inviteCall("/invites/preview", method: "POST", body: InviteTokenBody(token: token), fallback: fallback)
        return try decodeInvite(FSInvitePreview.self, data, fallback: fallback)
    }

    // POST /invites/{userId}/redeem
    func redeemInvite(userId: String, token: String) async throws -> FSInviteRedeemResult {
        let fallback = "Couldn't join the group. Please try again."
        let data = try await inviteCall("/invites/\(userId)/redeem", method: "POST", body: InviteTokenBody(token: token), fallback: fallback)
        return try decodeInvite(FSInviteRedeemResult.self, data, fallback: fallback)
    }

    // GET /invites/{userId}/groups/{groupId} -- 404 = feature unavailable.
    func listGroupInvites(userId: String, groupId: String) async throws -> FSInviteList {
        let fallback = "Couldn't load invite links."
        let data = try await inviteCall("/invites/\(userId)/groups/\(groupId)", method: "GET", fallback: fallback)
        return try decodeInvite(FSInviteList.self, data, fallback: fallback)
    }

    // POST /invites/{userId}/groups/{groupId}
    func createGroupInvite(userId: String, groupId: String, expiresInDays: Int, maxUses: Int) async throws -> FSInviteCreated {
        let fallback = "Couldn't create the link. Please try again."
        let data = try await inviteCall("/invites/\(userId)/groups/\(groupId)", method: "POST",
                                        body: InviteCreateBody(expires_in_days: expiresInDays, max_uses: maxUses), fallback: fallback)
        return try decodeInvite(FSInviteCreated.self, data, fallback: fallback)
    }

    // DELETE /invites/{userId}/{inviteId}
    func revokeInvite(userId: String, inviteId: String) async throws {
        _ = try await inviteCall("/invites/\(userId)/\(inviteId)", method: "DELETE", fallback: "Couldn't revoke. Please try again.")
    }

    // POST /invites/{userId}/groups/{groupId}/reset -> {revoked}
    func resetGroupInvites(userId: String, groupId: String) async throws -> Int {
        let fallback = "Couldn't reset the links. Please try again."
        let data = try await inviteCall("/invites/\(userId)/groups/\(groupId)/reset", method: "POST", fallback: fallback)
        return try decodeInvite(InviteResetResponse.self, data, fallback: fallback).revoked
    }
}
