// NetworkService+GroupMedia.swift -- task 20261023-group-info-row.
// GET /groups/{user_id}/{group_id}/media?kind=&limit=&cursor_* (flag group_media).
// Throw-not-fabricate: any non-2xx, transport error or undecodable body throws
// and the caller keeps what it already shows.

import Foundation

protocol GroupMediaService {
    func fetchGroupMedia(userId: String, groupId: String, limit: Int, cursor: FSGroupMediaCursor?) async throws -> FSGroupMediaPage
}

private struct GroupMediaResponse: Decodable {
    let media: [FSGroupMediaItem]?
    let page: RawPage?
}

extension NetworkService: GroupMediaService {
    func fetchGroupMedia(userId: String, groupId: String, limit: Int, cursor: FSGroupMediaCursor?) async throws -> FSGroupMediaPage {
        var query = "kind=image,video,gif&limit=\(limit)"
        if let cursor {
            query += "&cursor_timestamp=\(encodeURIComponent(cursor.timestamp))"
            if let seq = cursor.seq { query += "&cursor_seq=\(seq)" }
            query += "&cursor_id=\(encodeURIComponent(cursor.id))"
        }
        let path = "/groups/\(encodeURIComponent(userId))/\(encodeURIComponent(groupId))/media?\(query)"
        let data = try await get(path)
        guard let resp = decode(GroupMediaResponse.self, from: data, endpoint: "/groups/{id}/{id}/media"),
              let rows = resp.media else {
            throw AppError.networkError("Couldn't load media.")
        }
        let p = resp.page
        let more = p?.has_more == true && p?.next_cursor_timestamp != nil && p?.next_cursor_id != nil
        return FSGroupMediaPage(items: rows, hasMore: more,
                                cursorTimestamp: more ? p?.next_cursor_timestamp : nil,
                                cursorSeq: more ? p?.next_cursor_seq : nil,
                                cursorId: more ? p?.next_cursor_id : nil)
    }
}
