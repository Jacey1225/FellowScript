// Screen-share SENDING UI (task 20261009-session-ui-redesign, step 5,
// design-notes.md section 5): the pinned "Sharing your screen" pill with
// one-tap stop, the fail-soft notice, the "You are sharing" panel that
// replaces the (never rendered) self content tile, and the programmatic
// launcher for the system broadcast picker.

import SwiftUI
import ReplayKit

#if canImport(AmazonChimeSDK)

// MARK: - Pinned indicator + one-tap stop ─────────────────────────────────────

struct ScreenSharePill: View {
    let onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 8) {
                Circle().fill(Color.white).frame(width: 8, height: 8)
                    .opacity(reduceMotion ? 1 : (dim ? 0.35 : 1))
                Text("Sharing your screen")
                    .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(.white)
                Text("Stop")
                    .font(.inter(Theme.fontXS, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.22)))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(Capsule().fill(Color(hex: "#DC3232").opacity(0.90)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop sharing your screen")
        .accessibilityHint("Double tap to stop sharing")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

struct ScreenShareNotice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Theme.bgPage.opacity(0.85)))
            .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
            .accessibilityLabel(text)
    }
}

/// Shown in the content area while MY OWN share is the active content tile.
struct YourShareBody: View {
    let onStop: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 36, weight: .light)).foregroundColor(Theme.goldDim)
            Text("You are sharing your screen")
                .font(.interScaled(Theme.fontSM, relativeTo: .subheadline))
                .foregroundColor(Theme.textPrimary.opacity(0.85))
                .multilineTextAlignment(.center)
            Button(action: onStop) {
                Text("Stop sharing")
                    .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(.white)
                    .frame(maxWidth: 260, minHeight: 52)
                    .background(Capsule().fill(Theme.error.opacity(0.85)))
            }
            .accessibilityLabel("Stop sharing your screen")
        }
        .padding(.horizontal, 24)
    }
}

/// Compact stop control for MinimizedCallBar; renders nothing unless sharing.
struct MinimizedShareStopButton: View {
    @ObservedObject var manager: ChimeCallManager

    var body: some View {
        if manager.screenShare.showsIndicator {
            Button { manager.stopScreenShare() } label: {
                HStack(spacing: 5) {
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                    Text("Sharing \u{2022} Stop")
                        .font(.inter(Theme.fontXXS, weight: .semibold)).foregroundColor(.white)
                }
                .padding(.horizontal, 10).frame(minHeight: 34)
                .background(Capsule().fill(Color(hex: "#DC3232").opacity(0.90)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop sharing your screen")
        }
    }
}

// MARK: - System broadcast picker launcher ────────────────────────────────────

/// Keeps an RPSystemBroadcastPickerView in the hierarchy (it must exist to show
/// the system sheet) and "taps" its inner button whenever `trigger` changes.
/// Apple offers no public method to present the picker, so tapping the inner
/// button is the standard approach. The picker is preselected to our upload
/// extension and the mic toggle is hidden: call audio stays in the app.
struct BroadcastPickerLauncher: UIViewRepresentable {
    let trigger: Int

    static var extensionBundleId: String? {
        Bundle.main.bundleIdentifier.map { $0 + ScreenShareBridge.extensionBundleSuffix }
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = Self.extensionBundleId
        picker.showsMicrophoneButton = false
        picker.alpha = 0.01
        picker.isAccessibilityElement = false
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger
        guard trigger > 0 else { return }
        DispatchQueue.main.async {
            picker.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastTrigger = 0 }
}

#endif
