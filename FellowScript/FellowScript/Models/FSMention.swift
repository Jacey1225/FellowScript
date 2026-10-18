// FSMention.swift -- task 20261017-chat-mentions (iOS), contract.md sections 1, 4.
//
// Pure value types and logic (no SwiftUI, no networking) for chat @mentions:
//   - FSMention / FSMentionList: the wire shape, tolerant on decode.
//   - MentionRender: validates received ranges and splits a message into
//     plain / mention runs for bold rendering.
//   - MentionDraft: the composer-side state (trigger detection, insert,
//     edit maintenance, verification, outgoing offsets).
//
// UNIT: every offset here is a UTF-16 code unit offset into the exact text
// that is sent / stored. Never String.count (grapheme clusters). The server
// compares the slice [start, start+length) to "@" + username code unit for
// code unit, so a client must never send a range it has not re-verified.

import Foundation

// ── Wire shape ────────────────────────────────────────────────────────────────

/// One mention. Inbound to the server: `user_id`, `start`, `length` only.
/// Outbound from the server: the same plus the user's CURRENT `username`.
nonisolated struct FSMention: Codable, Equatable {
    var userId: String
    var start: Int
    var length: Int
    var username: String? = nil

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id", start, length, username
    }

    init(userId: String, start: Int, length: Int, username: String? = nil) {
        self.userId = userId; self.start = start; self.length = length; self.username = username
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        start = try c.decode(Int.self, forKey: .start)
        length = try c.decode(Int.self, forKey: .length)
        username = try? c.decodeIfPresent(String.self, forKey: .username)
    }

    /// The exact three keys the server accepts on send (nothing else).
    var outgoingJSON: [String: Any] {
        ["user_id": userId, "start": start, "length": length]
    }

    /// Parses the `mentions` array of a live frame / ack dictionary. nil when
    /// the key is absent, null, not an array, or yields no usable entry.
    /// Malformed entries are skipped, never fatal.
    static func parse(_ raw: Any?) -> [FSMention]? {
        guard let arr = raw as? [Any], !arr.isEmpty else { return nil }
        var out: [FSMention] = []
        for item in arr {
            guard let d = item as? [String: Any],
                  let uid = d["user_id"] as? String,
                  let start = d["start"] as? Int,
                  let length = d["length"] as? Int else { continue }
            out.append(FSMention(userId: uid, start: start, length: length, username: d["username"] as? String))
        }
        return out.isEmpty ? nil : out
    }
}

/// Decodes a `mentions` array without ever throwing: an absent key is handled
/// by the caller (decodeIfPresent), a non-array value yields no mentions, and
/// an individual malformed entry is skipped. A bad `mentions` key must never
/// cost the user the whole message list.
nonisolated struct FSMentionList: Decodable {
    let items: [FSMention]

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        guard var c = try? decoder.unkeyedContainer() else { items = []; return }
        var out: [FSMention] = []
        while !c.isAtEnd {
            if let m = try? c.decode(FSMention.self) {
                out.append(m)
            } else if (try? c.decode(Skip.self)) == nil {
                break   // cannot advance; stop rather than loop forever
            }
        }
        items = out
    }

    /// nil when there is nothing to show (matches "absent == none").
    var orNil: [FSMention]? { items.isEmpty ? nil : items }
}

/// One mentionable person (a member-list row).
nonisolated struct FSMentionCandidate: Equatable, Identifiable {
    let userId: String
    let username: String
    var id: String { userId }
}

/// GET /groups/{uid}/{gid}/mention-members body.
nonisolated struct FSMentionMembersResponse: Decodable {
    let members: [Member]
    struct Member: Decodable {
        let user_id: String
        let username: String
    }
}

// ── UTF-16 helpers ────────────────────────────────────────────────────────────

nonisolated enum MentionText16 {
    static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let s = Unicode.Scalar(unit) else { return false }   // surrogates are not whitespace
        return CharacterSet.whitespacesAndNewlines.contains(s)
    }

    /// Substring for a UTF-16 range, nil if out of bounds or it would split a
    /// surrogate pair.
    static func slice(_ text: String, start: Int, length: Int) -> String? {
        let total = text.utf16.count
        guard start >= 0, length >= 0, start + length <= total else { return nil }
        let u = text.utf16
        let a = u.index(u.startIndex, offsetBy: start)
        let b = u.index(a, offsetBy: length)
        guard a.samePosition(in: text.unicodeScalars) != nil,
              b.samePosition(in: text.unicodeScalars) != nil else { return nil }
        return String(text[a..<b])
    }
}

// ── Rendering ─────────────────────────────────────────────────────────────────

nonisolated enum MentionRender {

    struct Run: Equatable {
        let text: String
        let isMention: Bool
    }

    /// The mentions of a received message that are safe to render against its
    /// stored text: in bounds, at least 2 units, not splitting a surrogate
    /// pair, starting with "@", ascending and non-overlapping. Anything else
    /// is skipped (that range just renders as plain text); never throws.
    static func validRanges(_ mentions: [FSMention]?, in text: String) -> [FSMention] {
        guard let mentions, !mentions.isEmpty, !text.isEmpty else { return [] }
        var out: [FSMention] = []
        var cursor = 0
        for m in mentions {
            guard m.length >= 2, m.start >= cursor,
                  let s = MentionText16.slice(text, start: m.start, length: m.length),
                  s.hasPrefix("@") else { continue }
            out.append(m)
            cursor = m.start + m.length
        }
        return out
    }

    /// Splits `text` into ordered runs. A mention run shows "@" + the current
    /// username when the server sent one (rename-safe), else the stored slice.
    /// Built sequentially, never by in-place index mutation, so a username
    /// whose length differs from the stored one cannot shift later runs.
    /// Always yields at least the plain text when there are no valid ranges.
    static func runs(text: String, mentions: [FSMention]?) -> [Run] {
        let valid = validRanges(mentions, in: text)
        guard !valid.isEmpty else { return text.isEmpty ? [] : [Run(text: text, isMention: false)] }
        var runs: [Run] = []
        var cursor = 0
        for m in valid {
            if m.start > cursor, let plain = MentionText16.slice(text, start: cursor, length: m.start - cursor) {
                runs.append(Run(text: plain, isMention: false))
            }
            let stored = MentionText16.slice(text, start: m.start, length: m.length) ?? ""
            let shown: String
            if let name = m.username, !name.isEmpty { shown = "@" + name } else { shown = stored }
            runs.append(Run(text: shown, isMention: true))
            cursor = m.start + m.length
        }
        let total = text.utf16.count
        if cursor < total, let tail = MentionText16.slice(text, start: cursor, length: total - cursor) {
            runs.append(Run(text: tail, isMention: false))
        }
        return runs
    }

    /// True when at least one range will render bold.
    static func hasMentions(_ mentions: [FSMention]?, in text: String) -> Bool {
        !validRanges(mentions, in: text).isEmpty
    }
}

// ── Composer draft ────────────────────────────────────────────────────────────

nonisolated struct MentionDraft: Equatable {

    static let maxMentions = 10
    static let maxVisibleRows = 5

    /// Recorded mentions for the current composer text (ascending, `username`
    /// always set to the inserted name).
    var mentions: [FSMention] = []

    struct Trigger: Equatable {
        /// UTF-16 offset of the "@".
        let at: Int
        /// Text between the "@" and the caret (may be empty).
        let query: String
        /// UTF-16 length of the whole token (1 + query).
        var length: Int { 1 + query.utf16.count }
    }

    // MARK: trigger

    /// Open the picker when `caret` (UTF-16 offset) sits directly after an "@"
    /// that is at index 0 or preceded by whitespace, with no whitespace
    /// between that "@" and the caret. a@b (mid-word) never triggers.
    static func trigger(in text: String, caret: Int) -> Trigger? {
        let u = Array(text.utf16)
        guard caret >= 1, caret <= u.count else { return nil }
        var i = caret
        while i > 0 {
            let unit = u[i - 1]
            if unit == 0x40 {   // "@"
                let at = i - 1
                guard at == 0 || MentionText16.isWhitespace(u[at - 1]) else { return nil }
                let query = String(utf16CodeUnits: Array(u[i..<caret]), count: caret - i)
                return Trigger(at: at, query: query)
            }
            if MentionText16.isWhitespace(unit) { return nil }
            i -= 1
        }
        return nil
    }

    // MARK: candidates

    /// Candidates for the picker: excludes anyone already mentioned in this
    /// draft; ordered prefix match, then word-start match, then contains
    /// (case-insensitive, stable within each group). No cap here; the view
    /// caps the visible rows.
    func candidates(from members: [FSMentionCandidate], query: String) -> [FSMentionCandidate] {
        guard mentions.count < Self.maxMentions else { return [] }
        let taken = Set(mentions.map { $0.userId.lowercased() })
        let pool = members.filter { !taken.contains($0.userId.lowercased()) }
        return Self.filter(pool, query: query)
    }

    static func filter(_ pool: [FSMentionCandidate], query: String) -> [FSMentionCandidate] {
        let q = query.lowercased()
        guard !q.isEmpty else { return pool }
        var prefix: [FSMentionCandidate] = []
        var wordStart: [FSMentionCandidate] = []
        var contains: [FSMentionCandidate] = []
        for c in pool {
            let name = c.username.lowercased()
            if name.hasPrefix(q) {
                prefix.append(c)
            } else if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) {
                wordStart.append(c)
            } else if name.contains(q) {
                contains.append(c)
            }
        }
        return prefix + wordStart + contains
    }

    // MARK: insert

    /// Replaces the "@query" token with "@Name" plus one trailing space (none
    /// added if the next character is already a space) and records the
    /// mention. Returns the new text, or nil when the pick is not allowed
    /// (cap reached, person already mentioned, empty name, stale trigger).
    mutating func insert(_ candidate: FSMentionCandidate, trigger: Trigger, into text: String) -> String? {
        guard mentions.count < Self.maxMentions, !candidate.username.isEmpty,
              !mentions.contains(where: { $0.userId.lowercased() == candidate.userId.lowercased() }) else { return nil }
        let total = text.utf16.count
        let tokenEnd = trigger.at + trigger.length
        guard trigger.at >= 0, tokenEnd <= total,
              MentionText16.slice(text, start: trigger.at, length: 1) == "@" else { return nil }
        let name = "@" + candidate.username
        let nextIsSpace = tokenEnd < total
            && MentionText16.slice(text, start: tokenEnd, length: 1) == " "
        let insertion = nextIsSpace ? name : name + " "
        let before = MentionText16.slice(text, start: 0, length: trigger.at) ?? ""
        let after = MentionText16.slice(text, start: tokenEnd, length: total - tokenEnd) ?? ""
        let nameLen = name.utf16.count
        let delta = insertion.utf16.count - trigger.length
        var kept: [FSMention] = []
        for var m in mentions {
            if m.start >= tokenEnd { m.start += delta; kept.append(m) }
            else if m.start + m.length <= trigger.at { kept.append(m) }
            // a range overlapping the token cannot be valid any more: dropped
        }
        kept.append(FSMention(userId: candidate.userId.lowercased(), start: trigger.at, length: nameLen, username: candidate.username))
        mentions = kept.sorted { $0.start < $1.start }
        return before + insertion + after
    }

    // MARK: edits

    /// Keeps `mentions` aligned after the composer text changed from
    /// `oldText` to `newText`. Returns the (possibly adjusted) text:
    ///  - a pure deletion that removes characters inside a mention, or only
    ///    the single space right after it, removes that whole "@Name" and its
    ///    record in one step (backspace into a mention);
    ///  - typing or replacing inside a mention drops only the record (the
    ///    text stays as plain text);
    ///  - mentions after the edit shift by the length delta.
    /// The result is always re-verified, so a stale range can never survive.
    mutating func applyEdit(oldText: String, newText: String) -> String {
        guard oldText != newText else { return newText }
        guard !mentions.isEmpty else { return newText }
        if newText.isEmpty { mentions = []; return newText }

        let o = Array(oldText.utf16), n = Array(newText.utf16)
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        var oEnd = o.count, nEnd = n.count
        while oEnd > p, nEnd > p, o[oEnd - 1] == n[nEnd - 1] { oEnd -= 1; nEnd -= 1 }
        let inserted = nEnd - p
        let delta = (nEnd - oEnd)
        let pureDeletion = inserted == 0 && oEnd > p

        var kept: [FSMention] = []
        var removals: [(Int, Int)] = []   // [start, end) in NEW-text coordinates
        for var m in mentions {
            let s = m.start, e = m.start + m.length
            if e <= p {
                // Entirely before the edit. Exception: deleting just the one
                // space that follows the mention removes the whole mention.
                if pureDeletion, e == p, oEnd - p == 1, MentionText16.isWhitespace(o[p]) {
                    removals.append((s, e))
                } else {
                    kept.append(m)
                }
            } else if s >= oEnd {
                m.start += delta
                kept.append(m)
            } else if pureDeletion {
                // Deletion reaching into the mention: drop the leftover chars too.
                let remainder = e > oEnd ? e - oEnd : 0
                removals.append((min(s, p), p + remainder))
            }
            // else: an insertion/replacement inside the mention: record dropped
        }

        var text = newText
        if !removals.isEmpty {
            let sorted = removals.sorted { $0.0 < $1.0 }
            var out: [UInt16] = []
            var cursor = 0
            for (a, b) in sorted {
                let a2 = max(a, cursor), b2 = min(max(b, a2), n.count)
                if a2 > cursor { out.append(contentsOf: n[cursor..<a2]) }
                cursor = max(cursor, b2)
            }
            if cursor < n.count { out.append(contentsOf: n[cursor...]) }
            text = String(utf16CodeUnits: out, count: out.count)
            // Starts of surviving mentions move left by what was removed before them.
            kept = kept.map { m in
                var m2 = m
                var shift = 0
                for (a, b) in sorted where b <= m.start { shift += b - a }
                m2.start -= shift
                return m2
            }
        }
        mentions = kept
        mentions = verified(for: text)
        return text
    }

    // MARK: verification and outgoing

    /// Mentions whose range still equals exactly "@" + username inside `text`,
    /// ascending, non-overlapping, one per person, at most the cap. Anything
    /// else is dropped (never send an unverified range).
    func verified(for text: String) -> [FSMention] {
        var out: [FSMention] = []
        var seen = Set<String>()
        var cursor = 0
        for m in mentions.sorted(by: { $0.start < $1.start }) {
            guard out.count < Self.maxMentions, let name = m.username, !name.isEmpty,
                  m.start >= cursor, m.length == 1 + name.utf16.count,
                  MentionText16.slice(text, start: m.start, length: m.length) == "@" + name,
                  seen.insert(m.userId.lowercased()).inserted else { continue }
            out.append(m)
            cursor = m.start + m.length
        }
        return out
    }

    /// The text to send (trimmed, like the existing send path) and the
    /// mentions re-based onto that trimmed text and re-verified. Offsets are
    /// computed against the text that is actually sent.
    func outgoing(rawText: String) -> (text: String, mentions: [FSMention]) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        var lead = 0
        for scalar in rawText.unicodeScalars {
            guard CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            lead += String(scalar).utf16.count
        }
        var shifted = MentionDraft()
        shifted.mentions = mentions.compactMap { m in
            guard m.start >= lead else { return nil }
            var m2 = m
            m2.start -= lead
            return m2
        }
        return (trimmed, shifted.verified(for: trimmed))
    }
}
