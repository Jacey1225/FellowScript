// NetworkService+Profile.swift (task 20261030-user-profiles)
// Profile read, own-bio edit, and id-keyed friend request/accept.
//
// GET  /profiles/{id}                    -> FSProfile (404 = unavailable, see below)
// PUT  /profile/{userId}/bio             body {bio: string|null} -> {bio}
// POST /profiles/{id}/friend-request     -> 204 (uniform; refetch for the state)
// POST /profiles/{id}/friend-accept      -> 204 / uniform 404
//
// Throw-not-fabricate: every failure throws; nothing here returns a default
// profile. A 404 maps to AppError.notFound so ProfileViewModel can evict the
// cached profile (unknown, blocked and suspended are indistinguishable by
// design); any other failure is a plain throw and the cache is kept.

import Foundation

extension DataServiceProtocol {
    // Defaults keep other conformers (previews, test doubles) compiling; they
    // throw instead of returning made-up data.
    func fetchProfile(targetId: String) async throws -> FSProfile {
        throw AppError.networkError("Profiles aren't available right now.")
    }
    func updateBio(userId: String, bio: String?) async throws -> String? {
        throw AppError.networkError("Profiles aren't available right now.")
    }
    func sendProfileFriendRequest(targetId: String) async throws {
        throw AppError.networkError("Profiles aren't available right now.")
    }
    func acceptProfileFriendRequest(targetId: String) async throws {
        throw AppError.networkError("Profiles aren't available right now.")
    }
}

extension NetworkService {
    func fetchProfile(targetId: String) async throws -> FSProfile {
        let endpoint = "/profiles/{id}"
        let (data, response) = try await getRawResponse("/profiles/\(encodeURIComponent(targetId))")
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { throw AppError.notFound }
        try throwIfError(response, data)
        guard let profile = decode(FSProfile.self, from: data, endpoint: endpoint) else {
            throw AppError.networkError("Couldn't read this profile.")
        }
        return profile
    }

    /// Sends the key explicitly (`null` clears the bio); the server model
    /// requires the field and forbids extras. Returns the stored, normalized text.
    func updateBio(userId: String, bio: String?) async throws -> String? {
        let value: Any = bio.map { $0 as Any } ?? NSNull()
        let data = try await checkedRequestRaw("/profile/\(encodeURIComponent(userId))/bio",
                                               method: "PUT", jsonObject: ["bio": value])
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj.keys.contains("bio") else {
            throw AppError.networkError("Couldn't read the saved bio.")
        }
        return obj["bio"] as? String
    }

    func sendProfileFriendRequest(targetId: String) async throws {
        _ = try await request("/profiles/\(encodeURIComponent(targetId))/friend-request", method: "POST")
    }

    func acceptProfileFriendRequest(targetId: String) async throws {
        _ = try await request("/profiles/\(encodeURIComponent(targetId))/friend-accept", method: "POST")
    }
}
