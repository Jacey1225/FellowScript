// PlanBlock.swift — Free-plan blocked-action logic shared by every flow that
// can be rejected by the server's plan gates (task 20261002-free-plan-limits-ui).
//
// The server is authoritative: a blocked action is an HTTP 403 whose body (bare
// or under `detail`) is {resource, allowed:false, unlimited, used, limit,
// remaining[, paid_only]}. NetworkService.throwIfError already maps that to
// AppError.limitReached(resource:used:limit:); `PlanBlock.info(from:)` is the
// single detector that turns that typed error into a BlockedInfo for the
// upgrade prompt. Any other error (including the note_chars length cap and the
// announcements gate, which keep their own UI) returns nil.

import Foundation

struct BlockedInfo: Equatable {
    let resource: String
    let used: Int
    let limit: Int

    /// Features with no free allowance at all (server sends paid_only: true).
    var paidOnly: Bool { PlanBlock.paidOnlyResources.contains(resource) }
}

enum PlanBlock {
    /// Resources that open the upgrade prompt. `note_chars` and `announcements`
    /// are intentionally absent: they keep their own inline UI.
    static let resources: Set<String> = [
        "notes", "agent_events", "sessions", "session_summaries", "explorer_publish",
    ]
    static let paidOnlyResources: Set<String> = ["session_summaries", "explorer_publish"]

    static let title = "Not available on the Free plan"
    static let cta = "Subscribe to unlock it."

    /// The one detector: nil unless `error` is a plan block for one of the five flows.
    static func info(from error: Error) -> BlockedInfo? {
        guard case AppError.limitReached(let resource, let used, let limit) = error,
              resources.contains(resource) else { return nil }
        return BlockedInfo(resource: resource, used: used, limit: limit)
    }

    private static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    /// Body sentence per resource. Numbers come from the blocked response only;
    /// a missing figure (limit 0 on a paid-only block) is simply omitted.
    static func body(for info: BlockedInfo) -> String {
        switch info.resource {
        case "notes":
            return info.limit > 0 ? "Free plan includes \(plural(info.limit, "note")) per week."
                                  : "The Free plan has a weekly note limit."
        case "agent_events":
            return info.limit > 0
                ? "The Free plan includes \(plural(info.limit, "scheduled devotion")). Subscribe for as many as you like."
                : "The Free plan has a scheduled devotion limit. Subscribe for as many as you like."
        case "sessions":
            return info.limit > 0
                ? "Free plan members can host \(plural(info.limit, "session")) at a time. Finish your current one, or subscribe to host more."
                : "Free plan members can host one session at a time. Finish your current one, or subscribe to host more."
        case "session_summaries":
            return "Session summaries are for subscribers."
        case "explorer_publish":
            return "Publishing a group to Explorer is for subscribers. Browsing and joining stay free."
        default:
            return "This is not available on the Free plan."
        }
    }

    /// Returned by an editor `onSave` closure when the upgrade prompt was shown
    /// instead of an inline error: the editor stays open, no alert.
    static let handledMarker = "\u{0}plan-block-handled"
}

// ── Free plan limits list (Account subscription section) ──────────────────────

struct FreePlanLimitRow: Equatable {
    let label: String
    let value: String
    var caption: String? = nil
    var locked: Bool = false
}

struct FSPaidOnlyFlag: Codable, Equatable {
    var allowed: Bool = false
    var free_allowed: Bool = false
}

extension FSUsage {
    var sessions: FSUsageResource? { resources["sessions"] }

    /// "per week" for the 7-day window, otherwise "every N days".
    var windowPhrase: String { window_days == 7 ? "per week" : "every \(window_days) days" }

    /// Every Free-plan limit, rendered only from the usage payload (no hardcoded
    /// numbers). Rows for resources the server did not send are omitted.
    var freePlanRows: [FreePlanLimitRow] {
        var rows: [FreePlanLimitRow] = []
        if let n = resources["notes"] { rows.append(.init(label: "Notes", value: "\(n.limit) \(windowPhrase)")) }
        if let e = resources["agent_events"] { rows.append(.init(label: "Scheduled devotions", value: "\(e.limit) in total")) }
        if let s = sessions {
            rows.append(.init(label: "Hosting sessions", value: "\(s.limit) at a time", caption: "Join as many as you like"))
        }
        if let p = paid_only?["session_summaries"] {
            rows.append(.init(label: "Session summaries", value: p.free_allowed ? "Included" : "Subscribers only",
                              locked: !p.free_allowed))
        }
        if let p = paid_only?["explorer_publish"] {
            rows.append(.init(label: "Publish to Explorer", value: p.free_allowed ? "Included" : "Subscribers only",
                              caption: "Browsing and joining stay free", locked: !p.free_allowed))
        }
        if let n = resources["agent_notifications"] { rows.append(.init(label: "Notifications", value: "\(n.limit)")) }
        return rows
    }
}
