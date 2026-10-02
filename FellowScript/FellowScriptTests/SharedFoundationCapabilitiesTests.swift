// SharedFoundationCapabilitiesTests.swift — task 20261002-shared-foundation,
// step 9. Capabilities client fail-closed cases, the terms re-consent
// trigger, and GroupInfoExtraSections ordering.

import XCTest
import SwiftUI
@testable import FellowScript

// MARK: - FSCapabilities decode + NetworkService.fetchCapabilities fail-closed

@MainActor
final class CapabilitiesClientTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(StubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(StubURLProtocol.self); super.tearDown() }
    override func setUp() { super.setUp(); StubURLProtocol.resetRequestLog() }

    private func stub(_ status: Int, _ body: String) {
        StubURLProtocol.stubStatusCode = status
        StubURLProtocol.stubBody = Data(body.utf8)
    }
    private let good = #"{"v":1,"features":{"threads":true,"explorer_browse":true,"join_requests":false},"links":{"explore":"https://x/#/explore"},"terms_current":false}"#

    func test_200_validBody_decodes() async throws {
        stub(200, good)
        let c = try await NetworkService.shared.fetchCapabilities()
        XCTAssertTrue(c.isEnabled("threads"))
        XCTAssertFalse(c.isEnabled("join_requests"))
        XCTAssertFalse(c.isEnabled("unknown_flag"))
        XCTAssertEqual(c.exploreLink, "https://x/#/explore")
        XCTAssertFalse(c.termsCurrent)
        XCTAssertEqual(StubURLProtocol.requestLog.last?.path, "/api/app/capabilities")
        XCTAssertEqual(StubURLProtocol.requestLog.last?.timeoutInterval, 5)
    }

    func test_nonSuccessStatuses_throw() async {
        for status in [204, 401, 403, 404, 500, 503] {
            stub(status, good)
            do { _ = try await NetworkService.shared.fetchCapabilities(); XCTFail("status \(status) must throw") }
            catch { /* fail closed */ }
        }
    }

    func test_malformedBodies_throw() async {
        let bodies = ["", "not json", "[]", #"{"features":{}}"#, #"{"terms_current":true}"#,
                      #"{"features":{"a":"yes"},"terms_current":true}"#,
                      #"{"features":{},"terms_current":"false"}"#]
        for b in bodies {
            stub(200, b)
            do { _ = try await NetworkService.shared.fetchCapabilities(); XCTFail("body \(b) must throw") }
            catch { /* fail closed */ }
        }
    }

    func test_exploreLink_onlyWhenExplorerBrowseOn() throws {
        let json = #"{"features":{"explorer_browse":false},"links":{"explore":"u"},"terms_current":true}"#
        let c = try JSONDecoder().decode(FSCapabilities.self, from: Data(json.utf8))
        XCTAssertNil(c.exploreLink)
    }

    func test_allOff_isFailClosed() {
        XCTAssertTrue(FSCapabilities.allOff.features.isEmpty)
        XCTAssertNil(FSCapabilities.allOff.exploreLink)
        XCTAssertTrue(FSCapabilities.allOff.termsCurrent, "a missing endpoint must never trap a user behind the terms gate")
    }

    func test_protocolDefault_throws() async {
        let svc = ThrowingTestDataService()
        do { _ = try await svc.fetchCapabilities(); XCTFail("default must throw") } catch {}
    }
}

// MARK: - AppState: terms re-consent trigger + fail-closed

@MainActor
final class AppStateCapabilitiesTests: XCTestCase {

    private func waitUntil(_ cond: @autoclosure () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func test_termsCurrentFalse_raisesReacceptGate() async throws {
        let svc = ThrowingTestDataService()
        svc.fetchCapabilitiesResult = FSCapabilities(features: ["threads": true], exploreLink: nil, termsCurrent: false)
        let state = AppState(service: svc)
        try await state.signIn(username: "jacob", password: "password")
        await waitUntil(state.termsReacceptRequired)
        XCTAssertTrue(state.termsReacceptRequired)
        XCTAssertTrue(state.capabilities.isEnabled("threads"))
    }

    func test_termsCurrentTrue_doesNotRaiseGate() async throws {
        let svc = ThrowingTestDataService()
        svc.fetchCapabilitiesResult = FSCapabilities(features: ["threads": true], exploreLink: nil, termsCurrent: true)
        let state = AppState(service: svc)
        try await state.signIn(username: "jacob", password: "password")
        await waitUntil(state.capabilities.isEnabled("threads"))
        XCTAssertTrue(state.capabilities.isEnabled("threads"))
        XCTAssertFalse(state.termsReacceptRequired)
    }

    func test_fetchFailure_failsClosed_noGate() async throws {
        let svc = ThrowingTestDataService()
        svc.fetchCapabilitiesError = AppError.networkError("down")
        let state = AppState(service: svc)
        try await state.signIn(username: "jacob", password: "password")
        await waitUntil(svc.fetchCapabilitiesCallCount > 0)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(state.capabilities, .allOff)
        XCTAssertFalse(state.termsReacceptRequired)
    }

    func test_signedOut_noFetch_andSignOutResetsToAllOff() async throws {
        let svc = ThrowingTestDataService()
        svc.fetchCapabilitiesResult = FSCapabilities(features: ["threads": true], exploreLink: nil, termsCurrent: true)
        let state = AppState(service: svc)
        // AppState restores a persisted session in init (AppStorage leaks
        // across tests); sign out first so we start from a signed-out state.
        state.signOut()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let baseline = svc.fetchCapabilitiesCallCount
        state.refreshCapabilities(force: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(svc.fetchCapabilitiesCallCount, baseline, "signed out must not fetch")
        XCTAssertEqual(state.capabilities, .allOff)
        try await state.signIn(username: "jacob", password: "password")
        await waitUntil(state.capabilities.isEnabled("threads"))
        XCTAssertTrue(state.capabilities.isEnabled("threads"))
        state.signOut()
        XCTAssertEqual(state.capabilities, .allOff)
    }
}

// MARK: - GroupInfoExtraSections ordering

@MainActor
final class GroupInfoExtraSectionsTests: XCTestCase {
    private func sec(_ id: String, _ order: Int, visible: @escaping (FSCapabilities) -> Bool = { _ in true }) -> GroupInfoExtraSection {
        GroupInfoExtraSection(id: id, order: order,
                              isVisible: { caps, _ in visible(caps) },
                              makeView: { _, _ in AnyView(EmptyView()) })
    }
    private var ctx: GroupInfoSectionContext {
        GroupInfoSectionContext(service: MockDataService.shared, groupId: "g", userId: "u", isOwner: false)
    }

    func test_registry_publishAndThreadsRegistered_rendersNothingWhenAllOff() {
        // IOS#2 registered the owner-only Publish row at order 10; the
        // message-threads task (20261001-message-threads) added Threads at 30.
        XCTAssertEqual(GroupInfoExtraSections.registry.map(\.id), ["publish", "threads"])
        XCTAssertEqual(GroupInfoExtraSections.registry.map(\.order), [10, 30])
        XCTAssertTrue(GroupInfoExtraSections.visible(capabilities: .allOff, context: ctx).isEmpty)
    }

    func test_sortedByOrder_publish10_jrq20_thr30() {
        let input = [sec("threads", 30), sec("publish", 10), sec("join_requests", 20)]
        let out = GroupInfoExtraSections.visible(input, capabilities: .allOff, context: ctx).map(\.id)
        XCTAssertEqual(out, ["publish", "join_requests", "threads"])
    }

    func test_invisibleSectionsFiltered() {
        let input = [sec("a", 1, visible: { _ in false }), sec("b", 2, visible: { $0.isEnabled("threads") })]
        let on = FSCapabilities(features: ["threads": true], exploreLink: nil, termsCurrent: true)
        XCTAssertEqual(GroupInfoExtraSections.visible(input, capabilities: on, context: ctx).map(\.id), ["b"])
        XCTAssertTrue(GroupInfoExtraSections.visible(input, capabilities: .allOff, context: ctx).isEmpty)
    }

    func test_environmentDefault_isAllOff() {
        XCTAssertEqual(EnvironmentValues().fsCapabilities, .allOff)
    }
}
