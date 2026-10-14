// FSIcon.swift -- v3 custom raster icon set (task 20261013-ios-custom-icon-set-v3).
// Full-colour artwork shipped as image sets under Assets.xcassets/Icons with
// "original" rendering intent, so it never takes foregroundColor tinting.
// Enum cases make a typo or a missing name a compile error rather than a
// silently blank image. Each image set is sized N/2N/3x px for its largest
// render size (see `pointSize`); render at or below that to stay sharp.

import SwiftUI

enum FSIcon: String, CaseIterable {
    case browseGroups     = "browse-groups"
    case createGroup      = "create-group"
    case noAnnouncements  = "no-announcements"

    /// Point size the 1x asset was authored at.
    var pointSize: CGFloat {
        switch self {
        case .browseGroups, .createGroup: return 52
        case .noAnnouncements: return 64
        }
    }

    /// Untinted, resizable image. Callers apply `.frame(...)`.
    var image: Image {
        Image(rawValue).renderingMode(.original).resizable().interpolation(.high)
    }
}
