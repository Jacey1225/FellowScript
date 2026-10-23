// FSControls.swift
// Choice controls for forms (spec 2.5): toggle row, chip row, segmented
// control, radio list, number stepper. All 44pt+ hit targets, system font.

import SwiftUI

struct FSToggleRow: View {
    let title: String
    var helper: String? = nil
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.fsLabel).foregroundColor(Theme.textPrimary)
                if let helper { Text(helper).font(.fsHelper).foregroundColor(Theme.textSecondary) }
            }
        }
        .tint(Theme.gold)
        .disabled(disabled)
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }
}

struct FSChip: View {
    let title: String
    var selected: Bool
    var addOn: Bool = false
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withMotionAwareAnimation(.easeInOut(duration: 0.18), reduceMotion: reduceMotion, action)
        } label: {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                } else if addOn {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.gold)
                }
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(selected ? Theme.ink : (addOn ? Theme.textPrimary : Theme.textSecondary))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background {
                if selected { Capsule().fill(Theme.goldGradient) }
                else { Capsule().fill(addOn ? Color.clear : Theme.fieldFill) }
            }
            .overlay { if !selected { Capsule().strokeBorder(Theme.fieldBorder, lineWidth: 1) } }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Wrapping row of chips. Single-select behaves as a radio group.
struct FSChipRow<ID: Hashable>: View {
    let options: [(id: ID, title: String)]
    @Binding var selection: Set<ID>
    var multi: Bool = false

    var body: some View {
        FSFlowLayout(spacing: 8) {
            ForEach(options, id: \.id) { opt in
                FSChip(title: opt.title, selected: selection.contains(opt.id)) {
                    if multi {
                        if selection.contains(opt.id) { selection.remove(opt.id) } else { selection.insert(opt.id) }
                    } else {
                        selection = [opt.id]
                    }
                }
            }
        }
    }
}

/// Simple wrapping layout used by chip rows.
struct FSFlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing; rowH = max(rowH, size.height); maxW = max(maxW, x - spacing)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
    }
}

struct FSSegmented<ID: Hashable>: View {
    let options: [(id: ID, title: String)]
    @Binding var selection: ID

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { opt in
                let on = opt.id == selection
                Button { selection = opt.id } label: {
                    Text(opt.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(on ? Theme.gold : Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardGlassGray)
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.borderGold, lineWidth: 1))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fieldFill))
    }
}

struct FSRadioList<ID: Hashable>: View {
    let options: [(id: ID, title: String, helper: String?)]
    @Binding var selection: ID?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { idx, opt in
                let on = opt.id == selection
                Button { selection = opt.id } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt.title).font(.system(size: 16)).foregroundColor(Theme.textPrimary)
                            if let h = opt.helper { Text(h).font(.fsHelper).foregroundColor(Theme.textSecondary) }
                        }
                        Spacer()
                        ZStack {
                            Circle().strokeBorder(on ? Theme.gold : Theme.fieldBorder, lineWidth: 2).frame(width: 22, height: 22)
                            if on { Circle().fill(Theme.gold).frame(width: 12, height: 12) }
                        }
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                if idx < options.count - 1 { Divider().overlay(Theme.borderGray) }
            }
        }
    }
}

struct FSNumberStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var unit: String = ""

    var body: some View {
        HStack(spacing: 12) {
            stepButton("minus", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - 1) }
            Text(unit.isEmpty ? "\(value)" : "\(value) \(unit)")
                .font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: Theme.formFieldHeight)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.fieldBorder, lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(unit.isEmpty ? "Value" : unit)
                .accessibilityValue("\(value)")
                .accessibilityAdjustableAction { dir in
                    switch dir {
                    case .increment: value = min(range.upperBound, value + 1)
                    case .decrement: value = max(range.lowerBound, value - 1)
                    @unknown default: break
                    }
                }
            stepButton("plus", enabled: value < range.upperBound) { value = min(range.upperBound, value + 1) }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.gold).frame(width: 44, height: 44)
                .background(Circle().fill(Theme.cardGlassGray))
                .overlay(Circle().strokeBorder(Theme.borderGray, lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
    }
}
