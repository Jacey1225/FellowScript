// FSFormErrorCard.swift
// Form-level cards (spec 2.9): validation summary, retryable save failure,
// and the non-error informational card used for plan gates and limits.

import SwiftUI

struct FSErrorSummaryCard: View {
    let fields: [(id: String, name: String)]
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.error)
                Text(fields.count == 1 ? "1 thing needs attention" : "\(fields.count) things need attention")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.error)
            }
            ForEach(fields, id: \.id) { f in
                Button { onSelect(f.id) } label: {
                    Text(f.name).font(.system(size: 14)).underline().foregroundColor(Theme.textPrimary)
                        .frame(minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).fill(Theme.dangerBg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).strokeBorder(Theme.errorStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

struct FSRetryCard: View {
    var message: String = "We could not save. Check your connection."
    var onRetry: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.error)
                Text(message).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.error)
            }
            HStack(spacing: 12) {
                Button("Try again", action: onRetry)
                    .font(.system(size: 14, weight: .bold)).foregroundColor(Theme.gold)
                    .frame(minHeight: 44).padding(.horizontal, 16)
                    .overlay(Capsule().strokeBorder(Theme.borderGold, lineWidth: 1))
                Button("Dismiss", action: onDismiss)
                    .font(.system(size: 14)).foregroundColor(Theme.textSecondary).frame(minHeight: 44)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).fill(Theme.dangerBg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).strokeBorder(Theme.errorStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

struct FSInfoCard: View {
    let text: String
    var symbol: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundColor(Theme.gold)
            Text(text).font(.system(size: 14)).foregroundColor(Theme.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).fill(Theme.cardGlassGray))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).strokeBorder(Theme.borderGray, lineWidth: 1))
    }
}
