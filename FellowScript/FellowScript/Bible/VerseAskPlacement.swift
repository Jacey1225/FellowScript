// VerseAskPlacement.swift -- task 20261112-verse-ask-ai (step 5).
// Pure placement for the per-verse "Ask AI" overlays. Mirrors the web
// placeVerseAskOverlay (frontend/src/lib/verseAsk.js) so both platforms follow
// the same rules and are unit-tested the same way. No view or UIKit reads:
// every value is a plain number in one shared (global) coordinate space.
//
// Hard rule: the overlays only cover content. Nothing here pushes text; when a
// verse is near an edge the pill is clamped on screen (over the verse) and the
// panel flips above the pill instead of growing off-screen.

import CoreGraphics

enum VerseAskPlacement {
    static let margin: CGFloat = 8          // vertical viewport margin (web VIEWPORT_MARGIN)
    static let sideMargin: CGFloat = 16     // horizontal margin (Theme.spacingMD)
    static let gap: CGFloat = 6             // MENU_GAP / OVERLAY_GAP
    static let pillMaxWidth: CGFloat = 520
    static let panelMinHeight: CGFloat = 120
    static let flipBelowSpace: CGFloat = 160
    static let panelViewportFraction: CGFloat = 0.45

    struct Result: Equatable {
        var pillTop: CGFloat
        var panelTop: CGFloat
        var panelMaxHeight: CGFloat
        var flipped: Bool
    }

    /// - Parameters:
    ///   - verseTop: top edge of the verse row.
    ///   - viewportTop / viewportBottom: usable area (below safe area top, above safe bottom).
    ///   - keyboardTop: top of the on-screen keyboard, if shown.
    ///   - bottomObstruction: height of the floating tab bar (plus its margin) above viewportBottom.
    ///   - pillHeight / panelHeight: current measured heights.
    static func place(verseTop: CGFloat, viewportTop: CGFloat, viewportBottom: CGFloat,
                      keyboardTop: CGFloat?, bottomObstruction: CGFloat = 0,
                      pillHeight: CGFloat, panelHeight: CGFloat) -> Result {
        let topLimit = viewportTop + margin
        // The floating tab bar covers the bottom `bottomObstruction` points of the
        // viewport: that band is unusable, like the keyboard.
        let clearBottom = viewportBottom - max(0, bottomObstruction)
        let bottomEdge = keyboardTop.map { min($0, clearBottom) } ?? clearBottom
        let bottomLimit = bottomEdge - margin

        var pillTop = verseTop - gap - pillHeight
        pillTop = min(pillTop, bottomLimit - pillHeight)
        pillTop = max(pillTop, topLimit)

        let viewportHeight = viewportBottom - viewportTop
        let cap = max(panelMinHeight, (viewportHeight * panelViewportFraction).rounded(.down))
        let belowTop = pillTop + pillHeight + gap
        let spaceBelow = bottomLimit - belowTop
        let spaceAbove = pillTop - gap - topLimit

        if spaceBelow < flipBelowSpace && spaceAbove > spaceBelow && spaceAbove >= panelMinHeight {
            let maxH = min(cap, spaceAbove)
            let h = min(panelHeight, maxH)
            return Result(pillTop: pillTop, panelTop: pillTop - gap - h, panelMaxHeight: maxH, flipped: true)
        }
        let maxH = max(panelMinHeight, min(cap, spaceBelow))
        return Result(pillTop: pillTop, panelTop: belowTop, panelMaxHeight: maxH, flipped: false)
    }

    /// Horizontal placement: aligned to the verse column, at most 520 wide,
    /// kept inside the side margin.
    static func column(columnLeft: CGFloat, columnWidth: CGFloat, viewportWidth: CGFloat) -> (left: CGFloat, width: CGFloat) {
        let width = max(0, min(columnWidth, pillMaxWidth, viewportWidth - sideMargin * 2))
        let left = max(sideMargin, min(columnLeft, viewportWidth - width - sideMargin))
        return (left, width)
    }

    /// Whether a change of the overlay's host rect makes the captured verse
    /// frame stale. Only a genuine horizontal change counts (rotation, split
    /// or Stage Manager resize, pane move): those re-flow the verse column.
    /// Height-only changes happen on their own when the keyboard comes up
    /// (iPad's embedded Bible pane shrinks while the field takes focus) and
    /// must not dismiss the overlay.
    static func shouldClose(baseline: CGRect, current: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(current.width - baseline.width) > tolerance || abs(current.minX - baseline.minX) > tolerance
    }
}
