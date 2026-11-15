// NetworkService+ActivityCalendar.swift -- task 20261114-activity-calendar
// (api/routes/activity_calendar.py). Two calls, both owner-only (identity comes
// from the auth token; no user id is ever sent):
//   GET  /activity-calendar/month?year=&month=  -> {year, month, timezone, days}
//   POST /activity-calendar/bible-day           -> 204, no body, idempotent
// Both throw on failure (throw-not-fabricate): a failed month load never turns
// into an empty calendar. No counts or streaks exist in the response and none
// are derived here. Nothing in this file logs activity details.

import Foundation

enum FSActivityKind: String, Codable, Equatable, CaseIterable {
    case chat, note, bible
}

/// One month of the signed-in user's own activity. `days` maps "YYYY-MM-DD"
/// (already bucketed server-side in the user's timezone) to the kinds done
/// that day. A day with no activity is simply absent.
struct FSActivityMonth: Codable, Equatable {
    let year: Int
    let month: Int
    let timezone: String
    let days: [String: [FSActivityKind]]

    /// Activities for a "YYYY-MM-DD" key, in a stable display order.
    func kinds(on dayKey: String) -> [FSActivityKind] {
        let present = Set(days[dayKey] ?? [])
        return FSActivityKind.allCases.filter { present.contains($0) }
    }
}

extension NetworkService {

    /// GET the caller's own activity for a month. Throws on any failure,
    /// including a response that can't be decoded or that answers for a
    /// different month than the one requested (never fabricates empty days).
    func fetchActivityMonth(year: Int, month: Int) async throws -> FSActivityMonth {
        let endpoint = "GET /activity-calendar/month"
        let data = try await reportFetchFailure(endpoint: endpoint) {
            try await self.get("/activity-calendar/month?year=\(year)&month=\(month)")
        }
        guard let result = decode(FSActivityMonth.self, from: data, endpoint: endpoint),
              result.year == year, result.month == month else {
            throw AppError.networkError("Couldn't load your activity calendar.")
        }
        return result
    }

    /// POST the "read the Bible today" day marker. No body: the server picks
    /// the day itself, so nothing about the chapter or date leaves the device.
    /// Not retried (a retry is harmless server-side but the caller decides).
    func recordBibleDay() async throws {
        _ = try await request("/activity-calendar/bible-day", method: "POST")
    }
}
