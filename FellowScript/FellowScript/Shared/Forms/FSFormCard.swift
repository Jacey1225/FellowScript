// FSFormCard.swift
// Section card for forms: gray glass (cardGlassGray + borderGray), radius 20,
// padding 16, optional eyebrow, heading and trailing action (spec 2.2).

import SwiftUI

struct FSFormCard<Content: View, Trailing: View>: View {
    var eyebrow: String? = nil
    var title: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if eyebrow != nil || title != nil {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let eyebrow {
                            Text(eyebrow.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(1)
                                .foregroundColor(Theme.gold.opacity(0.85))
                        }
                        if let title {
                            Text(title)
                                .font(.fsCardHeading)
                                .foregroundColor(Theme.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing()
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous)
                .fill(Theme.cardGlassGray)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous)
                .strokeBorder(Theme.borderGray, lineWidth: 1)
        )
    }
}

extension FSFormCard where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.eyebrow = eyebrow
        self.title = title
        self.trailing = { EmptyView() }
        self.content = content
    }
}
