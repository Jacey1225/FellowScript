// NotesHighlightsRegressionTests.swift — regression coverage for
// task: 20260808-ios-backend-integration-audit, step 5 (backend) + step 6
// (frontend) notes+highlights domain findings.
//
// Two distinct bugs were fixed in that domain, both matching the intake
// spec's two incident classes:
//
// 1. Shape/decode-parity bug (incident #2's class), backend-side fix:
//    POST /notes/{user_id} used to return {"id": note_id, "data": note.dict()}.
//    iOS's NetworkService.saveNote() decodes the response as [String: String]
//    (via `try?`), and the nested "data" object made that decode throw —
//    decode() swallowed the error and saveNote() silently fell back to
//    `editingId ?? note.id`, i.e. for a fresh create it returned the
//    CLIENT's locally-generated FSNote.id instead of the server-issued id.
//    Fixed by returning {"id": note_id} only. Covered here at the
//    NetworkService level with a stubbed backend response, proving the
//    client now returns the real server id instead of the local fallback.
//
// 2. Swallowed-error bug (incident #1's class), frontend-side fix:
//    NetworkService.saveHighlight()/saveBookmark() used the unchecked
//    `requestRaw` (no throwIfError) instead of `checkedRequestRaw`, and
//    every call site (NotesViewModel, BibleViewModel) optimistically
//    mutated local state before awaiting the result and then discarded the
//    outcome with a bare `try?` — BibleViewModel.persistClearHighlight()
//    even fired from a detached `Task {}` whose error was never observed at
//    all. A failed write (expired session, free-tier limit, etc.) showed as
//    succeeded in the UI. Fixed by switching to `checkedRequestRaw` and
//    having every optimistic call site revert the local mutation and
//    surface the error via a new/existing `saveError` published property.
//    Covered here at two levels: NetworkService (checkedRequestRaw actually
//    throws on 4xx/5xx) and the two view models (revert + surface on
//    failure, keep-on-success).

import XCTest
@testable import FellowScript

// MARK: - Group A: NetworkService level (real network layer, stubbed HTTP)
//
// Reuses StubURLProtocol, already registered/defined in
// NetworkServiceGetErrorHandlingTests.swift within this same test target.

final class NotesHighlightsNetworkServiceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    // ── saveHighlight / saveBookmark now throw on error (checkedRequestRaw) ──

    /// Before the fix: saveHighlight() used `requestRaw`, which never checks
    /// the status code, so a 403 (e.g. the free-tier highlight limit) would
    /// return normally and the caller would believe the highlight saved.
    func test_saveHighlight_throws_on403_insteadOfSilentlySucceeding() async {
        StubURLProtocol.stubStatusCode = 403
        StubURLProtocol.stubBody = #"{"detail": {"resource": "highlights", "used": 5, "limit": 5}}"#.data(using: .utf8)!

        do {
            try await NetworkService.shared.saveHighlight(userId: "user-123", book: "John", chapter: 1, verse: 1, color: "#F5E642")
            XCTFail("saveHighlight() must throw on a 403 response, not silently succeed")
        } catch {
            if case AppError.limitReached(let resource, _, _) = error {
                XCTAssertEqual(resource, "highlights")
            } else {
                XCTFail("expected AppError.limitReached, got \(error)")
            }
        }
    }

    /// Same class of bug, saveBookmark(): a 401 (expired session) must throw,
    /// not be silently discarded.
    func test_saveBookmark_throws_on401_insteadOfSilentlySucceeding() async {
        StubURLProtocol.stubStatusCode = 401
        StubURLProtocol.stubBody = #"{"detail": "Not authenticated"}"#.data(using: .utf8)!

        do {
            try await NetworkService.shared.saveBookmark(userId: "user-123", book: "John", chapter: 1, label: "")
            XCTFail("saveBookmark() must throw on a 401 response, not silently succeed")
        } catch {
            if case AppError.networkError(let detail) = error {
                XCTAssertEqual(detail, "Not authenticated")
            } else {
                XCTFail("expected AppError.networkError, got \(error)")
            }
        }
    }

    /// Happy-path regression guard: a normal 200/201 must not be turned into
    /// a false failure by the fix.
    func test_saveHighlight_succeeds_on200() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = ##"{"key": "John-1-1", "color": "#F5E642"}"##.data(using: .utf8)!

        try await NetworkService.shared.saveHighlight(userId: "user-123", book: "John", chapter: 1, verse: 1, color: "#F5E642")
        // No throw == success; nothing further to assert.
    }

    // ── saveNote() response-shape parity (backend step 5 fix) ────────────────

    /// Before the fix: the backend's POST /notes/{user_id} response included
    /// a nested "data" object, which broke iOS's `[String: String]` decode
    /// and made saveNote() return the CLIENT's local id instead of the
    /// server's. Now that the backend returns {"id": ...} only, a fresh
    /// create (editingId == nil) must return the SERVER id, never the
    /// client-seeded local FSNote.id.
    func test_saveNote_create_returnsServerId_notClientFallbackId() async throws {
        StubURLProtocol.stubStatusCode = 201
        StubURLProtocol.stubBody = #"{"id": "server-issued-uuid-123"}"#.data(using: .utf8)!

        let localNote = FSNote(
            id: "client-local-uuid-999", user: "user-123",
            title: "Test", text: "Test note body",
            public: false, group_id: "", is_reply: false,
            timestamp: "2026-08-08 00:00:00",
            verses: [], replies: []
        )

        let savedId = try await NetworkService.shared.saveNote(localNote, editingId: nil, userId: "user-123")

        XCTAssertEqual(savedId, "server-issued-uuid-123",
                        "a fresh create must return the server-issued id from the {\"id\": ...}-only response")
        XCTAssertNotEqual(savedId, localNote.id,
                           "must never fall back to the client's locally-generated id when the server responded with a valid id")
    }

    /// Regression guard: editing an existing note (editingId != nil) via PUT
    /// still round-trips the id correctly.
    func test_saveNote_update_returnsServerId_whenEditingIdProvided() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"id": "existing-note-id"}"#.data(using: .utf8)!

        let note = FSNote(
            id: "existing-note-id", user: "user-123",
            title: "Edited", text: "Edited body",
            public: false, group_id: "", is_reply: false,
            timestamp: "2026-08-08 00:00:00",
            verses: [], replies: []
        )

        let savedId = try await NetworkService.shared.saveNote(note, editingId: "existing-note-id", userId: "user-123")
        XCTAssertEqual(savedId, "existing-note-id")
    }
}

// MARK: - Group B: ViewModel level (NotesViewModel, BibleViewModel)
//
// Uses ThrowingTestDataService (defined in AppStateAuthAccountTests.swift,
// same test target) with its saveHighlight/clearHighlight/saveBookmark/
// removeBookmark error seams, so these tests exercise the view models'
// actual revert-and-surface logic without touching the network.

@MainActor
final class NotesViewModelHighlightRegressionTests: XCTestCase {

    func test_saveHighlight_revertsOptimisticMutation_andSurfacesError_onFailure() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        service.saveHighlightError = AppError.networkError("Session expired")
        vm.service = service

        await vm.saveHighlight(book: "John", chapter: 1, verse: 1, color: "#F5E642", userId: "user-123")

        XCTAssertNil(vm.highlights["John-1-1"], "the optimistic highlight must be reverted after a failed save")
        XCTAssertEqual(vm.saveError, "Session expired", "the real failure reason must be surfaced, not a false success")
        XCTAssertEqual(service.saveHighlightCallCount, 1)
    }

    func test_saveHighlight_keepsMutation_onSuccess() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        vm.service = service

        await vm.saveHighlight(book: "John", chapter: 1, verse: 1, color: "#F5E642", userId: "user-123")

        XCTAssertEqual(vm.highlights["John-1-1"], "#F5E642")
        XCTAssertNil(vm.saveError)
    }

    func test_clearHighlight_revertsOptimisticRemoval_andSurfacesError_onFailure() async {
        let vm = NotesViewModel()
        vm.highlights["John-1-1"] = "#F5E642"
        let service = ThrowingTestDataService()
        service.clearHighlightError = AppError.networkError("Server error 500")
        vm.service = service

        await vm.clearHighlight(key: "John-1-1", userId: "user-123")

        XCTAssertEqual(vm.highlights["John-1-1"], "#F5E642", "the optimistically-removed highlight must be restored after a failed clear")
        XCTAssertEqual(vm.saveError, "Server error 500")
    }
}

@MainActor
final class BibleViewModelHighlightRegressionTests: XCTestCase {

    /// Poll for the fire-and-forget Task {} launched inside persistHighlight/
    /// persistClearHighlight/persistToggleBookmark to complete (these methods
    /// are intentionally synchronous — they kick off a detached Task rather
    /// than being `async` themselves — mirroring the production call sites in
    /// BibleReaderView, so tests can't just `await` them directly).
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_persistHighlight_revertsOptimisticMutation_andSurfacesError_onFailure() async {
        let vm = BibleViewModel()
        vm.curBook = "John"; vm.curChapter = 1
        let service = ThrowingTestDataService()
        service.saveHighlightError = AppError.networkError("Session expired")
        vm.service = service

        vm.persistHighlight(verse: 1, color: "#F5E642", userId: "user-123")
        await waitUntil { vm.saveError != nil }

        XCTAssertNil(vm.highlights["John-1-1"], "the optimistic highlight must be reverted after a failed save")
        XCTAssertEqual(vm.saveError, "Session expired")
    }

    /// This is the finding that was completely unobserved before the fix:
    /// persistClearHighlight() fired its network call from a detached
    /// `Task {}` whose error was never caught at all, so a failed clear
    /// silently left the UI showing "cleared" even though nothing changed
    /// server-side (and, worse, the local optimistic removal was never
    /// reverted either).
    func test_persistClearHighlight_revertsOptimisticRemoval_andSurfacesError_onFailure() async {
        let vm = BibleViewModel()
        vm.curBook = "John"; vm.curChapter = 1
        vm.setHighlight(verse: 1, color: "#F5E642")
        let service = ThrowingTestDataService()
        service.clearHighlightError = AppError.networkError("Server error 500")
        vm.service = service

        vm.persistClearHighlight(verse: 1, userId: "user-123")
        await waitUntil { vm.saveError != nil }

        XCTAssertEqual(vm.highlights["John-1-1"], "#F5E642", "the optimistically-cleared highlight must be restored after a failed clear")
        XCTAssertEqual(vm.saveError, "Server error 500")
    }

    func test_persistToggleBookmark_add_revertsOptimisticMutation_andSurfacesError_onFailure() async {
        let vm = BibleViewModel()
        vm.curBook = "John"; vm.curChapter = 1
        let service = ThrowingTestDataService()
        service.saveBookmarkError = AppError.networkError("Session expired")
        vm.service = service

        XCTAssertFalse(vm.isBookmarked())
        vm.persistToggleBookmark(userId: "user-123")
        await waitUntil { vm.saveError != nil }

        XCTAssertFalse(vm.isBookmarked(), "the optimistic bookmark add must be reverted after a failed save")
        XCTAssertEqual(vm.saveError, "Session expired")
    }

    func test_persistToggleBookmark_remove_revertsOptimisticMutation_andSurfacesError_onFailure() async {
        let vm = BibleViewModel()
        vm.curBook = "John"; vm.curChapter = 1
        vm.bookmarks["John-1"] = ""
        let service = ThrowingTestDataService()
        service.removeBookmarkError = AppError.networkError("Server error 500")
        vm.service = service

        XCTAssertTrue(vm.isBookmarked())
        vm.persistToggleBookmark(userId: "user-123")
        await waitUntil { vm.saveError != nil }

        XCTAssertTrue(vm.isBookmarked(), "the optimistic bookmark removal must be reverted after a failed removeBookmark")
        XCTAssertEqual(vm.saveError, "Server error 500")
    }

    func test_persistHighlight_keepsMutation_onSuccess() async {
        let vm = BibleViewModel()
        vm.curBook = "John"; vm.curChapter = 1
        let service = ThrowingTestDataService()
        vm.service = service

        vm.persistHighlight(verse: 1, color: "#F5E642", userId: "user-123")
        await waitUntil { vm.highlights["John-1-1"] != nil }

        XCTAssertEqual(vm.highlights["John-1-1"], "#F5E642")
        XCTAssertNil(vm.saveError)
    }
}
