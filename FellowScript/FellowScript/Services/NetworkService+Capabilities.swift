// NetworkService+Capabilities.swift — GET /app/capabilities (task
// 20261002-shared-foundation step 8, shared-contract-v2 sections 9.2 and 6.12).
// The one discovery mechanism for server-gated features and the live
// "Updated Terms" check.
//
// Throw-not-fabricate: fetchCapabilities() throws on any non-200, transport
// error, timeout, or malformed/undecodable body. Callers (AppState) map a
// throw to FSCapabilities.allOff at the call site, so every feature is off and
// terms are treated as current (a missing endpoint can never trap a user
// behind the terms gate).

import Foundation

/// Task 20261010-chat-reactions: server-owned reaction allowlist from
/// `reaction_emoji` (empty lists while the message_reactions flag is off).
struct FSReactionEmoji: Decodable, Equatable {
    var quick: [String]
    var more: [String]
    static let none = FSReactionEmoji(quick: [], more: [])
    /// Quick set first, then the rest without duplicates, for the full picker.
    var all: [String] { quick + more.filter { !quick.contains($0) } }
}

struct FSCapabilities: Decodable, Equatable {
    var features: [String: Bool]
    var exploreLink: String?
    var termsCurrent: Bool
    var reactionEmoji: FSReactionEmoji = .none

    /// Chat reactions UI shows only when the flag is on AND the server sent a set.
    var messageReactionsEnabled: Bool { isEnabled("message_reactions") && !reactionEmoji.quick.isEmpty }

    /// Task 20261010-reaction-highlight-push: friend-highlight push toggle shows only when the flag is on.
    var friendHighlightPushEnabled: Bool { isEnabled("friend_highlight_push") }

    /// Fail-closed value: nothing enabled, terms treated as current.
    static let allOff = FSCapabilities(features: [:], exploreLink: nil, termsCurrent: true)

    func isEnabled(_ name: String) -> Bool { features[name] == true }

    private struct Links: Decodable { let explore: String? }
    private enum CodingKeys: String, CodingKey { case features, links, terms_current, reaction_emoji }

    init(features: [String: Bool], exploreLink: String?, termsCurrent: Bool, reactionEmoji: FSReactionEmoji = .none) {
        self.reactionEmoji = reactionEmoji
        self.features = features
        self.exploreLink = exploreLink
        self.termsCurrent = termsCurrent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Strict: a non-boolean feature value, a missing features object, or a
        // missing terms_current makes the whole body malformed (throws).
        let features = try c.decode([String: Bool].self, forKey: .features)
        let termsCurrent = try c.decode(Bool.self, forKey: .terms_current)
        let links = try? c.decodeIfPresent(Links.self, forKey: .links)
        self.features = features
        self.termsCurrent = termsCurrent
        // Optional and lenient: a missing/odd block just leaves reactions hidden.
        self.reactionEmoji = ((try? c.decodeIfPresent(FSReactionEmoji.self, forKey: .reaction_emoji)) ?? nil) ?? .none
        self.exploreLink = features["explorer_browse"] == true ? links?.explore : nil
    }
}

extension NetworkService {

    static let capabilitiesTimeout: TimeInterval = 5

    func fetchCapabilities() async throws -> FSCapabilities {
        var req = URLRequest(url: url("/app/capabilities"))
        req.httpMethod = "GET"
        req.timeoutInterval = Self.capabilitiesTimeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppError.networkError("Capabilities unavailable.")
        }
        return try JSONDecoder().decode(FSCapabilities.self, from: data)
    }
}
