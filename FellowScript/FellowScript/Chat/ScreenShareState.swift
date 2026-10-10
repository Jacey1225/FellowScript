// Screen-share SENDING state machine (task 20261009-session-ui-redesign,
// step 5). Pure value types, no SDK / ReplayKit / UIKit, so the rules (flag
// gating, one share at a time, the pinned-indicator lifecycle) are unit
// testable. The Chime/ReplayKit plumbing lives in ChimeScreenShare.swift.

import Foundation

enum ScreenShareStartBlock: Equatable {
    case flagOff, notImplemented, notConnected, someoneElseSharing, alreadyActive
}

struct ScreenShareState: Equatable {
    enum Phase: Equatable {
        case idle
        /// Listening on the socket and the system picker was presented; waiting
        /// for the user to tap "Start Broadcast".
        case awaitingBroadcast
        /// The extension connected; the Chime content share is starting.
        case connecting
        /// Chime confirmed the share. The pinned indicator shows only here.
        case sharing
    }

    private(set) var phase: Phase = .idle

    /// The persistent "Sharing your screen" pill + one-tap stop.
    var showsIndicator: Bool { phase == .sharing }
    /// Anything other than idle: the receiver / source exist and need cleanup.
    var isActive: Bool { phase != .idle }

    /// Nil means a start is allowed. Fail-closed: the server flag must be on.
    static func startBlock(flagEnabled: Bool,
                           sendingImplemented: Bool = ScreenShareFlag.sendingImplemented,
                           isConnected: Bool,
                           someoneElseSharing: Bool,
                           phase: Phase) -> ScreenShareStartBlock? {
        if !flagEnabled { return .flagOff }
        if !sendingImplemented { return .notImplemented }
        if !isConnected { return .notConnected }
        if phase != .idle { return .alreadyActive }
        if someoneElseSharing { return .someoneElseSharing }
        return nil
    }

    mutating func requestStart() { if phase == .idle { phase = .awaitingBroadcast } }

    mutating func broadcastConnected() { if phase == .awaitingBroadcast { phase = .connecting } }

    mutating func shareStarted() {
        if phase == .connecting || phase == .awaitingBroadcast { phase = .sharing }
    }

    /// Picker dismissed without starting. Returns true if this actually ended a
    /// pending start (so the caller can tear the listener down).
    mutating func awaitTimedOut() -> Bool {
        guard phase == .awaitingBroadcast else { return false }
        phase = .idle
        return true
    }

    /// Any end of an active share (user stop, broadcast ended from Control
    /// Center, call ended, Chime failure). Returns true if a share was
    /// connecting/sharing, i.e. the user should be told it ended.
    @discardableResult
    mutating func ended() -> Bool {
        let wasLive = (phase == .connecting || phase == .sharing)
        phase = .idle
        return wasLive
    }

    mutating func reset() { phase = .idle }
}

/// User-facing copy for fail-soft errors (warm, never raw technical text).
enum ScreenShareMessages {
    static let unavailableBuild = "Screen sharing isn't available on this build yet."
    static let couldNotStart = "We couldn't start screen sharing. Please try again."
    static let ended = "Screen sharing ended."
    static let failedMidShare = "Screen sharing stopped unexpectedly."
    static let someoneElse = "Someone else is already sharing."
}
