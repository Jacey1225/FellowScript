// MentionViews.swift -- task 20261017-chat-mentions (iOS).
//
// Small SwiftUI pieces for chat @mentions, kept out of ChatThreadView so its
// (already long) modifier chains do not grow and trip the type-checker:
//   - MentionText: message text with the mention runs in bold (Inter Bold).
//   - MentionPickerView: the compact member list shown above the composer.
//   - MentionComposerSupport: the composer's edit-sync + member-load hooks as
//     one ViewModifier.
// All logic (ranges, filtering, edits) lives in Models/FSMention.swift.

import SwiftUI
import UIKit

// ── Rendering ─────────────────────────────────────────────────────────────────

/// Drop-in for `Text(message.text)`: identical output when the message has no
/// (valid) mentions, otherwise the mention runs are bold. The bold run uses the
/// Inter Bold face (not synthetic bold) and the same colour as the bubble
/// text; the "@" stays in the text so bold is never the only cue. Callers keep
/// applying `.font(.inter(Theme.fontBody))` etc. to this view.
struct MentionText: View {
    let text: String
    let mentions: [FSMention]?

    var body: some View {
        let runs = MentionRender.runs(text: text, mentions: mentions)
        if runs.contains(where: { $0.isMention }) {
            // Task 20261030-profile-everywhere: tappable runs open that user's profile.
            Text(Self.attributed(runs, linking: MentionRender.validRanges(mentions, in: text)))
                .mentionProfileOpener()
        } else {
            Text(text)
        }
    }

    static func attributed(_ runs: [MentionRender.Run], linking ranges: [FSMention] = []) -> AttributedString {
        var out = AttributedString()
        var mentionIndex = 0
        for run in runs {
            var piece = AttributedString(run.text)
            if run.isMention {
                piece.font = .inter(Theme.fontBody, weight: .bold)
                // Mention runs map 1:1, in order, onto the valid ranges.
                if mentionIndex < ranges.count {
                    piece.link = MentionProfileLink.url(for: ranges[mentionIndex], shownName: run.text)
                }
                mentionIndex += 1
            }
            out.append(piece)
        }
        return out
    }
}

// ── Picker ────────────────────────────────────────────────────────────────────

private struct MentionPickerSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.white.opacity(0.05))
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.borderGoldDim).frame(height: 1)
            }
    }
}

private struct MentionAvatar: View {
    let name: String
    var body: some View {
        ZStack {
            Circle().fill(Theme.gold.opacity(0.18))
            Circle().stroke(Theme.borderGoldDim, lineWidth: 1)
            Text(String(name.prefix(1)).uppercased())
                .font(.inter(Theme.fontXS, weight: .bold))
                .foregroundColor(Theme.gold)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

private struct MentionRow: View {
    let candidate: FSMentionCandidate
    let minHeight: CGFloat
    let onPick: (FSMentionCandidate) -> Void

    var body: some View {
        Button { onPick(candidate) } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel("Mention \(candidate.username)")
            .accessibilityAddTraits(.isButton)
    }

    private var label: some View {
        HStack(spacing: Theme.spacingSM) {
            MentionAvatar(name: candidate.username)
            Text(candidate.username)
                .font(.inter(Theme.fontBody))
                .foregroundColor(Theme.parchment)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.spacingMD)
        .frame(minHeight: minHeight)
        .contentShape(Rectangle())
    }
}

/// Compact member list inserted in the composer stack above the text field.
/// `rows` is already filtered; at most `MentionDraft.maxVisibleRows` rows are
/// visible, more scroll. An empty `rows` shows the single "No one matches" line.
struct MentionPickerView: View {
    let rows: [FSMentionCandidate]
    let onPick: (FSMentionCandidate) -> Void

    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44

    var body: some View {
        content
            .modifier(MentionPickerSurface())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mention a member")
            .onAppear { announceOpen() }
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            Text("No one matches")
                .font(.inter(Theme.fontXS))
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: rowHeight)
                .padding(.horizontal, Theme.spacingMD)
        } else {
            list
        }
    }

    private var list: some View {
        let visible = min(rows.count, MentionDraft.maxVisibleRows)
        let height = min(CGFloat(visible) * rowHeight, 320)
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    MentionRow(candidate: row, minHeight: rowHeight, onPick: onPick)
                    if row.id != rows.last?.id {
                        Rectangle().fill(Theme.borderGoldDim).frame(height: 0.5)
                    }
                }
            }
        }
        .frame(height: height)
    }

    private func announceOpen() {
        let message = rows.isEmpty ? "No one matches" : "\(rows.count) members match"
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

// ── Composer hooks ────────────────────────────────────────────────────────────

/// Keeps the recorded mentions aligned with the composer text (see
/// MentionDraft.applyEdit) and loads the mentionable members. `lastText` is the
/// text the draft was last reconciled with, so the follow-up change caused by
/// this modifier rewriting `text` is recognised and ignored.
struct MentionComposerSupport: ViewModifier {
    @Binding var text: String
    @Binding var draft: MentionDraft
    @Binding var lastText: String
    let loadKey: String
    let load: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: text) { _, new in reconcile(new) }
            .task(id: loadKey) { await load() }
    }

    private func reconcile(_ new: String) {
        guard new != lastText else { return }
        let adjusted = draft.applyEdit(oldText: lastText, newText: new)
        lastText = adjusted
        if adjusted != new { text = adjusted }
    }
}
