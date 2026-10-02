// GroupInviteRevealTests.swift — task 20260930/20261002-group-invite-show-link (testing gate).
//
// Covers: NetworkService.revealGroupInvite (route, method, url decode, error
// mapping, throw-not-fabricate), FSInviteItem decoding with and without the
// additive `revealable` field, and InviteLinksViewModel Show/Hide state for
// revealable vs legacy vs failure (memory only, cleared on revoke/reset).
// Uses the shared StubURLProtocol harness against the real NetworkService.

import XCTest
@testable import FellowScript

private let revealToken = String(repeating: "Z", count: 43)
private let revealURL = "https://fellowscript.com/join/\(revealToken)"

@MainActor
final class GroupInviteRevealTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(StubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(StubURLProtocol.self); super.tearDown() }
    override func setUp() { super.setUp(); StubURLProtocol.resetRequestLog() }

    private func stub(_ status: Int, _ body: String) {
        StubURLProtocol.stubStatusCode = status
        StubURLProtocol.stubBody = Data(body.utf8)
    }
    private func vm() -> InviteLinksViewModel {
        InviteLinksViewModel(service: NetworkService.shared, groupId: "g-\(UUID().uuidString)", userId: "u1")
    }
    private func row(_ id: String, _ revealable: String) -> String {
        #"{"invite_id":"\#(id)","created_by_username":"ann","is_mine":true,"created_at":"2026-09-30T00:00:00Z","expires_at":null,"max_uses":25,"use_count":3,"remaining_uses":22\#(revealable)}"#
    }
    private let options = #""options":{"default_expiry_days":7,"allowed_expiry_days":[1,7,30],"default_max_uses":25,"allowed_max_uses":[1,5,25],"max_active_links_per_user_per_group":5}"#
    private func listJSON(_ rows: [String]) -> String { #"{"invites":[\#(rows.joined(separator: ","))],\#(options)}"# }

    // MARK: decoding

    func test_item_decodesWithoutRevealable_asNil() throws {
        let item = try JSONDecoder().decode(FSInviteItem.self, from: Data(row("a", "").utf8))
        XCTAssertNil(item.revealable)
    }

    func test_item_decodesRevealableTrueAndFalse() throws {
        let t = try JSONDecoder().decode(FSInviteItem.self, from: Data(row("a", #","revealable":true"#).utf8))
        let f = try JSONDecoder().decode(FSInviteItem.self, from: Data(row("b", #","revealable":false"#).utf8))
        XCTAssertEqual(t.revealable, true)
        XCTAssertEqual(f.revealable, false)
    }

    func test_oldCachedListWithoutRevealable_stillDecodes() throws {
        let list = try JSONDecoder().decode(FSInviteList.self, from: Data(listJSON([row("a", ""), row("b", #","revealable":false"#)]).utf8))
        XCTAssertEqual(list.invites.count, 2)
        XCTAssertNil(list.invites[0].revealable)
        XCTAssertEqual(list.invites[1].revealable, false)
    }

    // MARK: network

    func test_reveal_getsRoute_returnsUrl_noBodyNoTokenInUrl() async throws {
        stub(200, #"{"url":"\#(revealURL)","invite_id":"i1"}"#)
        let url = try await NetworkService.shared.revealGroupInvite(userId: "u1", inviteId: "i1")
        XCTAssertEqual(url, revealURL)
        let req = StubURLProtocol.requestLog.last
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.path, "/api/invites/u1/i1/reveal")
        XCTAssertFalse(req?.url.contains(revealToken) ?? true)
    }

    func test_reveal_404_throwsInviteAPIError() async {
        stub(404, #"{"detail":"Not found"}"#)
        do { _ = try await NetworkService.shared.revealGroupInvite(userId: "u1", inviteId: "i1"); XCTFail("must throw") }
        catch let e as InviteAPIError { XCTAssertEqual(e.status, 404) }
        catch { XCTFail("wrong error \(error)") }
    }

    func test_reveal_undecodableBody_throws_notFabricated() async {
        stub(200, #"{"unexpected":true}"#)
        do { _ = try await NetworkService.shared.revealGroupInvite(userId: "u1", inviteId: "i1"); XCTFail("must throw") }
        catch { /* expected */ }
    }

    // MARK: view model

    func test_showLink_revealable_storesUrlInMemory_hideClears() async {
        stub(200, listJSON([row("i1", #","revealable":true"#)]))
        let m = vm()
        await m.load()
        stub(200, #"{"url":"\#(revealURL)","invite_id":"i1"}"#)
        await m.showLink(m.list!.invites[0])
        XCTAssertEqual(m.shownURLs["i1"], revealURL)
        XCTAssertNil(m.showBusyId)
        XCTAssertNil(m.rowErrors["i1"])
        // The cached/persisted list never carries the url.
        let encoded = String(data: try! JSONEncoder().encode(m.list!), encoding: .utf8)!
        XCTAssertFalse(encoded.contains(revealToken))
        m.hideLink("i1")
        XCTAssertNil(m.shownURLs["i1"])
    }

    func test_showLink_404_and_429_and_other_mapToFriendlyErrors() async {
        stub(200, listJSON([row("i1", #","revealable":true"#)]))
        let m = vm()
        await m.load()
        let item = m.list!.invites[0]
        stub(404, #"{"detail":"Not found"}"#)
        await m.showLink(item)
        XCTAssertEqual(m.rowErrors["i1"], "Couldn't show this link. It may have been revoked. Make a new link to share.")
        XCTAssertNil(m.shownURLs["i1"])
        stub(429, #"{"detail":"slow"}"#)
        await m.showLink(item)
        XCTAssertEqual(m.rowErrors["i1"], "Too many tries. Wait a minute and try again.")
        stub(500, #"{"detail":"boom"}"#)
        await m.showLink(item)
        XCTAssertEqual(m.rowErrors["i1"], "Couldn't show the link. Please try again.")
        XCTAssertTrue(m.shownURLs.isEmpty)
        XCTAssertNil(m.showBusyId)
    }

    func test_showLink_success_clearsPriorRowError() async {
        stub(200, listJSON([row("i1", "")]))
        let m = vm()
        await m.load()
        stub(404, #"{"detail":"x"}"#)
        await m.showLink(m.list!.invites[0])
        XCTAssertNotNil(m.rowErrors["i1"])
        stub(200, #"{"url":"\#(revealURL)","invite_id":"i1"}"#)
        await m.showLink(m.list!.invites[0])
        XCTAssertNil(m.rowErrors["i1"])
        XCTAssertEqual(m.shownURLs["i1"], revealURL)
    }

    func test_legacyItem_isFlaggedNotRevealable() async {
        stub(200, listJSON([row("old", #","revealable":false"#), row("new", #","revealable":true"#), row("nil", "")]))
        let m = vm()
        await m.load()
        XCTAssertEqual(m.list?.invites.map(\.revealable), [false, true, nil])
    }

    func test_createGroup_marksRowRevealable_andRevokeClearsShownUrl() async {
        stub(200, listJSON([]))
        let m = vm()
        await m.load()
        stub(200, #"{"invite_id":"n1","token":"\#(revealToken)","url":"\#(revealURL)","created_at":"2026-09-30T00:00:00Z","expires_at":null,"max_uses":25,"use_count":0}"#)
        await m.create()
        XCTAssertEqual(m.list?.invites.first?.revealable, true)
        stub(200, #"{"url":"\#(revealURL)","invite_id":"n1"}"#)
        await m.showLink(m.list!.invites[0])
        XCTAssertNotNil(m.shownURLs["n1"])
        stub(200, "{}")
        await m.revoke(m.list!.invites[0], reduceMotion: true)
        XCTAssertNil(m.shownURLs["n1"])
    }

    func test_resetAll_clearsShownUrls() async {
        stub(200, listJSON([row("i1", #","revealable":true"#)]))
        let m = vm()
        await m.load()
        stub(200, #"{"url":"\#(revealURL)","invite_id":"i1"}"#)
        await m.showLink(m.list!.invites[0])
        stub(200, #"{"revoked":1}"#)
        _ = await m.resetAll()
        XCTAssertTrue(m.shownURLs.isEmpty)
    }
}
