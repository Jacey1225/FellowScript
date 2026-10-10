// Session call screen building blocks (task 20261009-session-ui-redesign,
// design-notes.md): the End + Interactions dock, the upward submenu, the
// participant bubble row, and the added-content area (prompts panel / incoming
// screen share). Kept as standalone views fed by value inputs so ChimeCallView
// itself only owns state and layout selection. Pure logic lives in
// CallSessionUIState.swift.

import SwiftUI

#if canImport(AmazonChimeSDK)

// MARK: - Dock (End + Interactions) ───────────────────────────────────────────

struct CallDock: View {
    let isMuted: Bool
    let isExpanded: Bool
    let buttonSize: CGFloat
    let onEnd: () -> Void
    let onToggleMenu: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let gap: CGFloat = 20
    static let padding: CGFloat = 16
    static func width(buttonSize: CGFloat) -> CGFloat { buttonSize * 2 + gap + padding * 2 }

    var body: some View {
        HStack(spacing: Self.gap) {
            Button(action: onEnd) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(hex: "#DC3232"), Color(hex: "#B02525")],
                                             startPoint: .top, endPoint: .bottom))
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: buttonSize * 0.40)).foregroundColor(.white)
                }
                .frame(width: buttonSize, height: buttonSize)
            }
            .accessibilityLabel("End call")
            .accessibilityHint("Leaves the session")

            Button(action: onToggleMenu) {
                ZStack {
                    Circle().fill(Theme.goldDim.opacity(0.35))
                    Circle().stroke(Theme.borderGold, lineWidth: 1.5)
                    Image(systemName: isExpanded ? "xmark" : "ellipsis")
                        .font(.system(size: buttonSize * 0.36, weight: .semibold))
                        .foregroundColor(Theme.goldLight)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .motionAwareAnimation(.spring(response: 0.35, dampingFraction: 0.82),
                                              value: isExpanded, reduceMotion: reduceMotion)
                }
                .frame(width: buttonSize, height: buttonSize)
                .overlay(alignment: .topTrailing) {
                    if isMuted {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Theme.error))
                            .overlay(Circle().stroke(Theme.bgPage, lineWidth: 1.5))
                            .offset(x: 2, y: -2)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityLabel("Session options")
            .accessibilityValue((isExpanded ? "Expanded" : "Collapsed") + (isMuted ? ", Muted" : ""))
            .accessibilityHint("Double tap to show or hide options")
            .accessibilityAddTraits(.isButton)
        }
        .padding(Self.padding)
        .background(Capsule().fill(Theme.bgPage.opacity(0.72)))
        .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Submenu ─────────────────────────────────────────────────────────────

struct CallMenuRow: Identifiable {
    let id: String
    let icon: String
    let title: String
    var stateWord: String? = nil
    var caption: String? = nil
    var tint: Color = Theme.goldDim.opacity(0.35)
    var enabled = true
    var a11yLabel: String
    var a11yValue: String? = nil
    var a11yHint: String? = nil
    let action: () -> Void
}

struct CallSubmenu: View {
    /// Top to bottom; the row nearest the dock (thumb) is last.
    let rows: [CallMenuRow]
    let isCompact: Bool
    let maxHeight: CGFloat
    let onEscape: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            stack
            ScrollView(showsIndicators: false) { stack }
        }
        .frame(maxHeight: maxHeight)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onEscape)
        .onAppear {
            AccessibilityNotification.LayoutChanged().post()
        }
    }

    private var stack: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, index: index)
            }
        }
        .padding(.vertical, 2)
    }

    private func rowView(_ row: CallMenuRow, index: Int) -> some View {
        Button(action: row.action) {
            HStack(spacing: 10) {
                Image(systemName: row.icon)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.title)
                            .font(.interScaled(Theme.fontSM, weight: .semibold, relativeTo: .subheadline))
                            .foregroundColor(Theme.textPrimary).lineLimit(2)
                        if let word = row.stateWord {
                            Text(word)
                                .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                                .foregroundColor(Theme.textPrimary.opacity(0.85)).lineLimit(1)
                        }
                    }
                    if let caption = row.caption {
                        Text(caption)
                            .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                            .foregroundColor(Theme.textPrimary.opacity(0.85)).lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(minHeight: isCompact ? 48 : 56)
            .background(Capsule().fill(Theme.bgPage.opacity(0.72)))
            .background(Capsule().fill(row.tint))
            .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
            .opacity(row.enabled ? 1 : 0.55)
        }
        .disabled(!row.enabled)
        .accessibilityLabel(row.a11yLabel)
        .accessibilityValue(row.a11yValue ?? "")
        .accessibilityHint(row.a11yHint ?? "")
        // Rows rise in with a short stagger (opacity only under Reduce Motion).
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || reduceMotion ? 1 : 0.92)
        .onAppear {
            let delay = reduceMotion ? 0 : Double(rows.count - 1 - index) * 0.03
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.15)) { shown = true }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82).delay(delay)) { shown = true }
            }
        }
    }
}

// MARK: - Bubbles ─────────────────────────────────────────────────────────────

struct CallBubbleView: View {
    let item: CallBubbleItem
    let diameter: CGFloat
    let manager: ChimeCallManager
    /// Row layout puts the name in the cell above the circle; field layout
    /// floats it over the circle's top edge. Both render it above the circle.
    var floatingName = false

    var body: some View {
        VStack(spacing: 4) {
            nameLabel
            circle
        }
        .frame(width: diameter + 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
    }

    @ViewBuilder private var nameLabel: some View {
        if let name = item.name {
            Text(name)
                .font(.interScaled(Theme.fontXS, weight: .semibold, relativeTo: .caption))
                .foregroundColor(Theme.textPrimary).lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Theme.bgPage.opacity(0.72)))
                .frame(maxWidth: diameter + 12)
        } else {
            // Keep rows aligned when a name is unresolved.
            Color.clear.frame(height: 18)
        }
    }

    private var circle: some View {
        ZStack {
            switch item.kind {
            case .local(let tile?):
                ChimeVideoTileView(tileId: tile, manager: manager)
            case .remoteVideo(let tile):
                ChimeVideoTileView(tileId: tile, manager: manager)
            default:
                Circle().fill(Theme.goldDim.opacity(0.4))
                if let initial = item.initial {
                    Text(initial).font(.playfair(diameter * 0.39)).foregroundColor(Theme.goldLight)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: diameter * 0.40)).foregroundColor(Theme.goldLight.opacity(0.85))
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(isSelf ? Theme.goldLight : Theme.gold.opacity(0.38), lineWidth: isSelf ? 2 : 1))
        .shadow(color: .black.opacity(0.45), radius: 8)
    }

    private var isSelf: Bool { if case .local = item.kind { return true } else { return false } }
}

struct CallBubbleRow: View {
    let items: [CallBubbleItem]
    let diameter: CGFloat
    let vertical: Bool
    let manager: ChimeCallManager

    var body: some View {
        ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
            if vertical {
                LazyVStack(spacing: 12) { cells }.padding(.vertical, 4)
            } else {
                LazyHStack(alignment: .top, spacing: 12) { cells }
                    .padding(.horizontal, 16)
                    .scrollTargetLayout()
            }
        }
        .scrollTargetBehavior(.viewAligned)
    }

    @ViewBuilder private var cells: some View {
        ForEach(items) { CallBubbleView(item: $0, diameter: diameter, manager: manager) }
    }
}

// MARK: - Added-content area ──────────────────────────────────────────────────

struct CallContentArea: View {
    let kind: CallContentKind
    let prompts: [String]
    let shareTileId: Int?
    let sharerName: String?
    let manager: ChimeCallManager
    var sharerIsSelf: Bool = false
    var onStopSharing: () -> Void = {}
    let isCompact: Bool
    let onClosePrompts: () -> Void

    @State private var emphasized: Set<Int> = []   // local only, never synced

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch kind {
                case .share:   shareBody
                case .prompts: promptsBody
                case .none:    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous).fill(Theme.bgPage.opacity(0.80)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous).stroke(Theme.borderGold, lineWidth: 1))
        .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous))
    }

    private var header: some View {
        HStack {
            Text(kind == .share ? (sharerIsSelf ? "You are sharing" : "\(sharerName ?? "Someone") is sharing") : "Discussion Prompts")
                .font(.playfair(Theme.fontHeading)).foregroundColor(Theme.goldLight)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if kind == .prompts {
                Button(action: onClosePrompts) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close discussion prompts")
            }
        }
        .padding(.leading, 16).padding(.trailing, kind == .prompts ? 4 : 16)
        .frame(minHeight: 44)
    }

    @ViewBuilder private var shareBody: some View {
        if sharerIsSelf {
            // Never render my own share back at me (hall of mirrors).
            YourShareBody(onStop: onStopSharing)
        } else if let tile = shareTileId {
            ChimeVideoTileView(tileId: tile, manager: manager, contentMode: .scaleAspectFit)
                .background(Color.black)
                .accessibilityLabel("Shared screen")
        }
    }

    @ViewBuilder private var promptsBody: some View {
        if prompts.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 36, weight: .light)).foregroundColor(Theme.goldDim)
                Text("No discussion prompts for this session")
                    .font(.interScaled(Theme.fontSM, relativeTo: .subheadline))
                    .foregroundColor(Theme.textPrimary.opacity(0.85))
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(prompts.enumerated()), id: \.offset) { index, text in
                        promptCard(index: index, text: text)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    private func promptCard(index: Int, text: String) -> some View {
        let on = emphasized.contains(index)
        return Button {
            if on { emphasized.remove(index) } else { emphasized.insert(index) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text("\(index + 1)")
                    .font(.inter(Theme.fontXS, weight: .bold)).foregroundColor(Theme.bgPage)
                    .frame(width: 24, height: 24).background(Circle().fill(Theme.gold))
                Text(text)
                    .font(.interScaled(isCompact ? Theme.fontSM : Theme.fontBody,
                                       weight: on ? .semibold : .regular, relativeTo: .body))
                    .foregroundColor(Theme.textPrimary).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).fill(Theme.goldDim.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous)
                .stroke(on ? Theme.goldLight : Theme.borderGoldDim, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Prompt \(index + 1): \(text)")
        .accessibilityValue(on ? "Emphasized" : "")
        .accessibilityHint("Double tap to emphasize on your screen")
    }
}

#endif
