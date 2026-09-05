// SegmentedDurationControl.swift
// Ported from the standalone ChatSchedule prototype
// (Sources/ChatSchedule/Components/SegmentedDurationControl.swift and
// Models/ScheduleModels.swift's SessionDuration), re-expressed on
// Theme.swift tokens.
//
// FSSession has no duration field, only time_start/time_end strings — see
// SessionCreatorSheet in ChatThreadView.swift, which computes time_end from
// time_start + `SessionDuration.rawValue` minutes when calling createSession.
//
// DEPENDENCY: Theme.swift

import SwiftUI

/// The four duration options in schedule.html's `.segmented` control.
enum SessionDuration: Int, CaseIterable, Identifiable {
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case sixty = 60

    var id: Int { rawValue }
    var label: String { "\(rawValue)m" }

    /// Computes the ISO8601 `time_end` string for a session starting at
    /// `start` with this duration. FSSession has no duration field of its
    /// own — SessionCreatorSheet.scheduleSession() calls this to derive
    /// `time_end` from `time_start` + the segmented control's selection
    /// before calling createSession/updateSession. Extracted to a pure,
    /// directly-testable function (added by the testing gate) rather than
    /// leaving the formula inlined in that private view method.
    func timeEndISOString(from start: Date) -> String {
        ISO8601DateFormatter().string(from: start.addingTimeInterval(Double(rawValue * 60)))
    }
}

/// Interactive 15/30/45/60-minute segmented control — mirrors
/// schedule.html's `.segmented`/`.seg`/`.seg.active`.
struct SegmentedDurationControl: View {
    @Binding var selection: SessionDuration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SessionDuration.allCases) { duration in
                let isActive = duration == selection
                Text(duration.label)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(isActive ? Theme.ink : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        if isActive {
                            Capsule().fill(Theme.goldGradient)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withMotionAwareAnimation(.spring(response: 0.3, dampingFraction: 0.8), reduceMotion: reduceMotion) {
                            selection = duration
                        }
                    }
                    .accessibilityLabel("\(duration.label) duration")
                    .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.04))
        .overlay(Capsule().stroke(Theme.borderGoldDim, lineWidth: 1))
        .clipShape(Capsule())
    }
}
