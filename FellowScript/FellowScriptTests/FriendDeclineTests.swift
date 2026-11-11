// FriendDeclineTests.swift -- task 20261030-profile-everywhere (step 15).
// (1) from_user_id on paged rows decodes into FSMessage.senderId (never for my
//     own rows, never when absent/empty), without touching the sender name.
// (2) AccountViewModel.declineRequest: the row leaves at once, stays gone on
//     success, and is restored (same order) with warm copy on any failure.
// (3) ProfileViewModel.declineRequest: right ids sent, refetch on success,
//     warm copy and no fabricated state on failure.

import XCTest
@testable import FellowScript

// Seam state in statics (an extension cannot add stored properties); same
// pattern as ProfileSeam in ProfileViewModelTests.swift.
enum DeclineSeam {
    static var error: Error?
    static var calls: [(userId: String, senderId: String)] = []
    static func reset() { error = nil; calls = [] }
}

extension ThrowingTestDataService {
    func declineFriendRequest(userId: String, senderId: String) async throws {
        DeclineSeam.calls.append((userId, senderId))
        if let e = DeclineSeam.error { throw e }
    }
}

final class PagedRowSenderIdDecodeTests: XCTestCase {
    private let id = "123e4567-e89b-42d3-a456-426614174000"

    private func paged(_ json: String) throws -> FSMessage {
        NetworkService.pagedMessage(try JSONDecoder().decode(RawMsg.self, from: Data(json.utf8)))
    }

    func test_fromUserId_onAnotherSender_becomesSenderId_andNameIsUntouched() throws {
        let m = try paged(#"{"id":"m1","text":"hi","from_user":"ada","from_user_id":"\#(id)","timestamp":"t","mine":false}"#)
        XCTAssertEqual(m.senderId, id)
        XCTAssertEqual(m.sender, "ada")
    }

    func test_absentFromUserId_leavesSenderIdNil() throws {
        let m = try paged(#"{"id":"m1","text":"hi","from_user":"ada","timestamp":"t","mine":false}"#)
        XCTAssertNil(m.senderId)
        XCTAssertEqual(m.sender, "ada")
    }

    func test_emptyFromUserId_isNil() throws {
        let m = try paged(#"{"id":"m1","text":"hi","from_user":"ada","from_user_id":"","timestamp":"t","mine":false}"#)
        XCTAssertNil(m.senderId)
    }

    func test_nullFromUserId_isNil() throws {
        let m = try paged(#"{"id":"m1","text":"hi","from_user":"ada","from_user_id":null,"timestamp":"t","mine":false}"#)
        XCTAssertNil(m.senderId)
    }

    func test_myOwnRow_neverGetsSenderId() throws {
        let m = try paged(#"{"id":"m1","text":"hi","from_user":"me","from_user_id":"\#(id)","timestamp":"t","mine":true}"#)
        XCTAssertNil(m.senderId)
        XCTAssertEqual(m.sender, "")
    }

    func test_rowWithoutMineFlag_isNotTreatedAsMine() throws {
        let m = try paged(#"{"id":"m1","text":"hi","from_user":"ada","from_user_id":"\#(id)","timestamp":"t"}"#)
        XCTAssertEqual(m.senderId, id)
    }

    func test_rawMsg_decodesOldServerRowWithoutTheKey() throws {
        let raw = try JSONDecoder().decode(RawMsg.self, from: Data(#"{"id":"m1","text":"hi","timestamp":"t","mine":false}"#.utf8))
        XCTAssertNil(raw.from_user_id)
    }

    func test_otherKeysStillMapOnARowThatHasTheId() throws {
        let m = try paged(#"{"id":"m9","text":"hello","from_user":"ada","from_user_id":"\#(id)","timestamp":"t","mine":false,"pinned":true}"#)
        XCTAssertEqual(m.id, "m9")
        XCTAssertEqual(m.text, "hello")
        XCTAssertEqual(m.pinned, true)
    }
}

@MainActor
final class AccountDeclineTests: XCTestCase {
    private typealias Req = (id: String, username: String, profile_photo_url: String?)
    private let ann = "11111111-1111-4111-8111-111111111111"
    private let bob = "22222222-2222-4222-8222-222222222222"
    private let cy = "33333333-3333-4333-8333-333333333333"
    private var service: ThrowingTestDataService!

    override func setUp() async throws {
        try await super.setUp()
        DeclineSeam.reset()
        service = ThrowingTestDataService()
    }

    private func makeVM(signedIn: Bool = true) -> AccountViewModel {
        let vm = AccountViewModel()
        vm.service = service
        if signedIn {
            vm.profileData = FSUser(user_id: "me-1", username: "me", email: "me@example.com")
        }
        vm.friendRequests = [(ann, "ann", nil), (bob, "bob", nil), (cy, "cy", nil)] as [Req]
        return vm
    }

    func test_success_removesOnlyThatRow_andSendsRecipientOnlyArguments() async {
        let vm = makeVM()
        await vm.declineRequest(senderId: bob)
        XCTAssertEqual(vm.friendRequests.map(\.id), [ann, cy])
        XCTAssertEqual(DeclineSeam.calls.count, 1)
        XCTAssertEqual(DeclineSeam.calls.first?.userId, "me-1")
        XCTAssertEqual(DeclineSeam.calls.first?.senderId, bob)
        XCTAssertNil(vm.friendMsg)
    }

    func test_failure_restoresTheRowInItsOriginalPosition_withWarmCopy() async {
        DeclineSeam.error = URLError(.notConnectedToInternet)
        let vm = makeVM()
        await vm.declineRequest(senderId: bob)
        XCTAssertEqual(vm.friendRequests.map(\.id), [ann, bob, cy], "a failed decline must not silently drop the request")
        XCTAssertEqual(vm.friendMsg, AccountViewModel.declineFailureMessage)
    }

    func test_serverError_restoresRow_andDoesNotSurfaceServerText() async {
        DeclineSeam.error = AppError.networkError("psycopg2 boom internals")
        let vm = makeVM()
        await vm.declineRequest(senderId: ann)
        XCTAssertEqual(vm.friendRequests.map(\.id), [ann, bob, cy])
        XCTAssertEqual(vm.friendMsg, AccountViewModel.declineFailureMessage)
        XCTAssertFalse((vm.friendMsg ?? "").contains("psycopg2"))
    }

    func test_rateLimited_restoresRow_withSlowDownCopy() async {
        DeclineSeam.error = AppError.rateLimited("Too many requests")
        let vm = makeVM()
        await vm.declineRequest(senderId: cy)
        XCTAssertEqual(vm.friendRequests.map(\.id), [ann, bob, cy])
        XCTAssertEqual(vm.friendMsg, "Slow down a little and try again in a moment.")
    }

    func test_notSignedIn_isANoOp_noRequestSent() async {
        let vm = makeVM(signedIn: false)
        await vm.declineRequest(senderId: ann)
        XCTAssertTrue(DeclineSeam.calls.isEmpty)
        XCTAssertEqual(vm.friendRequests.count, 3)
    }

    func test_unknownSenderId_leavesTheListAlone_andStillAsksTheServer() async {
        let vm = makeVM()
        await vm.declineRequest(senderId: "99999999-9999-4999-8999-999999999999")
        XCTAssertEqual(vm.friendRequests.map(\.id), [ann, bob, cy])
        XCTAssertEqual(DeclineSeam.calls.count, 1)
    }

    func test_retryAfterFailure_succeeds() async {
        DeclineSeam.error = AppError.networkError("x")
        let vm = makeVM()
        await vm.declineRequest(senderId: ann)
        XCTAssertEqual(vm.friendRequests.count, 3)
        DeclineSeam.error = nil
        await vm.declineRequest(senderId: ann)
        XCTAssertEqual(vm.friendRequests.map(\.id), [bob, cy])
    }

    func test_defaultProtocolImplementation_throws_notFabricatesSuccess() async {
        // MockDataService has no decline implementation of its own: the protocol
        // default must throw so a caller can never believe a decline happened.
        do {
            try await MockDataService.shared.declineFriendRequest(userId: "a", senderId: "b")
            XCTFail("the default implementation must throw")
        } catch {
            XCTAssertTrue(true)
        }
    }
}

@MainActor
final class ProfileDeclineTests: XCTestCase {
    private let viewer = "viewer-1"
    private let target = "target-1"
    private var service: ThrowingTestDataService!

    override func setUp() async throws {
        try await super.setUp()
        ProfileSeam.reset()
        DeclineSeam.reset()
        service = ThrowingTestDataService()
    }

    private func profile(_ rel: FSProfileRelationship) -> FSProfile {
        FSProfile(user_id: target, username: "Ann", relationship: rel, editable: false, bio: nil, bioVisible: false)
    }

    private func makeVM() -> ProfileViewModel {
        ProfileViewModel(viewerId: viewer, targetId: target, service: service, cache: ProfileCache())
    }

    func test_decline_success_sendsViewerAndTarget_thenRefetchesWhatTheServerSays() async {
        ProfileSeam.fetchQueue = [.success(profile(.requestReceived)), .success(profile(FSProfileRelationship.none))]
        let vm = makeVM()
        await vm.load()
        await vm.declineRequest()
        XCTAssertEqual(DeclineSeam.calls.count, 1)
        XCTAssertEqual(DeclineSeam.calls.first?.userId, viewer)
        XCTAssertEqual(DeclineSeam.calls.first?.senderId, target)
        XCTAssertEqual(vm.profile?.relationship, FSProfileRelationship.none)
        XCTAssertNil(vm.actionError)
    }

    func test_decline_failure_setsWarmCopy_andDoesNotFabricateAState() async {
        ProfileSeam.fetchFallback = .success(profile(.requestReceived))
        DeclineSeam.error = AppError.networkError("boom")
        let vm = makeVM()
        await vm.load()
        await vm.declineRequest()
        XCTAssertEqual(vm.actionError, "Couldn't decline that right now. Please try again.")
        XCTAssertEqual(vm.profile?.relationship, .requestReceived, "the request must still show after a failed decline")
        XCTAssertFalse(vm.busy)
    }

    func test_decline_rateLimited_usesSlowDownCopy() async {
        ProfileSeam.fetchFallback = .success(profile(.requestReceived))
        DeclineSeam.error = AppError.rateLimited("Too many")
        let vm = makeVM()
        await vm.load()
        await vm.declineRequest()
        XCTAssertEqual(vm.actionError, "Slow down a little and try again in a moment.")
    }
}
