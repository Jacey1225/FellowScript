// MessageGroupRow.swift
// Ported from the standalone ChatSchedule prototype
// (Sources/ChatSchedule/Components/MessageGroupRow.swift), re-expressed on
// Theme.swift tokens. The prototype's `MessageGroupRow` rendered a mock
// `MessageGroup` model (Models/ChatModels.swift) that was never ported —
// `MessageDisplayGroup` below is a presentation-only grouping of the real
// `FSMessage` array (same pattern as Dashboard/DashboardComponents.swift's
// `GroupSummary`/`QuickAction`: a view-model struct, not a domain model).
// No new persisted/network data — purely a client-side grouping of messages
// that are already loaded by ChatThreadViewModel.
//
// DEPENDENCY: Theme.swift, Models.swift (FSMessage)

import SwiftUI

/// One Slack-style grouped row in the thread: avatar + sender name/time
/// meta, then one or more stacked message bubbles from the same sender.
/// Mirrors chat.html's `.group`/`.group.out`.
struct MessageDisplayGroup: Identifiable {
    let id:            String   // first message's id — stable across re-renders
    let senderInitial: String
    let senderName:    String
    let timeLabel:     String
    let isOutgoing:    Bool
    let messages:      [FSMessage]
}

extension MessageDisplayGroup {
    /// Groups consecutive messages from the same sender (same `mine` value
    /// and, for received messages, the same `sender` id) into display groups,
    /// preserving order. Pure transformation of already-loaded real data —
    /// no fabrication.
    static func grouped(from messages: [FSMessage], me: FSUser?) -> [MessageDisplayGroup] {
        var groups: [MessageDisplayGroup] = []
        for message in messages {
            if let lastIndex = groups.indices.last,
               groups[lastIndex].isOutgoing == message.mine,
               (message.mine || groups[lastIndex].messages.last?.sender == message.sender) {
                groups[lastIndex] = MessageDisplayGroup(
                    id:            groups[lastIndex].id,
                    senderInitial: groups[lastIndex].senderInitial,
                    senderName:    groups[lastIndex].senderName,
                    timeLabel:     groups[lastIndex].timeLabel,
                    isOutgoing:    groups[lastIndex].isOutgoing,
                    messages:      groups[lastIndex].messages + [message]
                )
            } else {
                let name = message.mine ? "You" : (message.sender.isEmpty ? "Them" : message.sender)
                groups.append(MessageDisplayGroup(
                    id:            message.id,
                    senderInitial: message.mine ? (me?.initials ?? "Y") : String(name.prefix(1)).uppercased(),
                    senderName:    name,
                    timeLabel:     message.formattedTime,
                    isOutgoing:    message.mine,
                    messages:      [message]
                ))
            }
        }
        return groups
    }
}

struct MessageGroupRow: View {
    let group: MessageDisplayGroup

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if group.isOutgoing { Spacer(minLength: 40) }

            if !group.isOutgoing {
                avatar
            }

            VStack(alignment: group.isOutgoing ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if group.isOutgoing { Spacer(minLength: 0) }
                    Text(group.senderName)
                        .font(.lora(Theme.fontSM, weight: .bold))
                        .foregroundColor(Theme.parchment)
                    if !group.timeLabel.isEmpty {
                        Text(group.timeLabel)
                            .font(.lora(Theme.fontXXS))
                            .foregroundColor(Theme.textSecondary)
                    }
                    if !group.isOutgoing { Spacer(minLength: 0) }
                }

                ForEach(group.messages) { message in
                    Text(message.text)
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                        .multilineTextAlignment(group.isOutgoing ? .trailing : .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            group.isOutgoing
                                ? Theme.gold.opacity(0.10)
                                : Color.white.opacity(0.03)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius)
                                .stroke(group.isOutgoing ? Theme.borderGoldDim : Theme.borderGoldFaint, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        .accessibilityLabel("\(group.senderName): \(message.text)")
                }
            }

            if group.isOutgoing {
                avatar
            } else {
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingSM)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(group.isOutgoing ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.gold.opacity(0.18)))
            Circle()
                .stroke(Theme.borderGoldDim, lineWidth: 1)
            Text(group.senderInitial)
                .font(.lora(Theme.fontXS, weight: .bold))
                .foregroundColor(group.isOutgoing ? Theme.ink : Theme.gold)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}
