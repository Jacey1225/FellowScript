// FSStepperRail.swift
// 3-node stepper rail for long forms (spec 2.4). Done = gold dot with check,
// current = gold ring, upcoming = field-border ring. In create mode only
// completed and current steps are tappable (`maxReachable`); in edit mode pass
// steps.count - 1.

import SwiftUI

struct FSStepperRail: View {
    let steps: [String]
    let current: Int
    var maxReachable: Int
    var onSelect: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var compact: Bool { typeSize >= .accessibility3 }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(steps.indices, id: \.self) { i in
                    node(i)
                    if i < steps.count - 1 {
                        Rectangle()
                            .fill(i < current ? Theme.gold : Theme.fieldBorder)
                            .frame(height: 2).padding(.top, 11)
                    }
                }
            }
            if compact {
                Text("Step \(current + 1) of \(steps.count): \(steps[current])")
                    .font(.fsHelper).foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    private func node(_ i: Int) -> some View {
        let done = i < current, isCurrent = i == current
        return Button { if i <= maxReachable { onSelect(i) } } label: {
            VStack(spacing: 6) {
                ZStack {
                    if done {
                        Circle().fill(Theme.gold).frame(width: 24, height: 24)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.ink)
                    } else {
                        Circle().strokeBorder(isCurrent ? Theme.gold : Theme.fieldBorder, lineWidth: 2).frame(width: 24, height: 24)
                        if isCurrent { Circle().fill(Theme.gold).frame(width: 8, height: 8) }
                    }
                    if compact && !done { Text("\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.textPrimary) }
                }
                if !compact {
                    Text(steps[i].uppercased())
                        .font(.system(size: 12, weight: .semibold)).tracking(1)
                        .foregroundColor(isCurrent || done ? Theme.gold : Theme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(i > maxReachable)
        .accessibilityLabel("Step \(i + 1) of \(steps.count), \(steps[i]), \(isCurrent ? "current" : (done ? "done" : "upcoming"))")
    }
}
