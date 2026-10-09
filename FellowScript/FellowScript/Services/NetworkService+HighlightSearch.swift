// NetworkService+HighlightSearch.swift — GET /notes/highlight/{userId}/search
// (task 20260909-highlight-search). Own file so NetworkService.swift and
// NetworkService+Highlights.swift don't grow.

import Foundation

private struct HighlightSearchResponse: Decodable {
    struct Page: Decodable {
        let has_more: Bool?
        let next_cursor_timestamp: String?
        let next_cursor_id: String?
        let next_cursor_key: String?
    }
    let highlights: [FSHighlightSearchResult]?
    let page: Page?
}

extension NetworkService {
    func searchHighlights(userId: String, query: String, limit: Int?,
                          cursorTimestamp: String?, cursorId: String?, cursorKey: String?) async throws -> FSHighlightSearchPage {
        var path = "/notes/highlight/\(encodeURIComponent(userId))/search?q=\(encodeURIComponent(query))"
        if let limit { path += "&limit=\(limit)" }
        if let ts = cursorTimestamp, let id = cursorId, let key = cursorKey {
            path += "&cursor_timestamp=\(encodeURIComponent(ts))&cursor_id=\(encodeURIComponent(id))&cursor_key=\(encodeURIComponent(key))"
        }
        // get() throws on non-2xx (throw-not-fabricate): a failed search is an
        // error, never an empty result set.
        let data = try await get(path)
        guard let resp = decode(HighlightSearchResponse.self, from: data, endpoint: "GET /notes/highlight/{user_id}/search"),
              let rows = resp.highlights else {
            throw FSHighlightSearchError.failed("Couldn't search highlights.")
        }
        let p = resp.page
        let more = p?.has_more == true && p?.next_cursor_timestamp != nil
            && p?.next_cursor_id != nil && p?.next_cursor_key != nil
        return FSHighlightSearchPage(results: rows, hasMore: more,
                                     cursorTimestamp: more ? p?.next_cursor_timestamp : nil,
                                     cursorId: more ? p?.next_cursor_id : nil,
                                     cursorKey: more ? p?.next_cursor_key : nil)
    }
}

extension DataServiceProtocol {
    /// Default for conformers without a backend (mocks): unsupported, so the
    /// UI surfaces an error instead of fabricating an empty result.
    func searchHighlights(userId: String, query: String, limit: Int?,
                          cursorTimestamp: String?, cursorId: String?, cursorKey: String?) async throws -> FSHighlightSearchPage {
        throw FSHighlightSearchError.failed("Highlight search isn't available right now.")
    }
}
