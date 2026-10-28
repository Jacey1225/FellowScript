// DmDirectCallTests.swift -- testing gate (step 8) for task
// 20261028-dm-direct-call (iOS).
//
// Covers: friend-DM Call replaces Sessions (source-pinned, the header cannot be
// hosted without live EnvironmentObjects), DM call start errors surface as warm
// DmCallError values and never fabricate a session, the DM thread no longer
// loads/caches sessions while groups still do and the message cache survives a
// failed refresh, a single join route (joinCall) is used, the ring lifecycle
// network routes, VoipCallManager ring_cancel / decline / timeout handling
// (source-pinned: PKPushCredentials and CallKit UUIDs cannot be minted), and the
// caller-side ring states (CallRingTracker phase + banner text + cancel).

import XCTest
@testable import FellowScript

// MARK: - URLProtocol stub (own class so it never fights PagingStubURLProtocol)

final class DmCallStubURLProtocol: URLProtocol {
    struct Hit { let path: String; let method: String; let body: [String: Any] }
    /// full path -> (status, body). status 0 throws URLError(.notConnectedToInternet).
    static var routes: [String: (Int, String)] = [:]
    static var hits: [Hit] = []
    static func reset() { routes = [:]; hits = [] }

    override class func canInit(with request: URLRequest) -> Bool {
        guard request.url?.host == "fellowscript.com", let path = request.url?.path else { return false }
        return path.hasPrefix("/api/devotions/dm-call") || path.hasPrefix("/api/devotions/ring/")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096); var d = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                d.append(buf, count: n)
            }
            bodyData = d
        }
        let json = (bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        Self.hits.append(Hit(path: url.path, method: request.httpMethod ?? "", body: json))
        let route = Self.routes[url.path] ?? (404, #"{"detail":"nf"}"#)
        if route.0 == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let resp = HTTPURLResponse(url: url, statusCode: route.0, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.1.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - 1. DM call start + ring lifecycle network routes

final class DmCallNetworkTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(DmCallStubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(DmCallStubURLProtocol.self); super.tearDown() }
    override func setUp() { DmCallStubURLProtocol.reset() }

    private let svc = NetworkService.shared
    private let route = "/api/devotions/dm-call"

    func test_startDmCall_success_returnsServerIssuedSession_andPostsBothIds() async throws {
        DmCallStubURLProtocol.routes[route] = (200, #"{"id":"dev-1"}"#)
        let s = try await svc.startDmCall(userId: "uB", peerId: "uA")
        XCTAssertEqual(s.id, "dev-1")
        XCTAssertEqual(s.group_id, "uA|uB", "DM key is the sorted pair so both sides share one room")
        let hit = try XCTUnwrap(DmCallStubURLProtocol.hits.last)
        XCTAssertEqual(hit.method, "POST")
        XCTAssertEqual(hit.body["user_id"] as? String, "uB")
        XCTAssertEqual(hit.body["peer_id"] as? String, "uA")
    }

    func test_startDmCall_forbidden_mapsToNotAllowed_warmCopy() async {
        for body in [#"{"detail":"Not authorized"}"#, #"{"detail":"Forbidden"}"#, "{}"] {
            DmCallStubURLProtocol.routes[route] = (403, body)
            do { _ = try await svc.startDmCall(userId: "u1", peerId: "u2"); XCTFail("must throw for \(body)") }
            catch { XCTAssertEqual(error as? DmCallError, .notAllowed, body) }
        }
        XCTAssertEqual(DmCallError.notAllowed.errorDescription, "You can't call this person right now.")
    }

    func test_startDmCall_serverError_mapsToFailed_noRawServerText() async {
        DmCallStubURLProtocol.routes[route] = (500, #"{"detail":"psycopg2 exploded"}"#)
        do { _ = try await svc.startDmCall(userId: "u1", peerId: "u2"); XCTFail("must throw") }
        catch {
            XCTAssertEqual(error as? DmCallError, .failed)
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.contains("psycopg") ?? true)
        }
    }

    func test_startDmCall_transportFailure_mapsToNetwork() async {
        DmCallStubURLProtocol.routes[route] = (0, "")
        do { _ = try await svc.startDmCall(userId: "u1", peerId: "u2"); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? DmCallError, .network) }
        XCTAssertEqual(DmCallError.network.errorDescription,
                       "Couldn't start the call. Check your connection and try again.")
    }

    func test_startDmCall_missingOrEmptyId_throwsInsteadOfFabricating() async {
        for body in ["{}", #"{"id":""}"#, #"{"id":null}"#, "not json"] {
            DmCallStubURLProtocol.routes[route] = (200, body)
            do { _ = try await svc.startDmCall(userId: "u1", peerId: "u2"); XCTFail("must throw for \(body)") }
            catch { XCTAssertEqual(error as? DmCallError, .failed, body) }
        }
    }

    func test_respondToRing_postsOutcomeAndIds() async throws {
        DmCallStubURLProtocol.routes["/api/devotions/ring/respond"] = (200, "{}")
        try await svc.respondToRing(devotionId: "d1", userId: "me", targetId: "me", outcome: .declined)
        let hit = try XCTUnwrap(DmCallStubURLProtocol.hits.last)
        XCTAssertEqual(hit.method, "POST")
        XCTAssertEqual(hit.body["devotion_id"] as? String, "d1")
        XCTAssertEqual(hit.body["user_id"] as? String, "me")
        XCTAssertEqual(hit.body["target_id"] as? String, "me")
        XCTAssertEqual(hit.body["outcome"] as? String, "declined")
        XCTAssertEqual(RingOutcome.canceled.rawValue, "canceled")
        XCTAssertEqual(RingOutcome.answered.rawValue, "answered")
    }

    func test_respondToRing_failureThrows() async {
        DmCallStubURLProtocol.routes["/api/devotions/ring/respond"] = (500, "{}")
        do { try await svc.respondToRing(devotionId: "d", userId: "u", targetId: "t", outcome: .canceled); XCTFail("must throw") }
        catch {}
    }

    func test_fetchRingStatus_decodesRings_andThrowsOnFailureOrGarbage() async throws {
        DmCallStubURLProtocol.routes["/api/devotions/ring/status"] =
            (200, #"{"rings":{"t1":{"status":"ringing","seconds_left":31.5},"t2":{"status":"declined"}}}"#)
        let rings = try await svc.fetchRingStatus(devotionId: "d1", userId: "me")
        XCTAssertEqual(rings["t1"], RingStatusEntry(status: "ringing", seconds_left: 31.5))
        XCTAssertEqual(rings["t2"]?.status, "declined")
        XCTAssertNil(rings["t2"]?.seconds_left)

        DmCallStubURLProtocol.routes["/api/devotions/ring/status"] = (200, "garbage")
        do { _ = try await svc.fetchRingStatus(devotionId: "d1", userId: "me"); XCTFail("garbage must throw, not invent an empty result") }
        catch {}
        DmCallStubURLProtocol.routes["/api/devotions/ring/status"] = (500, "{}")
        do { _ = try await svc.fetchRingStatus(devotionId: "d1", userId: "me"); XCTFail("must throw") }
        catch {}
    }
}

// MARK: - 2. DM thread: no sessions, cache preserved; groups unchanged

@MainActor
final class DmThreadNoSessionsCacheTests: XCTestCase {

    private func fresh(_ l: String) -> String { "\(l)-\(UUID().uuidString)" }
    private func msg(_ id: String) -> FSMessage {
        FSMessage(id: id, text: "t-\(id)", mine: false, sender: "x", timestamp: "2026-10-28 00:00:00")
    }

    func test_dmLoad_neverReadsOrWritesSessionsCache() async throws {
        let contact = FSContact(id: fresh("peer"), name: "Peer", type: .friend)
        let uid = fresh("me")
        let key = ChatThreadViewModel.roomKey(contact: contact, userId: uid)
        await DiskCache.shared.save([FSSession()], forKey: "sessions:\(key)")   // legacy cached DM sessions
        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:1"
        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: uid)
        XCTAssertTrue(vm.sessions.isEmpty, "a DM thread must not surface cached or fetched sessions")
        // Not rewritten either: the legacy entry is untouched (still one item, not the mock fetch result).
        let still: [FSSession]? = await DiskCache.shared.load([FSSession].self, forKey: "sessions:\(key)")
        XCTAssertEqual(still?.count, 1)
        await DiskCache.shared.remove(forKey: "sessions:\(key)")
        await DiskCache.shared.remove(forKey: "messages:\(key)")
        vm.disconnect()
    }

    func test_dmLoad_failedRefresh_preservesCachedMessages() async throws {
        let contact = FSContact(id: fresh("peer"), name: "Peer", type: .friend)
        let uid = fresh("me")
        let key = ChatThreadViewModel.roomKey(contact: contact, userId: uid)
        await DiskCache.shared.save([msg("c1"), msg("c2")], forKey: "messages:\(key)")
        let service = ThrowingTestDataService()
        service.fetchFriendMessagesError = AppError.networkError("down")
        service.wsBaseOverride = "ws://127.0.0.1:1"
        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: uid)
        XCTAssertEqual(vm.messages.map(\.id), ["c1", "c2"], "failed refresh must keep the cached thread")
        let cached: [FSMessage]? = await DiskCache.shared.load([FSMessage].self, forKey: "messages:\(key)")
        XCTAssertEqual(cached?.map(\.id), ["c1", "c2"], "failed refresh must not clobber the cache")
        await DiskCache.shared.remove(forKey: "messages:\(key)")
        vm.disconnect()
    }

    func test_groupLoad_stillFetchesAndCachesSessions() async throws {
        let contact = FSContact(id: fresh("group"), name: "Group", type: .group)
        let uid = fresh("me")
        let key = ChatThreadViewModel.roomKey(contact: contact, userId: uid)
        await DiskCache.shared.remove(forKey: "sessions:\(key)")
        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:1"
        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: uid)
        let expected = try await service.fetchSessionsForContact(contactId: key)
        XCTAssertEqual(vm.sessions.map(\.id), expected.map(\.id), "group threads keep loading sessions")
        let cached: [FSSession]? = await DiskCache.shared.load([FSSession].self, forKey: "sessions:\(key)")
        XCTAssertNotNil(cached, "group sessions cache is still written")
        await DiskCache.shared.remove(forKey: "sessions:\(key)")
        await DiskCache.shared.remove(forKey: "messages:\(key)")
        vm.disconnect()
    }
}

// MARK: - 3. Ring-push join for a DM key goes through the single join route

@MainActor
final class DmRingedJoinTests: XCTestCase {
    override func tearDown() async throws { CallController.shared.end(); try await super.tearDown() }

    func test_joinRingedCall_dmKey_startsCallWithoutFetchingSessions_andOpensDmThread() async throws {
        let service = ThrowingTestDataService()
        service.joinCallResult = .failure(AppError.networkError("no meeting in tests"))
        let appState = AppState(service: service)
        appState.currentUser = FSUser(user_id: "uB", username: "b", email: "b@example.com")
        appState.isAuthenticated = true

        appState.joinRingedCall(devotionId: "dev-dm", groupId: "uA|uB")

        XCTAssertEqual(CallController.shared.session?.id, "dev-dm", "call starts synchronously with a minimal session")
        XCTAssertEqual(CallController.shared.session?.group_id, "uA|uB")
        XCTAssertEqual(appState.pendingChatContact?.id, "uA", "lands on the DM thread underneath")
        XCTAssertEqual(appState.pendingChatContact?.type, .friend)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertLessThanOrEqual(service.joinCallCount, 1, "one join through CallController/joinCall, never a second path")
    }
}

// MARK: - 4. Source pins: Call replaces Sessions, single join route, ring wiring

final class DmCallSourcePinTests: XCTestCase {
    private func src(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FellowScript/\(rel)"), encoding: .utf8)
    }
    private func allSwiftSources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript")
        var out: [(String, String)] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            guard u.pathExtension == "swift" else { continue }
            out.append((u.lastPathComponent, try String(contentsOf: u, encoding: .utf8)))
        }
        return out
    }

    func test_singleJoinRoute_joinCallEndpointDefinedOnce_dmAndRingFilesNeverJoinDirectly() throws {
        let all = try allSwiftSources()
        let routeFiles = all.filter { $0.1.contains("\"/devotions/join-call") }.map(\.0)
        XCTAssertEqual(routeFiles, ["NetworkService+Messaging.swift"], "exactly one definition of the join-call route")
        for name in ["NetworkService+DmCall.swift", "NetworkService+Ring.swift", "CallRingTracker.swift"] {
            let body = try XCTUnwrap(all.first { $0.0 == name }?.1)
            XCTAssertFalse(body.contains(".joinCall("), "\(name) must not join a call itself")
            XCTAssertFalse(body.contains("join-call"), "\(name) must not hit the join route itself")
        }
        let callers = Set(all.filter { $0.1.contains(".joinCall(userId:") }.map(\.0))
        XCTAssertTrue(callers.isSubset(of: ["CallRoomController.swift", "ChimeCallView.swift", "MockDataService.swift"]),
                      "only the existing call controllers invoke joinCall, found \(callers)")
        XCTAssertFalse(callers.contains("ChatThreadView.swift"), "the DM Call button must not call joinCall directly")
    }

    func test_dmCallButton_usesCallControllerStart_thenExistingRingMembers() throws {
        let s = try src("Chat/ChatThreadView.swift")
        let start = try XCTUnwrap(s.range(of: "private func startDmCall() {"))
        let end = try XCTUnwrap(s.range(of: "closeSessionsMenu() {", range: start.upperBound..<s.endIndex))
        let body = String(s[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("contact.type == .friend"), "friend DMs only")
        XCTAssertTrue(body.contains("dmService.startDmCall(userId: uid, peerId: peer.id)"))
        XCTAssertTrue(body.contains("CallController.shared.start(session: session"))
        XCTAssertTrue(body.contains("ringMembers(") && body.contains("targetIds: [peer.id]"))
        let startIdx = try XCTUnwrap(body.range(of: "CallController.shared.start(")).lowerBound
        let ringIdx = try XCTUnwrap(body.range(of: "ringMembers(")).lowerBound
        XCTAssertLessThan(startIdx, ringIdx, "join first, then ring")
        XCTAssertTrue(body.contains("They weren't alerted"), "a refused or failed ring is surfaced")
        XCTAssertTrue(body.contains("dmCallError = "), "start failures surface as an alert, no call UI opened")
        let catchIdx = try XCTUnwrap(body.range(of: "dmCallError = ", options: .backwards)).lowerBound
        XCTAssertGreaterThan(catchIdx, startIdx)
        XCTAssertTrue(body.contains("CallController.shared.ring.begin("), "caller ring state tracking starts after a sent ring")
    }

    func test_callEnd_cancelsOutstandingRings_andCallScreenShowsBanner() throws {
        let v = try src("Chat/ChimeCallView.swift")
        let endStart = try XCTUnwrap(v.range(of: "    func end() {"))
        XCTAssertTrue(String(v[endStart.upperBound...].prefix(900)).contains("ring.cancelOutstandingAndReset()"))
        XCTAssertTrue(v.contains("OutgoingRingBanner(tracker: call.ring") || v.contains("OutgoingRingBanner(tracker:"),
                      "ChimeCallView must render the caller ring banner")
    }

    func test_groupRingSheet_usesSameRingTracker() throws {
        let r = try src("Chat/RingMembersSheet.swift")
        XCTAssertTrue(r.contains("ring.begin("), "group rings share the one tracker (no second call path)")
    }

    // VoipCallManager: ring_cancel, decline vs timeout, defaults.
    func test_voip_ringCancel_handledBeforeGroupGuard_withPlaceholderAndNoDeclineReport() throws {
        let v = try src("Services/VoipCallManager.swift")
        let cancelIdx = try XCTUnwrap(v.range(of: "(data[\"action\"] as? String) == \"ring_cancel\"")).lowerBound
        let guardIdx = try XCTUnwrap(v.range(of: "guard let devotionId, let groupId, !devotionId.isEmpty")).lowerBound
        XCTAssertLessThan(cancelIdx, guardIdx, "ring_cancel carries no group_id, so it must be handled before the malformed-payload guard")
        let cancelBlock = String(v[cancelIdx..<guardIdx])
        XCTAssertTrue(cancelBlock.contains("endRingingCalls(devotionId: devotionId)"))
        XCTAssertTrue(cancelBlock.contains("reportPlaceholderAndEnd("), "PushKit rule: every push reports a call")
        XCTAssertFalse(cancelBlock.contains("reportDecline"), "a cancel is never a decline")
        let helper = try XCTUnwrap(v.range(of: "private func endRingingCalls(devotionId: String) {"))
        let helperBody = String(v[helper.upperBound...].prefix(900))
        XCTAssertTrue(helperBody.contains("reason: .remoteEnded"))
        XCTAssertFalse(helperBody.contains("reportDecline"))
        XCTAssertTrue(helperBody.contains("earlyCancels[devotionId] = Date()"), "cancel before ring is remembered")
        XCTAssertTrue(helperBody.contains("ringTimeoutTimers[uuid]?.invalidate()"))
    }

    func test_voip_earlyCancel_endsLateRingImmediately_andIsConsumedOnce() throws {
        let v = try src("Services/VoipCallManager.swift")
        let idx = try XCTUnwrap(v.range(of: "if earlyCancels[devotionId] != nil {"))
        let block = String(v[idx.lowerBound...].prefix(300))
        XCTAssertTrue(block.contains("earlyCancels[devotionId] = nil"))
        XCTAssertTrue(block.contains("reportPlaceholderAndEnd("))
        XCTAssertTrue(v.contains("earlyCancelWindow: TimeInterval = 60"))
    }

    func test_voip_declineReportedOnlyForUserEnds_timeoutIsNotADecline() throws {
        let v = try src("Services/VoipCallManager.swift")
        let endStart = try XCTUnwrap(v.range(of: "perform action: CXEndCallAction) {"))
        let endBody = String(v[endStart.upperBound...].prefix(1100))
        XCTAssertTrue(endBody.contains("let endedBySystem = systemEndedCalls.remove(action.callUUID) != nil"))
        XCTAssertTrue(endBody.contains("if let target, !endedBySystem { reportDecline(target) }"))
        let timer = try XCTUnwrap(v.range(of: "private func scheduleRingTimeout("))
        let timerBody = String(v[timer.upperBound...].prefix(900))
        let insertIdx = try XCTUnwrap(timerBody.range(of: "systemEndedCalls.insert(uuid)")).lowerBound
        let reqIdx = try XCTUnwrap(timerBody.range(of: "callController.request(")).lowerBound
        XCTAssertLessThan(insertIdx, reqIdx, "mark as system-ended before requesting the end")
        let decline = try XCTUnwrap(v.range(of: "private func reportDecline("))
        let declineBody = String(v[decline.upperBound...].prefix(900))
        XCTAssertTrue(declineBody.contains("outcome: .declined"))
        XCTAssertTrue(declineBody.contains("targetId: uid"), "the ringed target is the signed-in user")
        XCTAssertTrue(declineBody.contains("guard !uid.isEmpty"), "no signed-in user means no report")
    }

    func test_voip_answerSendsNoDecline_andDefaultTimeoutIs45() throws {
        let v = try src("Services/VoipCallManager.swift")
        let a = try XCTUnwrap(v.range(of: "perform action: CXAnswerCallAction) {"))
        let aBody = String(v[a.upperBound...].prefix(700))
        XCTAssertFalse(aBody.contains("reportDecline"))
        XCTAssertFalse(aBody.contains("respondToRing"))
        XCTAssertTrue(v.contains("defaultRingTimeout: Double = 45"))
        XCTAssertTrue(v.contains("?? Self.defaultRingTimeout"), "the push's ring_timeout_seconds wins, 45 is only the fallback")
    }
}

// MARK: - 5. CallRingTracker: caller ring states

private final class RingScript: @unchecked Sendable {
    static let shared = RingScript()
    private let lock = NSLock()
    private var _statuses: [[String: String]] = []   // queue of poll responses
    private var _failNext = 0
    private var _responds: [(devotionId: String, userId: String, targetId: String, outcome: RingOutcome)] = []
    private var _polls = 0
    func reset() { lock.lock(); _statuses = []; _failNext = 0; _responds = []; _polls = 0; lock.unlock() }
    func queue(_ s: [String: String]) { lock.lock(); _statuses.append(s); lock.unlock() }
    func failNext(_ n: Int) { lock.lock(); _failNext = n; lock.unlock() }
    var responds: [(devotionId: String, userId: String, targetId: String, outcome: RingOutcome)] { lock.lock(); defer { lock.unlock() }; return _responds }
    var polls: Int { lock.lock(); defer { lock.unlock() }; return _polls }
    func nextPoll() throws -> [String: RingStatusEntry] {
        lock.lock(); defer { lock.unlock() }
        _polls += 1
        if _failNext > 0 { _failNext -= 1; throw AppError.networkError("poll failed") }
        let s = _statuses.isEmpty ? [:] : (_statuses.count > 1 ? _statuses.removeFirst() : _statuses[0])
        return s.mapValues { RingStatusEntry(status: $0, seconds_left: nil) }
    }
    func record(_ d: String, _ u: String, _ t: String, _ o: RingOutcome) { lock.lock(); _responds.append((d, u, t, o)); lock.unlock() }
}

extension ThrowingTestDataService: RingLifecycleServiceProtocol {
    func respondToRing(devotionId: String, userId: String, targetId: String, outcome: RingOutcome) async throws {
        RingScript.shared.record(devotionId, userId, targetId, outcome)
    }
    func fetchRingStatus(devotionId: String, userId: String) async throws -> [String: RingStatusEntry] {
        try RingScript.shared.nextPoll()
    }
}

@MainActor
final class CallRingTrackerTests: XCTestCase {
    override func setUp() { RingScript.shared.reset() }

    private func tracker(_ targets: [(id: String, name: String)]) -> CallRingTracker {
        let t = CallRingTracker()
        t.begin(sessionId: "s1", targets: targets, service: ThrowingTestDataService(), userId: "me")
        return t
    }
    private func waitForPolls(_ n: Int, timeout: TimeInterval = 8) async throws {
        let end = Date().addingTimeInterval(timeout)
        while RingScript.shared.polls < n, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 150_000_000)   // let the poll's state write land
    }

    func test_begin_showsRingingImmediately_singleAndMultiple() {
        let one = tracker([("a", "Alice")])
        XCTAssertEqual(one.phase, .ringing)
        XCTAssertEqual(one.bannerText, "Ringing Alice...")
        one.cancelOutstandingAndReset()
        let many = tracker([("a", "Alice"), ("b", "Bob")])
        XCTAssertEqual(many.bannerText, "Ringing 2 people...")
        many.cancelOutstandingAndReset()
    }

    func test_begin_withNoTargetsOrNoUser_doesNothing() {
        let t = CallRingTracker()
        t.begin(sessionId: "s", targets: [], service: ThrowingTestDataService(), userId: "me")
        XCTAssertNil(t.phase)
        t.begin(sessionId: "s", targets: [("a", "A")], service: ThrowingTestDataService(), userId: "")
        XCTAssertNil(t.phase)
        XCTAssertTrue(t.targets.isEmpty)
    }

    func test_declined_singleTarget_showsDeclinedBanner() async throws {
        RingScript.shared.queue(["a": "declined"])
        let t = tracker([("a", "Alice")])
        try await waitForPolls(1)
        XCTAssertEqual(t.phase, .declined)
        XCTAssertEqual(t.bannerText, "Alice declined.")
        t.cancelOutstandingAndReset()
    }

    func test_timedOut_singleTarget_showsDidntAnswer() async throws {
        RingScript.shared.queue(["a": "timed_out"])
        let t = tracker([("a", "Alice")])
        try await waitForPolls(1)
        XCTAssertEqual(t.phase, .noAnswer)
        XCTAssertEqual(t.bannerText, "Alice didn't answer.")
        t.cancelOutstandingAndReset()
    }

    func test_answered_hidesBanner() async throws {
        RingScript.shared.queue(["a": "answered"])
        let t = tracker([("a", "Alice")])
        try await waitForPolls(1)
        XCTAssertNil(t.phase)
        XCTAssertNil(t.bannerText)
        t.cancelOutstandingAndReset()
    }

    func test_failedPoll_keepsLastKnownState_neverInventsOutcome() async throws {
        RingScript.shared.failNext(1)
        let t = tracker([("a", "Alice")])
        try await waitForPolls(1)
        XCTAssertEqual(t.phase, .ringing, "a failed poll must leave the ringing state alone")
        XCTAssertEqual(t.targets.first?.status, "ringing")
        t.cancelOutstandingAndReset()
    }

    func test_mixedGroup_phaseMapping_andCancelOnlyStillRinging() async throws {
        RingScript.shared.queue(["a": "declined", "b": "ringing", "c": "timed_out"])
        let t = tracker([("a", "Alice"), ("b", "Bob"), ("c", "Cy")])
        try await waitForPolls(1)
        XCTAssertEqual(t.phase, .ringing, "anyone still ringing keeps the ringing phase")
        XCTAssertEqual(t.bannerText, "Ringing Bob...")

        // Caller hangs up while Bob is still ringing: only Bob gets a canceled report.
        t.cancelOutstandingAndReset()
        try await Task.sleep(nanoseconds: 300_000_000)
        let sent = RingScript.shared.responds
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.targetId, "b")
        XCTAssertEqual(sent.first?.outcome, .canceled)
        XCTAssertEqual(sent.first?.devotionId, "s1")
        XCTAssertEqual(sent.first?.userId, "me", "the caller sends the cancel")
        XCTAssertTrue(t.targets.isEmpty)
        XCTAssertNil(t.phase)
    }

    func test_groupAllDeclined_andMixedDoneStates() async throws {
        RingScript.shared.queue(["a": "declined", "b": "declined"])
        let allDeclined = tracker([("a", "Alice"), ("b", "Bob")])
        try await waitForPolls(1)
        XCTAssertEqual(allDeclined.phase, .declined)
        XCTAssertEqual(allDeclined.bannerText, "No one joined. They declined.")
        allDeclined.cancelOutstandingAndReset()

        RingScript.shared.reset()
        RingScript.shared.queue(["a": "declined", "b": "timed_out"])
        let mixed = tracker([("a", "Alice"), ("b", "Bob")])
        try await waitForPolls(1)
        XCTAssertEqual(mixed.phase, .noAnswer)
        XCTAssertEqual(mixed.bannerText, "No one answered.")
        mixed.cancelOutstandingAndReset()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(RingScript.shared.responds.isEmpty, "nothing still ringing, so nothing to cancel")
    }

    func test_cancel_stopsPolling() async throws {
        let t = tracker([("a", "Alice")])
        t.cancelOutstandingAndReset()
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertEqual(RingScript.shared.polls, 0)
    }
}
