// Views for tap-to-maximize in the session call screen (task
// 20261016-call-maximize-tiles, design-notes.md). Pure state lives in
// CallFocusState.swift. Chime binds a tile id to ONE render view at a time
// (ChimeCallManager.bindTile -> bindVideoView; the latest binding wins, and every
// ChimeVideoTileView re-binds on each SwiftUI update), so a tile is rendered in
// exactly one place: the enlarged view replaces its source bubble rather than
// duplicating it, and the strip hides the enlarged participant.

import SwiftUI

#if canImport(AmazonChimeSDK)

/// "Back to everyone": 44pt minimum, scrimmed so it stays readable over any frame.
struct CallFocusBackButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityHidden(true)
                Text(CallFocusLogic.backLabel)
                    .font(.interScaled(Theme.fontXS, weight: .semibold, relativeTo: .caption))
                    .lineLimit(2)
            }
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(Capsule().fill(Theme.bgPage.opacity(0.72)))
            .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .accessibilityLabel(CallFocusLogic.backLabel)
        .accessibilityHint("Returns to the normal call layout")
    }
}

/// Shared chrome for an enlarged tile: black aspect-fit stage in the content
/// card shape, tap anywhere to return, Back button, and a VoiceOver escape action.
private struct CallFocusStage<Media: View>: View {
    let label: String
    let nameCapsule: String?
    let onReturn: () -> Void
    @ViewBuilder let media: () -> Media

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var backFocused: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onReturn) {
                media()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityHint(CallFocusLogic.returnHint)

            CallFocusBackButton(onTap: onReturn)
                .padding(12)
                .accessibilityFocused($backFocused)
        }
        .overlay(alignment: .bottomLeading) {
            if let name = nameCapsule {
                Text(name)
                    .font(.interScaled(Theme.fontXS, weight: .semibold, relativeTo: .caption))
                    .foregroundColor(Theme.textPrimary).lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.bgPage.opacity(0.72)))
                    .padding(12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)   // the stage's own label already names them
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Theme.borderGold, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onReturn)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
        .onAppear { backFocused = true }
        .onDisappear { AccessibilityNotification.LayoutChanged().post() }
    }
}

/// An enlarged camera (own or remote). Aspect-fit so nobody is cropped; the
/// own camera uses the same render view as the self preview, so it is mirrored
/// exactly as the preview is.
struct CallFocusedCameraView: View {
    let item: CallBubbleItem
    let manager: ChimeCallManager
    let onReturn: () -> Void

    private var tileId: Int? {
        switch item.kind {
        case .local(let t):      return t
        case .remoteVideo(let t): return t
        case .audioOnly:         return nil
        }
    }

    var body: some View {
        CallFocusStage(label: CallFocusLogic.enlargedCameraLabel(for: item),
                       nameCapsule: item.name, onReturn: onReturn) {
            if let tile = tileId {
                ChimeVideoTileView(tileId: tile, manager: manager, contentMode: .scaleAspectFit)
            }
        }
    }
}

/// The enlarged incoming screen share.
struct CallFocusedShareView: View {
    let tileId: Int
    let sharerName: String?
    let manager: ChimeCallManager
    let onReturn: () -> Void

    var body: some View {
        CallFocusStage(label: CallFocusLogic.shareLabel(sharerName: sharerName),
                       nameCapsule: nil, onReturn: onReturn) {
            ChimeVideoTileView(tileId: tileId, manager: manager, contentMode: .scaleAspectFit)
        }
    }
}

/// The normal (not enlarged) incoming share: the bare tile, tap to enlarge, with
/// a visible corner glyph because the old "<Name> is sharing" heading is gone.
struct CallShareTile: View {
    let tileId: Int
    let sharerName: String?
    let manager: ChimeCallManager
    let onEnlarge: () -> Void

    var body: some View {
        Button(action: onEnlarge) {
            ChimeVideoTileView(tileId: tileId, manager: manager, contentMode: .scaleAspectFit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.goldLight)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.bgPage.opacity(0.72)))
                        .padding(8)
                        .accessibilityHidden(true)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CallFocusLogic.shareLabel(sharerName: sharerName))
        .accessibilityHint(CallFocusLogic.enlargeHint)
    }
}

/// Head-of-strip cell shown while a camera is enlarged and someone else is
/// sharing, so the share stays reachable without stealing focus.
struct CallShareChip: View {
    let tileId: Int
    let sharerName: String?
    let manager: ChimeCallManager
    let height: CGFloat
    let onEnlarge: () -> Void

    var body: some View {
        Button(action: onEnlarge) {
            ChimeVideoTileView(tileId: tileId, manager: manager, contentMode: .scaleAspectFit)
                .frame(width: height * 16 / 9, height: height)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                    .stroke(Theme.gold.opacity(0.38), lineWidth: 1))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CallFocusLogic.shareLabel(sharerName: sharerName))
        .accessibilityHint(CallFocusLogic.enlargeHint)
    }
}

#endif
