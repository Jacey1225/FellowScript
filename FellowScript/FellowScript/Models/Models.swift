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
    }
}

// ── Note ──────────────────────────────────────────────────────────────────────
struct FSNote: Codable, Identifiable {
    var id:        String  = UUID().uuidString
    var user:      String  = ""
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
enum ContactType { case friend, group }

struct FSContact: Identifiable {
    let id:      String
    let name:    String
    let type:    ContactType
    var preview: String = ""
    var toUsers: [String] = []
}

struct FSMessage: Identifiable {
    let id:        String
    let text:      String
    let mine:      Bool
    let sender:    String
    let timestamp: String

    var formattedTime: String {
        guard !timestamp.isEmpty else { return "" }
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = df.date(from: timestamp) {
            let f = DateFormatter()
            f.timeStyle = .short
            return f.string(from: d)
        }
        return ""
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
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = df.date(from: time_start) {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: d)
        }
        return time_start
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

struct FSAgentMessage: Identifiable {
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

// ── Notification ──────────────────────────────────────────────────────────────
struct FSNotification: Codable, Identifiable {
    var id:         String    = UUID().uuidString
    var user_id:    String    = ""
    var name:       String    = ""
    var prompt:     String    = ""
    var timestamps: [String?] = Array(repeating: nil, count: 31)

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case user_id, name, prompt, timestamps
    }

    init(id: String = UUID().uuidString, user_id: String = "", name: String = "",
         prompt: String = "", timestamps: [String?] = Array(repeating: nil, count: 31)) {
        self.id = id; self.user_id = user_id; self.name = name
        self.prompt = prompt; self.timestamps = timestamps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = (try? c.decode(String.self,    forKey: .id))         ?? UUID().uuidString
        user_id    = (try? c.decode(String.self,    forKey: .user_id))    ?? ""
        name       = (try? c.decode(String.self,    forKey: .name))       ?? ""
        prompt     = (try? c.decode(String.self,    forKey: .prompt))     ?? ""
        var ts     = (try? c.decode([String?].self, forKey: .timestamps)) ?? []
        while ts.count < 31 { ts.append(nil) }
        timestamps = ts
    }
}

extension FSNotification {
    var activeCount: Int { timestamps.filter { $0 != nil }.count }

    var recurrenceSummary: String {
        let count = activeCount
        if count == 0  { return "Not scheduled" }
        if count >= 31 { return "Daily" }
        return "\(count) day\(count == 1 ? "" : "s") / month"
    }

    var scheduledTime: String? {
        guard let raw = timestamps.compactMap({ $0 }).first else { return nil }
        let utcFmt = DateFormatter()
        utcFmt.dateFormat = "HH:mm"
        utcFmt.timeZone = TimeZone(identifier: "UTC")
        guard let date = utcFmt.date(from: raw) else { return raw }
        let display = DateFormatter()
        display.timeStyle = .short
        return display.string(from: date)
    }
}

// ── Group ─────────────────────────────────────────────────────────────────────
struct FSGroup: Codable, Identifiable {
    var id:    String = UUID().uuidString
    var title: String = ""
    var users: [String] = []
}
