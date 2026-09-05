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
// VISUAL: Ember Glass restyle (task 20260827-ember-glass-chat-rewrite, design
// gate §1/§5/§10/§13) — bubbles snap to Theme.radiusLG (rounder), sent/
// received fill opacity is turned up for stronger differentiation, bubbles
// share the top-edge-hairline elevation language (no shadow), and real
// day-boundary detection (Added item 5) is added below via
// `ChatThreadRow`/`DayDividerRow` so ChatThreadView can interleave labeled
// day dividers between MessageDisplayGroups — not merely a cosmetic divider
// restyle.
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
    // Parsed send time of the group's first message, used purely for
    // day-boundary detection (§13) — not displayed directly (timeLabel is
    // the user-facing short time string already shown next to the name).
    let date:          Date?
    let messages:      [FSMessage]
    // Task 20260905-profile-photo: FSMessage carries no sender id/photo of
    // its own (`sender` is a plain display-name string) -- ChatThreadView
    // resolves this from data it already has (the outgoing case uses `me`;
    // a DM's incoming case uses the contact's own already-fetched photo; a
    // group's incoming case uses ChatThreadViewModel's per-member
    // GET /user/{id} resolution, keyed by username) and threads it in here.
    // nil falls back to the existing initial-circle treatment in `avatar`
    // below, exactly like every other surface's fallback.
    var senderPhotoURL: String? = nil
}

extension MessageDisplayGroup {
    /// Groups consecutive messages from the same sender (same `mine` value
    /// and, for received messages, the same `sender` id) into display groups,
    /// preserving order. Pure transformation of already-loaded real data —
    /// no fabrication.
    /// `photoByUsername` (task 20260905-profile-photo): a username → photo
    /// URL lookup for every *received* message's sender (a DM's single
    /// contact, or a group's other members) -- defaulted empty so every
    /// pre-existing call site/preview/test that doesn't supply one keeps
    /// compiling and rendering the initials-only avatar exactly as before.
    static func grouped(from messages: [FSMessage], me: FSUser?, photoByUsername: [String: String] = [:]) -> [MessageDisplayGroup] {
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
                    date:          groups[lastIndex].date,
                    messages:      groups[lastIndex].messages + [message],
                    senderPhotoURL: groups[lastIndex].senderPhotoURL
                )
            } else {
                let name = message.mine ? "You" : (message.sender.isEmpty ? "Them" : message.sender)
                groups.append(MessageDisplayGroup(
                    id:            message.id,
                    senderInitial: message.mine ? (me?.initials ?? "Y") : String(name.prefix(1)).uppercased(),
                    senderName:    name,
                    timeLabel:     message.formattedTime,
                    isOutgoing:    message.mine,
                    date:          parseTimestamp(message.timestamp),
                    messages:      [message],
                    senderPhotoURL: message.mine ? me?.profile_photo_url : photoByUsername[name]
                ))
            }
        }
        return groups
    }

    /// Parses `FSMessage.timestamp` (ISO8601) into a `Date`, tolerating both
    /// forms actually produced app-wide: the server's fractional-seconds
    /// format and the client's own `sendMessage` stamp (no fractional
    /// seconds). `FSMessage.formattedTime` only handles the fractional form,
    /// which would silently drop the client's own just-sent messages from
    /// day-boundary detection — this tries both rather than assuming one.
    static func parseTimestamp(_ iso: String) -> Date? {
        guard !iso.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }

    /// Day-divider label contract (design gate §13): "Today"/"Yesterday" for
    /// the two nearest days, else a short date ("Aug 25") — not all-caps,
    /// matching `render-2-conversation-thread.png` literally.
    static func dayLabel(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

// ── Thread row kind (message group vs. day divider) ────────────────────────
/// `ChatThreadView`'s message list interleaves two distinct row kinds — a
/// grouped set of bubbles, or a labeled day-boundary divider — in one
/// ordered list so a single `ForEach` can render both (design gate §13).
enum ChatThreadRow: Identifiable {
    case group(MessageDisplayGroup)
    case dayDivider(id: String, label: String)

    var id: String {
        switch self {
        case .group(let group):        return group.id
        case .dayDivider(let id, _):   return id
        }
    }
}

extension Array where Element == MessageDisplayGroup {
    /// Interleaves a labeled day-divider row before the first group of each
    /// new calendar day (real `Calendar.isDate(_:inSameDayAs:)` detection —
    /// not a cosmetic restyle of the existing plain sender-group hairline,
    /// which stays as-is for consecutive groups within the same day).
    func withDayDividers(calendar: Calendar = .current) -> [ChatThreadRow] {
        var rows: [ChatThreadRow] = []
        var lastDay: Date? = nil
        for group in self {
            if let date = group.date {
                if lastDay == nil || !calendar.isDate(date, inSameDayAs: lastDay!) {
                    rows.append(.dayDivider(id: "day-\(group.id)",
                                             label: MessageDisplayGroup.dayLabel(for: date, calendar: calendar)))
                    lastDay = date
                }
            }
            rows.append(.group(group))
        }
        return rows
    }
}

/// Centered label flanked by hairlines, mirroring
/// `render-2-conversation-thread.png` (design gate §13): normal case (not
/// the uppercase-tracked `SectionEyebrow` style used elsewhere), distinct
/// from — and rendered alongside — the existing plain unlabeled hairline
/// between same-day sender groups.
struct DayDividerRow: View {
    let label: String

    var body: some View {
        HStack(spacing: Theme.spacingSM) {
            Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)
            Text(label)
                .font(.inter(Theme.fontXS))
                .foregroundColor(Theme.textSecondary)
                .fixedSize()
            Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingXS)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

struct MessageGroupRow: View {
    let group: MessageDisplayGroup
    // Task 20260904-messaging-attachments: keyed by FSMessage.id — see
    // MessageAttachments.swift's LocalAttachmentPreview doc comment. Empty
    // for every screen except this one's own thread, so every other
    // (nonexistent) caller of MessageGroupRow is unaffected; there is none
    // today besides ChatThreadView.
    var localAttachmentPreviews: [String: LocalAttachmentPreview] = [:]

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
                        .font(.inter(Theme.fontSM, weight: .bold))
                        .foregroundColor(Theme.parchment)
                    if !group.timeLabel.isEmpty {
                        Text(group.timeLabel)
                            .font(.inter(Theme.fontXXS))
                            .foregroundColor(Theme.textSecondary)
                    }
                    if !group.isOutgoing { Spacer(minLength: 0) }
                }

                ForEach(group.messages) { message in
                    bubble(for: message)
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

    /// One message bubble. Reuses the exact same container (background/
    /// stroke/clipShape/topEdgeHighlight chain) for every message regardless
    /// of `attachment_kind` (design gate §4) — only the content inside
    /// changes, and only image/video/gif drop the container's inner text
    /// padding (edge-to-edge media); `file` and plain text keep it.
    @ViewBuilder
    private func bubble(for message: FSMessage) -> some View {
        let isMedia = ["image", "video", "gif"].contains(message.attachmentKind ?? "")
        Group {
            if let kind = message.attachmentKind, !kind.isEmpty {
                // A caption riding alongside an attachment (`text` and
                // `attachment_kind` can both be set — design gate's wire
                // contract note) renders below the attachment content,
                // inside the same bubble.
                VStack(alignment: group.isOutgoing ? .trailing : .leading, spacing: 0) {
                    AttachmentContentView(message: message, localPreview: localAttachmentPreviews[message.id])
                        .padding(isMedia ? 0 : 14)
                        .padding(.vertical, isMedia ? 0 : 10)
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.inter(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                            .multilineTextAlignment(group.isOutgoing ? .trailing : .leading)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                            .padding(.top, isMedia ? 6 : 0)
                    }
                }
            } else {
                Text(message.text)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .multilineTextAlignment(group.isOutgoing ? .trailing : .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .background(
            group.isOutgoing
                ? Theme.gold.opacity(0.18)
                : Color.white.opacity(0.06)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLG)
                .stroke(group.isOutgoing ? Theme.borderGoldDim : Theme.borderGoldFaint, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
        .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusLG))
        .accessibilityLabel(accessibilityLabel(for: message))
    }

    /// Extends the pre-existing `"{sender}: {text}"` pattern with a
    /// per-kind label (design gate §4) — never both at once (an attachment
    /// message with `text` empty has nothing to append).
    private func accessibilityLabel(for message: FSMessage) -> String {
        // compile-errors #3 (20260904-frontend-arch-sweep): switches on the
        // actual FSAttachmentKind enum (exhaustive, no default:) instead of
        // the raw wire string -- see FSMessage.attachmentKindEnum. An
        // unrecognized/nil kind falls into the same "plain text" branch a
        // stringly-typed `default:` used to catch.
        guard let kind = message.attachmentKindEnum else {
            return "\(group.senderName): \(message.text)"
        }
        switch kind {
        case .image: return "\(group.senderName): photo attachment"
        case .video: return "\(group.senderName): video attachment, tap to play"
        case .gif:   return "\(group.senderName): GIF attachment"
        case .file:  return "\(group.senderName): file attachment, \(message.attachmentMeta?.filename ?? "file"), double tap to download"
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(group.isOutgoing ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.gold.opacity(0.18)))
            Circle()
                .stroke(Theme.borderGoldDim, lineWidth: 1)
            Text(group.senderInitial)
                .font(.inter(Theme.fontXS, weight: .bold))
                .foregroundColor(group.isOutgoing ? Theme.ink : Theme.gold)
            // Task 20260905-profile-photo: layered over the existing
            // gradient/initial circle above rather than replacing it, so a
            // missing/loading/failed photo just shows that same initials
            // treatment underneath -- never a broken image.
            if let photoURL = group.senderPhotoURL, !photoURL.isEmpty, let url = URL(string: photoURL) {
                AsyncImage(
                    url: url,
                    transaction: Transaction(animation: reduceMotion ? nil : .easeIn(duration: 0.25))
                ) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}
