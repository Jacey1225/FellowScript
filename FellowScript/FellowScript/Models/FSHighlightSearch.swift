// Models/FSHighlightSearch.swift — result models for the Highlights-tab search
// (task 20260909-highlight-search). Wire shape: GET /notes/highlight/{user}/search.

import Foundation

/// One highlight returned by search -- the viewer's own or an accepted friend's.
struct FSHighlightSearchResult: Identifiable, Decodable, Equatable {
    let owner_id: String
    let owner_username: String?
    let is_self: Bool
    let key: String
    let book: String
    let chapter: Int
    let verse: Int
    let color: String
    /// nil when the verse text couldn't be resolved; the row is still shown.
    let verse_text: String?
    let timestamp: String?
    /// Verse reaction emoji (task 20261009-verse-reactions); nil for plain highlights.
    var emoji: String? = nil

    /// owner + key: the same verse can be highlighted by several people.
    var id: String { "\(owner_id)|\(key)" }
}

/// A page of results plus the keyset cursor for the next page.
struct FSHighlightSearchPage: Equatable {
    let results: [FSHighlightSearchResult]
    let hasMore: Bool
    let cursorTimestamp: String?
    let cursorId: String?
    let cursorKey: String?
}

enum FSHighlightSearchError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let m): return m }
    }
}
