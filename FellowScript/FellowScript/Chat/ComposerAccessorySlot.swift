// ComposerAccessorySlot.swift -- task 20261024-chat-chips-bottom. The slot directly above
// the composer's text row. In groups it always holds a fixed-height row: the group info
// chips, or (while the plus is toggled) the attach buttons, cross-swapped with a short
// fade + 12pt slide. In DMs and thread view there are no chips: the slot is 0pt tall until
// the attach buttons open. Both layers stay mounted and are driven by the single `attachMode`
// Bool, so the swap is interruptible (SwiftUI retargets the in-flight animation).
// Also holds the bottom edge fade for the message list and the attach-mode coordination.

import SwiftUI

enum ComposerAccessoryMotion {
    /// Drives the offset / height / plus rotation (applied through withAnimation).
    static let swap = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Opacity leads the movement so the two rows never both read at full strength.
    static let fade = Animation.easeOut(duration: 0.2)
    static let slide: CGFloat = 12
    static let attachStagger: Double = 0.03
}

struct ComposerAccessorySlot<Chips: View>: View {
    /// Groups (not thread view): the chip row owns the slot and its height is always reserved.
    let showsChips: Bool
    let attachMode: Bool
    var compact: Bool = false
    var onPickPhotoVideo: () -> Void
    var onPickFile: () -> Void
    var onPickGif: () -> Void
    /// DMs: the Pinned chip for the attach row (nil elsewhere).
    var pinned: AttachPinnedChip? = nil
    @ViewBuilder var chips: () -> Chips

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var chipHeight: CGFloat = 38

    /// 4pt top + 44pt chip hit area; grows with Dynamic Type.
    private var slotHeight: CGFloat { max(48, chipHeight + 10) }
    private var height: CGFloat { showsChips || attachMode ? slotHeight : 0 }
    private var slide: CGFloat { reduceMotion ? 0 : ComposerAccessoryMotion.slide }
    private var fade: Animation { reduceMotion ? .easeInOut(duration: 0.2) : ComposerAccessoryMotion.fade }

    var body: some View {
        ZStack(alignment: .bottom) {
            if showsChips {
                chips()
                    .opacity(attachMode ? 0 : 1)
                    .animation(fade, value: attachMode)
                    .offset(y: attachMode ? -slide : 0)
                    .allowsHitTesting(!attachMode)
                    .accessibilityHidden(attachMode)
            }
            AttachPickerRow(compact: compact, onPickPhotoVideo: onPickPhotoVideo,
                            onPickFile: onPickFile, onPickGif: onPickGif, pinned: pinned)
                .opacity(attachMode ? 1 : 0)
                .animation(fade, value: attachMode)
                .offset(y: attachMode ? 0 : slide)
                .allowsHitTesting(attachMode)
                .accessibilityHidden(!attachMode)
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityIdentifier("composer-accessory-slot")
    }
}

// ── Bottom edge fade (replaces the top chipRowEdgeAlphaMask) ────────────────
// The message list is alpha-masked so bubbles reach zero alpha exactly at the bottom of the
// list (the top edge of the composer / chip row), ramping to opaque over 36pt. The list
// frame already ends at the composer inset (and follows the keyboard), so the ramp is simply
// the last 36pt of that frame. Never append a clear block of safeAreaInsets.bottom: inside
// the mask that inset is the composer height, which hid the newest messages.
// Masks never affect hit testing.
struct BottomEdgeAlphaMask: View {
    static let rampHeight: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.black).ignoresSafeArea(edges: .top)
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.5), location: 0.4),
                .init(color: .black.opacity(0.12), location: 0.7),
                .init(color: .black.opacity(0.0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: Self.rampHeight)
        }
    }
}

extension View {
    /// Groups: fade the bottom edge of the message list. Otherwise the old opaque mask.
    func bottomEdgeFade(_ enabled: Bool) -> some View {
        mask {
            if enabled {
                BottomEdgeAlphaMask()
            } else {
                Rectangle().fill(Color.black).ignoresSafeArea()
            }
        }
    }

    /// While the attach buttons are open, a tap on the covered area (message list / header)
    /// collapses them. Simultaneous, so buttons and the keyboard-dismiss tap still work.
    func collapsesAttachOnTap(_ active: Bool, collapse: @escaping () -> Void) -> some View {
        simultaneousGesture(TapGesture().onEnded { collapse() }, including: active ? .all : .none)
    }
}

/// Attach mode follows the rest of the composer: focusing the text field or opening a chip
/// panel returns the slot to the chips (no animation fight with the keyboard); a thread
/// opening resets it.
struct ComposerAttachCoordination: ViewModifier {
    @Binding var attachMode: Bool
    var composerFocused: FocusState<Bool>.Binding
    let category: GroupInfoCategory?
    let isThreadOpen: Bool
    let collapse: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: composerFocused.wrappedValue) { _, focused in if focused && attachMode { collapse() } }
            .onChange(of: category) { _, c in if c != nil && attachMode { collapse() } }
            .onChange(of: isThreadOpen) { _, _ in if attachMode { collapse() } }
    }
}
