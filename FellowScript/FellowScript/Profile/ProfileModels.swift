// ProfileModels.swift (task 20261030-user-profiles)
// Wire model for GET /profiles/{id} plus the in-memory profile cache.
//
// Privacy notes (security D3/D10):
//  * `bio` is only present in the payload for self and friends. A missing key
//    means "hidden from you" (`bioVisible == false`), which is different from a
//    present-but-null bio ("this person has no bio yet"). The two are never
//    merged, so a stranger can't be shown "No bio yet." by mistake.
//  * The cache is memory-only (never written to disk), keyed by viewer + target
//    so one account can never read another's entries, and is wiped on sign-out.

import Foundation

enum FSProfileRelationship: String, Equatable {
    case selfUser        = "self"
    case friends
    case requestSent     = "request_sent"
    case requestReceived = "request_received"
    case none
}

struct FSProfile: Decodable, Equatable, Identifiable {
    let user_id: String
    let username: String
    var profile_photo_url: String?
    var relationship: FSProfileRelationship
    var editable: Bool
    /// The stored bio text; nil when the user has none OR when it is hidden.
    var bio: String?
    /// False when the server omitted the `bio` key (stranger tier).
    var bioVisible: Bool

    var id: String { user_id }

    private enum CodingKeys: String, CodingKey {
        case user_id, username, profile_photo_url, relationship, editable, bio
    }
    private struct RelationshipBody: Decodable { let state: String }

    init(user_id: String, username: String, profile_photo_url: String? = nil,
         relationship: FSProfileRelationship, editable: Bool,
         bio: String? = nil, bioVisible: Bool) {
        self.user_id = user_id
        self.username = username
        self.profile_photo_url = profile_photo_url
        self.relationship = relationship
        self.editable = editable
        self.bio = bio
        self.bioVisible = bioVisible
    }

    /// Throws on an unknown relationship state rather than guessing one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user_id  = try c.decode(String.self, forKey: .user_id)
        username = try c.decode(String.self, forKey: .username)
        profile_photo_url = try c.decodeIfPresent(String.self, forKey: .profile_photo_url)
        editable = try c.decode(Bool.self, forKey: .editable)
        let rel = try c.decode(RelationshipBody.self, forKey: .relationship)
        guard let state = FSProfileRelationship(rawValue: rel.state) else {
            throw DecodingError.dataCorruptedError(forKey: .relationship, in: c,
                debugDescription: "Unknown relationship state")
        }
        relationship = state
        bioVisible = c.contains(.bio)
        bio = bioVisible ? try c.decodeIfPresent(String.self, forKey: .bio) : nil
    }
}

/// Memory-only profile cache (design D10). Not persisted, cleared on sign-out.
@MainActor
final class ProfileCache {
    static let shared = ProfileCache()
    private var entries: [String: FSProfile] = [:]
    private func key(_ viewer: String, _ target: String) -> String { "\(viewer)|\(target)" }

    func profile(viewer: String, target: String) -> FSProfile? { entries[key(viewer, target)] }
    func store(_ profile: FSProfile, viewer: String) { entries[key(viewer, profile.user_id)] = profile }
    func evict(viewer: String, target: String) { entries[key(viewer, target)] = nil }
    func clear() { entries.removeAll() }
}
