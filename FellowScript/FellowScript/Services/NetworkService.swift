// Real network layer. Conforms to DataServiceProtocol.
// Swap into AppState.init(service:) to go live:
//   AppState(service: NetworkService.shared)
// All endpoint paths mirror frontend/src/hooks/* and frontend/src/pages/Account.jsx.
//
// readability #H16 (20260904-frontend-arch-sweep): this file used to be a
// single ~1450-line type spanning ~10 unrelated domains (auth, notes,
// highlights, agents, contacts, messaging, attachments, subscriptions, ...)
// with only `// ── Section ──` banners separating them. Split by domain into
// `NetworkService+<Domain>.swift` extension files (same type, same single
// `DataServiceProtocol` conformance) -- pure file-organization work, no
// behavior/interface change. This file now holds only what every domain
// shares: the type declaration, its two stored properties, and the low-level
// request/decode/error-reporting plumbing every domain extension calls into.
// The shared helpers below dropped their `private` access (Swift's `private`
// only extends to same-file extensions) in favor of plain internal access,
// which is what makes them callable from the domain extension files -- still
// invisible outside this app target, so this is not a behavior change from
// the app's perspective.
//
// Domain files: NetworkService+Auth.swift (auth/2FA/password-reset/user/
// device-token), NetworkService+Notes.swift, NetworkService+Highlights.swift
// (highlights+bookmarks), NetworkService+Agents.swift,
// NetworkService+Contacts.swift (contacts/friends/reports+blocks),
// NetworkService+Messaging.swift (friend+group message fetch/groups/
// sessions+devotions/Chime calls), NetworkService+Attachments.swift,
// NetworkService+Subscriptions.swift, NetworkService+RawModels.swift (the
// private Decodable "wire shape" structs shared by more than one domain
// file -- kept internal, not private, for the same cross-file-access reason
// as the helpers above).

import Foundation

final class NetworkService: DataServiceProtocol {
    static let shared = NetworkService()
    private init() {}

    let apiBase = "https://fellowscript.com/api"
    let wsBase  = "wss://fellowscript.com/api"

    // Hoisted, shared instances instead of a fresh JSONEncoder()/JSONDecoder()
    // per call (readability/optimization sweep #6) — this is the app's single
    // busiest service, so every request/response previously paid an avoidable
    // allocation. Mirrors DiskCache.swift's existing hoisted-instance pattern
    // for the same two types. Both types are documented thread-safe for
    // concurrent encode/decode calls, and this service already shares a single
    // `NetworkService.shared` instance across the whole app.
    private let sharedEncoder = JSONEncoder()
    private let sharedDecoder = JSONDecoder()

    // ── Helpers ───────────────────────────────────────────────────────────────

    // Defensive bound on every request built by the four helpers below. Chosen
    // as half of URLSession's own 60s default (timeoutIntervalForRequest) --
    // generous enough not to false-positive on a slow-but-alive connection,
    // while making sure a stalled/black-holed connect phase (the one plausible
    // mechanism identified for the never-reproduced NetworkServiceGetErrorHandlingTests
    // hang -- see 20260828-networkservice-get-hang-investigation) can no longer
    // hang indefinitely. This is defensive hardening, not a confirmed-bug fix:
    // four real xcodebuild attempts (three prior + one full-suite re-attempt
    // during this task) never reproduced the hang.
    //
    // dependency-errors #10 (20260904-frontend-arch-sweep): still a fixed
    // constant (no build-config override) -- this hardcoded value is already
    // well-reasoned/documented, per that finding's own "low priority"
    // framing, so only the retry half is addressed here (see get() below).
    static let requestTimeout: TimeInterval = 30

    func url(_ path: String) -> URL {
        URL(string: apiBase + path)!
    }

    /// Bounded retry (dependency-errors #10, 20260904-frontend-arch-sweep):
    /// one retry, only for `get()` specifically (every other helper below is
    /// a write, and a write must never be silently retried -- retrying a
    /// non-idempotent POST/PUT/DELETE on a timeout risks double-applying it
    /// server-side), and only for the two failure classes a transient blip
    /// actually produces: a URLSession transport error, or a 5xx status
    /// (checked on the raw response, before throwIfError's own error
    /// mapping) -- never a 4xx, which a retry can't fix and would just
    /// repeat a real rejection.
    func get(_ path: String) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            var req = URLRequest(url: url(path))
            req.timeoutInterval = Self.requestTimeout
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if attempt == 1, let http = response as? HTTPURLResponse, (500...599).contains(http.statusCode) {
                    continue
                }
                // Validate status like request()/checkedRequestRaw() do — previously this
                // never called throwIfError, so every fetch* built on it silently turned
                // an HTTP error (e.g. a 401 from an expired session) into a blank default
                // value or empty collection instead of surfacing a thrown error. Fixed at
                // this single shared helper since it underlies nearly every domain's reads.
                try throwIfError(response, data)
                return data
            } catch let error where attempt == 1 && error is URLError {
                continue
            }
        }
    }

    func request(_ path: String, method: String, body: Encodable? = nil) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try sharedEncoder.encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        try throwIfError(response, data)
        return data
    }

    func requestRaw(_ path: String, method: String, jsonObject: Any) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    /// Like `requestRaw` but validates the HTTP status. Use for writes that must
    /// surface backend rejections (e.g. free-tier 403 limits) instead of silently
    /// swallowing them.
    func checkedRequestRaw(_ path: String, method: String, jsonObject: Any) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        let (data, response) = try await URLSession.shared.data(for: req)
        try throwIfError(response, data)
        return data
    }

    /// Maps an error response to a typed AppError. A 403 whose `detail` is the
    /// LimitsManager gate dict becomes `.limitReached`; anything else with a
    /// string detail becomes `.networkError`.
    private func throwIfError(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode >= 400 else { return }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if http.statusCode == 403, let gate = body?["detail"] as? [String: Any],
           let resource = gate["resource"] as? String {
            throw AppError.limitReached(
                resource: resource,
                used:  gate["used"]  as? Int ?? 0,
                limit: gate["limit"] as? Int ?? 0
            )
        }
        let detail = body?["detail"] as? String
        throw AppError.networkError(detail ?? "Server error \(http.statusCode)")
    }

    /// Decodes `data` as `T`. Callers keep their existing "nil on failure →
    /// fall back to an empty/default value" behavior (that part is
    /// unchanged and still intentional for these best-effort reads) — what
    /// changes is that a failure is no longer silently discarded. It's
    /// always logged, and when `endpoint` is given (the call sites that
    /// matter most for diagnosing a broken contract) it's also beaconed to
    /// the server via `reportDecodeFailure`.
    ///
    /// This replaces a blanket `try? JSONDecoder().decode(...)` that swallowed
    /// every decode failure with zero logging or user-facing signal anywhere
    /// in this file — which is exactly why the notes-load-failure incident
    /// this fix is part of (an out-of-date client build silently failing to
    /// decode the new `GET /notes/{user_id}` envelope) produced no error
    /// trail on the client side either. See notes-load-failure-cloudwatch-gap
    /// intake spec.
    func decode<T: Decodable>(_ type: T.Type, from data: Data, endpoint: String = "") -> T? {
        do {
            return try sharedDecoder.decode(type, from: data)
        } catch {
            let context = endpoint.isEmpty ? "\(T.self)" : endpoint
            print("[NetworkService] decode(\(T.self)) failed for \(context): \(error)")
            if !endpoint.isEmpty {
                reportDecodeFailure(endpoint: endpoint, summary: String(describing: error))
            }
            return nil
        }
    }

    /// Logs + beacons a thrown fetch failure (a non-2xx HTTP response or
    /// transport error surfaced by throwIfError()/URLSession) for a given
    /// endpoint, then rethrows so the caller's own fallback behavior (e.g. a
    /// `try? ... ?? .empty` degrade-to-cache pattern) is unchanged — this
    /// only makes the failure visible, it never changes control flow.
    ///
    /// Complements decode(endpoint:) above: that one covers a 200 response
    /// this client can't parse; this one covers the response never getting
    /// that far at all (e.g. a 404/500). Both were silent before — a fetch
    /// failure caught by a bare `try?` at the call site (as
    /// DashboardViewModel.load() does for fetchFriendActivity) previously
    /// vanished with zero signal, exactly the gap that let a stale-deploy
    /// 404 on GET /friends/{user_id}/activity hide the check-in row with no
    /// error trail anywhere. See 20260827-checkin-row-investigation.
    func reportFetchFailure<T>(endpoint: String, operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            print("[NetworkService] fetch failed for \(endpoint): \(error)")
            reportDecodeFailure(endpoint: endpoint, summary: String(describing: error))
            throw error
        }
    }

    /// "\(short) (\(build))", e.g. "1.4.2 (37)" — matches
    /// `ClientErrorReport.client_app_version`'s documented format, the key
    /// signal for distinguishing an out-of-date client build from a genuine
    /// current-code bug when triaging a reported detection.
    private func currentAppVersion() -> String {
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Fire-and-forget beacon to `POST /monitoring/client-error` (backend
    /// step 1 of the notes-load-failure-cloudwatch-gap workflow) — the
    /// server-log-based CloudWatch watchdog can never see a well-formed 200
    /// response an out-of-date client fails to decode on its own, so this is
    /// the only way that class of failure becomes visible at all. Diagnostics
    /// only: deliberately best-effort (`try?`) so a beacon failure (e.g. no
    /// network) never surfaces to or blocks the caller that hit the original
    /// decode failure. Never sends the raw response body — only the
    /// endpoint, app version, and a short error summary, per
    /// `ClientErrorReport`'s data-minimization contract.
    func reportDecodeFailure(endpoint: String, summary: String) {
        let version = currentAppVersion()
        Task {
            _ = try? await requestRaw("/monitoring/client-error", method: "POST", jsonObject: [
                "endpoint": endpoint,
                "client_app_version": version,
                "error_summary": String(summary.prefix(500)),
            ])
        }
    }

    /// FastAPI's `detail` is a plain string for our own `HTTPException(...)` raises,
    /// but a pydantic field_validator rejection (e.g. SignUp's terms_accepted check)
    /// surfaces as the framework's default array shape:
    /// `{"detail": [{"loc": [...], "msg": "...", "type": "..."}]}`. Handle both so
    /// the user sees the real message either way, not a generic fallback.
    func extractErrorDetail(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let s = obj["detail"] as? String { return s }
        if let arr = obj["detail"] as? [[String: Any]], let msg = arr.first?["msg"] as? String { return msg }
        return nil
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    func encodeURIComponent(_ s: String) -> String {
        // .urlQueryAllowed treats '+' as a legal sub-delim character per raw URI
        // syntax and leaves it unescaped. But query strings are decoded using
        // application/x-www-form-urlencoded conventions (by FastAPI/Starlette and
        // virtually every other web framework), where an unescaped '+' means
        // "space", not a literal plus sign. Any value that can contain a literal
        // '+' — e.g. an ISO-8601 timestamp with a UTC offset like "+00:00", as
        // used by the notes-pagination cursor — must have it escaped as "%2B" or
        // it gets silently corrupted into a space server-side. Remove '+' from
        // the allowed set so addingPercentEncoding always escapes it.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try sharedEncoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}
