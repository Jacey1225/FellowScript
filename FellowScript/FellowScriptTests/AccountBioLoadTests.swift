// AccountBioLoadTests.swift (task 20261125-account-page-cleanup, testing step 3)
// NOT COMPILED OR RUN: written on a Linux host with no Xcode. Verify on a Mac
// (one xcodebuild/simulator run at a time). Covers the ProfileViewModel paths
// the Account "Edit Profile" bio field (AccountBioField) relies on: a failed
// first load never fabricates a profile (so no editor and no Save), a failed
// refresh keeps the cached bio, a failed save keeps the draft, a save sends
// nil for an empty bio.

import XCTest
@testable import FellowScript

@MainActor
final class AccountBioLoadTests: XCTestCase {
    private let me = "me-1"
    private var service: ThrowingTestDataService!
    private var cache: ProfileCache!

    override func setUp() async throws {
        try await super.setUp()
        ProfileSeam.reset()
        service = ThrowingTestDataService()
        cache = ProfileCache()
    }

    private func mine(bio: String?) -> FSProfile {
        FSProfile(user_id: me, username: "Me", relationship: .selfUser, editable: true,
                  bio: bio, bioVisible: true)
    }

    private func makeVM() -> ProfileViewModel {
        ProfileViewModel(viewerId: me, targetId: me, service: service, cache: cache)
    }

    func test_firstLoadFailure_withNoCache_leavesProfileNil_soNoEditorOrSave() async {
        ProfileSeam.fetchFallback = .failure(AppError.networkError("down"))
        let vm = makeVM()
        await vm.load()
        XCTAssertNil(vm.profile, "must not fabricate an empty profile/bio")
        XCTAssertEqual(vm.phase, .failed)
        await vm.saveBio()
        XCTAssertTrue(ProfileSeam.updateBioSent.isEmpty, "Save must be a no-op without a loaded profile")
    }

    func test_failedRefresh_keepsCachedBio() async {
        cache.store(mine(bio: "cached bio"), viewer: me)
        ProfileSeam.fetchFallback = .failure(AppError.networkError("down"))
        let vm = makeVM()
        await vm.load()
        XCTAssertEqual(vm.profile?.bio, "cached bio")
        XCTAssertEqual(vm.phase, .loaded)
    }

    func test_failedSave_keepsDraft_andShowsSharedErrorCopy() async {
        ProfileSeam.fetchFallback = .success(mine(bio: "old"))
        let vm = makeVM()
        await vm.load()
        vm.draft = "new text"
        ProfileSeam.updateBioResult = .failure(AppError.rateLimited("slow"))
        await vm.saveBio()
        XCTAssertEqual(vm.draft, "new text")
        XCTAssertEqual(vm.bioError, ProfileViewModel.bioErrorMessage(AppError.rateLimited("slow")))
        XCTAssertEqual(vm.profile?.bio, "old")
    }

    func test_emptyDraft_savesAsNil_andOverLimitBlocksSave() async {
        ProfileSeam.fetchFallback = .success(mine(bio: "old"))
        let vm = makeVM()
        await vm.load()
        vm.draft = "  \n "
        ProfileSeam.updateBioResult = .success(nil)
        await vm.saveBio()
        XCTAssertEqual(ProfileSeam.updateBioSent.count, 1)
        XCTAssertNil(ProfileSeam.updateBioSent[0] ?? nil)
        XCTAssertTrue(vm.bioJustSaved)

        vm.draft = String(repeating: "a", count: ProfileViewModel.bioMaxLength + 1)
        XCTAssertFalse(vm.canSaveBio)
    }
}
