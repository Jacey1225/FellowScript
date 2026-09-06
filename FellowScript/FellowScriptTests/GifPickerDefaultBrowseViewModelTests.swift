// GifPickerDefaultBrowseViewModelTests.swift — coverage for task
// 20260905-gif-picker-default-browse (testing step 4, the final gate)'s
// iOS-side GifSearchViewModel additions (MessageAttachments.swift).
//
// Exercised directly against GifSearchViewModel (a plain @MainActor
// ObservableObject) using ThrowingTestDataService's browseGifs queue
// (AppStateAuthAccountTests.swift) for full, sequenced control over
// success/failure/pagination -- no view rendering required, matching the
// existing network-layer-test precedent (MessagingAttachmentsNetworkServiceTests)
// one level up the stack.
//
// Covers:
//   - fetchBrowse: loading -> success populates browseResults/
//     browseNextPageToken/browseHasMore and clears browseErrored; a failure
//     sets browseErrored without touching any previously-held results.
//   - loadMoreBrowse: appends to (never replaces) browseResults, updates the
//     page token/hasMore from the new page; a failure leaves already-loaded
//     results untouched and sets loadMoreErrored, distinct from browseErrored;
//     a second successful call after a failure clears loadMoreErrored again;
//     re-entrancy guard -- a call while one is already in flight is a no-op.
//   - isSearching / query-cleared semantics: isSearching reflects only the
//     trimmed query, independent of browse state, so the view can revert to
//     the already-held browse grid the instant a query is cleared with no
//     refetch.
//   - queryChanged: a blank/whitespace query clears search `results` without
//     ever touching browse state.

import XCTest
@testable import FellowScript

@MainActor
final class GifPickerDefaultBrowseViewModelTests: XCTestCase {

    private func gif(_ id: String) -> FSGifResult {
        FSGifResult(id: id, url: "https://example.com/\(id).gif", preview_url: "https://example.com/\(id)-small.gif", width: 200, height: 150)
    }

    // MARK: - fetchBrowse

    func test_fetchBrowse_success_populatesResultsTokenAndHasMore() async {
        let service = ThrowingTestDataService()
        service.browseGifsQueue = [.success(results: [gif("a1"), gif("a2")], nextPageToken: "page-2", hasMore: true)]
        let vm = GifSearchViewModel()

        await vm.fetchBrowse(service: service)

        XCTAssertEqual(vm.browseResults.map(\.id), ["a1", "a2"])
        XCTAssertEqual(vm.browseNextPageToken, "page-2")
        XCTAssertTrue(vm.browseHasMore)
        XCTAssertFalse(vm.browseErrored)
        XCTAssertFalse(vm.browseLoading, "must not be left stuck loading after completion")
        XCTAssertEqual(service.browseGifsPageTokens, [nil], "the initial browse fetch requests the first page (nil token)")
    }

    func test_fetchBrowse_failure_setsBrowseErrored_withoutTouchingPriorResults() async {
        let service = ThrowingTestDataService()
        service.browseGifsQueue = [
            .success(results: [gif("a1")], nextPageToken: nil, hasMore: false),
            .failure(AppError.networkError("boom")),
        ]
        let vm = GifSearchViewModel()

        await vm.fetchBrowse(service: service) // seeds a successful prior state
        XCTAssertFalse(vm.browseErrored)

        await vm.fetchBrowse(service: service) // this call fails
        XCTAssertTrue(vm.browseErrored)
        XCTAssertFalse(vm.browseLoading)
        // A failed refetch must not clobber/blank the previously-shown page --
        // GifSearchSheet's error branch is keyed off `browseErrored`, not off
        // `browseResults` being empty, precisely so a transient refetch
        // failure doesn't flash the grid away.
        XCTAssertEqual(vm.browseResults.map(\.id), ["a1"])
    }

    // MARK: - loadMoreBrowse

    func test_loadMoreBrowse_appendsRatherThanReplaces_andAdvancesPagination() async {
        let service = ThrowingTestDataService()
        service.browseGifsQueue = [
            .success(results: [gif("a1")], nextPageToken: "page-2", hasMore: true),
            .success(results: [gif("a2"), gif("a3")], nextPageToken: nil, hasMore: false),
        ]
        let vm = GifSearchViewModel()
        await vm.fetchBrowse(service: service)

        await vm.loadMoreBrowse(service: service)

        XCTAssertEqual(vm.browseResults.map(\.id), ["a1", "a2", "a3"], "load-more appends, never replaces")
        XCTAssertNil(vm.browseNextPageToken)
        XCTAssertFalse(vm.browseHasMore)
        XCTAssertFalse(vm.loadMoreErrored)
        XCTAssertFalse(vm.loadMoreLoading)
        XCTAssertEqual(service.browseGifsPageTokens, [nil, "page-2"], "load-more re-sends the stored next-page token, unmodified")
    }

    func test_loadMoreBrowse_failure_leavesExistingResultsIntact_andSetsDistinctErrorFlag() async {
        let service = ThrowingTestDataService()
        service.browseGifsQueue = [
            .success(results: [gif("a1")], nextPageToken: "page-2", hasMore: true),
            .failure(AppError.networkError("load-more blip")),
        ]
        let vm = GifSearchViewModel()
        await vm.fetchBrowse(service: service)

        await vm.loadMoreBrowse(service: service)

        XCTAssertEqual(vm.browseResults.map(\.id), ["a1"], "a load-more failure must not disturb already-loaded results")
        XCTAssertTrue(vm.loadMoreErrored)
        XCTAssertFalse(vm.browseErrored, "load-more failure is a distinct flag from the initial-load failure -- "
            + "the grid itself must not flip into the full-sheet error state over a load-more hiccup")
        XCTAssertEqual(vm.browseNextPageToken, "page-2", "the token is preserved so a retry re-requests the same page")
    }

    func test_loadMoreBrowse_retryAfterFailure_succeedsAndClearsErrorFlag() async {
        let service = ThrowingTestDataService()
        service.browseGifsQueue = [
            .success(results: [gif("a1")], nextPageToken: "page-2", hasMore: true),
            .failure(AppError.networkError("load-more blip")),
            .success(results: [gif("a2")], nextPageToken: nil, hasMore: false),
        ]
        let vm = GifSearchViewModel()
        await vm.fetchBrowse(service: service)
        await vm.loadMoreBrowse(service: service)
        XCTAssertTrue(vm.loadMoreErrored)

        await vm.loadMoreBrowse(service: service) // retry, reusing the same stored token

        XCTAssertFalse(vm.loadMoreErrored)
        XCTAssertEqual(vm.browseResults.map(\.id), ["a1", "a2"])
        XCTAssertEqual(service.browseGifsPageTokens, [nil, "page-2", "page-2"], "retry re-sends the identical stored token")
    }

    func test_loadMoreBrowse_reentrancyGuard_ignoresACallWhileOneIsAlreadyInFlight() async {
        let service = ThrowingTestDataService()
        service.browseGifsQueue = [.success(results: [gif("a1")], nextPageToken: "page-2", hasMore: true)]
        let vm = GifSearchViewModel()
        await vm.fetchBrowse(service: service)
        vm.loadMoreLoading = true // simulate an in-flight load-more

        await vm.loadMoreBrowse(service: service)

        XCTAssertEqual(service.browseGifsPageTokens, [nil], "a second load-more call while one is in flight must be a no-op, "
            + "never firing a duplicate/overlapping request for the same page")
    }

    // MARK: - isSearching / query-cleared semantics

    func test_isSearching_reflectsOnlyTrimmedQuery_independentOfBrowseState() {
        let vm = GifSearchViewModel()
        XCTAssertFalse(vm.isSearching)

        vm.query = "   "
        XCTAssertFalse(vm.isSearching, "whitespace-only input still counts as no query -- shows the browse grid, not search")

        vm.query = "cats"
        XCTAssertTrue(vm.isSearching)
    }

    func test_queryChanged_blankQuery_clearsSearchResults_withoutTouchingBrowseState() {
        let service = ThrowingTestDataService()
        let vm = GifSearchViewModel()
        vm.results = [gif("stale-search-result")]
        vm.browseResults = [gif("a1")] // already-held browse state from an earlier open

        vm.queryChanged("", service: service)

        XCTAssertTrue(vm.results.isEmpty, "clearing the query drops stale search results")
        XCTAssertFalse(vm.isLoading)
        // Clearing the query must never touch already-held browse state --
        // that retained state is exactly what lets the UI revert to the
        // browse grid instantly, with no refetch.
        XCTAssertEqual(vm.browseResults.map(\.id), ["a1"])
    }
}
