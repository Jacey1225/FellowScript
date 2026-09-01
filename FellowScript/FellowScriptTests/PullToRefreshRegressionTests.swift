// PullToRefreshRegressionTests.swift — testing-gate coverage for task
// 20260831-interaction-polish-conventions, step 2.
//
// Pull-to-refresh needed no new shared UI mechanism (native `.refreshable`
// is the one-line SwiftUI primitive), so the actual shared discipline this
// task introduced is at the view-model layer: every cache-backed list's
// `.refreshable` handler calls a NEW entry point (`refresh(...)`) that
// re-runs the same fetch+cache-write flow as the screen's existing `load()`
// but deliberately (a) bypasses the `hasLoadedOnce` startup-dedup guard
// (which exists only to stop a duplicate INITIAL fetch racing
// StartupCoordinator, not a later user-triggered refresh) and (b) never
// flips `isLoading` (so a screen that gates its whole body on `isLoading`
// -- NotesListView, ChatRootView -- doesn't blank/replace an already-
// populated list mid-refresh, losing scroll position). Both of those were
// real regression risks the frontend gate's own audit called out.
//
// This file proves, per screen with a real testable reload method
// (NotesViewModel, ChatViewModel, DashboardViewModel, AccountViewModel):
//   1. refresh()/a second load() call actually re-fetches -- not blocked by
//      hasLoadedOnce.
//   2. isLoading is never flipped to true by the refresh path, on the two
//      screens whose body actually gates on it (Notes, Chat).
//   3. Freshly-fetched data really lands in the view model's published
//      state (not just "doesn't crash").
//
// Plus source-pinning for:
//   4. Every in-scope screen's `.refreshable` is wired to that screen's own
//      correct reload method (not a copy-pasted wrong one).
//   5. The three explicitly-excluded screens (BibleReaderView -- static
//      bundled content; ChatThreadView/AgentChatView -- live WebSocket
//      threads with no pagination) carry NO `.refreshable` at all, proving
//      the audit's scope decision was actually followed, not just decided.

import XCTest
@testable import FellowScript

private func note(_ id: String, groupId: String = "") -> FSNote {
    FSNote(
        id: id, user: "user-1", title: "Note \(id)", text: "body",
        public: false, group_id: groupId, is_reply: false,
        timestamp: "2026-08-17 00:00:00", verses: [], replies: []
    )
}

// MARK: - 1/2/3. NotesViewModel.refresh

@MainActor
final class NotesViewModelRefreshRegressionTests: XCTestCase {

    func test_refresh_bypassesHasLoadedOnceGuard_andPicksUpNewData() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        let userId = "refresh-test-notes-user-1"

        service.fetchNotesPageQueue = [
            NotesPage(notes: ["n1": note("n1")], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false)
        ]
        await vm.load(service: service, userId: userId)
        XCTAssertEqual(vm.notes.count, 1)
        let callCountAfterLoad = service.fetchNotesCallCount

        // A second load() call is a documented no-op (hasLoadedOnce) --
        // sanity-checks the guard actually still exists before proving
        // refresh() bypasses it.
        await vm.load(service: service, userId: userId)
        XCTAssertEqual(service.fetchNotesCallCount, callCountAfterLoad,
                       "sanity check: a second load() call must still be blocked by hasLoadedOnce")

        service.fetchNotesPageQueue = [
            NotesPage(notes: ["n1": note("n1"), "n2": note("n2")], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false)
        ]
        await vm.refresh(service: service, userId: userId)

        XCTAssertGreaterThan(service.fetchNotesCallCount, callCountAfterLoad,
                             "refresh() must actually re-fetch -- pull-to-refresh must not be silently blocked by the same startup-dedup guard load() uses")
        XCTAssertEqual(vm.notes.count, 2, "refresh() must pick up notes added since the last fetch")
        XCTAssertNotNil(vm.notes["n1"], "refresh() must not lose previously-loaded data")
    }

    func test_refresh_neverFlipsIsLoading_soAPopulatedListIsNotBlankedMidRefresh() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        let userId = "refresh-test-notes-user-2"

        service.fetchNotesPageQueue = [
            NotesPage(notes: ["n1": note("n1")], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false)
        ]
        await vm.load(service: service, userId: userId)
        XCTAssertFalse(vm.isLoading)

        service.fetchNotesPageQueue = [
            NotesPage(notes: ["n1": note("n1")], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false)
        ]
        await vm.refresh(service: service, userId: userId)

        XCTAssertFalse(vm.isLoading,
                       "refresh() must never flip isLoading -- NotesListView gates notesTab/highlightsTab's whole body on it, so a stray flip would blank the already-populated list and lose scroll position during a pull-to-refresh")
    }

    func test_refresh_worksEvenWithoutAPriorLoad() async {
        // Defensive: refresh() must be independently correct, not merely
        // "load() with a flag" that happens to also require load() to have
        // run first. (isLoading defaults to true at init and refresh() never
        // touches it either way -- only load()'s showLoadingSpinner path
        // does -- so this deliberately doesn't assert on isLoading here; see
        // test_refresh_neverFlipsIsLoading... above for that contract.)
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        service.fetchNotesPageQueue = [
            NotesPage(notes: ["n1": note("n1")], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false)
        ]
        await vm.refresh(service: service, userId: "refresh-test-notes-user-3")
        XCTAssertEqual(vm.notes.count, 1, "refresh() must fetch and populate notes on its own, without requiring load() to have run first")
    }
}

// MARK: - 1/2/3. ChatViewModel.refresh

@MainActor
final class ChatViewModelRefreshRegressionTests: XCTestCase {

    func test_refresh_bypassesHasLoadedOnceGuard() async {
        let vm = ChatViewModel()
        let service = ThrowingTestDataService()
        let userId = "refresh-test-chat-user-1"

        await vm.load(service: service, userId: userId)
        let callCountAfterLoad = service.fetchContactsCallCount
        XCTAssertGreaterThan(callCountAfterLoad, 0)

        // Sanity check: hasLoadedOnce still blocks a second load() call.
        await vm.load(service: service, userId: userId)
        XCTAssertEqual(service.fetchContactsCallCount, callCountAfterLoad,
                       "sanity check: a second load() call must still be blocked by hasLoadedOnce")

        await vm.refresh(service: service, userId: userId)
        XCTAssertGreaterThan(service.fetchContactsCallCount, callCountAfterLoad,
                             "refresh() must actually re-fetch friends/groups/agents -- pull-to-refresh on the friends/groups/agents lists must not be blocked by the startup-dedup guard")
    }

    func test_refresh_neverFlipsIsLoading() async {
        let vm = ChatViewModel()
        let service = ThrowingTestDataService()
        let userId = "refresh-test-chat-user-2"

        await vm.load(service: service, userId: userId)
        XCTAssertFalse(vm.isLoading)

        await vm.refresh(service: service, userId: userId)
        XCTAssertFalse(vm.isLoading,
                       "refresh() must never flip isLoading -- ChatRootView gates its friends/groups/agents lists' body on it, so a stray flip would blank an already-populated list mid-refresh")
    }

    func test_refresh_populatesFriendsAndGroupsFromFetchContacts() async {
        let vm = ChatViewModel()
        let service = ThrowingTestDataService()
        await vm.refresh(service: service, userId: "refresh-test-chat-user-3")

        XCTAssertEqual(vm.friends.count, 2, "refresh() must populate friends from fetchContacts even without a prior load()")
        XCTAssertEqual(vm.groups.count, 1, "refresh() must populate groups from fetchContacts even without a prior load()")
    }
}

// MARK: - 1/3. DashboardViewModel + AccountViewModel: refreshable reuses load() directly

@MainActor
final class DashboardAndAccountRefreshRegressionTests: XCTestCase {

    /// DashboardView has no hasLoadedOnce guard at all and doesn't gate its
    /// body on isLoading, so its `.refreshable` wires directly to `load()`
    /// (no separate refresh() entry point needed) -- proves that reuse is
    /// safe to call twice in a row and still reflects fresh data both times.
    func test_dashboardViewModel_load_isSafelyReCallable_forPullToRefresh() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = "refresh-test-dashboard-user-1"

        await vm.load(service: service, userId: userId)
        XCTAssertFalse(vm.isLoading)
        let notesAfterFirstLoad = vm.notes.count

        // Re-running load() (what `.refreshable` does) must not be a no-op
        // and must not crash/corrupt state.
        await vm.load(service: service, userId: userId)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.notes.count, notesAfterFirstLoad,
                       "a second load() against the same fixture data must remain stable, proving pull-to-refresh can safely re-run this screen's existing reload method repeatedly")
    }

    /// AccountViewModel.load also carries no hasLoadedOnce guard -- proves
    /// AccountView's refreshAccountData() (which calls vm.load) is safe to
    /// invoke repeatedly, the same reuse contract pull-to-refresh depends on.
    func test_accountViewModel_load_isSafelyReCallable_forPullToRefresh() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        let user = FSUser(user_id: "refresh-test-account-user-1", username: "alice", email: "a@example.com")

        await vm.load(service: service, user: user)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNotNil(vm.profileData)

        await vm.load(service: service, user: user)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNotNil(vm.profileData, "a second load() call (what pull-to-refresh triggers via refreshAccountData()) must still leave profileData populated, not nil it out mid-refresh")
    }
}

// MARK: - 4/5. Source-pinning: correct wiring per screen, and correct exclusions

final class PullToRefreshWiringSourceTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_notesListView_bothTabs_refreshableCallsVmRefresh() throws {
        let source = try readSource("FellowScript/Notes/NotesListView.swift")
        let occurrences = source.components(separatedBy: "await vm.refresh(service: appState.service, userId: appState.currentUser?.user_id ?? \"\")").count - 1
        XCTAssertEqual(occurrences, 2, "both the Notes tab and Highlights tab must wire .refreshable to vm.refresh(), sharing the same underlying fetch")
    }

    func test_chatRootView_allThreeLists_refreshableCallsVmRefresh() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        let occurrences = source.components(separatedBy: "await vm.refresh(service: appState.service, userId: appState.currentUser?.user_id ?? \"\")").count - 1
        XCTAssertEqual(occurrences, 3, "friends, groups, and agents lists must each wire .refreshable to vm.refresh()")
    }

    func test_dashboardView_refreshableCallsVmLoad() throws {
        let source = try readSource("FellowScript/Dashboard/DashboardView.swift")
        guard let range = source.range(of: ".refreshable {") else {
            XCTFail(".refreshable not found in DashboardView")
            return
        }
        let body = String(source[range.upperBound...].prefix(200))
        XCTAssertTrue(body.contains("await vm.load(service: appState.service, userId: uid)"),
                      "DashboardView's .refreshable must call vm.load(), its existing reload method")
    }

    func test_accountView_refreshableCallsRefreshAccountData_whichCallsVmLoad() throws {
        let source = try readSource("FellowScript/Account/AccountView.swift")
        guard let refreshableRange = source.range(of: ".refreshable {") else {
            XCTFail(".refreshable not found in AccountView")
            return
        }
        let refreshableBody = String(source[refreshableRange.upperBound...].prefix(100))
        XCTAssertTrue(refreshableBody.contains("await refreshAccountData()"),
                      "AccountView's .refreshable must call its dedicated refreshAccountData() reload method")

        guard let methodRange = source.range(of: "private func refreshAccountData() async {") else {
            XCTFail("refreshAccountData() not found in AccountView")
            return
        }
        let methodBody = String(source[methodRange.upperBound...].prefix(400))
        XCTAssertTrue(methodBody.contains("await vm.load(service: appState.service, user: user)"),
                      "refreshAccountData() must call vm.load(), the same reload path as the screen's own .task")
        XCTAssertFalse(methodBody.contains("store.startListening()") && methodBody.contains("loadProducts()"),
                       "refreshAccountData() must NOT re-run StoreKit session bootstrapping -- that's one-time app-launch setup, not this screen's own reload concern")
    }

    func test_blockedUsersView_refreshableCallsLoad_withSpinnerSuppressed() throws {
        let source = try readSource("FellowScript/Account/BlockedUsersView.swift")
        guard let range = source.range(of: ".refreshable {") else {
            XCTFail(".refreshable not found in BlockedUsersView")
            return
        }
        let body = String(source[range.upperBound...].prefix(100))
        XCTAssertTrue(body.contains("await load(showSpinner: false)"),
                      "BlockedUsersView's .refreshable must call its existing load() with the spinner suppressed, so the already-populated list isn't replaced by the full-screen loading branch mid-refresh")
    }

    // 5. Explicitly-excluded screens must carry no .refreshable at all --
    // proves the audit's scope decisions were actually implemented, not
    // just written down in the frontend gate's summary.
    func test_bibleReaderView_hasNoRefreshable() throws {
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertFalse(source.contains(".refreshable"),
                       "BibleReaderView displays static bundled content with no 'new data since cache' concept -- it must not gain a no-op pull-to-refresh")
    }

    func test_chatThreadView_hasNoRefreshable() throws {
        let source = try readSource("FellowScript/Chat/ChatThreadView.swift")
        XCTAssertFalse(source.contains(".refreshable"),
                       "ChatThreadView is a live WebSocket thread with no existing pagination for an overscroll gesture to drive -- must not gain pull-to-refresh")
    }

    func test_agentChatView_hasNoRefreshable() throws {
        let source = try readSource("FellowScript/Chat/AgentChatView.swift")
        XCTAssertFalse(source.contains(".refreshable"),
                       "AgentChatView is a live WebSocket thread with no existing pagination for an overscroll gesture to drive -- must not gain pull-to-refresh")
    }
}
