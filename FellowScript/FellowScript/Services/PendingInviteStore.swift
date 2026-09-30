// PendingInviteStore.swift — the invite token a user arrived with, kept across
// sign-in / sign-up / email verification / cold launch (task
// 20260929-group-invite-links, design-notes.md C). The token is a bearer
// secret, so it lives in the Keychain (this-device-only, available when
// unlocked), never UserDefaults. Expires after 24h. Consumed exactly once by
// AppState: cleared on redeem success, terminal 4xx, Cancel, and sign-out.

import Foundation
import Security

/// Parsing/validation of invite links. Strict on purpose: only the exact
/// FellowScript shapes produce a token, and the token itself must be the
/// 43-char url-safe form the backend mints.
enum InviteLink {
    static let host = "fellowscript.com"
    static let customScheme = "com.fellowscript.app"

    static func isWellFormed(_ token: String) -> Bool {
        guard token.utf8.count == 43 else { return false }
        return token.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F
        }
    }

    /// https://fellowscript.com/join/<token> (Universal Link) or
    /// com.fellowscript.app://join/<token> (custom scheme). Anything else nil.
    static func token(from url: URL) -> String? {
        let scheme = url.scheme?.lowercased()
        let comps = url.pathComponents.filter { $0 != "/" }
        if scheme == "https" {
            guard let h = url.host?.lowercased(), h == host || h == "www.\(host)",
                  comps.count == 2, comps[0] == "join", isWellFormed(comps[1]) else { return nil }
            return comps[1]
        }
        if scheme == customScheme {
            guard url.host?.lowercased() == "join", comps.count == 1, isWellFormed(comps[0]) else { return nil }
            return comps[0]
        }
        return nil
    }
}

enum PendingInviteStore {
    static let ttl: TimeInterval = 24 * 60 * 60
    private static let service = "com.fellowscript.app.pending-invite"
    private static let account = "token"

    private struct Stored: Codable { let token: String; let at: TimeInterval }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Replaces any existing pending invite. Returns false if the Keychain
    /// write failed (the caller still holds the token in memory this session).
    @discardableResult
    static func save(_ token: String, now: Date = Date()) -> Bool {
        guard InviteLink.isWellFormed(token),
              let data = try? JSONEncoder().encode(Stored(token: token, at: now.timeIntervalSince1970)) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// The stored token, or nil when none / expired / unreadable (an expired
    /// or corrupt entry is deleted).
    static func load(now: Date = Date()) -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              InviteLink.isWellFormed(stored.token),
              now.timeIntervalSince1970 - stored.at <= ttl else {
            clear()
            return nil
        }
        return stored.token
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
