// FSDestructive.swift
// Destructive patterns (spec 9.2). Tier 1: undo snackbar (6s). Tier 2: use a
// confirmationDialog with a destructive role. Tier 3: typed confirm field.

import SwiftUI

struct FSUndoSnackbar: View {
    let message: String
    var onUndo: () -> Void

    var body: some View {
        HStack {
            Text(message).font(.system(size: 14)).foregroundColor(Theme.textPrimary)
            Spacer()
            Button("Undo", action: onUndo).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.gold).frame(minHeight: 44)
        }
        .padding(.horizontal, 16).frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.navBg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.borderGray, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Shows `FSUndoSnackbar` at the bottom for 6 seconds while `item` is non-nil; runs `commit` when the time elapses.
    func fsUndoSnackbar(message: Binding<String?>, onUndo: @escaping () -> Void, onExpire: @escaping () -> Void) -> some View {
        overlay(alignment: .bottom) {
            if let m = message.wrappedValue {
                FSUndoSnackbar(message: m) { message.wrappedValue = nil; onUndo() }
                    .padding(16)
                    .task(id: m) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        if message.wrappedValue == m { message.wrappedValue = nil; onExpire() }
                    }
            }
        }
    }
}

/// True when the typed text matches the required phrase (case-insensitive, trimmed).
func fsTypedConfirmMatches(_ typed: String, required: String) -> Bool {
    typed.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(required) == .orderedSame
}
