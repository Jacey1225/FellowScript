// FSField.swift
// The one text-entry control for forms (spec 2.3): label above, 48pt field,
// helper/error slot, counter at >=80% of the limit. Supports single-line,
// secure (with 44pt reveal toggle that re-masks on blur), and multiline.
// Autofill: pass `contentType` and `keyboard`; the kit never strips them.

import SwiftUI

enum FSFieldState: Equatable {
    case normal
    case error(String)
    case disabled(String?)   // helper explaining why
}

struct FSField: View {
    let label: String
    var required: Bool = false
    var optional: Bool = false
    @Binding var text: String
    var placeholder: String = ""
    var helper: String? = nil
    var state: FSFieldState = .normal
    var maxLength: Int? = nil
    var leadingSymbol: String? = nil
    /// Accessibility label override (UI tests key on e.g. "Username field").
    var accessibilityName: String? = nil
    var accessibilityId: String? = nil
    var secure: Bool = false
    var multiline: Bool = false
    var minLines: Int = 1
    var contentType: UITextContentType? = nil
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .sentences
    var autocorrect: Bool = true
    var submitLabel: SubmitLabel = .done
    var onSubmit: (() -> Void)? = nil

    @FocusState private var focused: Bool
    @State private var revealed = false

    private var isError: Bool { if case .error = state { return true } else { return false } }
    private var isDisabled: Bool { if case .disabled = state { return true } else { return false } }

    private var showCounter: Bool {
        guard let maxLength else { return false }
        if multiline { return focused || text.count * 5 >= maxLength * 4 }
        return text.count * 5 >= maxLength * 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.fsLabel)
                    .foregroundColor(focused ? Theme.gold : Theme.textPrimary)
                if required { Text("*").font(.fsLabel).foregroundColor(Theme.gold).accessibilityHidden(true) }
                if optional { Text("(optional)").font(.system(size: 14)).foregroundColor(Theme.textSecondary) }
            }
            fieldBody
            footer
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var fieldBody: some View {
        HStack(spacing: 10) {
            if let leadingSymbol {
                Image(systemName: leadingSymbol).font(.system(size: 18)).foregroundColor(Theme.gold)
            }
            Group {
                if secure && !revealed {
                    SecureField("", text: $text, prompt: promptText)
                } else if multiline {
                    TextField("", text: $text, prompt: promptText, axis: .vertical)
                        .lineLimit(minLines...12)
                } else {
                    TextField("", text: $text, prompt: promptText)
                }
            }
            .font(.fsBody)
            .foregroundColor(isDisabled ? Theme.textSecondary : Theme.textPrimary)
            .tint(Theme.gold)
            .textContentType(contentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(capitalization)
            .autocorrectionDisabled(!autocorrect)
            .submitLabel(submitLabel)
            .focused($focused)
            .disabled(isDisabled)
            .onSubmit { onSubmit?() }
            .accessibilityLabel(accessibilityName ?? label)
            .accessibilityIdentifier(accessibilityId ?? "")
            .onChange(of: focused) { _, now in if !now { revealed = false } }
            .onChange(of: text) { _, new in
                if let maxLength, new.count > maxLength { text = String(new.prefix(maxLength)) }
            }
            if secure {
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealed ? "Hide password" : "Show password")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, multiline ? 12 : 0)
        .frame(minHeight: multiline ? 120 : Theme.formFieldHeight, alignment: multiline ? .topLeading : .center)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(isError ? Theme.dangerBg : (isDisabled ? Theme.fieldFill.opacity(0.4) : Theme.fieldFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: (focused || isError) ? 1.5 : 1)
        )
        .shadow(color: focused ? Theme.gold.opacity(0.12) : .clear, radius: 3)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private var promptText: Text { Text(placeholder).foregroundColor(Theme.textSecondary) }

    private var borderColor: Color {
        if isError { return Theme.errorStrong }
        if focused { return Theme.gold }
        if isDisabled { return Theme.borderGray }
        return Theme.fieldBorder
    }

    @ViewBuilder private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch state {
                case .error(let message):
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 14))
                        Text(message)
                    }
                    .foregroundColor(Theme.error)
                    .accessibilityElement(children: .combine)
                case .disabled(let why):
                    if let why { Text(why).foregroundColor(Theme.textSecondary) }
                case .normal:
                    if let helper { Text(helper).foregroundColor(Theme.textSecondary) }
                }
            }
            .font(.fsHelper)
            Spacer(minLength: 0)
            if showCounter, let maxLength {
                Text("\(text.count) / \(maxLength)")
                    .font(.fsHelper)
                    .foregroundColor(text.count >= maxLength ? Theme.error : Theme.textSecondary)
                    .accessibilityLabel("\(text.count) of \(maxLength) characters")
            }
        }
    }
}
