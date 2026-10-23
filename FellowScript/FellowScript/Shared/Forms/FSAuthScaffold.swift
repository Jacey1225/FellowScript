// FSAuthScaffold.swift
// Type C (auth / credential) skeleton, spec 4 Type C: full-screen, title +
// subtitle, content in a glass card, form-level error above the single
// full-width pinned primary. Optional trailing close for sheet presentations.

import SwiftUI

struct FSAuthScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var errorMessage: String? = nil
    var primaryTitle: String? = nil
    var primaryDimmed: Bool = false
    var saving: Bool = false
    var onPrimary: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()
            VStack(spacing: 0) {
                if let onClose {
                    HStack {
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.gold)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Theme.cardGlassGray))
                                .overlay(Circle().strokeBorder(Theme.borderGray, lineWidth: 1))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Close")
                    }
                    .padding(.horizontal, 12)
                }
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 8) {
                            Text(title).font(.system(size: 28, weight: .heavy)).foregroundColor(Theme.textPrimary)
                                .multilineTextAlignment(.center)
                                .accessibilityAddTraits(.isHeader)
                            if let subtitle {
                                Text(subtitle).font(.system(size: 14)).foregroundColor(Theme.textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.top, onClose == nil ? 48 : 16)
                        FSFormCard { content() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                if let errorMessage, !errorMessage.isEmpty {
                    FSInlineError(message: errorMessage).padding(.horizontal, 16).padding(.bottom, 8)
                }
                if let primaryTitle, let onPrimary {
                    FSPinnedActionBar(primaryTitle: primaryTitle, primaryDimmed: primaryDimmed, saving: saving, onPrimary: onPrimary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Form-level error row (non-field): icon + text on the danger fill.
struct FSInlineError: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(Theme.error)
            Text(message).font(.system(size: 14)).foregroundColor(Theme.error)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).fill(Theme.dangerBg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).strokeBorder(Theme.errorStrong, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Six-box one-time-code entry (spec TC2). One hidden text field owns focus,
/// `.oneTimeCode` autofill and paste of the whole code; the boxes mirror it.
struct FSCodeField: View {
    let label: String
    @Binding var code: String
    var length: Int = 6
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.fsLabel).foregroundColor(focused ? Theme.gold : Theme.textPrimary)
            ZStack {
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .opacity(0.02)
                    .accessibilityLabel(label)
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(length))
                        if digits != new { code = digits }
                    }
                HStack(spacing: 8) {
                    ForEach(0..<length, id: \.self) { i in
                        let chars = Array(code)
                        let active = focused && i == min(chars.count, length - 1)
                        Text(i < chars.count ? String(chars[i]) : "")
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fieldFill))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                .strokeBorder(active ? Theme.gold : Theme.fieldBorder, lineWidth: active ? 1.5 : 1))
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
    }
}
