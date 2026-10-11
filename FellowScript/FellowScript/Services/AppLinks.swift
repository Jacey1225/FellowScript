// AppLinks.swift — task 20261011-ios-share-notes-highlights.
//
// Strict, deny-by-default parser and builders for the share links that open the
// app (alongside the existing /join/<token> invite link in PendingInviteStore):
//
//   https://fellowscript.com/u/<username>                 friend request (confirm first)
//   https://fellowscript.com/v/<book-slug>/<chapter>/<verse>   open the Bible at a verse
//   https://fellowscript.com/g/<public_id>                request to join a published group
//
// plus the custom-scheme twins (com.fellowscript.app://u/<username>, .../v/..., .../g/...).
//
// Anything that is not exactly one of these shapes is ignored (nil). No link grants
// a capability: friend and group links only open a confirm screen. Nothing here logs
// the URL, the username or the public id.
//
// This file also holds the pure share-text builders (note / verse / announcement)
// so what a share exposes is one small, unit-tested allowlist.

import Foundation

enum AppLink: Equatable {
    case friend(username: String)
    case verse(book: String, chapter: Int, verse: Int)
    case group(publicId: String)

    // ── Validation primitives ────────────────────────────────────────────────

    /// ^[A-Za-z0-9_.-]{1,32}$ (the security-gate fallback for usernames; backend
    /// signup has no server-side rule). A name made only of dots is rejected so it
    /// can never act as a path dot-segment.
    static func isValidUsername(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (1...32).contains(u.count) else { return false }
        guard u.allSatisfy({ b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                || b == 0x5F || b == 0x2E || b == 0x2D
        }) else { return false }
        return !u.allSatisfy { $0 == 0x2E }
    }

    /// ^[0-9A-Za-z]{10}$, ASCII only (the Explorer listing public_id).
    static func isValidPublicId(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count == 10 else { return false }
        return u.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
    }

    /// Chapters per book (66-book canon). Doubles as the canonical book allowlist.
    static let chapterCounts: [String: Int] = [
        "Genesis": 50, "Exodus": 40, "Leviticus": 27, "Numbers": 36, "Deuteronomy": 34,
        "Joshua": 24, "Judges": 21, "Ruth": 4, "1 Samuel": 31, "2 Samuel": 24,
        "1 Kings": 22, "2 Kings": 25, "1 Chronicles": 29, "2 Chronicles": 36, "Ezra": 10,
        "Nehemiah": 13, "Esther": 10, "Job": 42, "Psalms": 150, "Proverbs": 31,
        "Ecclesiastes": 12, "Song of Solomon": 8, "Isaiah": 66, "Jeremiah": 52, "Lamentations": 5,
        "Ezekiel": 48, "Daniel": 12, "Hosea": 14, "Joel": 3, "Amos": 9, "Obadiah": 1, "Jonah": 4,
        "Micah": 7, "Nahum": 3, "Habakkuk": 3, "Zephaniah": 3, "Haggai": 2, "Zechariah": 14,
        "Malachi": 4, "Matthew": 28, "Mark": 16, "Luke": 24, "John": 21, "Acts": 28, "Romans": 16,
        "1 Corinthians": 16, "2 Corinthians": 13, "Galatians": 6, "Ephesians": 6, "Philippians": 4,
        "Colossians": 4, "1 Thessalonians": 5, "2 Thessalonians": 3, "1 Timothy": 6, "2 Timothy": 4,
        "Titus": 3, "Philemon": 1, "Hebrews": 13, "James": 5, "1 Peter": 5, "2 Peter": 3,
        "1 John": 5, "2 John": 1, "3 John": 1, "Jude": 1, "Revelation": 22,
    ]

    /// Highest verse number in any chapter (Psalm 119). A hard cap; the reader just
    /// doesn't scroll when a verse is past the end of a shorter chapter.
    static let maxVerse = 176

    /// "1 Samuel" -> "1-samuel" (matches the /v landing page's 66-slug table).
    static func slug(forBook book: String) -> String? {
        guard chapterCounts[book] != nil else { return nil }
        return book.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private static let bookForSlug: [String: String] = {
        var m: [String: String] = [:]
        for name in chapterCounts.keys { if let s = slug(forBook: name) { m[s] = name } }
        return m
    }()

    static func isValidVerse(book: String, chapter: Int, verse: Int) -> Bool {
        guard let chapters = chapterCounts[book] else { return false }
        return (1...chapters).contains(chapter) && (1...maxVerse).contains(verse)
    }

    // ── Parsing ──────────────────────────────────────────────────────────────

    /// The /u, /v and /g links only (a /join invite is InviteLink's job). nil for
    /// anything else.
    static func parse(_ url: URL) -> AppLink? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.user == nil, comps.password == nil, comps.port == nil,
              comps.query == nil, comps.fragment == nil,
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host?.lowercased() else { return nil }
        let rawPath = comps.percentEncodedPath
        // ASCII only, and no percent-encoding anywhere: every legal id/username/slug
        // is plain unreserved ASCII, so an encoded form can only be a trick.
        guard rawPath.utf8.allSatisfy({ $0 < 0x80 && $0 != 0x25 && $0 != 0x5C }) else { return nil }

        let kind: String
        var segments: [String]
        if scheme == "https" {
            guard host == InviteLink.host || host == "www.\(InviteLink.host)" else { return nil }
            var parts = rawPath.components(separatedBy: "/")
            guard parts.first == "" else { return nil }
            parts.removeFirst()
            if parts.last == "" { parts.removeLast() }          // one optional trailing slash
            guard let k = parts.first else { return nil }
            kind = k
            segments = Array(parts.dropFirst())
        } else if scheme == InviteLink.customScheme {
            kind = comps.host ?? ""                               // com.fellowscript.app://<kind>/... (exact case)
            var parts = rawPath.components(separatedBy: "/")
            if parts.first == "" { parts.removeFirst() }
            if parts.last == "" { parts.removeLast() }
            segments = parts
        } else {
            return nil
        }
        // An empty segment anywhere (a//b) is malformed.
        guard !segments.contains("") else { return nil }

        switch kind {
        case "u":
            guard segments.count == 1, isValidUsername(segments[0]) else { return nil }
            return .friend(username: segments[0])
        case "g":
            guard segments.count == 1, isValidPublicId(segments[0]) else { return nil }
            return .group(publicId: segments[0])
        case "v":
            guard segments.count == 3,
                  let book = bookForSlug[segments[0]],
                  let ch = canonicalInt(segments[1]), let vs = canonicalInt(segments[2]),
                  isValidVerse(book: book, chapter: ch, verse: vs) else { return nil }
            return .verse(book: book, chapter: ch, verse: vs)
        default:
            return nil
        }
    }

    /// 1-3 ASCII digits, no leading zero.
    private static func canonicalInt(_ s: String) -> Int? {
        let u = Array(s.utf8)
        guard (1...3).contains(u.count), u[0] != 0x30,
              u.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(s)
    }

    // ── Building ─────────────────────────────────────────────────────────────

    private static func httpsURL(_ path: String) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = InviteLink.host
        c.percentEncodedPath = path
        return c.url
    }

    static func friendURL(username: String) -> URL? {
        guard isValidUsername(username) else { return nil }
        return httpsURL("/u/\(username)")
    }

    static func verseURL(book: String, chapter: Int, verse: Int) -> URL? {
        guard isValidVerse(book: book, chapter: chapter, verse: verse), let s = slug(forBook: book) else { return nil }
        return httpsURL("/v/\(s)/\(chapter)/\(verse)")
    }

    static func groupURL(publicId: String) -> URL? {
        guard isValidPublicId(publicId) else { return nil }
        return httpsURL("/g/\(publicId)")
    }
}

// ── Share text builders (pure) ───────────────────────────────────────────────

/// What the share sheet is handed. Exactly one composed string, so the user sees
/// everything that will be sent before sending.
struct SharePayload: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

enum SharePayloads {

    /// Single line, no control / bidi / zero-width characters, no URL schemes (a hostile
    /// title cannot forge a second line or a second link), whitespace collapsed, capped.
    static func clean(_ raw: String, max: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            switch s.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                scalars.append(" ")
            default:
                scalars.append(s)
            }
        }
        var t = String(scalars)
        t = t.replacingOccurrences(of: #"(?i)[a-z][a-z0-9+.\-]*://"#, with: "", options: .regularExpression)
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if t.count > max { t = String(t.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" }
        return t
    }

    /// Note share: title + creator name + friend-request link, and nothing else
    /// (never the body, preview, ids, group ids or timestamps). nil when the
    /// creator can't be resolved to a valid username: no fabricated creator.
    static func note(title: String, creatorUsername: String) -> SharePayload? {
        guard let link = AppLink.friendURL(username: creatorUsername) else { return nil }
        let t = clean(title, max: 120)
        return SharePayload(text: [
            t.isEmpty ? "A note on FellowScript" : "\u{201C}\(t)\u{201D}",
            "Shared by \(creatorUsername) on FellowScript",
            "Send them a friend request: \(link.absoluteString)",
        ].joined(separator: "\n"))
    }

    /// Who wrote a note: the author name carried on the note, or the signed-in user for
    /// their own notes. nil (hide Share) when neither resolves to a valid username.
    static func noteCreator(noteUsername: String, noteUserId: String,
                            currentUserId: String?, currentUsername: String?) -> String? {
        if !noteUsername.isEmpty { return AppLink.isValidUsername(noteUsername) ? noteUsername : nil }
        guard let me = currentUsername, AppLink.isValidUsername(me) else { return nil }
        if noteUserId.isEmpty || noteUserId == currentUserId { return me }
        return nil
    }

    /// Verse share: reference + verse text + link that opens the verse. nil when the
    /// reference isn't a real one or there is no text.
    static func verse(book: String, chapter: Int, verse: Int, text: String) -> SharePayload? {
        guard let link = AppLink.verseURL(book: book, chapter: chapter, verse: verse) else { return nil }
        let body = clean(text, max: 1200)
        guard !body.isEmpty else { return nil }
        return SharePayload(text: "\(book) \(chapter):\(verse)\n\(body)\nRead it in FellowScript: \(link.absoluteString)")
    }

    /// Announcement share: group name + title + date + request-to-join link.
    /// Never the description, links, payment handles, attendee data, host names, ids or
    /// the location (a possibly private address). Scheduled announcements, a missing
    /// group name or a missing/invalid listing id are not shareable (nil).
    static func announcement(groupName: String, title: String, publishAt: String,
                             published: Bool, publicId: String) -> SharePayload? {
        guard published, let link = AppLink.groupURL(publicId: publicId) else { return nil }
        let group = clean(groupName, max: 80)
        let head = clean(title, max: 120)
        guard !group.isEmpty, !head.isEmpty else { return nil }
        var lines = ["\(group): \(head)"]
        let when = FSAnnouncementDates.display(publishAt)
        if !when.isEmpty { lines.append(when) }
        lines.append("Ask to join \(group): \(link.absoluteString)")
        return SharePayload(text: lines.joined(separator: "\n"))
    }
}
