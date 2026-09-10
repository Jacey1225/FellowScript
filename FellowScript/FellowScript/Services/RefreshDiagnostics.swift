// RefreshDiagnostics.swift — structured, PII-free diagnostics added for task
// 20260910-refresh-clobber-live-rootcause (spec: "live capture first, fix
// second"). This is the FOURTH attempt at the group-notes/Account
// pull-to-refresh data-loss bug; the first three each "fixed" the problem at
// the code-reading/synthetic-test level and each still reproduced live. This
// file exists purely to make the real, on-device sequence of cache reads/
// writes and network outcomes observable via Console.app / `log stream`
// against the paired iPhone Air while the user reproduces the exact recorded
// Notes and Account pull-to-refresh sequences — see this task's pipeline
// directory for the resulting root-cause artifact and statement.
//
// Security Posture Q13 (proactively redact everywhere): every call site below
// logs endpoint template, HTTP-adjacent error class, DiskCache key NAMESPACE,
// entry COUNT, Task.isCancelled, and a timestamp only — never note text,
// titles, emails, or user ids in plaintext, and nothing from a response body.
//
// Security review correction (20260910-refresh-clobber-live-rootcause, step 4):
// an earlier version of this file logged the DiskCache key verbatim (e.g.
// "notes:60aa9553-...", the real signed-in user's uuid), reasoning that
// NetworkService's own request paths and CloudWatch already carry the same
// id. That comparison doesn't hold: NetworkService's *existing* diagnostics
// (`decode(...)`'s failure print, `reportDecodeFailure`) always pass a route
// *template* ("/notes/{user_id}"), never the literal id, and DiskCache's own
// pre-existing `print` lines only include the real key on rare failure paths
// (decode/write/remove errors), not on every routine read/write. This file's
// `emit()` runs on EVERY cache read/write during EVERY launch and refresh,
// and does so through `os.Logger` with `privacy: .public` — a deliberate
// opt-out of OSLog's default redaction, captured by Console.app/`log stream`
// far more broadly than a debugger-attached `print`. That combination made
// this new instrumentation a materially larger, systematic exposure of a
// real account identifier than anything already logged, in an artifact this
// task deliberately saves to disk (device-capture/console-capture.log) —
// exactly what Security Posture Q13 says to avoid. `redactedKey(_:)` below
// strips the identifying suffix before any key ever reaches `emit()`, so the
// namespace (which cache/table this is) is still fully diagnosable while the
// account id itself never appears in this file's output.
//
// Left compiled in indefinitely (unified logging is a negligible-cost no-op
// when nothing is streaming/capturing it) rather than scoped for removal —
// standard os.Logger usage, matching the "capture via Console/log stream"
// evidence bar this task's acceptance criteria set. Not wired into any
// user-visible UI.
import Foundation
import os

enum RefreshDiagnostics {
    // Subsystem matches the app's bundle id so a live capture can filter with
    // `log stream --predicate 'subsystem == "com.fellowscript.app"'` or the
    // equivalent Console.app filter. Single shared category for this task's
    // instrumentation across Notes/Dashboard/Account/NetworkService so all of
    // it shows up together, ordered by device clock, in one capture.
    private static let logger = Logger(subsystem: "com.fellowscript.app", category: "refresh-diagnostics")

    // A human-readable wall-clock stamp embedded in the message text itself
    // (in addition to whatever timestamp Console/log stream already attaches)
    // so a saved/exported log excerpt remains self-describing and can be
    // correlated against server-side log timestamps (which run in UTC) even
    // outside Console's own timeline view.
    private static func ts() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// Strips a DiskCache key's identifying suffix before it's ever logged.
    /// Every DiskCache key in this codebase is namespaced as
    /// "<namespace>:<uid>" (DiskCache.swift's own doc comment) — this keeps
    /// only the namespace ("notes", "dashboardNotes", "events", ...), which
    /// is all a live capture needs to tell keys apart, and replaces the
    /// account identifier with a fixed placeholder so no real user id ever
    /// reaches Console.app/`log stream` or a saved capture file. Falls back
    /// to the input unchanged only if a key has no ":" at all (shouldn't
    /// happen given the codebase-wide convention, but never worth crashing
    /// diagnostics over).
    private static func redactedKey(_ key: String) -> String {
        guard let colonIndex = key.firstIndex(of: ":") else { return key }
        return "\(key[key.startIndex..<colonIndex]):<redacted>"
    }

    /// Emits a line on both capture channels this task's live evidence bar
    /// relies on: os.Logger (Console.app / `log stream` against the
    /// connected device, per the spec's own suggested method) and `print`
    /// (already this codebase's existing convention for NetworkService's own
    /// diagnostics, and the channel a plain `devicectl device process launch
    /// --console` stdout capture can pick up without a GUI). Same PII-free
    /// text on both — see this file's header comment for the redaction
    /// contract.
    private static func emit(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        print("[RefreshDiagnostics] \(line)")
    }

    /// A DiskCache read at the start of a load/refresh. `count` is the
    /// decoded collection's entry count, or nil if the key was a cache miss
    /// (no `.load` result) — never the entries themselves.
    static func cacheRead(key: String, count: Int?) {
        let countStr = count.map(String.init) ?? "miss"
        emit("[cache-read] key=\(redactedKey(key)) count=\(countStr) ts=\(ts())")
    }

    /// A DiskCache write at the end of a load/refresh round.
    static func cacheWrite(key: String, count: Int) {
        emit("[cache-write] key=\(redactedKey(key)) count=\(count) ts=\(ts())")
    }

    /// A DiskCache write that was intentionally SKIPPED this round (task
    /// 20260910-refresh-clobber-live-rootcause, step 3: "a cancelled refresh
    /// round persists nothing to disk"). Distinct from `cacheWrite` so a live
    /// capture / final verification pass can positively confirm the skip
    /// happened, rather than inferring it from the mere absence of a
    /// cache-write line.
    static func cacheWriteSkipped(key: String, reason: String) {
        emit("[cache-write-skipped] key=\(redactedKey(key)) reason=\(reason) ts=\(ts())")
    }

    /// One network fetch's outcome. `endpoint` is always a route template
    /// (e.g. "GET /notes/{user_id}"), never the literal request path with a
    /// real user id interpolated in. `outcome` is "success" or "failure".
    /// `count` is the decoded item count on success, when meaningful.
    /// `taskCancelled` is `Task.isCancelled` sampled at the catch site, for
    /// failures — the key signal for telling routine SwiftUI task
    /// cancellation apart from a genuine transport/HTTP failure (spec open
    /// question 2).
    static func fetchOutcome(endpoint: String, outcome: String, count: Int? = nil,
                              errorClass: String? = nil, taskCancelled: Bool? = nil) {
        var parts = ["endpoint=\(endpoint)", "outcome=\(outcome)"]
        if let count { parts.append("count=\(count)") }
        if let errorClass { parts.append("errorClass=\(errorClass)") }
        if let taskCancelled { parts.append("taskCancelled=\(taskCancelled)") }
        parts.append("ts=\(ts())")
        let msg = parts.joined(separator: " ")
        emit("[fetch] \(msg)")
    }

    /// A single Notes segment's (Personal, or one group) splice decision for
    /// this refresh round — mirrors the segmentErrors bookkeeping already in
    /// NotesViewModel.fetchAndCache, just also emitted live. `name` is
    /// "Personal" or a group's display title (never a note's own text/title).
    static func segmentOutcome(name: String, outcome: String, count: Int? = nil) {
        let countStr = count.map(String.init) ?? "n/a"
        emit("[segment] name=\(name) outcome=\(outcome) count=\(countStr) ts=\(ts())")
    }

    /// Classifies an error down to a coarse, PII-free class string —
    /// "CancellationError", "URLError(<code>)" (the raw Int rawValue, e.g.
    /// -999 for .cancelled), or "AppError.<case>" — deliberately never the
    /// error's own `localizedDescription`/`errorDescription`, which for
    /// AppError.networkError/.limitReached can embed server-provided detail
    /// text.
    static func errorClass(_ error: Error) -> String {
        if error is CancellationError { return "CancellationError" }
        if let urlError = error as? URLError { return "URLError(\(urlError.code.rawValue))" }
        if let appError = error as? AppError {
            switch appError {
            case .authFailed:    return "AppError.authFailed"
            case .networkError:  return "AppError.networkError"
            case .limitReached:  return "AppError.limitReached"
            case .notFound:      return "AppError.notFound"
            case .rateLimited:   return "AppError.rateLimited"
            case .mfaRequired:   return "AppError.mfaRequired"
            }
        }
        return String(describing: type(of: error))
    }

    /// True if `error` is cooperative task cancellation rather than a genuine
    /// transport/HTTP failure — same check AccountViewModel.isCancellation
    /// already uses; centralized here so every new diagnostic call site
    /// (including ones outside AccountViewModel) classifies it identically.
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
