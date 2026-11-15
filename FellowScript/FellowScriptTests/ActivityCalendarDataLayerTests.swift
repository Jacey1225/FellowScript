// ActivityCalendarDataLayerTests.swift -- task 20261114-activity-calendar, step 8.
// Network layer (throws, never fabricates), store (preserves last good month in
// memory and on disk on failure), Bible read signal (day-only, once per day).

import XCTest
@testable import FellowScript

final class ActivityCalendarNetworkTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(StubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(StubURLProtocol.self); super.tearDown() }

    private func stub(_ code: Int, _ body: String) {
        StubURLProtocol.stubStatusCode = code
        StubURLProtocol.stubBody = body.data(using: .utf8)!
        StubURLProtocol.resetRequestLog()
    }

    func test_month_decodes_andUsesGetWithYearMonthQuery() async throws {
        stub(200, #"{"year":2026,"month":11,"timezone":"America/Los_Angeles","days":{"2026-11-03":["note","chat","bible"],"2026-11-30":["chat"]}}"#)
        let m = try await NetworkService.shared.fetchActivityMonth(year: 2026, month: 11)
        XCTAssertEqual(m.year, 2026); XCTAssertEqual(m.month, 11)
        XCTAssertEqual(m.timezone, "America/Los_Angeles")
        XCTAssertEqual(m.days["2026-11-30"], [.chat])
        // stable display order regardless of server order
        XCTAssertEqual(m.kinds(on: "2026-11-03"), [.chat, .note, .bible])
        XCTAssertEqual(m.kinds(on: "2026-11-04"), [])
        let req = StubURLProtocol.requestLog.first { $0.path.hasSuffix("/activity-calendar/month") }
        XCTAssertEqual(req?.method, "GET")
        XCTAssertTrue(req?.url.contains("year=2026") == true && req?.url.contains("month=11") == true)
        XCTAssertNil(req?.bodyData)
    }

    func test_month_minimalEmptyDays_decodes() async throws {
        stub(200, #"{"year":2026,"month":2,"timezone":"UTC","days":{}}"#)
        let m = try await NetworkService.shared.fetchActivityMonth(year: 2026, month: 2)
        XCTAssertTrue(m.days.isEmpty)
    }

    func test_month_throwsOnHTTPFailure_neverEmptyMonth() async {
        for code in [401, 403, 422, 500] {
            stub(code, #"{"detail":"nope"}"#)
            do { _ = try await NetworkService.shared.fetchActivityMonth(year: 2026, month: 11)
                 XCTFail("must throw on \(code)") } catch {}
        }
    }

    func test_month_throwsOnUndecodableBody() async {
        stub(200, #"{"unexpected":true}"#)
        do { _ = try await NetworkService.shared.fetchActivityMonth(year: 2026, month: 11)
             XCTFail("must throw on undecodable 200") } catch {}
        stub(200, "")
        do { _ = try await NetworkService.shared.fetchActivityMonth(year: 2026, month: 11)
             XCTFail("must throw on empty 200") } catch {}
    }

    func test_month_throwsWhenServerAnswersForDifferentMonth() async {
        stub(200, #"{"year":2026,"month":10,"timezone":"UTC","days":{"2026-10-01":["chat"]}}"#)
        do { _ = try await NetworkService.shared.fetchActivityMonth(year: 2026, month: 11)
             XCTFail("must throw on month mismatch") } catch {}
    }

    func test_unknownKind_isNotSilentlyAccepted() async {
        stub(200, #"{"year":2026,"month":11,"timezone":"UTC","days":{"2026-11-01":["streak"]}}"#)
        do { _ = try await NetworkService.shared.fetchActivityMonth(year: 2026, month: 11)
             XCTFail("unknown kind should fail decode, not be dropped") } catch {}
    }

    func test_recordBibleDay_postsNoBodyNoUserIdNoQuery() async throws {
        stub(204, "")
        try await NetworkService.shared.recordBibleDay()
        let reqs = StubURLProtocol.requestLog.filter { $0.path.hasSuffix("/activity-calendar/bible-day") }
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs[0].method, "POST")
        XCTAssertNil(reqs[0].bodyData, "day-only: nothing about chapter or date is sent")
        XCTAssertFalse(reqs[0].url.contains("?"))
    }

    func test_recordBibleDay_throwsOnServerError() async {
        stub(500, #"{"detail":"boom"}"#)
        do { try await NetworkService.shared.recordBibleDay(); XCTFail("must throw") } catch {}
        stub(401, #"{"detail":"Not authenticated"}"#)
        do { try await NetworkService.shared.recordBibleDay(); XCTFail("must throw") } catch {}
    }
}

@MainActor
final class ActivityCalendarStoreTests: XCTestCase {
    private struct Boom: Error {}
    private var cleanup: [(String, String)] = []

    private func month(_ y: Int, _ m: Int, _ days: [String: [FSActivityKind]]) -> FSActivityMonth {
        FSActivityMonth(year: y, month: m, timezone: "UTC", days: days)
    }

    override func tearDown() async throws {
        for (uid, key) in cleanup { await DiskCache.shared.remove(forKey: "activityCalendar_\(uid)_\(key)") }
        cleanup = []
    }

    private func uid() -> String { let u = "test-\(UUID().uuidString)"; cleanup.append((u, "2026-11")); cleanup.append((u, "2026-10")); return u }

    func test_successReplacesMemoryAndClearsError() async throws {
        let good = month(2026, 11, ["2026-11-01": [.chat]])
        let store = ActivityCalendarStore(userId: uid()) { _, _ in good }
        try await store.refresh(year: 2026, month: 11)
        XCTAssertEqual(store.month(year: 2026, month: 11), good)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.activeDays(year: 2026, month: 11), 1)
    }

    func test_failedFirstRefresh_throwsAndNeverFabricatesEmptyMonth() async {
        let store = ActivityCalendarStore(userId: uid()) { _, _ in throw Boom() }
        do { try await store.refresh(year: 2026, month: 11); XCTFail("must rethrow") } catch {}
        XCTAssertNil(store.month(year: 2026, month: 11))
        XCTAssertNotNil(store.lastError)
        XCTAssertNil(store.activeDays(year: 2026, month: 11))
    }

    func test_failedRefresh_preservesLastGoodMonthInMemoryAndOnDisk() async throws {
        let u = uid()
        let good = month(2026, 11, ["2026-11-05": [.bible, .note]])
        var fail = false
        let store = ActivityCalendarStore(userId: u) { _, _ in
            if fail { throw Boom() }
            return good
        }
        try await store.refresh(year: 2026, month: 11)
        fail = true
        do { try await store.refresh(year: 2026, month: 11); XCTFail("must rethrow") } catch {}
        XCTAssertEqual(store.month(year: 2026, month: 11), good, "memory kept")
        XCTAssertNotNil(store.lastError)
        // a cold store (new launch) sees the good disk copy, not an empty month
        let cold = ActivityCalendarStore(userId: u) { _, _ in throw Boom() }
        await cold.loadCached(year: 2026, month: 11)
        XCTAssertEqual(cold.month(year: 2026, month: 11), good, "disk kept")
        // and recovers on next success
        fail = false
        try await store.refresh(year: 2026, month: 11)
        XCTAssertNil(store.lastError)
    }

    func test_cacheIsNamespacedPerUser() async throws {
        let a = uid(), b = uid()
        let sA = ActivityCalendarStore(userId: a) { _, _ in self.month(2026, 11, ["2026-11-01": [.chat]]) }
        try await sA.refresh(year: 2026, month: 11)
        let sB = ActivityCalendarStore(userId: b) { _, _ in throw Boom() }
        await sB.loadCached(year: 2026, month: 11)
        XCTAssertNil(sB.month(year: 2026, month: 11), "another user's cache must not leak")
    }

    func test_loadCached_doesNotOverwriteMemoryAndRejectsWrongMonth() async throws {
        let u = uid()
        let old = month(2026, 11, ["2026-11-01": [.chat]])
        let s1 = ActivityCalendarStore(userId: u) { _, _ in old }
        try await s1.refresh(year: 2026, month: 11)
        let fresher = month(2026, 11, ["2026-11-01": [.chat], "2026-11-02": [.note]])
        let s2 = ActivityCalendarStore(userId: u) { _, _ in fresher }
        try await s2.refresh(year: 2026, month: 11)
        await s2.loadCached(year: 2026, month: 11)
        XCTAssertEqual(s2.month(year: 2026, month: 11), fresher)
    }

    func test_cancellationDoesNotSetLastError_butRethrows() async {
        let store = ActivityCalendarStore(userId: uid()) { _, _ in throw CancellationError() }
        do { try await store.refresh(year: 2026, month: 11); XCTFail() } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(store.lastError)
    }

    func test_load_swallowsFailureButKeepsData() async throws {
        let good = month(2026, 11, ["2026-11-09": [.chat]])
        var fail = false
        let store = ActivityCalendarStore(userId: uid()) { _, _ in if fail { throw Boom() }; return good }
        await store.load(year: 2026, month: 11)
        fail = true
        await store.load(year: 2026, month: 11)
        XCTAssertEqual(store.month(year: 2026, month: 11), good)
    }

    func test_activeDays_countsDatesNotKinds_andIgnoresEmptyArrays() async throws {
        let m = month(2026, 11, ["2026-11-01": [.chat, .note, .bible], "2026-11-02": [], "2026-11-30": [.bible]])
        let store = ActivityCalendarStore(userId: uid()) { _, _ in m }
        try await store.refresh(year: 2026, month: 11)
        XCTAssertEqual(store.activeDays(year: 2026, month: 11), 2)
        XCTAssertEqual(activeDaysText(1), "Active on 1 day this month")
        XCTAssertEqual(activeDaysText(2), "Active on 2 days this month")
    }

    func test_monthKey_zeroPads() {
        XCTAssertEqual(ActivityCalendarStore.monthKey(year: 2026, month: 3), "2026-03")
    }
}

@MainActor
final class BibleReadSignalTests: XCTestCase {
    private struct Boom: Error {}

    func test_defaultHoldIsTenSeconds_andSleepReceivesIt() async {
        XCTAssertEqual(BibleReadSignal.defaultHoldSeconds, 10)
        var slept: [TimeInterval] = []
        let s = BibleReadSignal(sleep: { slept.append($0) }, dayKey: { "2026-11-14" }, record: {})
        await s.chapterHeld()
        XCTAssertEqual(slept, [10])
    }

    func test_recordsOncePerDay_notPerChapter() async {
        var n = 0
        let s = BibleReadSignal(sleep: { _ in }, dayKey: { "2026-11-14" }, record: { n += 1 })
        let r1 = await s.chapterHeld(); let r2 = await s.chapterHeld(); let r3 = await s.chapterHeld()
        XCTAssertEqual([r1, r2, r3], [true, false, false])
        XCTAssertEqual(n, 1)
    }

    func test_newDayRecordsAgain() async {
        var day = "2026-11-14"; var n = 0
        let s = BibleReadSignal(sleep: { _ in }, dayKey: { day }, record: { n += 1 })
        await s.chapterHeld(); day = "2026-11-15"; await s.chapterHeld()
        XCTAssertEqual(n, 2)
    }

    func test_leavingBeforeHold_cancelsAndRecordsNothing() async {
        var n = 0
        let s = BibleReadSignal(holdSeconds: 10,
                                sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                                dayKey: { "2026-11-14" }, record: { n += 1 })
        let t = Task { await s.chapterHeld() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        t.cancel()
        let result = await t.value
        XCTAssertFalse(result)
        XCTAssertEqual(n, 0, "a chapter that did not stay on screen never counts")
    }

    func test_cancelledAfterSleepButBeforeRecord_doesNotRecord() async {
        var n = 0
        let holder = TaskBox()
        let s = BibleReadSignal(sleep: { _ in holder.task?.cancel() }, dayKey: { "d" }, record: { n += 1 })
        holder.task = Task { await s.chapterHeld() }
        let r = await holder.task!.value
        XCTAssertFalse(r); XCTAssertEqual(n, 0)
    }

    func test_failedRecordIsRetriedOnLaterHold_andNeverThrows() async {
        var n = 0; var fail = true
        let s = BibleReadSignal(sleep: { _ in }, dayKey: { "d" }, record: { n += 1; if fail { throw Boom() } })
        let r1 = await s.chapterHeld()
        XCTAssertFalse(r1)
        fail = false
        let r2 = await s.chapterHeld(); let r3 = await s.chapterHeld()
        XCTAssertTrue(r2); XCTAssertFalse(r3)
        XCTAssertEqual(n, 2)
    }

    func test_localDayKeyFormat() {
        let k = BibleReadSignal.localDayKey()
        XCTAssertNotNil(k.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression))
    }

    private final class TaskBox { var task: Task<Bool, Never>? }
}
