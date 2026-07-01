// Core data models — mirror the JSON shapes used by the FellowScript backend API.
// All Codable so they decode directly from API responses.

import Foundation

// ── User ──────────────────────────────────────────────────────────────────────
struct FSUser: Codable, Identifiable {
    let user_id:  String
    let username: String
    let email:    String
    var friends:  [String]  = []
    var groups:   [String]  = []
    var notes:    [String: FSNote]     = [:]
    var highlights: [String: String]   = [:]

    var id: String { user_id }
    var initials: String { String(username.prefix(1)).uppercased() }
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
        let fmts = ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"]
        let df = DateFormatter()
        for fmt in fmts {
            df.dateFormat = fmt
            if let d = df.date(from: timestamp) {
                df.dateStyle = .medium
                df.timeStyle = .none
                return df.string(from: d)
            }
        }
        return ""
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
        switch self { case .int(let i): return i; case .string: return nil }
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
    var id:         String = UUID().uuidString
    var title:      String = ""
    var time_start: String = ""
    var time_end:   String = ""
    var verses:     [String] = []
    var prompts:    [String] = []
    var recurring:  Bool = false
    var summarize:  Bool = false
    var group_id:   String = ""

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
    var role:    String = ""
    var enabled: Bool   = true
    var chats:   [String] = []

    var displayLabel: String {
        if role.isEmpty || role.hasPrefix("You are a spiritual") { return "Spiritual Guide" }
        return String(role.components(separatedBy: "\n").first(where: { !$0.isEmpty })?.prefix(28) ?? "Agent")
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
            if let d = df.date(from: timestamp) {
                let f = DateFormatter(); f.timeStyle = .short
                return f.string(from: d)
            }
        }
        return String(timestamp.suffix(8).prefix(5))
    }
}

struct FSHeartbeat: Codable, Identifiable {
    var id:           String   = UUID().uuidString
    var agent_id:     String   = ""
    var user_id:      String   = ""
    var timestamp:    String   = ""
    var days_per_week: [String] = []
    var prompt:       String   = ""

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case agent_id, user_id, timestamp, days_per_week, prompt
    }
}

// ── Group ─────────────────────────────────────────────────────────────────────
struct FSGroup: Codable, Identifiable {
    var id:    String = UUID().uuidString
    var title: String = ""
    var users: [String] = []
}
