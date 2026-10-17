// Tap-to-maximize wiring for ChimeCallView (task 20261016-call-maximize-tiles).
// Kept out of ChimeCallView.swift so the main file only grows by call sites.
// State is local (never synced) and cleared on room switch / leaving the screen.

import SwiftUI

#if canImport(AmazonChimeSDK)

extension ChimeCallView {

    // MARK: Derived state

    /// The focus, only while its tile still exists. Derived, not event-driven, so a
    /// vanished tile can never leave a blank enlarged view behind for even a frame.
    var activeFocus: FocusedTile? {
        guard let focus else { return nil }
        return CallFocusLogic.isValid(focus.tile, items: bubbleItems,
                                      shareTileId: manager.contentShareTileId,
                                      sharerIsSelf: manager.sharerIsSelf) ? focus.tile : nil
    }

    /// The bubble scatter is only shown when nothing is enlarged.
    var showsFieldLayout: Bool { layoutMode == .field && activeFocus == nil }

    // MARK: Actions

    func focusCamera(id: String) {
        guard let item = bubbleItems.first(where: { $0.id == id }), CallFocusLogic.isMaximizable(item) else { return }
        var attendee: String?
        if case .remoteVideo(let tile) = item.kind { attendee = manager.tileAttendeeIds[tile] }
        setFocus(CallFocus(tile: .camera(id), name: item.name, attendeeId: attendee))
    }

    func focusShare() {
        guard manager.contentShareTileId != nil, !manager.sharerIsSelf else { return }
        setFocus(CallFocus(tile: .share, name: sharerName, attendeeId: nil))
    }

    func returnFromFocus() { setFocus(nil) }

    private func setFocus(_ new: CallFocus?) {
        withMotionAwareAnimation(.easeInOut(duration: new == nil ? 0.2 : 0.28), reduceMotion: reduceMotion) {
            focus = new
        }
    }

    /// The focused tile vanished (left, camera off, share ended): restore without
    /// an error and say so politely. A user-initiated return already cleared `focus`.
    func reconcileFocus() {
        guard let lost = focus, activeFocus == nil else { return }
        let loss = CallFocusLogic.loss(of: lost, remoteAttendeeIds: manager.remoteAttendeeIds)
        setFocus(nil)
        AccessibilityNotification.Announcement(CallFocusLogic.announcement(for: loss, name: lost.name)).post()
    }

    // MARK: Row-layout pieces

    func showsPortraitStrip(height: CGFloat, diameter: CGFloat, compact: Bool, dockZone: CGFloat) -> Bool {
        CallFocusLogic.showsStrip(focused: activeFocus != nil, containerHeight: height,
                                  headerEstimate: compact ? 80 : 140, stripHeight: diameter + 40, dockZone: dockZone)
    }

    func bubbleStrip(diameter: CGFloat, vertical: Bool) -> some View {
        var chip: AnyView?
        if case .camera? = activeFocus, !manager.sharerIsSelf, let tile = manager.contentShareTileId {
            chip = AnyView(CallShareChip(tileId: tile, sharerName: sharerName, manager: manager,
                                         height: 56, onEnlarge: { focusShare() }))
        }
        return CallBubbleRow(items: CallFocusLogic.stripItems(bubbleItems, focused: activeFocus),
                             diameter: diameter, vertical: vertical, manager: manager,
                             onEnlarge: { focusCamera(id: $0.id) }, leading: chip)
    }

    @ViewBuilder
    func contentOrFocus(_ contentArea: CallContentArea) -> some View {
        switch activeFocus {
        case .camera(let id)?:
            if let item = bubbleItems.first(where: { $0.id == id }) {
                CallFocusedCameraView(item: item, manager: manager, onReturn: { returnFromFocus() })
            }
        case .share?:
            if let tile = manager.contentShareTileId {
                CallFocusedShareView(tileId: tile, sharerName: sharerName, manager: manager,
                                     onReturn: { returnFromFocus() })
            }
        case nil:
            contentArea
        }
    }
}

#endif
