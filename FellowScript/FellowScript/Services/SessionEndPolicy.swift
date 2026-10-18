// SessionEndPolicy.swift — task 20261017-chat-ws-reconnect-stuck (step 3).
//
// Pure decision logic for "the server ended this user's session", shared by
// the chat sockets (ChatSocketOwner, AgentChatViewModel) and NetworkService's
// global 401 path. Kept free of UIKit/URLSession state so it is unit-testable
// as plain functions.
//
// Why: an expired session cookie makes the websocket handshake come back
// 401/403 and every REST call 401, but the sockets used to treat that like a
// network blip and retried forever behind a "Reconnecting…" pill.

import Foundation

extension Notification.Name {
    /// Posted (any thread) by NetworkService when an authenticated request got
    /// a 401. AppState observes it, de-duplicates, and flips `sessionEnded`.
    static let sessionEndedByServer = Notification.Name("sessionEndedByServer")
}

enum SocketFailureKind: Equatable {
    /// The handshake was rejected because the session is not valid.
    case authRejected
    /// Anything else (offline, timeout, 5xx, no HTTP response): keep backing off.
    case transient
}

enum ReconnectDecision: Equatable {
    /// Intentional close (backgrounding / teardown): do nothing.
    case ignore
    /// Auth rejection: stop the loop, surface "session ended", do not retry silently.
    case stopSessionEnded
    /// Transient failure: reconnect after this many seconds (capped).
    case retry(after: TimeInterval)
}

enum SessionEndPolicy {
    static let maxBackoffSeconds: TimeInterval = 30

    /// Handshake HTTP status of the failed URLSessionWebSocketTask (nil when no
    /// HTTP response was received). 401 and 403 mean the session is not valid.
    static func classifyHandshake(status: Int?) -> SocketFailureKind {
        guard let status else { return .transient }
        return (status == 401 || status == 403) ? .authRejected : .transient
    }

    /// 1s, 2s, 4s, ... capped at 30s. `attempt` is 1 for the first retry.
    static func backoffDelay(attempt: Int) -> TimeInterval {
        let n = max(attempt, 1)
        return min(pow(2.0, Double(min(n - 1, 10))), maxBackoffSeconds)
    }

    /// What a socket should do after a receive failure.
    static func decide(handshakeStatus: Int?, isDisconnecting: Bool, nextAttempt: Int) -> ReconnectDecision {
        if isDisconnecting { return .ignore }
        switch classifyHandshake(status: handshakeStatus) {
        case .authRejected: return .stopSessionEnded
        case .transient:    return .retry(after: backoffDelay(attempt: nextAttempt))
        }
    }

    // ── Global 401 path ──────────────────────────────────────────────────────

    /// Endpoints legitimately called without a session (login family, public
    /// previews, capabilities before sign-in, logout). A 401 here is the
    /// endpoint's own answer, not "your session ended". Matched on the request
    /// path with the "/api" mount prefix removed.
    static func isUnauthenticatedPath(_ rawPath: String) -> Bool {
        var path = rawPath
        if path.hasPrefix("/api/") { path.removeFirst(4) }
        let exact: Set<String> = [
            "/login", "/signup", "/logout", "/auth/google", "/auth/apple",
            "/auth/mfa/verify-login", "/app/capabilities", "/invites/preview",
            // Signed-in user, but a wrong password answers 401 (not a session failure).
            "/auth/mfa/disable",
        ]
        if exact.contains(path) { return true }
        return path.hasPrefix("/auth/password-reset") || path.hasPrefix("/explorer/listings/")
    }

    /// True when a response with this status for this request path means the
    /// signed-in user's session has ended.
    static func shouldMarkSessionEnded(status: Int, path: String?) -> Bool {
        guard status == 401 else { return false }
        if let path, isUnauthenticatedPath(path) { return false }
        return true
    }
}

/// Idempotent "session ended" latch: the first `mark()` returns true, later
/// ones false until `reset()`. AppState uses it so a burst of 401s from
/// parallel requests is handled once.
struct SessionEndLatch {
    private(set) var isEnded = false
    mutating func mark() -> Bool {
        if isEnded { return false }
        isEnded = true
        return true
    }
    mutating func reset() { isEnded = false }
}
