// OnboardingSurveyView.swift -- task 20261105-onboarding-redo.
// The 4-option "tick all that apply" survey in the gray-card form style
// (mockups `survey` / `ipadSurvey`). Used by the first-run flow (before
// sign-in) and by "Replay onboarding" in Account.
//
// Next is dimmed until a pick but stays tappable (kit rule); with nothing
// ticked, Next behaves like Skip: the flow continues with only the friends part.
// iPad: the same column, centered at a readable 560pt width.

import SwiftUI

struct OnboardingSurveyView: View {
    var onFinish: (Set<OnboardingTopic>) -> Void
    /// Replay from Account: Skip leaves the survey instead of running friends-only.
    var onCancel: (() -> Void)? = nil
    @State private var selected = Set<OnboardingTopic>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.clear.warmBloomBackground()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What would you like help with?")
                                .font(.fsSheetTitle)
                                .foregroundColor(Theme.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                            Text("Select all that apply. We’ll show you just those parts of the app.")
                                .font(.fsBody)
                                .foregroundColor(Theme.textSecondary)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(OnboardingTopic.allCases.enumerated()), id: \.element.id) { idx, topic in
                                if idx > 0 { Divider().overlay(Theme.borderGray) }
                                row(topic)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous).fill(Theme.cardGlassGray))
                        .overlay(RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous).strokeBorder(Theme.borderGray, lineWidth: 1))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 56)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                FSPinnedActionBar(secondaryTitle: "Skip",
                                  onSecondary: { if let onCancel { onCancel() } else { onFinish([]) } },
                                  primaryTitle: "Next",
                                  primaryTrailingIcon: "arrow.right",
                                  primaryDimmed: selected.isEmpty,
                                  onPrimary: { onFinish(selected) })
                    .frame(maxWidth: 560)
            }
        }
    }

    private func row(_ topic: OnboardingTopic) -> some View {
        let on = selected.contains(topic)
        return Button {
            withMotionAwareAnimation(.easeInOut(duration: 0.18), reduceMotion: reduceMotion) {
                if on { selected.remove(topic) } else { selected.insert(topic) }
            }
        } label: {
            HStack(spacing: 14) {
                Text(topic.surveyTitle)
                    .font(.fsBody)
                    .foregroundColor(on ? Theme.textPrimary : Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(on ? Theme.gold : Theme.fieldBorder, lineWidth: 2)
                        .frame(width: 22, height: 22)
                    if on {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.gold).frame(width: 22, height: 22)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.ink)
                    }
                }
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(topic.surveyTitle)
        .accessibilityValue(on ? "Selected" : "Not selected")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
