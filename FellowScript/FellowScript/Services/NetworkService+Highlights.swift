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
