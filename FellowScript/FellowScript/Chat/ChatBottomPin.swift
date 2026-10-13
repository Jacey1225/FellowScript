// ChatBottomPin.swift
// Task 20261013-ios-chat-initial-scroll-bottom.
//
// Pure (SwiftUI-free) state machine behind a chat list's "stay on the newest
// message" behavior. It replaces the one-shot `proxy.scrollTo(lastId)` that
// ChatThreadView/AgentChatView used to fire once after load.
//
// Root cause that motivated it: a single scrollTo against a LazyVStack lands
// where the *estimated* row heights say the bottom is. Rows then realize at
// their real heights (images, shared verse/note cards, reactions, quotes),
// the content grows, and nothing re-pinned, so the list rested short of the
// bottom. The cache-first render, fresh-fetch swap and the older-page
// auto-load (which prepended and re-anchored to the top of the old first
// row) all raced that single scroll.
//
// Model:
//   * `pinned`   - the reader is on the newest message. Any content or
//                  container height change re-pins (non-animated) until the
//                  reader drags away.
//   * `released` - the reader scrolled away on purpose. Never re-pinned by
//                  size changes; reattaches only when they come back to the
//                  bottom (by hand, jump-to-latest, or a new-message scroll).
//   * Older-page loading is gated until the bottom is established (or the
//     reader has taken over by scrolling).

import CoreGraphics

/// Snapshot of the scroll view's geometry that the pin cares about.
struct ChatScrollMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var containerHeight: CGFloat = 0
    /// Points between the viewport bottom and the content bottom (>= 0 when
    /// content extends below the viewport).
    var distanceFromBottom: CGFloat = 0
}

struct ChatBottomPin: Equatable {
    enum Phase: Equatable { case pinned, released }
    enum Action: Equatable { case none, repin }

    /// Past this distance a user-driven scroll releases the pin.
    static let releaseDistance: CGFloat = 80
    /// Within this distance the reader counts as back at the bottom.
    static let reattachDistance: CGFloat = 24
    /// Distance below which a pinned list is considered exactly at the bottom.
    static let settledTolerance: CGFloat = 2

    private(set) var phase: Phase = .pinned
    /// The initial load (cache + fresh fetch) has finished.
    private(set) var loadFinished = false
    /// The bottom position has been reached and held once after (re)load.
    private(set) var bottomEstablished = false

    /// Older pages may auto-load only after the bottom is established, or once
    /// the reader has taken over by scrolling away themselves.
    var allowsOlderPageLoad: Bool {
        loadFinished && (bottomEstablished || phase == .released)
    }

    var isPinned: Bool { phase == .pinned }

    mutating func loadDidFinish() {
        loadFinished = true
    }

    /// The whole list was swapped (thread enter/exit): pin again and require
    /// the bottom to be re-established before older pages may load.
    mutating func beginReposition() {
        phase = .pinned
        bottomEstablished = false
    }

    /// Called once the view has verified the list rests at the bottom with a
    /// stable content height.
    mutating func markBottomEstablished() {
        guard loadFinished, phase == .pinned else { return }
        bottomEstablished = true
    }

    /// Feeds one geometry change. `userDriven` is true while the reader's
    /// finger is tracking/dragging/decelerating the scroll view.
    mutating func scrollGeometryChanged(old: ChatScrollMetrics,
                                        new: ChatScrollMetrics,
                                        userDriven: Bool) -> Action {
        if userDriven {
            switch phase {
            case .pinned where new.distanceFromBottom > Self.releaseDistance:
                phase = .released
            case .released where new.distanceFromBottom <= Self.reattachDistance:
                phase = .pinned
                bottomEstablished = bottomEstablished || loadFinished
            default:
                break
            }
            return .none
        }

        switch phase {
        case .released:
            // Arrived back at the bottom by a programmatic scroll
            // (jump-to-latest, new-message scroll).
            if new.distanceFromBottom <= Self.reattachDistance {
                phase = .pinned
                bottomEstablished = bottomEstablished || loadFinished
            }
            return .none
        case .pinned:
            let sizeChanged = old.contentHeight != new.contentHeight
                || old.containerHeight != new.containerHeight
            return sizeChanged && new.distanceFromBottom > Self.settledTolerance ? .repin : .none
        }
    }
}
