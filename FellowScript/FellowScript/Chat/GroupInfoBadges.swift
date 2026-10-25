// GroupInfoBadges.swift -- red "new" badges on the group chat chips (announcements,
// threads, pins). Client-side only: the lists the chips open already carry timestamps
// and authors, so "unseen" = items by someone else newer than the last time this user
// opened that submenu on this device. No backend change. A first run with no watermark
// seeds it to the newest item so existing content never lights up retroactively.

import Foundation

enum GroupInfoBadgeLogic {
    struct Item: Equatable {
        let at: Date
        let byMe: Bool
    }

    /// Newest item time, whoever wrote it (what opening the submenu marks as seen).
    static func newest(_ items: [Item]) -> Date? { items.map(\.at).max() }

    /// Items by others strictly newer than the watermark. No watermark = nothing unseen.
    static func unseenCount(_ items: [Item], seen: Date?) -> Int {
        guard let seen else { return 0 }
        return items.filter { !$0.byMe && $0.at > seen }.count
    }

    /// Watermark written the first time a list loads for this user and group.
    static func seedWatermark(newest: Date?, now: Date = Date()) -> Date { newest ?? now }

    static func seenKey(userId: String, groupId: String, category: GroupInfoCategory) -> String {
        "groupinfo.seen.\(userId).\(groupId).\(category.rawValue)"
    }
}

/// Persists the per-group, per-category "seen up to" watermark.
struct GroupInfoSeenStore {
    var defaults: UserDefaults = .standard
    let userId: String
    let groupId: String

    func seen(_ c: GroupInfoCategory) -> Date? {
        let v = defaults.double(forKey: GroupInfoBadgeLogic.seenKey(userId: userId, groupId: groupId, category: c))
        return v > 0 ? Date(timeIntervalSince1970: v) : nil
    }

    func setSeen(_ c: GroupInfoCategory, _ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: GroupInfoBadgeLogic.seenKey(userId: userId, groupId: groupId, category: c))
    }
}
