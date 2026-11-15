// BibleReadSignal.swift -- task 20261114-activity-calendar.
// Decides when "the user read the Bible today" is reported: only after the
// same chapter has stayed on screen for `holdSeconds`. The server records the
// DAY ONLY, so no book, chapter or verse is passed to `record`, and highlights
// or other taps never count (only the hold does). At most one report per local
// calendar day per process; the server is idempotent per user per day anyway.

import Foundation

@MainActor
final class BibleReadSignal {
    static let defaultHoldSeconds: TimeInterval = 10

    private let holdSeconds: TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private let record: () async throws -> Void
    private let dayKey: () -> String
    private var reportedDay: String?

    init(holdSeconds: TimeInterval = BibleReadSignal.defaultHoldSeconds,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         dayKey: @escaping () -> String = BibleReadSignal.localDayKey,
         record: @escaping () async throws -> Void) {
        self.holdSeconds = holdSeconds
        self.sleep = sleep
        self.dayKey = dayKey
        self.record = record
    }

    static func localDayKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Call from a SwiftUI `.task(id: chapter)`: the task is cancelled when the
    /// chapter changes or the screen leaves, which cancels the hold. Returns
    /// true if a record call succeeded. A failed record is not remembered as
    /// reported, so the next chapter hold tries again; it never surfaces UI.
    @discardableResult
    func chapterHeld() async -> Bool {
        let today = dayKey()
        if reportedDay == today { return false }
        do {
            try await sleep(holdSeconds)
            try Task.checkCancellation()
            try await record()
            reportedDay = today
            return true
        } catch {
            return false
        }
    }
}
