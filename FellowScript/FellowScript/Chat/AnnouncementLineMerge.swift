// AnnouncementLineMerge.swift -- task 20261030-chat-announcements.
// Applies a fresh history read to the announcement lines already on screen after
// an `announcement_updated` frame: an edited card replaces the old one in place,
// a restored line is inserted at its timestamp position. Nothing else in the
// list is touched, and a failed read never reaches this function (the caller
// keeps the cached messages: preserve-cache-on-failed-refresh).

import Foundation

enum AnnouncementLineMerge {
    /// `fetched` are the announcement lines of the fresh read (already
    /// sender-resolved). Lines not in `fetched` are left alone (an older page
    /// the fresh window does not cover must not disappear).
    static func merge(_ current: [FSMessage], fetched: [FSMessage]) -> [FSMessage] {
        var out = current
        for line in fetched {
            if let idx = out.firstIndex(where: { $0.id == line.id }) {
                if out[idx].announcement != line.announcement { out[idx].announcement = line.announcement }
            } else {
                out = fsInsertRestored(out, line)
            }
        }
        return out
    }

    /// The history window's announcement lines, whichever shape came back.
    static func lines(in history: FSMessageHistory) -> [FSMessage] {
        let all: [FSMessage]
        switch history {
        case .legacy(let list): all = list
        case .paged(let page): all = page.messages
        }
        return all.filter { $0.systemKind == "announcement" && $0.announcement != nil }
    }
}
