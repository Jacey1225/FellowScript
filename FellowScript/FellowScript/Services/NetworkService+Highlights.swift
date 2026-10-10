// NetworkService+Highlights.swift — Highlights and Bookmarks (small, near-
// identical-shaped domains, grouped in one file). Split out of
// NetworkService.swift (readability #H16, 20260904-frontend-arch-sweep) --
// same type, same behavior, just this domain's own file. See
// NetworkService.swift's header comment for the full split rationale and
// the list of sibling domain files.

import Foundation

extension NetworkService {

    // ── Highlights ────────────────────────────────────────────────────────────
    // GET    /notes/highlight/{userId}
    // POST   /notes/highlight/{userId}             body: {book, chapter, verse, color}
    // DELETE /notes/highlight/{userId}/{encodedKey}

    func fetchHighlights(userId: String) async throws -> [String: String] {
        let data = try await get("/notes/highlight/\(userId)")
        // task 20260903-account-stats-not-loading: tagged like fetchNotesCount
        // above -- a decode failure here (e.g. a value shape the plain
        // [String: String] decode doesn't tolerate) previously vanished
        // indistinguishably from "this account really has zero highlights".
        return decode([String: String].self, from: data, endpoint: "GET /notes/highlight/{user_id}") ?? [:]
    }

    func saveHighlight(userId: String, book: String, chapter: Int, verse: Int, color: String) async throws {
        // checkedRequestRaw (not requestRaw) so a 4xx/5xx response (e.g. an
        // expired session or a free-tier highlight limit) throws instead of
        // being silently discarded — callers optimistically mutate local
        // state and must be able to revert on failure.
        _ = try await checkedRequestRaw("/notes/highlight/\(userId)", method: "POST",
                                  jsonObject: ["book": book, "chapter": chapter, "verse": verse, "color": color])
    }

    // Task 20261009-verse-reactions. GET ...?include_emoji=true returns
    // {key: {color, emoji|null}}; a server that predates the param returns the
    // plain {key: color} shape, which FSVerseHighlight also decodes.
    func fetchHighlightsWithReactions(userId: String) async throws -> [String: FSVerseHighlight] {
        let data = try await get("/notes/highlight/\(userId)?include_emoji=true")
        return decode([String: FSVerseHighlight].self, from: data, endpoint: "GET /notes/highlight/{user_id}?include_emoji") ?? [:]
    }

    /// Saves a verse reaction (emoji, with an optional highlight color). Omitting
    /// the color lets the server use its neutral default.
    func saveVerseReaction(userId: String, book: String, chapter: Int, verse: Int, color: String?, emoji: String) async throws {
        var body: [String: Any] = ["book": book, "chapter": chapter, "verse": verse, "emoji": emoji]
        if let color { body["color"] = color }
        _ = try await checkedRequestRaw("/notes/highlight/\(userId)", method: "POST", jsonObject: body)
    }

    func clearHighlight(userId: String, key: String) async throws {
        _ = try await request("/notes/highlight/\(userId)/\(encodeURIComponent(key))", method: "DELETE")
    }

    // ── Bookmarks ─────────────────────────────────────────────────────────────
    // GET    /notes/bookmark/{userId}
    // POST   /notes/bookmark/{userId}             body: {book, chapter, label}
    // DELETE /notes/bookmark/{userId}/{encodedKey}

    func fetchBookmarks(userId: String) async throws -> [String: String] {
        let data = try await get("/notes/bookmark/\(userId)")
        // readability #7: tagged like its closest sibling, fetchHighlights,
        // for symmetry -- a decode failure here previously degraded silently
        // to the same "[:]" a genuinely-empty bookmark list would show, with
        // no reportDecodeFailure/CloudWatch signal, unlike every other read
        // this file's 20260903-account-stats/-events-not-loading passes tagged.
        return decode([String: String].self, from: data, endpoint: "GET /notes/bookmark/{user_id}") ?? [:]
    }

    func saveBookmark(userId: String, book: String, chapter: Int, label: String) async throws {
        // checkedRequestRaw (not requestRaw) — same rationale as saveHighlight above.
        _ = try await checkedRequestRaw("/notes/bookmark/\(userId)", method: "POST",
                                  jsonObject: ["book": book, "chapter": chapter, "label": label])
    }

    func removeBookmark(userId: String, key: String) async throws {
        _ = try await request("/notes/bookmark/\(userId)/\(encodeURIComponent(key))", method: "DELETE")
    }
}

/// One highlight row from GET /notes/highlight/{user}?include_emoji=true.
/// Tolerates both the plain `"#hex"` string and the `{color, emoji}` object.
struct FSVerseHighlight: Decodable, Equatable {
    let color: String
    let emoji: String?

    private enum CodingKeys: String, CodingKey { case color, emoji }

    init(color: String, emoji: String? = nil) {
        self.color = color
        self.emoji = emoji
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let hex = try? single.decode(String.self) {
            self.init(color: hex)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(color: try c.decode(String.self, forKey: .color),
                  emoji: try c.decodeIfPresent(String.self, forKey: .emoji))
    }
}

/// The server's closed verse-reaction list (api/backend/interactions/verse_reactions.py,
/// same order). Not sent in capabilities, so mirrored here; the flag `verse_reactions`
/// decides whether any of it is shown.
enum VerseReactionEmoji {
    static let neutralColor = "#8E8E93"
    static let flagName = "verse_reactions"

    static let all: [(emoji: String, name: String)] = [
        ("\u{2764}\u{FE0F}", "Heart"), ("\u{1F64F}", "Praying hands"), ("\u{1F525}", "Fire"),
        ("\u{1F44D}", "Thumbs up"), ("\u{1F622}", "Crying"), ("\u{1F62E}", "Surprised"),
        ("\u{2728}", "Sparkles"), ("\u{1F4D6}", "Open book"), ("\u{1F64C}", "Raised hands"),
        ("\u{1F4A1}", "Light bulb"),
    ]
    static let quick: [String] = Array(all.prefix(4).map(\.emoji)) + ["\u{1F4D6}"]
    static let allEmoji: [String] = all.map(\.emoji)

    static func name(for emoji: String) -> String {
        all.first { $0.emoji == emoji }?.name ?? "reaction"
    }
}

extension DataServiceProtocol {
    /// Default: fall back to the plain fetch (no reactions) so test doubles compile.
    func fetchHighlightsWithReactions(userId: String) async throws -> [String: FSVerseHighlight] {
        try await fetchHighlights(userId: userId).mapValues { FSVerseHighlight(color: $0) }
    }
    func saveVerseReaction(userId: String, book: String, chapter: Int, verse: Int, color: String?, emoji: String) async throws {
        throw AppError.networkError("Reactions aren't available right now.")
    }
}
