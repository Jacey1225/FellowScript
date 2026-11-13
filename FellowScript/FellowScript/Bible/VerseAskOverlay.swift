// VerseAskOverlay.swift -- task 20261112-verse-ask-ai (step 5).
// The pill input + response panel for per-verse "Ask AI". Hard rule: this only
// OVERLAYS the reader. It is a sibling layer above the page, positioned with
// absolute offsets from the verse's captured frame, so it never reflows text,
// never calls scrollTo, and never changes scroll offset when it opens, grows
// with the answer, or closes. Placement comes from VerseAskPlacement (pure).
//
// Tokens: the same glass as BibleNavDropdown (ultraThinMaterial + panelGlassTint,
// borderGray hairline, topEdgeHighlight), Capsule pill, Theme.radiusLG panel,
// gold send control with ink glyph, Theme fonts. Reduce Transparency -> solid;
// Reduce Motion -> opacity-only.

import SwiftUI
import UIKit
import Combine

// ── Glass surface (one definition for the pill and the panel) ────────────────
private struct VerseAskGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(Theme.widgetBg)
                } else {
                    shape.fill(Theme.panelGlassTint)
                    shape.fill(.ultraThinMaterial)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.borderGray, lineWidth: 1))
            .topEdgeHighlight(shape)
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    }
}

private extension View {
    func verseAskGlass<S: InsettableShape>(_ shape: S) -> some View { modifier(VerseAskGlass(shape: shape)) }
}

// ── Keyboard top (global y). Read only by this overlay; the page ignores it. ──
@MainActor
private final class KeyboardTopObserver: ObservableObject {
    @Published var top: CGFloat?
    private var token: NSObjectProtocol?
    init() {
        token = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenH = UIScreen.main.bounds.height
            MainActor.assumeIsolated { self?.top = frame.minY >= screenH - 1 ? nil : frame.minY }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

struct VerseAskOverlay: View {
    @ObservedObject var vm: VerseAskViewModel
    /// Window-space frame of the verse row, captured when "Ask AI" was chosen.
    let verseFrame: CGRect
    let onClose: () -> Void

    @StateObject private var keyboard = KeyboardTopObserver()
    @FocusState private var inputFocused: Bool
    @Environment(\.floatingTabBarReserve) private var tabBarReserve
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pillHeight: CGFloat = 44
    @State private var panelHeight: CGFloat = 0
    @State private var baselineHost: CGRect?

    private var fade: Animation { reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.18) }

    var body: some View {
        GeometryReader { geo in
            let host = geo.frame(in: .global)
            let viewportTop = host.minY + geo.safeAreaInsets.top
            let viewportBottom = host.maxY - geo.safeAreaInsets.bottom
            let col = VerseAskPlacement.column(columnLeft: verseFrame.minX - host.minX + Theme.spacingMD,
                                               columnWidth: verseFrame.width - Theme.spacingMD * 2,
                                               viewportWidth: host.width)
            let p = VerseAskPlacement.place(verseTop: verseFrame.minY, viewportTop: viewportTop,
                                            viewportBottom: viewportBottom, keyboardTop: keyboard.top, bottomObstruction: tabBarReserve,
                                            pillHeight: pillHeight, panelHeight: panelHeight)
            ZStack(alignment: .topLeading) {
                // Invisible dismiss layer: a tap or drag outside closes. It adds
                // no visual and no layout; a dismissal never scrolls the page.
                Color.black.opacity(0.0001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .gesture(DragGesture(minimumDistance: 12).onChanged { _ in onClose() })
                    .accessibilityHidden(true)

                pill
                    .frame(width: col.width)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pillHeight = $0 }
                    .offset(x: col.left, y: p.pillTop - host.minY)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))

                if vm.hasPanel {
                    panel(maxHeight: p.panelMaxHeight)
                        .frame(width: col.width)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                        .offset(x: col.left, y: p.panelTop - host.minY)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(fade, value: vm.hasPanel)
            .onChange(of: host, initial: true) { _, now in
                // Rotation / horizontal resize: the captured verse frame is stale.
                // Height-only changes (keyboard focus on iPad) are tolerated.
                guard let base = baselineHost else { baselineHost = now; return }
                if VerseAskPlacement.shouldClose(baseline: base, current: now) { onClose() }
            }
        }
        .ignoresSafeArea(.keyboard)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask AI about \(vm.reference)")
        .onKeyPress(.escape) { onClose(); return .handled }
        .accessibilityAction(.escape) { onClose() }
        .task {
            // One beat so the verse context menu has finished dismissing.
            try? await Task.sleep(nanoseconds: 350_000_000)
            inputFocused = true
        }
        .onChange(of: vm.phase) { _, phase in announce(phase) }
    }

    // ── Pill ─────────────────────────────────────────────────────────────────
    private var pill: some View {
        HStack(spacing: Theme.spacingSM) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.gold)
                .accessibilityHidden(true)

            TextField("", text: $vm.draft,
                      prompt: Text("Ask about this verse").foregroundColor(Theme.textSecondary),
                      axis: .vertical)
                .font(.interScaled(Theme.fontBody))
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.gold)
                .lineLimit(1...3)
                .submitLabel(.send)
                .focused($inputFocused)
                .onChange(of: vm.draft) { _, new in
                    // Return sends (the pill never takes a newline).
                    if new.contains("\n") {
                        vm.draft = new.replacingOccurrences(of: "\n", with: " ")
                        vm.send()
                    } else if new.count > VerseAskViewModel.maxQuestionChars {
                        vm.draft = String(new.prefix(VerseAskViewModel.maxQuestionChars))
                    }
                }
                .onSubmit { vm.send() }
                .accessibilityLabel("Question about \(vm.reference)")

            if vm.showsCounter {
                Text("\(vm.draft.count)/\(VerseAskViewModel.maxQuestionChars)")
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(vm.atLimit ? Theme.error : Theme.textSecondary)
                    .accessibilityHidden(true)
            }

            sendButton
        }
        .padding(.leading, Theme.spacingMD)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .verseAskGlass(Capsule())
    }

    private var sendButton: some View {
        Button {
            vm.send()
        } label: {
            ZStack {
                Circle().fill(Theme.gold.opacity(vm.canSend || vm.isLoading ? 1 : 0.25))
                if vm.isLoading {
                    ProgressView().tint(Theme.ink).controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.ink.opacity(vm.canSend ? 1 : 0.5))
                }
            }
            .frame(width: 36, height: 36)
            .frame(width: 44, height: 44)           // 44pt hit area
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!vm.canSend)
        .padding(.vertical, -4)
        .accessibilityLabel("Send question")
        .accessibilityHint(vm.isLoading ? "Waiting for an answer" : "")
    }

    // ── Response panel ───────────────────────────────────────────────────────
    private func panel(maxHeight: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous)
        return VStack(alignment: .leading, spacing: Theme.spacingSM) {
            panelHeader
            ScrollView(.vertical, showsIndicators: false) {
                panelBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: max(0, maxHeight - 112))   // header + footer allowance; the panel scrolls, never clips
            .fixedSize(horizontal: false, vertical: true)
            if vm.answerText != nil {
                Rectangle().fill(Theme.borderGoldFaint).frame(height: 1).accessibilityHidden(true)
                copyButton
            }
        }
        .padding(Theme.spacingMD)
        .frame(maxHeight: maxHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .verseAskGlass(shape)
    }

    private var panelHeader: some View {
        HStack(spacing: Theme.spacingSM) {
            Text("ASK AI")
                .font(.inter(Theme.fontXS, weight: .semibold))
                .tracking(1.4)
                .foregroundColor(Theme.gold.opacity(0.7))
            Text(vm.reference)
                .font(.inter(Theme.fontXS))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, -Theme.spacingSM)
            .accessibilityLabel("Close Ask AI")
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private var panelBody: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            switch vm.phase {
            case .idle:
                EmptyView()
            case .loading(let q):
                questionChip(q)
                HStack(spacing: Theme.spacingSM) {
                    ProgressView().tint(Theme.gold)
                    Text("Thinking")
                        .font(.interScaled(Theme.fontSM))
                        .foregroundColor(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Thinking")
            case .answer(let q, let text):
                questionChip(q)
                HStack(alignment: .top, spacing: Theme.spacingSM) {
                    Rectangle().fill(Theme.goldDim).frame(width: 2)
                        .accessibilityHidden(true)
                    // Plain text only: the reply is never parsed as markup.
                    Text(verbatim: text)
                        .font(.interScaled(Theme.fontBody))
                        .lineSpacing(4)
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            case .failed(let q, let message):
                questionChip(q)
                HStack(alignment: .top, spacing: Theme.spacingSM) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.error)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.interScaled(Theme.fontSM))
                        .foregroundColor(Theme.textPrimary.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Try again") { vm.retry() }
                    .font(.inter(Theme.fontSM, weight: .semibold))
                    .foregroundColor(Theme.gold)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityHint("Sends your question again")
            }
        }
        .animation(fade, value: vm.phase)
    }

    private func questionChip(_ q: String) -> some View {
        Text(verbatim: q)
            .font(.interScaled(Theme.fontSM))
            .foregroundColor(Theme.textPrimary.opacity(0.85))
            .lineLimit(2)
            .accessibilityLabel("You asked: \(q)")
    }

    private var copyButton: some View {
        Button { vm.copyAnswer() } label: {
            HStack(spacing: 6) {
                Image(systemName: vm.copied ? "checkmark" : "doc.on.doc")
                Text(vm.copied ? "Copied" : "Copy")
            }
            .font(.inter(Theme.fontSM, weight: .semibold))
            .foregroundColor(Theme.gold)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(vm.copied ? "Answer copied" : "Copy answer")
    }

    private func announce(_ phase: VerseAskViewModel.Phase) {
        switch phase {
        case .answer: AccessibilityNotification.Announcement("Answer ready").post()
        case .failed(_, let m): AccessibilityNotification.Announcement(m).post()
        default: break
        }
    }
}
