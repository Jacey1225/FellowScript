// AttachPinnedChip.swift -- task 20261029-dm-pinned-chip. The "Pinned" chip DMs show in the
// "+" attach row (groups keep theirs in GroupInfoChipRow). Count text and accessibility
// strings come from FSPinnedListCopy; the iPad-embedded popover anchors on the chip itself.

import SwiftUI

struct AttachPinnedChip {
    let pinCount: Int
    let action: () -> Void
    /// iPad workspace: Pinned opens as a popover anchored to the chip (phone uses a sheet).
    let popoverPresented: Binding<Bool>
    let popoverContent: () -> AnyView

    /// "Pinned" or "Pinned  3" (same text the group chip shows).
    var label: String {
        guard let badge = FSPinnedListCopy.badgeText(count: pinCount) else { return FSPinnedListCopy.title }
        return "\(FSPinnedListCopy.title)  \(badge)"
    }
}

struct AttachPinnedChipButton: View {
    let chip: AttachPinnedChip
    var compact: Bool = false

    var body: some View {
        Button(action: chip.action) { ChipIconLabel(title: chip.label, systemIcon: "pin", compact: compact) }
            .buttonStyle(ChipButtonStyle(compact: compact, hasIcon: true))
            .popover(isPresented: chip.popoverPresented, arrowEdge: .bottom) {
                chip.popoverContent().presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel("Pinned messages")
            .accessibilityValue(FSPinnedListCopy.buttonValue(count: chip.pinCount) ?? "")
            .accessibilityHint("Opens the list of pinned messages")
    }
}
