// GroupJoinRequestsTests.swift -- task 20261011-join-requests-ios-email step 2.
// Owner-side join-requests section: capability/owner gating (fail closed),
// registry slot, decoding, server error mapping, and the view-model state
// machine (approve, deny, deny and block, undo, accepting switch, group_full,
// throw-not-fabricate, preserve rows on failed refresh).

import XCTest
@testable import FellowScript

enum JoinSeam {
    static var list: Result<FSJoinRequestsList, Error> = .failure(FSJoinRequestsError.failed("unset"))
    static var approveError: Error?
    static var denyResult: Result<Int, Error> = .success(10)
    static var undoError: Error?
    static var acceptingError: Error?
    static var log: [String] = []
    static func reset() {
        list = .failure(FSJoinRequestsError.failed("unset")); approveError = nil
        denyResult = .success(10); undoError = nil; acceptingError = nil; log = []
    }
}

extension ThrowingTestDataService {
    func fetchJoinRequests(userId: String, groupId: String) async throws -> FSJoinRequestsList {
        JoinSeam.log.append("list"); return try JoinSeam.list.get()
    }
    func approveJoinRequest(userId: String, groupId: String, requestId: String) async throws {
        JoinSeam.log.append("approve:\(requestId)"); if let e = JoinSeam.approveError { throw e }
    }
    func denyJoinRequest(userId: String, groupId: String, requestId: String, blockReapply: Bool) async throws -> Int {
        JoinSeam.log.append("deny:\(requestId):\(blockReapply)"); return try JoinSeam.denyResult.get()
    }
    func undoDenyJoinRequest(userId: String, groupId: String, requestId: String) async throws {
        JoinSeam.log.append("undo:\(requestId)"); if let e = JoinSeam.undoError { throw e }
    }
    func setAcceptingJoinRequests(userId: String, groupId: String, accepting: Bool) async throws {
        JoinSeam.log.append("accepting:\(accepting)"); if let e = JoinSeam.acceptingError { throw e }
    }
}

final class GroupJoinRequestsGatingTests: XCTestCase {
    private func caps(_ f: [String: Bool]) -> FSCapabilities { FSCapabilities(features: f, exploreLink: nil, termsCurrent: true) }
    private func ctx(owner: Bool) -> GroupInfoSectionContext {
        GroupInfoSectionContext(service: ThrowingTestDataService(), groupId: "g", userId: "u", isOwner: owner)
    }

    func test_visibleOnlyWhenFlagOnAndOwner() {
        XCTAssertTrue(GroupJoinRequestsViewModel.isVisible(caps(["join_requests": true]), isOwner: true))
        XCTAssertFalse(GroupJoinRequestsViewModel.isVisible(caps(["join_requests": true]), isOwner: false))
        XCTAssertFalse(GroupJoinRequestsViewModel.isVisible(caps(["join_requests": false]), isOwner: true))
        XCTAssertFalse(GroupJoinRequestsViewModel.isVisible(caps([:]), isOwner: true), "missing flag fails closed")
        XCTAssertFalse(GroupJoinRequestsViewModel.isVisible(.allOff, isOwner: true), "failed capabilities fetch fails closed")
    }

    func test_registrySlotIsOrder20_andAbsentWhenOff() {
        let reg = GroupJoinRequestsSection.registration
        XCTAssertEqual(reg.id, "join_requests")
        XCTAssertEqual(reg.order, 20)
        XCTAssertTrue(GroupInfoExtraSections.registry.contains { $0.id == "join_requests" })
        let off = GroupInfoExtraSections.visible(capabilities: .allOff, context: ctx(owner: true))
        XCTAssertFalse(off.contains { $0.id == "join_requests" })
        let on = GroupInfoExtraSections.visible(capabilities: caps(["join_requests": true, "threads": true]), context: ctx(owner: true))
        let ids = on.map(\.id)
        XCTAssertEqual(ids.firstIndex(of: "join_requests").map { $0 < (ids.firstIndex(of: "threads") ?? Int.max) }, true)
    }
}

final class JoinRequestsModelTests: XCTestCase {
    func test_decodesOwnerList() throws {
        let json = """
        {"accepting_requests":false,"pending_count":3,"requests":[{"id":"r1","applicant_user_id":"a","username":"ann","profile_photo_url":null,"note":"hi","created_at":"2026-10-11T00:00:00Z"}]}
        """
        let l = try JSONDecoder().decode(FSJoinRequestsList.self, from: Data(json.utf8))
        XCTAssertFalse(l.acceptingRequests)
        XCTAssertEqual(l.pendingCount, 3)
        XCTAssertEqual(l.requests.first?.displayName, "ann")
    }

    func test_bodyWithoutRequestsIsMalformed_notEmpty() {
        XCTAssertThrowsError(try JSONDecoder().decode(FSJoinRequestsList.self, from: Data(#"{"pending_count":0}"#.utf8)))
    }

    func test_errorMapping() {
        func map(_ status: Int, _ code: String?) -> FSJoinRequestsError {
            let body = code.map { #"{"detail":{"code":"\#($0)","message":"m"}}"# } ?? "{}"
            return NetworkService.joinRequestsError(status: status, data: Data(body.utf8), fallback: "fb")
        }
        XCTAssertEqual(map(409, "group_full"), .groupFull)
        XCTAssertEqual(map(409, "busy"), .busy)
        XCTAssertEqual(map(409, "not_pending"), .notPending)
        XCTAssertEqual(map(409, "no_longer_available"), .notPending)
        XCTAssertEqual(map(409, "not_undoable"), .notUndoable)
        XCTAssertEqual(map(403, "terms_reaccept_required"), .termsReacceptRequired)
        XCTAssertEqual(map(429, nil), .rateLimited)
        XCTAssertEqual(map(404, nil), .notFound)
        XCTAssertEqual(map(500, nil), .failed("fb"))
    }
}

@MainActor
final class GroupJoinRequestsViewModelTests: XCTestCase {
    override func setUp() { super.setUp(); JoinSeam.reset() }

    private func req(_ id: String) -> FSJoinRequest {
        FSJoinRequest(id: id, applicantUserId: "a\(id)", username: "user\(id)", profilePhotoUrl: nil, note: nil, createdAt: nil)
    }
    private func list(_ ids: [String], accepting: Bool = true) -> FSJoinRequestsList {
        FSJoinRequestsList(acceptingRequests: accepting, pendingCount: ids.count, requests: ids.map(req))
    }
    private func makeVM() -> GroupJoinRequestsViewModel {
        GroupJoinRequestsViewModel(service: ThrowingTestDataService(), groupId: "g", userId: "u")
    }

    func test_load_success_setsRowsCountAndSwitch() async {
        JoinSeam.list = .success(list(["1", "2"], accepting: false))
        let vm = makeVM(); await vm.load()
        XCTAssertTrue(vm.loaded); XCTAssertEqual(vm.requests.count, 2); XCTAssertEqual(vm.pendingCount, 2)
        XCTAssertFalse(vm.accepting); XCTAssertNil(vm.listError)
    }

    func test_load_failure_neverFabricatesEmptySuccess() async {
        let vm = makeVM(); await vm.load()
        XCTAssertFalse(vm.loaded); XCTAssertNotNil(vm.listError); XCTAssertTrue(vm.requests.isEmpty)
    }

    func test_failedRefresh_keepsPreviousRows() async {
        JoinSeam.list = .success(list(["1", "2"]))
        let vm = makeVM(); await vm.load()
        JoinSeam.list = .failure(FSJoinRequestsError.failed("boom"))
        await vm.load()
        XCTAssertEqual(vm.requests.map(\.id), ["1", "2"])
        XCTAssertTrue(vm.loaded); XCTAssertEqual(vm.listError, "boom")
    }

    func test_load_404_marksUnavailable() async {
        JoinSeam.list = .failure(FSJoinRequestsError.notFound)
        let vm = makeVM(); await vm.load()
        XCTAssertTrue(vm.unavailable); XCTAssertNil(vm.listError)
    }

    func test_approve_removesRowAndDecrementsCount() async {
        JoinSeam.list = .success(list(["1", "2"]))
        let vm = makeVM(); await vm.load()
        await vm.approve(vm.requests[0])
        XCTAssertEqual(vm.requests.map(\.id), ["2"]); XCTAssertEqual(vm.pendingCount, 1)
        XCTAssertTrue(JoinSeam.log.contains("approve:1"))
    }

    func test_approve_groupFull_keepsRowPending_withClearMessage() async {
        JoinSeam.list = .success(list(["1"]))
        JoinSeam.approveError = FSJoinRequestsError.groupFull
        let vm = makeVM(); await vm.load()
        await vm.approve(vm.requests[0])
        XCTAssertEqual(vm.requests.map(\.id), ["1"], "not marked approved")
        XCTAssertEqual(vm.pendingCount, 1)
        XCTAssertEqual(vm.rowErrors["1"], FSJoinRequestsError.groupFull.errorDescription)
    }

    func test_approve_notPending_dropsRowWithoutClaimingApproval() async {
        JoinSeam.list = .success(list(["1"]))
        JoinSeam.approveError = FSJoinRequestsError.notPending
        let vm = makeVM(); await vm.load()
        await vm.approve(vm.requests[0])
        XCTAssertTrue(vm.requests.isEmpty); XCTAssertEqual(vm.announcement, "No longer available.")
    }

    func test_deny_removesRow_andOffersUndo_withBlockFlag() async {
        JoinSeam.list = .success(list(["1", "2"]))
        let vm = makeVM(); await vm.load()
        await vm.deny(vm.requests[0], block: true)
        XCTAssertEqual(vm.requests.map(\.id), ["2"])
        XCTAssertEqual(vm.undo?.request.id, "1"); XCTAssertEqual(vm.undo?.block, true)
        XCTAssertTrue(JoinSeam.log.contains("deny:1:true"))
        vm.dismissUndo()
        XCTAssertNil(vm.undo)
    }

    func test_deny_failure_keepsRow_noUndo() async {
        JoinSeam.list = .success(list(["1"]))
        JoinSeam.denyResult = .failure(FSJoinRequestsError.failed("nope"))
        let vm = makeVM(); await vm.load()
        await vm.deny(vm.requests[0], block: false)
        XCTAssertEqual(vm.requests.count, 1); XCTAssertNil(vm.undo); XCTAssertEqual(vm.rowErrors["1"], "nope")
    }

    func test_undo_restoresRequestViaReload() async {
        JoinSeam.list = .success(list(["1"]))
        let vm = makeVM(); await vm.load()
        await vm.deny(vm.requests[0], block: false)
        XCTAssertTrue(vm.requests.isEmpty)
        JoinSeam.list = .success(list(["1"]))   // server restored it
        await vm.undoDeny()
        XCTAssertNil(vm.undo); XCTAssertEqual(vm.requests.map(\.id), ["1"])
        XCTAssertTrue(JoinSeam.log.contains("undo:1"))
    }

    func test_undo_failure_surfacesMessage() async {
        JoinSeam.list = .success(list(["1"]))
        let vm = makeVM(); await vm.load()
        await vm.deny(vm.requests[0], block: false)
        JoinSeam.undoError = FSJoinRequestsError.notUndoable
        JoinSeam.list = .success(list([]))
        await vm.undoDeny()
        XCTAssertEqual(vm.listError, "That denial can no longer be undone.")
        XCTAssertTrue(vm.requests.isEmpty)
    }

    func test_acceptingSwitch_updatesAndRollsBackOnFailure() async {
        JoinSeam.list = .success(list([]))
        let vm = makeVM(); await vm.load()
        await vm.setAccepting(false)
        XCTAssertFalse(vm.accepting); XCTAssertNil(vm.switchError)
        JoinSeam.acceptingError = FSJoinRequestsError.failed("x")
        await vm.setAccepting(true)
        XCTAssertFalse(vm.accepting, "rolled back to the last server-confirmed value")
        XCTAssertEqual(vm.switchError, "x")
    }
}
