// ReactionHighlightPushTests.swift -- testing gate for task
// 20261010-reaction-highlight-push (iOS). Covers FriendHighlightPushTarget
// parsing (fail closed), FriendHighlightPushModel (throw-not-fabricate,
// revert on failed save), and AppDelegate routing of message_reaction /
// friend_highlight (source-pinned, same technique as AnnouncementPushWidgetTests).

import XCTest
@testable import FellowScript

@MainActor
final class ReactionHighlightPushTests: XCTestCase {

    // MARK: FriendHighlightPushTarget

    func test_target_parsesValidPayload() {
        let t = FriendHighlightPushTarget(userInfo: ["book": "John", "chapter": 3, "verse": 16])
        XCTAssertEqual(t, FriendHighlightPushTarget(userInfo: ["book": "John", "chapter": 3, "verse": 16]))
        XCTAssertEqual(t?.book, "John")
        XCTAssertEqual(t?.chapter, 3)
        XCTAssertEqual(t?.verse, 16)
    }

    func test_target_failsClosedOnMalformed() {
        XCTAssertNil(FriendHighlightPushTarget(userInfo: [:]))
        XCTAssertNil(FriendHighlightPushTarget(userInfo: ["book": "", "chapter": 3, "verse": 16]))
        XCTAssertNil(FriendHighlightPushTarget(userInfo: ["book": "John", "chapter": 0, "verse": 16]))
        XCTAssertNil(FriendHighlightPushTarget(userInfo: ["book": "John", "chapter": 3, "verse": -1]))
        XCTAssertNil(FriendHighlightPushTarget(userInfo: ["book": "John", "chapter": "3", "verse": 16]))
        XCTAssertNil(FriendHighlightPushTarget(userInfo: ["book": 5, "chapter": 3, "verse": 16]))
        XCTAssertNil(FriendHighlightPushTarget(userInfo: ["book": "John", "chapter": 3]))
        XCTAssertNil(FriendHighlightPushTarget(userInfo: ["book": String(repeating: "a", count: 65), "chapter": 1, "verse": 1]))
    }

    // MARK: FriendHighlightPushModel (real NetworkService over StubURLProtocol)

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = Data()
    }

    private func makeModel(userId: String = "u1") -> FriendHighlightPushModel {
        FriendHighlightPushModel(service: NetworkService.shared, userId: userId)
    }

    private func puts() -> [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.requestLog.filter { $0.method == "PUT" }
    }

    func test_model_loadReflectsServerValue() async {
        StubURLProtocol.stubBody = Data(#"{"friend_highlight":false}"#.utf8)
        let m = makeModel()
        await m.load()
        XCTAssertTrue(m.loaded)
        XCTAssertFalse(m.enabled)
        XCTAssertNil(m.errorMessage)
        XCTAssertTrue(StubURLProtocol.requestLog.contains { $0.method == "GET" && $0.path.hasSuffix("/notification/u1/push-preferences") })
    }

    func test_model_loadFailure_doesNotFabricate() async {
        StubURLProtocol.stubStatusCode = 500
        let m = makeModel()
        await m.load()
        XCTAssertFalse(m.loaded)
        XCTAssertNotNil(m.errorMessage)
        await m.set(false)
        XCTAssertTrue(puts().isEmpty, "must not save before a server value is loaded")
    }

    func test_model_loadMalformedBody_doesNotFabricate() async {
        StubURLProtocol.stubBody = Data(#"{"other":true}"#.utf8)
        let m = makeModel()
        await m.load()
        XCTAssertFalse(m.loaded)
        XCTAssertNotNil(m.errorMessage)
    }

    func test_model_setSuccess_updatesAndPersists() async {
        StubURLProtocol.stubBody = Data(#"{"friend_highlight":true}"#.utf8)
        let m = makeModel()
        await m.load()
        await m.set(false)
        XCTAssertEqual(puts().count, 1)
        XCTAssertEqual(puts().first?.bodyJSON?["friend_highlight"] as? Bool, false)
        XCTAssertFalse(m.enabled)
        XCTAssertNil(m.errorMessage)
    }

    func test_model_setFailure_revertsAndShowsError() async {
        StubURLProtocol.stubBody = Data(#"{"friend_highlight":true}"#.utf8)
        let m = makeModel()
        await m.load()
        StubURLProtocol.stubStatusCode = 500
        await m.set(false)
        XCTAssertTrue(m.enabled, "failed save must keep server-confirmed value")
        XCTAssertNotNil(m.errorMessage)
        XCTAssertFalse(m.saving)
    }

    func test_model_noOpWhenValueUnchanged_orEmptyUser() async {
        StubURLProtocol.stubBody = Data(#"{"friend_highlight":true}"#.utf8)
        let m = makeModel()
        await m.load()
        await m.set(true)
        XCTAssertTrue(puts().isEmpty)
        StubURLProtocol.resetRequestLog()
        let empty = makeModel(userId: "")
        await empty.load()
        XCTAssertFalse(empty.loaded)
        XCTAssertTrue(StubURLProtocol.requestLog.isEmpty)
    }

    // MARK: AppDelegate routing (source-pinned)

    private func didReceiveBody() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("FellowScript/FellowScriptApp.swift"), encoding: .utf8)
        guard let start = source.range(of: "func userNotificationCenter(_ center: UNUserNotificationCenter,\n                                didReceive response:") else {
            XCTFail("didReceive handler not found"); return ""
        }
        let end = source.range(of: "\n}", range: start.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        return String(source[start.upperBound..<end])
    }

    func test_appDelegate_messageReaction_routesToChat() throws {
        let body = try didReceiveBody()
        guard let r = body.range(of: "action == \"message_reaction\"") else { XCTFail("branch missing"); return }
        let branch = String(body[r.lowerBound...].prefix(400))
        XCTAssertTrue(branch.contains(".sessionPushTapped"))
        XCTAssertTrue(branch.contains("object: groupId"))
    }

    func test_appDelegate_friendHighlight_usesFailClosedTarget() throws {
        let body = try didReceiveBody()
        guard let r = body.range(of: "action == \"friend_highlight\"") else { XCTFail("branch missing"); return }
        let branch = String(body[r.lowerBound...].prefix(400))
        XCTAssertTrue(branch.contains("FriendHighlightPushTarget(userInfo: data)"))
        XCTAssertTrue(branch.contains(".friendHighlightPushTapped"))
    }
}
