// NetworkService+SystemLines.swift -- opt-in for in-chat system lines (G2).
// Only the chat-thread history calls append this. The contact-list load
// (fetchContacts, limit=1) never does, so a join line can never become a
// group's "last message" or raise an unread dot.

import Foundation

extension NetworkService {
    static let includeSystemQuery = "include_system=1"
}
