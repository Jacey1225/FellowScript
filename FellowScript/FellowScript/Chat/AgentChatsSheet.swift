// AgentChatsSheet.swift — list of every chat between the user and one agent
// (flag `agent_chats`), opened from the top-right Chats button in
// AgentChatView. Ember Glass tokens only; no new palette or type.
//
// Rows come most-recent-first from the server (not re-sorted here). Secondary
// text uses Theme.textSecondary (AA); textMuted/textGoldMuted are avoided for
// information-bearing text. Active chat is marked with a checkmark and the
// .isSelected trait, so it never relies on colour alone.

import SwiftUI

/// Short relative label for a chat's last activity ("Today", "Yesterday",
/// "Oct 4"). Tolerates the server's timezone-less ISO strings and fractional
/// seconds. Returns "" when the input is nil or unparseable.
enum AgentChatDateLabel {
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    static func label(_ s: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let d = parse(s) else { return "" }
        if calendar.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) {
            return "Yesterday"
        }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: d)
    }
}

struct AgentChatsSheet: View {
    let agentName: String
    let chats: [FSAgentChat]
    let activeChatId: String?
    let isLoading: Bool
    let loadError: String?
    var onSelect: (String) -> Void
    var onNewChat: () -> Void
    var onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()
            RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                           center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                           center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                titleRow
                content
            }
        }
        .preferredColorScheme(.dark)
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Chats")
                    .font(.inter(Theme.fontHeading, weight: .bold))
                    .foregroundColor(Theme.parchment)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.gold)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            Text(agentName)
                .font(.inter(Theme.fontXS))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.top, Theme.spacingMD)
        .padding(.bottom, Theme.spacingSM)
    }

    @ViewBuilder
    private var content: some View {
        if chats.isEmpty && isLoading {
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in SkeletonRow(reduceMotion: reduceMotion) }
            }
            .padding(Theme.spacingMD)
            .accessibilityLabel("Loading chats")
            Spacer(minLength: 0)
        } else if chats.isEmpty, loadError != nil {
            VStack(spacing: Theme.spacingSM) {
                Text("Couldn't load chats")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textSecondary)
                PillButton(title: "Try again", action: onRetry)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.spacingXL)
            Spacer(minLength: 0)
        } else if chats.isEmpty {
            VStack(spacing: Theme.spacingSM) {
                Text("No chats yet")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textSecondary)
                PillButton(title: "Start a chat", action: onNewChat)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.spacingXL)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(chats) { chat in
                        ChatRow(chat: chat, isActive: chat.id == activeChatId, reduceMotion: reduceMotion) {
                            onSelect(chat.id)
                        }
                    }
                }
                .padding(Theme.spacingMD)
            }
        }
    }
}

private struct ChatRow: View {
    let chat: FSAgentChat
    let isActive: Bool
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.displayTitle)
                        .font(.inter(Theme.fontBody, weight: .semibold))
                        .foregroundColor(chat.title.isEmpty ? Theme.textSecondary : Theme.parchment)
                        .lineLimit(1)
                    Text(date)
                        .font(.inter(Theme.fontXS))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.gold)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 56)
            .background(Color.white.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusLG)
                    .stroke(isActive ? Theme.borderGold : Theme.borderGoldDim, lineWidth: isActive ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
            .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusLG))
        }
        .buttonStyle(ChatRowPressStyle(reduceMotion: reduceMotion))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(date.isEmpty ? chat.displayTitle : "\(chat.displayTitle), \(date)")
        .accessibilityHint("Opens this chat")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var date: String { AgentChatDateLabel.label(chat.lastMessageAt ?? chat.createdAt) }
}

private struct ChatRowPressStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct SkeletonRow: View {
    let reduceMotion: Bool
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.radiusLG)
            .fill(Color.white.opacity(0.05))
            .frame(height: 56)
            .opacity(dim ? 0.5 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}
