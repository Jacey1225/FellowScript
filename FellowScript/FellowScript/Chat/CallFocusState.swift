// Pure, SDK-free state for tap-to-maximize in the session call screen
// (task 20261016-call-maximize-tiles, design-notes.md). Local only, never
// synced. Deliberately NOT named isExpanded: that already means the full-screen
// call vs the minimized bar (CallController) and the Interactions menu.

import Foundation

/// What is currently enlarged. Only one at a time.
enum FocusedTile: Equatable {
    /// A camera bubble, keyed by `CallBubbleItem.id` ("self" or "tile-<n>").
    case camera(String)
    /// The incoming (remote) screen share. Your own share is never focusable.
    case share
}

/// Why a focus ended on its own; drives the warm, polite announcement.
enum FocusLoss: Equatable {
    case left, cameraOff, ownCameraOff, shareEnded
}

/// The focused tile plus what we knew about it when it was chosen, so a loss
/// can be explained after the tile (and its roster entry) is already gone.
struct CallFocus: Equatable {
    var tile: FocusedTile
    var name: String?
    var attendeeId: String?
}

enum CallFocusLogic {
    /// A bubble is a button only when there is video to enlarge.
    static func isMaximizable(_ item: CallBubbleItem) -> Bool {
        switch item.kind {
        case .local(let tile):   return tile != nil
        case .remoteVideo:       return true
        case .audioOnly:         return false
        }
    }

    /// Derived, never stored: a focus whose tile is gone is simply not valid.
    static func isValid(_ tile: FocusedTile, items: [CallBubbleItem],
                        shareTileId: Int?, sharerIsSelf: Bool) -> Bool {
        switch tile {
        case .share:
            return shareTileId != nil && !sharerIsSelf
        case .camera(let id):
            return items.first(where: { $0.id == id }).map(isMaximizable) ?? false
        }
    }

    /// Why a no-longer-valid focus ended.
    static func loss(of focus: CallFocus, remoteAttendeeIds: [String]) -> FocusLoss {
        switch focus.tile {
        case .share:
            return .shareEnded
        case .camera(let id):
            if id == "self" { return .ownCameraOff }
            if let a = focus.attendeeId, remoteAttendeeIds.contains(a) { return .cameraOff }
            return .left
        }
    }

    static func announcement(for loss: FocusLoss, name: String?) -> String {
        let who = name ?? "Someone"
        switch loss {
        case .left:         return "\(who) left the call. Back to everyone."
        case .cameraOff:    return "\(who) turned their camera off. Back to everyone."
        case .ownCameraOff: return "Your camera is off. Back to everyone."
        case .shareEnded:   return "\(who) stopped sharing. Back to everyone."
        }
    }

    /// Bubble strip while something is enlarged: everyone except the enlarged camera.
    static func stripItems(_ items: [CallBubbleItem], focused: FocusedTile?) -> [CallBubbleItem] {
        guard case .camera(let id)? = focused else { return items }
        return items.filter { $0.id != id }
    }

    /// Fallback from design: unknown names read as "Participant".
    static func enlargedCameraLabel(for item: CallBubbleItem) -> String {
        switch item.kind {
        case .local: return "You, enlarged video"
        default:     return "\(item.name ?? "Participant"), enlarged video"
        }
    }

    static func shareLabel(sharerName: String?) -> String {
        sharerName.map { "Shared screen from \($0)" } ?? "Shared screen"
    }

    static let enlargeHint = "Double tap to enlarge"
    static let returnHint = "Double tap to return to everyone"
    static let backLabel = "Back to everyone"
}

extension CallFocusLogic {
    /// The enlarged view must keep at least this much height; otherwise the
    /// portrait strip collapses (Back control stays) rather than clipping it.
    static let minEnlargedHeight: CGFloat = 160

    static func showsStrip(focused: Bool, containerHeight: CGFloat, headerEstimate: CGFloat,
                           stripHeight: CGFloat, dockZone: CGFloat) -> Bool {
        guard focused else { return true }
        return containerHeight - headerEstimate - stripHeight - dockZone >= minEnlargedHeight
    }
}
