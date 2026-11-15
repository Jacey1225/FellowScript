// ActivityCalendarStore.swift -- task 20261114-activity-calendar, data layer
// only (the calendar view is step 6, blocked on the design spec).
//
// Cache rules (Jacey's standing architecture principles):
//  - throw, never fabricate: a failed refresh throws and never produces an
//    empty month;
//  - preserve the last good month: a failed refresh leaves `months` untouched
//    and the cached copy on disk intact;
//  - the cache is namespaced by user id and lives in DiskCache (Library/Caches,
//    file protection completeUntilFirstUserAuthentication). It holds only
//    day -> kind labels, never message/note text or chapters.

import Foundation
import Combine

@MainActor
final class ActivityCalendarStore: ObservableObject {
    /// Last good month per "YYYY-MM" key.
    @Published private(set) var months: [String: FSActivityMonth] = [:]
    /// Surfaced error of the most recent refresh (nil after a success). The
    /// month shown stays the last good one while this is set.
    @Published private(set) var lastError: Error?

    private let userId: String
    private let fetch: (Int, Int) async throws -> FSActivityMonth
    private let cache: DiskCache

    init(userId: String,
         cache: DiskCache = .shared,
         fetch: @escaping (Int, Int) async throws -> FSActivityMonth) {
        self.userId = userId
        self.cache = cache
        self.fetch = fetch
    }

    convenience init(userId: String, service: NetworkService) {
        self.init(userId: userId) { year, month in
            try await service.fetchActivityMonth(year: year, month: month)
        }
    }

    static func monthKey(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    private func cacheKey(_ monthKey: String) -> String {
        "activityCalendar_\(userId)_\(monthKey)"
    }

    func month(year: Int, month: Int) -> FSActivityMonth? {
        months[Self.monthKey(year: year, month: month)]
    }

    /// Show the cached month immediately (stale-while-revalidate). Does not
    /// overwrite a month already in memory.
    func loadCached(year: Int, month: Int) async {
        let key = Self.monthKey(year: year, month: month)
        guard months[key] == nil,
              let cached = await cache.load(FSActivityMonth.self, forKey: cacheKey(key)),
              cached.year == year, cached.month == month else { return }
        months[key] = cached
    }

    /// Fetch fresh data. On success replace memory + disk. On failure: keep the
    /// last good month, record `lastError`, and rethrow so the caller can show it.
    func refresh(year: Int, month: Int) async throws {
        let key = Self.monthKey(year: year, month: month)
        do {
            let fresh = try await fetch(year, month)
            months[key] = fresh
            lastError = nil
            await cache.save(fresh, forKey: cacheKey(key))
        } catch {
            if !(error is CancellationError) { lastError = error }
            throw error
        }
    }
}
