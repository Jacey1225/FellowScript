// MessageGroupRow+SystemLine.swift -- per-kind glyph for the centered system
// line (task 20261016-push-notifications-and-ui, gap G2). A pin line keeps its
// pin; a "member joined" line gets a person glyph; any other kind shows none.

import Foundation

extension MessageGroupRow {
    static func systemLineIcon(for kind: String?) -> String? {
        switch kind {
        case "pin": return "pin.fill"
        case "member_joined": return "person.badge.plus"
        case "announcement": return "megaphone.fill"
        default: return nil
        }
    }
}
