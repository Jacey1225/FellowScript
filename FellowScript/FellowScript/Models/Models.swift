// Core data models — mirror the JSON shapes used by the FellowScript backend API.
// All Codable so they decode directly from API responses.

import Foundation

// ── User ──────────────────────────────────────────────────────────────────────
struct FSUser: Codable, Identifiable {
    let user_id:  String
    let username: String
    let email:    String
    var friends:     [String]          = []
    var groups:      [String]          = []
    var notes:       [String: FSNote]  = [:]
    var highlights:  [String: String]  = [:]
    var timezone:    String            = "UTC"
    // True when this account predates a material Terms of Service change
    // (e.g. the Guideline 1.2 zero-tolerance rewrite) and must re-accept
    // before continuing — set only by login/signup responses, never sent.
    var terms_reaccept_required: Bool  = false
    // Email-code 2FA toggle state (see AccountView's Two-Factor
    // Authentication section) — reflects the account's current setting.
    var mfa_enabled: Bool = false
    // True when an Apple sign-in created this account without a real name/email
    // (Apple only ever supplies them on the very first authorization for a given
    // Apple ID + app — a missed grant can never be recovered from Apple again).
    // The client should prompt the user to set both manually.
    var needs_profile_completion: Bool = false

    var id: String { user_id }
    var initials: String { String(username.prefix(1)).uppercased() }
}

// Moved to extension so Swift still synthesizes the memberwise initializer
// (custom inits in the struct body suppress it).
// Only user_id/username/email are required; all other fields fall back to
// defaults when absent from the server response (login/signup omit notes).
extension FSUser {
    init(from decoder: Decoder) throws {
        let c       = try decoder.container(keyedBy: CodingKeys.self)
        user_id     = try c.decode(String.self, forKey: .user_id)
        username    = try c.decode(String.self, forKey: .username)
        email       = try c.decode(String.self, forKey: .email)
        friends     = (try? c.decode([String].self,         forKey: .friends))    ?? []
        groups      = (try? c.decode([String].self,         forKey: .groups))     ?? []
        notes       = (try? c.decode([String: FSNote].self, forKey: .notes))      ?? [:]
        highlights  = (try? c.decode([String: String].self, forKey: .highlights)) ?? [:]
        timezone    = (try? c.decode(String.self, forKey: .timezone)) ?? "UTC"
        terms_reaccept_required = (try? c.decode(Bool.self, forKey: .terms_reaccept_required)) ?? false
        mfa_enabled = (try? c.decode(Bool.self, forKey: .mfa_enabled)) ?? false
        needs_profile_completion = (try? c.decode(Bool.self, forKey: .needs_profile_completion)) ?? false
    }
}

// ── Blocked user (Guideline 1.2) ──────────────────────────────────────────────
struct FSBlockedUser: Codable, Identifiable {
    let user_id:  String
    var username: String = ""
    var id: String { user_id }
}

// ── Subscription ────────────────────────────────────────────────────────────
// Mirrors api/schemas/subscription.py. Only the fields the UI needs are decoded;
// every field is defensive (try? … ?? default) so a partial server row still loads.
struct FSSubscription: Codable, Identifiable {
    var id:           String = ""
    var user_id:      String = ""    // the host who owns the plan
    var plan_type:    String = "free"         // "free" | "group"
    var provider:     String = ""    // "stripe" | "apple"
    var status:       String = "inactive"
    var price_cents:  Int    = 0
    var max_members:  Int    = 1
    var card_brand:   String = ""
    var card_last4:   String = ""
    var is_trial:     Bool   = false
    var trial_days_remaining: Int = 0
    var next_billing_date: String = ""   // ISO-ish "2026-08-15 19:42:23+00:00"

    enum CodingKeys: String, CodingKey {
        case id, user_id, plan_type, provider, status, price_cents, max_members
        case card_brand, card_last4, is_trial, trial_days_remaining, next_billing_date
    }

    init(id: String = "", user_id: String = "", plan_type: String = "free",
         status: String = "inactive", price_cents: Int = 0, max_members: Int = 1) {
        self.id = id; self.user_id = user_id; self.plan_type = plan_type
        self.status = status; self.price_cents = price_cents; self.max_members = max_members
    }

    init(from decoder: Decoder) throws {
        let c        = try decoder.container(keyedBy: CodingKeys.self)
        id           = (try? c.decode(String.self, forKey: .id))          ?? ""
        user_id      = (try? c.decode(String.self, forKey: .user_id))     ?? ""
        plan_type    = (try? c.decode(String.self, forKey: .plan_type))   ?? "free"
        provider     = (try? c.decode(String.self, forKey: .provider))    ?? ""
        status       = (try? c.decode(String.self, forKey: .status))      ?? "inactive"
        price_cents  = (try? c.decode(Int.self,    forKey: .price_cents)) ?? 0
        max_members  = (try? c.decode(Int.self,    forKey: .max_members)) ?? 1
        card_brand   = (try? c.decode(String.self, forKey: .card_brand))  ?? ""
        card_last4   = (try? c.decode(String.self, forKey: .card_last4))  ?? ""
        is_trial     = (try? c.decode(Bool.self,   forKey: .is_trial))    ?? false
        trial_days_remaining = (try? c.decode(Int.self, forKey: .trial_days_remaining)) ?? 0
        next_billing_date    = (try? c.decode(String.self, forKey: .next_billing_date)) ?? ""
    }

    var priceLabel: String { "$\(price_cents / 100)" }
    func isHost(_ userId: String) -> Bool { user_id == userId }

    // "2026-08-15 19:42:23+00:00" → "Aug 15, 2026"
    var nextBillingLabel: String {
        guard !next_billing_date.isEmpty else { return "" }
        let iso = next_billing_date.replacingOccurrences(of: " ", with: "T")
        let parsers: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
        ]
        for opts in parsers {
            let f = ISO8601DateFormatter(); f.formatOptions = opts
            if let d = f.date(from: iso) {
                let out = DateFormatter(); out.dateStyle = .medium
                return out.string(from: d)
            }
        }
        return ""
    }
}

// ── Free-tier usage ────────────────────────────────────────────────────────────
// Mirrors GET /subscriptions/user/{id}/usage (api/backend/subscription/limits.py).
// Free users are capped; subscribed users report `unlimited`.

struct FSUsageResource: Codable {
    var unlimited: Bool = false
    var used:      Int  = 0
    var limit:     Int  = 0
    var remaining: Int? = nil   // null when unlimited

    // Progress 0…1 for a meter (0 when unlimited or no limit).
    var fraction: Double {
        guard !unlimited, limit > 0 else { return 0 }
        return min(1, Double(used) / Double(limit))
    }
    var maxedOut: Bool { !unlimited && used >= limit }
}

struct FSUsage: Codable {
    var subscribed:  Bool   = false
    var plan_type:   String = "free"
    var window_days: Int    = 7
    var resources:   [String: FSUsageResource] = [:]

    var notes:              FSUsageResource { resources["notes"] ?? FSUsageResource() }
    var agentEvents:        FSUsageResource { resources["agent_events"] ?? FSUsageResource() }
}

// Billing details collected at checkout. Only NON-SENSITIVE fields are sent to
// the server — the full card number and CVC never leave the device.
struct FSBillingInfo {
    var brand: String
    var last4: String
    var expMonth: String
    var expYear: String
}

// A member of a group plan (host included).
struct FSSubMember: Codable, Identifiable {
    let user_id:  String
    var username: String = ""
    var email:    String = ""
    var id: String { user_id }
}

// An outstanding join request this user has sent to a group plan.
struct FSSubRequest: Codable, Identifiable {
    let subscription_id: String
    var plan_type: String = "group"
    var host_id:   String = ""
    var id: String { subscription_id }
}

// ── Note ──────────────────────────────────────────────────────────────────────
struct FSNote: Codable, Identifiable {
    var id:        String  = UUID().uuidString
    var user:      String  = ""
    // Author's display-ready username, stamped on by fetchGroupNotes from the
    // outer "notes: { username: { note_id: {...} } }" response key (the
    // decoded note payload itself carries only user_id, which becomes `user`
    // above). Defaults to "" so Personal notes, MockDataService, and any
    // other FSNote call site that doesn't populate it are unaffected — NoteRow
    // treats an empty username as "no author to show," never a placeholder.
    var username:  String  = ""
    var title:     String  = ""
    var text:      String  = ""
    var `public`:  Bool    = false
    var group_id:  String  = ""
    var is_reply:  Bool    = false
    var timestamp: String  = ""
    var verses:    [[FSVerseComponent]] = []
    var replies:   [FSNote] = []

    var preview: String {
        let stripped = text
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(stripped.prefix(120))
    }

    var formattedTimestamp: String {
        guard !timestamp.isEmpty else { return "" }
        // Try ISO8601 with fractional seconds first (FastAPI serializes datetime as ISO 8601)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: timestamp) {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
            return f.string(from: d)
        }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: timestamp) {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
            return f.string(from: d)
        }
        // Fallback for plain date strings
        let df = DateFormatter()
        for fmt in ["yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: timestamp) {
                df.dateStyle = .medium; df.timeStyle = .none
                return df.string(from: d)
            }
        }
        return ""
    }
}

// Backend returns notes as {uuid: {user, title, ...}} — the `id` field is the dict key,
// not present in the value. decodeIfPresent so the dict decode doesn't throw keyNotFound.
extension FSNote {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = (try? c.decode(String.self,               forKey: .id))        ?? UUID().uuidString
        user      = (try? c.decode(String.self,               forKey: .user))      ?? ""
        username  = (try? c.decode(String.self,               forKey: .username))  ?? ""
        title     = (try? c.decode(String.self,               forKey: .title))     ?? ""
        text      = (try? c.decode(String.self,               forKey: .text))      ?? ""
        `public`  = (try? c.decode(Bool.self,                 forKey: .public))    ?? false
        group_id  = (try? c.decode(String.self,               forKey: .group_id))  ?? ""
        is_reply  = (try? c.decode(Bool.self,                 forKey: .is_reply))  ?? false
        timestamp = (try? c.decode(String.self,               forKey: .timestamp)) ?? ""
        verses    = (try? c.decode([[FSVerseComponent]].self, forKey: .verses))    ?? []
        replies   = (try? c.decode([FSNote].self,             forKey: .replies))   ?? []
    }
}

enum FSVerseComponent: Codable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let i = try? c.decode(Int.self)    { self = .int(i);    return }
        throw DecodingError.typeMismatch(FSVerseComponent.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected String or Int"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i):    try c.encode(i)
        }
    }

    var asString: String {
        switch self { case .string(let s): return s; case .int(let i): return "\(i)" }
    }
    var asInt: Int? {
        switch self { case .int(let i): return i; case .string(let s): return Int(s) }
    }
}

struct VerseRef {
    let book:    String
    let chapter: Int
    let verse:   Int
    var label: String { "\(book) \(chapter):\(verse)" }
}

// ── Highlight ─────────────────────────────────────────────────────────────────
struct FSHighlight: Identifiable {
    let id:      String
    let book:    String
    let chapter: Int
    let verse:   Int
    let color:   String
    let username: String?

    static func from(key: String, color: String, username: String? = nil) -> FSHighlight {
        let parts = key.components(separatedBy: "-")
        guard parts.count >= 3,
              let ch = Int(parts[parts.count - 2]),
              let vs = Int(parts[parts.count - 1])
        else {
            return FSHighlight(id: key, book: key, chapter: 0, verse: 0, color: color, username: username)
        }
        let book = parts.dropLast(2).joined(separator: "-")
        return FSHighlight(id: key, book: book, chapter: ch, verse: vs, color: color, username: username)
    }
}

// ── Bookmark ──────────────────────────────────────────────────────────────────
struct FSBookmark: Identifiable {
    let id:      String
    let book:    String
    let chapter: Int
    let label:   String

    static func from(key: String, label: String) -> FSBookmark {
        let parts = key.components(separatedBy: "-")
        let chapter = parts.last.flatMap(Int.init) ?? 0
        let book    = parts.dropLast().joined(separator: "-")
        return FSBookmark(id: key, book: book, chapter: chapter, label: label)
    }
}

// ── Chat / Messaging ──────────────────────────────────────────────────────────
enum ContactType: String, Codable { case friend, group }

struct FSContact: Identifiable, Codable, Equatable {
    let id:      String
    let name:    String
    let type:    ContactType
    var preview: String = ""
    var toUsers: [String] = []      // member user IDs — used for message routing
    var memberNames: [String] = []  // member usernames (excludes self) — for display
    var lastMessageAt: String = ""  // ISO timestamp of the most recent message (for sorting)
}

// ── Friend activity feed (Dashboard's Friend Activity hero card) ───────────────
// SOURCE: GET /friends/{user_id}/activity (FriendsManager.get_friend_activity).
// Friend-only, block-respecting in both directions. `note_preview` is only ever
// a friend's public, non-reply, non-group personal note — highlights never
// surface content here (no privacy flag exists for them yet), though a
// highlight still counts toward `last_active_at`.
struct FSFriendNotePreview: Codable, Equatable {
    let note_id:   String
    let title:     String
    let text:      String
    let timestamp: String
}

struct FSFriendActivityEntry: Codable, Identifiable, Equatable {
    var id: String { friend_id }
    let friend_id:      String
    let username:       String
    let last_active_at: String?
    let note_preview:   FSFriendNotePreview?

    var initial: String { String(username.prefix(1)).uppercased() }
}

struct FSCheckInCandidate: Codable, Equatable {
    let friend_id:          String
    let username:           String
    let days_since_contact: Int?
}

struct FSFriendActivityFeed: Codable, Equatable {
    let friends_active: [FSFriendActivityEntry]
    let check_in:       FSCheckInCandidate?

    static let empty = FSFriendActivityFeed(friends_active: [], check_in: nil)
}

/// Parses an ISO8601 timestamp string, tolerating both forms actually
/// produced app-wide: the server's fractional-seconds format and the
/// client's own stamp (no fractional seconds, e.g.
/// `ChatThreadViewModel.sendMessage`'s `ISO8601DateFormatter().string(from:)`).
/// Mirrors `MessageDisplayGroup.parseTimestamp` (MessageGroupRow.swift),
/// which already needed this same dual-format retry for day-boundary
/// detection on this same `FSMessage.timestamp` field — `FSSession.formattedStart`
/// and `FSMessage.formattedTime` had the identical single-format-only gap
/// (fidelity-pass audit) and are fixed here to share one implementation
/// instead of each re-deriving it.
///
/// Testing bounce 1: both `ISO8601DateFormatter` variants above set
/// `.withInternetDateTime`, which internally implies `.withTimeZone` — so a
/// timezone-less string (no trailing `Z`/offset at all, e.g.
/// `MockDataService.mockSession.time_start == "2026-07-02T19:00:00"`) fails
/// both and used to fall through to the raw-string fallback. That's a
/// distinct case from "missing fractional seconds but still has a
/// timezone" — add an explicit `DateFormatter` fallback for the bare
/// `yyyy-MM-dd'T'HH:mm:ss` shape, assuming the current calendar's time zone
/// since the string carries none.
func parseFlexibleISO8601(_ iso: String) -> Date? {
    guard !iso.isEmpty else { return nil }
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: iso) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: iso) { return date }
    let noTimeZone = DateFormatter()
    noTimeZone.locale = Locale(identifier: "en_US_POSIX")
    noTimeZone.timeZone = TimeZone.current
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
        noTimeZone.dateFormat = fmt
        if let date = noTimeZone.date(from: iso) { return date }
    }
    return nil
}

struct FSMessage: Identifiable, Codable {
    let id:        String
    let text:      String
    let mine:      Bool
    let sender:    String
    let timestamp: String

    var formattedTime: String {
        // Fidelity-pass audit: same single-format gap as FSSession.formattedStart
        // had — without the dual-format retry, a client-sent message (no
        // fractional seconds) fails to parse and silently renders no time at all.
        guard let d = parseFlexibleISO8601(timestamp) else { return "" }
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: d)
    }
}

// ── Study Sessions ────────────────────────────────────────────────────────────
struct FSSession: Codable, Identifiable {
    var id:           String   = UUID().uuidString
    var title:        String   = ""
    var time_start:   String   = ""
    var time_end:     String   = ""
    var verses:       [String] = []
    var prompts:      [String] = []
    var recurring:    Bool     = false
    var summarize:    Bool     = false
    var group_id:     String   = ""
    var creator_id:   String   = ""
    var participants: [String] = []

    var formattedStart: String {
        guard !time_start.isEmpty else { return "" }
        // Fidelity-pass fix: this only handled the fractional-seconds ISO8601
        // form, so any timestamp lacking fractional seconds fell through to
        // the raw-string fallback below (visible as e.g. "2026-07-02T19:00:00"
        // in the SessionBanner instead of "Today · 8:00 PM"). Retry without
        // fractional seconds before giving up, mirroring
        // MessageDisplayGroup.parseTimestamp's existing dual-format retry.
        if let d = parseFlexibleISO8601(time_start) {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: d)
        }
        return time_start
    }
}

// Resilient decoding: the server omits some fields (e.g. `summarize`) and returns
// null for others (e.g. `time_end`). The synthesized Codable init throws on a
// missing key or a null → non-optional mismatch, which would drop the WHOLE
// session list. decodeIfPresent falls back to the property defaults instead.
extension FSSession {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = (try? c.decode(String.self,   forKey: .id))           ?? UUID().uuidString
        title        = (try? c.decode(String.self,   forKey: .title))         ?? ""
        time_start   = (try? c.decode(String.self,   forKey: .time_start))    ?? ""
        time_end     = (try? c.decode(String.self,   forKey: .time_end))      ?? ""
        verses       = (try? c.decode([String].self, forKey: .verses))        ?? []
        prompts      = (try? c.decode([String].self, forKey: .prompts))       ?? []
        recurring    = (try? c.decode(Bool.self,     forKey: .recurring))     ?? false
        summarize    = (try? c.decode(Bool.self,     forKey: .summarize))     ?? false
        group_id     = (try? c.decode(String.self,   forKey: .group_id))      ?? ""
        creator_id   = (try? c.decode(String.self,   forKey: .creator_id))    ?? ""
        participants = (try? c.decode([String].self, forKey: .participants))  ?? []
    }
}

// ── AI Agents ─────────────────────────────────────────────────────────────────
struct FSAgent: Codable, Identifiable {
    var id:      String = UUID().uuidString
    var user_id: String = ""
    var name:    String = ""
    var role:    String = ""
    var enabled: Bool   = true
    var chats:   [String] = []

    var displayLabel: String {
        if !name.isEmpty { return name }
        if role.isEmpty || role.hasPrefix("You are a spiritual") { return "Spiritual Guide" }
        return String(role.components(separatedBy: "\n").first(where: { !$0.isEmpty })?.prefix(28) ?? "Agent")
    }
}

// Same pattern: backend returns {uuid: {user_id, role, ...}} — id is the dict key.
extension FSAgent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id      = (try? c.decode(String.self,   forKey: .id))      ?? UUID().uuidString
        user_id = (try? c.decode(String.self,   forKey: .user_id)) ?? ""
        name    = (try? c.decode(String.self,   forKey: .name))    ?? ""
        role    = (try? c.decode(String.self,   forKey: .role))    ?? ""
        enabled = (try? c.decode(Bool.self,     forKey: .enabled)) ?? true
        chats   = (try? c.decode([String].self, forKey: .chats))   ?? []
    }
}

struct FSAgentMessage: Identifiable, Codable {
    let id:        String
    let text:      String
    let mine:      Bool
    let timestamp: String

    var formattedTime: String {
        guard !timestamp.isEmpty else { return "" }
        if timestamp.contains("T") {
            let df = ISO8601DateFormatter()
            df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = df.date(from: timestamp) {
                let f = DateFormatter(); f.timeStyle = .short
                return f.string(from: d)
            }
            df.formatOptions = [.withInternetDateTime]
            if let d = df.date(from: timestamp) {
                let f = DateFormatter(); f.timeStyle = .short
                return f.string(from: d)
            }
        }
        return String(timestamp.suffix(8).prefix(5))
    }
}

struct FSHeartbeat: Codable, Identifiable {
    var id:         String    = UUID().uuidString
    var agent_id:   String    = ""
    var user_id:    String    = ""
    var timestamps: [String?] = Array(repeating: nil, count: 31)
    var prompt:     String    = ""

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case agent_id, user_id, timestamps, prompt
    }
}

extension FSHeartbeat {
    var activeCount: Int { timestamps.compactMap { $0 }.count }

    var scheduleSummary: String {
        let n = activeCount
        if n == 0  { return "Not scheduled" }
        if n >= 30 { return "Every day" }
        return "\(n) day\(n == 1 ? "" : "s") / month"
    }

    func nextFireDate() -> Date? {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        fmt.timeZone = TimeZone(identifier: "UTC")   // timestamps stored as UTC "HH:mm"
        let cal = Calendar.current; let now = Date()
        for offset in 0..<62 {
            guard let target = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            let day = cal.component(.day, from: target)
            let idx = day - 1
            guard idx < timestamps.count,
                  let timeStr = timestamps[idx], !timeStr.isEmpty,
                  let seed = fmt.date(from: timeStr) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: target)
            comps.hour   = cal.component(.hour,   from: seed)
            comps.minute = cal.component(.minute, from: seed)
            comps.second = 0
            guard let fireDate = cal.date(from: comps), fireDate > now else { continue }
            return fireDate
        }
        return nil
    }
}

// ── Group ─────────────────────────────────────────────────────────────────────
struct FSGroup: Codable, Identifiable {
    var id:    String = UUID().uuidString
    var title: String = ""
    var users: [String] = []
}
