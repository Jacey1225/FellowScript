// NetworkService+HomeMessage.swift -- Home announcement headline (task
// 20261002-home-announcement-headline). GET /app/home-message ->
// {v:1, message: null | {id, text, destination}}. Kept behind its own small
// protocol (same pattern as GroupAnnouncementsService) so neither
// NetworkService nor DataServiceProtocol grows. Throws on any failure
// (throw-not-fabricate); the caller keeps whatever is already shown.

import Foundation

/// Tolerant payload: every field optional, unknown keys ignored, `v` not
/// required to equal 1. `destination` is decoded-and-ignored in v1.
struct FSHomeMessagePayload: Decodable, Equatable {
    struct Message: Decodable, Equatable {
        let id: String?
        let text: String?
    }
    let message: Message?

    private enum CodingKeys: String, CodingKey { case message }

    init(message: Message?) { self.message = message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try? c.decodeIfPresent(Message.self, forKey: .message)
    }

    /// Display text: trimmed, blank -> nil, capped defensively at 200 chars.
    var displayText: String? { HomeMessageText.clean(message?.text) }
}

enum HomeMessageText {
    static let maxDisplayLength = 200

    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return String(t.prefix(maxDisplayLength))
    }
}

protocol HomeMessageService {
    /// The active announcement text, or nil when the server has none.
    func fetchHomeMessage() async throws -> String?
}

extension NetworkService: HomeMessageService {
    func fetchHomeMessage() async throws -> String? {
        let data = try await get("/app/home-message")
        guard let payload = try? JSONDecoder().decode(FSHomeMessagePayload.self, from: data) else {
            throw AppError.networkError("Couldn't load the home message.")
        }
        return payload.displayText
    }
}
