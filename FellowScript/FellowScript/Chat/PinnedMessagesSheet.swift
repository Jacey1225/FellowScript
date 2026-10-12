// PinnedMessagesSheet.swift -- task 20261012-message-pins.
// The Pinned list opened by the pin button at the top right of the chat header.
// Newest pin first (server order), "Show more" paging, tap a row to jump to the
// message, unpin from a trailing button / swipe / VoiceOver action. Warm,
// minimal copy; raw server errors are never shown.

import SwiftUI

/// Pure copy and mapping for the Pinned list so it is unit-testable.
enum FSPinnedListCopy {
    static let title = "Pinned"
    static let empty = "No pinned messages yet."
    static let emptyHint = "Press and hold a message, then choose Pin."
    static let loadError = "Couldn't load pinned messages. Try again?"
    static let actionError = "That didn't go through. Please try again."
    static let unavailable = "That message is no longer available."

    /// The one line shown under an unpin/jump failure.
    static func message(for error: Error) -> String {
        switch error as? FSPinError {
        case .rateLimited?:  return FSPinError.rateLimited.errorDescription ?? actionError
        case .unavailable?:  return unavailable
        default:             return actionError
        }
    }

    /// "Pinned by You" for the viewer's own pin, else "Pinned by NAME".
    static func pinnedByLine(_ pin: FSPinnedMessage, viewerId: String?) -> String {
        let mine = viewerId.map { !$0.isEmpty && $0.lowercased() == pin.pinnedById.lowercased() } ?? false
        let name = mine ? "You" : (pin.pinnedBy.isEmpty ? "Someone" : pin.pinnedBy)
        return "Pinned by \(name)"
    }

    /// Header button VoiceOver value: "3 pinned" when there are pins, else nil.
    static func buttonValue(count: Int) -> String? { count > 0 ? "\(count) pinned" : nil }

    /// Badge text, capped for display only.
    static func badgeText(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }
}

struct PinnedMessagesSheet: View {
    @ObservedObject var vm: ChatThreadViewModel
    let contact: FSContact
    let service: DataServiceProtocol
    let userId: String
    let onSelect: (FSPinnedMessage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inlineError: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()
                content
            }
            .navigationTitle(FSPinnedListCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close pinned messages")
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await vm.loadPins(service: service, contact: contact, userId: userId, reset: true) }
        .onChange(of: vm.pinsState) { _, state in
            // Flag turned off mid-session (uniform 404): close silently.
            if state == .unavailable { dismiss() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.pinsState {
        case .idle where vm.pins.isEmpty, .loading where vm.pins.isEmpty:
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 64)
                }
            }
            .padding(Theme.spacingMD)
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading pinned messages")
        case .failed where vm.pins.isEmpty:
            VStack(spacing: 12) {
                Text(FSPinnedListCopy.loadError)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await vm.loadPins(service: service, contact: contact, userId: userId, reset: true) }
                }
                .font(.inter(Theme.fontBody, weight: .bold))
                .foregroundColor(Theme.gold)
                .frame(minHeight: 44)
            }
            .padding(Theme.spacingLG)
            .frame(maxHeight: .infinity)
        default:
            if vm.pins.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "pin")
                        .font(.system(size: 26))
                        .foregroundColor(Theme.gold.opacity(0.55))
                        .accessibilityHidden(true)
                    Text(FSPinnedListCopy.empty)
                        .font(.inter(Theme.fontBody, weight: .bold))
                        .foregroundColor(Theme.parchment)
                    Text(FSPinnedListCopy.emptyHint)
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(Theme.spacingLG)
                .frame(maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if let inlineError {
                Text(inlineError)
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.error)
                    .listRowBackground(Color.clear)
            }
            ForEach(vm.pins) { pin in
                row(pin)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.borderGoldFaint)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { unpin(pin) } label: { Label("Unpin", systemImage: "pin.slash") }
                            .tint(Theme.goldDim)
                    }
            }
            if vm.pinsHasMore {
                Button {
                    Task { await vm.loadPins(service: service, contact: contact, userId: userId, reset: false) }
                } label: {
                    HStack(spacing: 8) {
                        if vm.isLoadingMorePins { ProgressView() }
                        Text("Show more")
                            .font(.inter(Theme.fontSM, weight: .bold))
                            .foregroundColor(Theme.gold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(_ pin: FSPinnedMessage) -> some View {
        let author = pin.message.fromUser.isEmpty ? "Someone" : pin.message.fromUser
        let when = FSMessageActionPolicy.relativeTime(pin.message.timestamp)
        let by = FSPinnedListCopy.pinnedByLine(pin, viewerId: userId)
        return HStack(alignment: .top, spacing: 12) {
            Button { onSelect(pin) } label: {
                HStack(alignment: .top, spacing: 12) {
                    AvatarView(initial: String(author.prefix(1)).uppercased(), diameter: 28,
                               fillColor: Theme.gold.opacity(0.18), textColor: Theme.gold)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(author)
                                .font(.inter(Theme.fontSM, weight: .bold))
                                .foregroundColor(Theme.parchment)
                                .lineLimit(1)
                            if !when.isEmpty {
                                Text(when)
                                    .font(.inter(Theme.fontXS))
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                        Text(pin.previewText)
                            .font(.inter(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(by)
                            .font(.inter(Theme.fontXS))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(author): \(pin.previewText). \(by)")
            .accessibilityHint("Jumps to the message")

            Button { unpin(pin) } label: {
                Image(systemName: "pin.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.gold)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unpin message from \(author)")
        }
        .accessibilityAction(named: "Unpin") { unpin(pin) }
    }

    private func unpin(_ pin: FSPinnedMessage) {
        inlineError = nil
        Task {
            do {
                try await vm.unpin(pin, service: service, userId: userId)
            } catch {
                inlineError = FSPinnedListCopy.message(for: error)
            }
        }
    }
}
