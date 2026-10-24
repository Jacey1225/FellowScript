// GroupInfoCategory.swift -- task 20261023-group-info-row. The four things a
// group has (chips under the group chat header) plus the pure gating and copy
// so they are unit-testable without views.

import Foundation

enum GroupInfoCategory: String, CaseIterable, Identifiable, Equatable {
    case announcements, threads, pinned, media, sessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .announcements: return "Announcements"
        case .threads:       return "Threads"
        case .pinned:        return FSPinnedListCopy.title
        case .media:         return "Media"
        case .sessions:      return "Sessions"
        }
    }

    /// Noun used in the shared error line ("We couldn't load <noun> just now.").
    var errorNoun: String {
        switch self {
        case .announcements: return "announcements"
        case .threads:       return "threads"
        case .pinned:        return "pins"
        case .media:         return "media"
        case .sessions:      return "sessions"
        }
    }

    /// Chips in order (Announcements, Threads, Pinned, Media); each is hidden when its
    /// feature is off. An empty result means the row is not rendered at all.
    static func visible(announcements: Bool, threads: Bool, pins: Bool, media: Bool) -> [GroupInfoCategory] {
        var out: [GroupInfoCategory] = []
        if announcements { out.append(.announcements) }
        if threads { out.append(.threads) }
        if pins { out.append(.pinned) }
        if media { out.append(.media) }
        return out
    }

    /// The chip row shows in group chats only, never inside an open thread. It always
    /// has at least the trailing Sessions pill, so it no longer depends on the chips.
    static func rowShows(isGroup: Bool, isThreadOpen: Bool) -> Bool {
        isGroup && !isThreadOpen
    }

    /// Tapping the open chip closes it; any other chip swaps the panel in place.
    static func toggled(_ current: GroupInfoCategory?, tapped: GroupInfoCategory) -> GroupInfoCategory? {
        current == tapped ? nil : tapped
    }

    /// Chip label: Pinned carries the count as plain text ("Pinned  3"), hidden at 0.
    func chipLabel(pinCount: Int) -> String {
        guard self == .pinned, pinCount > 0 else { return title }
        return "\(title)  \(pinCount > 99 ? "99+" : String(pinCount))"
    }
}

/// Shared copy for the submenu lists (design-spec section 5).
enum GroupInfoCopy {
    static let refreshNote = "Couldn't refresh. Showing what we had."
    static let tryAgain = "Try again"

    static func loadError(_ category: GroupInfoCategory) -> String {
        "We couldn't load \(category.errorNoun) just now."
    }

    static func empty(_ category: GroupInfoCategory) -> (title: String, hint: String) {
        switch category {
        case .announcements: return ("No announcements yet.", "When a leader posts one, it will show up here.")
        case .threads:       return ("No threads yet.", "Start one from any message to keep a conversation tidy.")
        case .pinned:        return (FSPinnedListCopy.empty, FSPinnedListCopy.emptyHint)
        case .media:         return ("No photos or videos yet.", "Anything shared in this chat will gather here.")
        case .sessions:      return ("No sessions scheduled yet.", "Schedule one to study together.")
        }
    }
}

/// Panel height: 45% of the message area, min 240pt, max 420pt (the min wins on short screens).
enum GroupInfoPanelMetrics {
    static func height(forAvailable available: CGFloat) -> CGFloat {
        min(420, max(240, available * 0.45))
    }
}
