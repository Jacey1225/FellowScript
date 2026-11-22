// ThreadUnreadDot.swift -- task 20261122-app-fixes-threads-widget (item 1).
// The same small red dot the chat rows use for unread (ContactRow: 12pt
// Theme.error circle ringed in Theme.bgPage, .unreadBadge transition), shown
// beside a thread row while the thread has unread messages from others.
// Inserted only when count > 0, so a read thread shows nothing. Folded into
// the row's accessibility label/value by the callers, so hidden from VoiceOver.

import SwiftUI

struct ThreadUnreadDot: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if count > 0 {
            Circle()
                .fill(Theme.error)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Theme.bgPage, lineWidth: 2))
                .transition(.unreadBadge(reduceMotion: reduceMotion))
                .accessibilityHidden(true)
                .accessibilityIdentifier("thread-unread-dot")
        }
    }
}
