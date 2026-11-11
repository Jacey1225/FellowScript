// ProfileViewModelTests.swift (task 20261030-user-profiles, testing step 8)
// ProfileViewModel against a controllable DataServiceProtocol double:
// 404 evicts, network/5xx keeps the cache, first-load failure never
// fabricates, friend actions refetch (uniform D5 responses), bio rules mirror
// the server (NFC + whitespace collapse, 160), draft survives failures,
// unfriend undo / immediate commit, block, report.

import XCTest
@testable import FellowScript

// Seam state lives in statics because an extension cannot add stored properties
// (same pattern as RenameDeleteSeam in ThreadRenameDeleteTests.swift).
enum ProfileSeam {
    static var fetchQueue: [Result<FSProfile, Error>] = []
    static var fetchFallback: Result<FSProfile, Error>?
    static var fetchCalls = 0
    static var updateBioResult: Result<String?, Error> = .success(nil)
    static var updateBioSent: [String?] = []
    static var sendError: Error?
    static var sendCalls = 0
    static var acceptError: Error?
    static var acceptCalls = 0

    static func reset() {
        fetchQueue = []; fetchFallback = nil; fetchCalls = 0
        updateBioResult = .success(nil); updateBioSent = []
        sendError = nil; sendCalls = 0; acceptError = nil; acceptCalls = 0
    }
}

extension ThrowingTestDataService {
    func fetchProfile(targetId: String) async throws -> FSProfile {
        ProfileSeam.fetchCalls += 1
        if !ProfileSeam.fetchQueue.isEmpty { return try ProfileSeam.fetchQueue.removeFirst().get() }
        if let fallback = ProfileSeam.fetchFallback { return try fallback.get() }
        throw AppError.networkError("Profiles aren't available right now.")
    }
    func updateBio(userId: String, bio: String?) async throws -> String? {
        ProfileSeam.updateBioSent.append(bio)
        return try ProfileSeam.updateBioResult.get()
    }
    func sendProfileFriendRequest(targetId: String) async throws {
        ProfileSeam.sendCalls += 1
        if let e = ProfileSeam.sendError { throw e }
    }
    func acceptProfileFriendRequest(targetId: String) async throws {
        ProfileSeam.acceptCalls += 1
        if let e = ProfileSeam.acceptError { throw e }
    }
}

@MainActor
final class ProfileViewModelTests: XCTestCase {

    private let viewer = "viewer-1"
    private let target = "target-1"
    private var service: ThrowingTestDataService!
    private var cache: ProfileCache!

    override func setUp() async throws {
        try await super.setUp()
        ProfileSeam.reset()
        service = ThrowingTestDataService()
        cache = ProfileCache()
    }

    private func profile(_ rel: FSProfileRelationship, bio: String? = nil, visible: Bool = true,
                         editable: Bool = false, id: String? = nil) -> FSProfile {
        FSProfile(user_id: id ?? target, username: "Ann", relationship: rel, editable: editable,
                  bio: bio, bioVisible: visible)
    }

    private func makeVM(target: String? = nil) -> ProfileViewModel {
        ProfileViewModel(viewerId: viewer, targetId: target ?? self.target, service: service, cache: cache)
    }

    // MARK: load

    func test_load_success_setsLoadedAndCaches() async {
        ProfileSeam.fetchFallback = .success(profile(.friends, bio: "Hi"))
        let vm = makeVM()
        XCTAssertEqual(vm.phase, .loading)
        await vm.load()
        XCTAssertEqual(vm.phase, .loaded)
        XCTAssertEqual(vm.profile?.bio, "Hi")
        XCTAssertEqual(cache.profile(viewer: viewer, target: target)?.bio, "Hi")
        XCTAssertFalse(vm.isRefreshing)
    }

    func test_load_404_evictsCacheAndShowsUnavailable() async {
        cache.store(profile(.friends, bio: "old secret"), viewer: viewer)
        ProfileSeam.fetchFallback = .failure(AppError.notFound)
        let vm = makeVM()
        await vm.load()
        XCTAssertEqual(vm.phase, .unavailable)
        XCTAssertNil(vm.profile, "the cached bio must not stay on screen after a 404")
        XCTAssertNil(cache.profile(viewer: viewer, target: target))
    }

    func test_load_networkFailureWithCache_keepsCachedProfileAndSaysSo() async {
        cache.store(profile(.friends, bio: "cached bio"), viewer: viewer)
        ProfileSeam.fetchFallback = .failure(URLError(.notConnectedToInternet))
        let vm = makeVM()
        await vm.load()
        XCTAssertEqual(vm.phase, .loaded)
        XCTAssertEqual(vm.profile?.bio, "cached bio")
        XCTAssertEqual(vm.statusMessage, "Couldn't refresh. Showing what we had.")
        XCTAssertNotNil(cache.profile(viewer: viewer, target: target), "a failed refresh must not evict")
    }

    func test_load_serverErrorWithCache_keepsCachedProfile() async {
        cache.store(profile(.friends, bio: "cached bio"), viewer: viewer)
        ProfileSeam.fetchFallback = .failure(AppError.networkError("Server error 503"))
        let vm = makeVM()
        await vm.load()
        XCTAssertEqual(vm.profile?.bio, "cached bio")
        XCTAssertEqual(vm.phase, .loaded)
    }

    func test_load_firstLoadFailureWithoutCache_isFailedAndNeverFabricates() async {
        ProfileSeam.fetchFallback = .failure(URLError(.timedOut))
        let vm = makeVM()
        await vm.load()
        XCTAssertEqual(vm.phase, .failed)
        XCTAssertNil(vm.profile)
    }

    func test_load_recoversAfterFailure() async {
        ProfileSeam.fetchQueue = [.failure(URLError(.timedOut)), .success(profile(.none, visible: false))]
        let vm = makeVM()
        await vm.load()
        XCTAssertEqual(vm.phase, .failed)
        await vm.load()
        XCTAssertEqual(vm.phase, .loaded)
        XCTAssertFalse(vm.profile?.bioVisible ?? true)
    }

    func test_isSelf() {
        XCTAssertTrue(ProfileViewModel(viewerId: "a", targetId: "a", service: service, cache: cache).isSelf)
        XCTAssertFalse(makeVM().isSelf)
    }

    // MARK: friend actions

    func test_addFriend_refetchesAndShowsServerState_notAssumedRequestSent() async {
        // The send route is uniform: the server may record nothing. The UI must
        // show whatever the refetch says (still .none here).
        ProfileSeam.fetchFallback = .success(profile(.none, visible: false))
        let vm = makeVM()
        await vm.load()
        let fetchesBefore = ProfileSeam.fetchCalls
        await vm.addFriend()
        XCTAssertEqual(ProfileSeam.sendCalls, 1)
        XCTAssertEqual(ProfileSeam.fetchCalls, fetchesBefore + 1, "must refetch after the send")
        XCTAssertEqual(vm.profile?.relationship, FSProfileRelationship.none)
        XCTAssertNil(vm.actionError)
        XCTAssertFalse(vm.busy)
    }

    func test_addFriend_showsRequestSentOnlyWhenServerSaysSo() async {
        ProfileSeam.fetchQueue = [.success(profile(.none, visible: false)), .success(profile(.requestSent, visible: false))]
        let vm = makeVM()
        await vm.load()
        await vm.addFriend()
        XCTAssertEqual(vm.profile?.relationship, .requestSent)
    }

    func test_addFriend_rateLimited_usesGenericSlowDownCopy() async {
        ProfileSeam.fetchFallback = .success(profile(.none, visible: false))
        ProfileSeam.sendError = AppError.rateLimited("Too many requests. Please try again later.")
        let vm = makeVM()
        await vm.load()
        await vm.addFriend()
        XCTAssertEqual(vm.actionError, "Slow down a little and try again in a moment.")
    }

    func test_addFriend_otherFailure_usesUniformCopyThatRevealsNothing() async {
        ProfileSeam.fetchFallback = .success(profile(.none, visible: false))
        ProfileSeam.sendError = AppError.networkError("No pending friend request found")
        let vm = makeVM()
        await vm.load()
        await vm.addFriend()
        let msg = vm.actionError ?? ""
        XCTAssertEqual(msg, "Couldn't send that right now. Please try again.")
        for word in ["block", "not found", "exist", "already", "pending"] {
            XCTAssertFalse(msg.lowercased().contains(word), "D5: copy must not leak '\(word)'")
        }
    }

    func test_acceptRequest_success_refetchesFriendState() async {
        ProfileSeam.fetchQueue = [.success(profile(.requestReceived, visible: false)), .success(profile(.friends, bio: nil))]
        let vm = makeVM()
        await vm.load()
        await vm.acceptRequest()
        XCTAssertEqual(ProfileSeam.acceptCalls, 1)
        XCTAssertEqual(vm.profile?.relationship, .friends)
        XCTAssertTrue(vm.profile?.bioVisible ?? false)
    }

    func test_acceptRequest_failure_setsUniformMessage() async {
        ProfileSeam.fetchFallback = .success(profile(.requestReceived, visible: false))
        ProfileSeam.acceptError = AppError.notFound
        let vm = makeVM()
        await vm.load()
        await vm.acceptRequest()
        XCTAssertEqual(vm.actionError, "Couldn't accept that right now. Please try again.")
    }

    func test_friendActionMessage_mapping() {
        XCTAssertEqual(ProfileViewModel.friendActionMessage(AppError.rateLimited("x"), fallback: "F"),
                       "Slow down a little and try again in a moment.")
        XCTAssertEqual(ProfileViewModel.friendActionMessage(URLError(.timedOut), fallback: "F"), "F")
    }

    // MARK: bio rules

    func test_normalizedBio_collapsesWhitespaceAndNewlines_andTrims() {
        XCTAssertEqual(ProfileViewModel.normalizedBio("  a \n\n b\t c  "), "a b c")
        XCTAssertEqual(ProfileViewModel.normalizedBio("   \n "), "")
    }

    func test_normalizedBio_isNFC() {
        XCTAssertEqual(ProfileViewModel.normalizedBio("e\u{0301}").unicodeScalars.count, 1)
    }

    func test_draftLength_countedAfterNormalization() {
        let vm = makeVM()
        vm.draft = "  " + String(repeating: "a", count: 160) + " \n\n"
        XCTAssertEqual(vm.draftLength, 160)
        XCTAssertEqual(vm.draftRemaining, 0)
        XCTAssertTrue(vm.canSaveBio, "exactly 160 is allowed")
        vm.draft = String(repeating: "a", count: 161)
        XCTAssertEqual(vm.draftRemaining, -1)
        XCTAssertFalse(vm.canSaveBio, "161 blocks Save")
    }

    func test_bioMaxLength_mirrorsServerConfig() {
        XCTAssertEqual(ProfileViewModel.bioMaxLength, 160)
    }

    func test_beginEditingBio_onlyWhenEditable() async {
        ProfileSeam.fetchFallback = .success(profile(.friends, bio: "not mine", editable: false))
        let vm = makeVM()
        await vm.load()
        vm.beginEditingBio()
        XCTAssertFalse(vm.isEditingBio)
    }

    func test_beginEditingBio_prefillsDraftForSelf() async {
        ProfileSeam.fetchFallback = .success(profile(.selfUser, bio: "mine", editable: true, id: viewer))
        let vm = makeVM(target: viewer)
        await vm.load()
        vm.beginEditingBio()
        XCTAssertTrue(vm.isEditingBio)
        XCTAssertEqual(vm.draft, "mine")
    }

    func test_saveBio_success_sendsNormalizedText_showsStoredBio_closesEditor() async {
        ProfileSeam.fetchFallback = .success(profile(.selfUser, bio: nil, editable: true, id: viewer))
        ProfileSeam.updateBioResult = .success("Hello there")
        let vm = makeVM(target: viewer)
        await vm.load()
        vm.beginEditingBio()
        vm.draft = "  Hello \n\n there "
        await vm.saveBio()
        XCTAssertEqual(ProfileSeam.updateBioSent, ["Hello there"])
        XCTAssertEqual(vm.profile?.bio, "Hello there")
        XCTAssertFalse(vm.isEditingBio)
        XCTAssertNil(vm.bioError)
        XCTAssertTrue(vm.bioJustSaved)
        XCTAssertEqual(cache.profile(viewer: viewer, target: viewer)?.bio, "Hello there")
    }

    func test_saveBio_emptyDraft_sendsNilToClear() async {
        ProfileSeam.fetchFallback = .success(profile(.selfUser, bio: "old", editable: true, id: viewer))
        ProfileSeam.updateBioResult = .success(nil)
        let vm = makeVM(target: viewer)
        await vm.load()
        vm.beginEditingBio()
        vm.draft = "   \n  "
        await vm.saveBio()
        XCTAssertEqual(ProfileSeam.updateBioSent.count, 1)
        XCTAssertNil(ProfileSeam.updateBioSent[0] ?? nil)
        XCTAssertNil(vm.profile?.bio)
    }

    func test_saveBio_failure_keepsDraftAndEditorOpen_withServerSentence() async {
        ProfileSeam.fetchFallback = .success(profile(.selfUser, bio: nil, editable: true, id: viewer))
        ProfileSeam.updateBioResult = .failure(AppError.networkError("Bios are plain text, so links can't be saved."))
        let vm = makeVM(target: viewer)
        await vm.load()
        vm.beginEditingBio()
        vm.draft = "see evil.com"
        await vm.saveBio()
        XCTAssertEqual(vm.draft, "see evil.com", "the draft is never cleared on failure")
        XCTAssertTrue(vm.isEditingBio)
        XCTAssertEqual(vm.bioError, "Bios are plain text, so links can't be saved.")
        XCTAssertNil(vm.profile?.bio)
        XCTAssertFalse(vm.isSavingBio)
    }

    func test_saveBio_overLimit_doesNotCallServer() async {
        ProfileSeam.fetchFallback = .success(profile(.selfUser, bio: nil, editable: true, id: viewer))
        let vm = makeVM(target: viewer)
        await vm.load()
        vm.beginEditingBio()
        vm.draft = String(repeating: "x", count: 161)
        await vm.saveBio()
        XCTAssertTrue(ProfileSeam.updateBioSent.isEmpty)
    }

    func test_bioErrorMessage_mapping() {
        let generic = "Couldn't save your bio. Your text is still here."
        XCTAssertEqual(ProfileViewModel.bioErrorMessage(AppError.rateLimited("x")),
                       "You've edited a lot just now. Try again in a few minutes.")
        XCTAssertEqual(ProfileViewModel.bioErrorMessage(AppError.networkError("Server error 500")), generic)
        XCTAssertEqual(ProfileViewModel.bioErrorMessage(AppError.networkError("Please accept the latest Terms to edit your bio.")),
                       "Please accept the latest Terms to edit your bio.")
        XCTAssertEqual(ProfileViewModel.bioErrorMessage(URLError(.notConnectedToInternet)), generic)
    }

    // MARK: unfriend (deferred commit)

    func test_beginUnfriend_onlyForFriends() async {
        ProfileSeam.fetchFallback = .success(profile(.none, visible: false))
        let vm = makeVM()
        await vm.load()
        vm.beginUnfriend()
        XCTAssertFalse(vm.unfriendPending)
    }

    func test_beginUnfriend_hidesCachedBio_andDoesNotCallServerYet() async {
        ProfileSeam.fetchFallback = .success(profile(.friends, bio: "friend only"))
        let vm = makeVM()
        await vm.load()
        vm.beginUnfriend()
        XCTAssertTrue(vm.unfriendPending)
        XCTAssertNil(cache.profile(viewer: viewer, target: target), "bio hides from the cache the moment Unfriend is tapped")
        XCTAssertEqual(service.removeFriendCallCount, 0, "nothing is sent until the undo window ends")
        vm.undoUnfriend()
    }

    func test_undoUnfriend_cancelsAndNeverCallsServer() async {
        ProfileSeam.fetchFallback = .success(profile(.friends, bio: "x"))
        let vm = makeVM()
        await vm.load()
        vm.beginUnfriend()
        vm.undoUnfriend()
        XCTAssertFalse(vm.unfriendPending)
        await vm.commitUnfriendNow()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(service.removeFriendCallCount, 0)
    }

    func test_commitUnfriendNow_commitsOnceAndRefetches() async {
        ProfileSeam.fetchQueue = [.success(profile(.friends, bio: "x")), .success(profile(.none, visible: false))]
        let vm = makeVM()
        await vm.load()
        vm.beginUnfriend()
        await vm.commitUnfriendNow()
        XCTAssertEqual(service.removeFriendCallCount, 1)
        XCTAssertFalse(vm.unfriendPending)
        XCTAssertEqual(vm.profile?.relationship, FSProfileRelationship.none)
        await vm.commitUnfriendNow()
        XCTAssertEqual(service.removeFriendCallCount, 1, "a second commit is a no-op")
    }

    func test_commitUnfriend_failure_surfacesErrorAndRefetchesTruth() async {
        service.removeFriendError = AppError.networkError("Server error 500")
        ProfileSeam.fetchFallback = .success(profile(.friends, bio: "x"))
        let vm = makeVM()
        await vm.load()
        vm.beginUnfriend()
        await vm.commitUnfriendNow()
        XCTAssertEqual(vm.actionError, "Couldn't remove that friend. Please try again.")
        XCTAssertEqual(vm.profile?.relationship, .friends, "the server still says friends, so the UI says friends")
        XCTAssertFalse(vm.unfriendPending)
    }

    // MARK: block / report

    func test_block_success_evictsCacheAndReturnsTrue() async {
        ProfileSeam.fetchFallback = .success(profile(.friends, bio: "x"))
        let vm = makeVM()
        await vm.load()
        let ok = await vm.block()
        XCTAssertTrue(ok)
        XCTAssertEqual(service.blockUserCallCount, 1)
        XCTAssertNil(cache.profile(viewer: viewer, target: target))
    }

    func test_block_failure_returnsFalseWithMessage_keepsCache() async {
        service.blockUserError = AppError.networkError("Server error 500")
        ProfileSeam.fetchFallback = .success(profile(.friends, bio: "x"))
        let vm = makeVM()
        await vm.load()
        let ok = await vm.block()
        XCTAssertFalse(ok)
        XCTAssertEqual(vm.actionError, "Couldn't block right now. Please try again.")
        XCTAssertNotNil(cache.profile(viewer: viewer, target: target))
    }

    func test_report_success_andFailure() async {
        let vm = makeVM()
        await vm.report(reason: "spam", detail: "d")
        XCTAssertEqual(service.reportUserCallCount, 1)
        XCTAssertEqual(vm.statusMessage, "Report submitted. We review every report within 24 hours.")
        service.reportUserError = AppError.networkError("Server error 500")
        await vm.report(reason: "spam", detail: "d")
        XCTAssertEqual(vm.actionError, "Couldn't send the report. Please try again.")
    }
}
