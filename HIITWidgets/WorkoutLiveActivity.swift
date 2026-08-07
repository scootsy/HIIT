import ActivityKit
import SwiftUI
import WidgetKit

/// The workout on the lock screen and in the Dynamic Island: phase, a
/// system-driven countdown that keeps ticking while the app is backgrounded,
/// the current target, what's next, and +/- steppers that adjust the live
/// workout via App Intents (executed in the app's process).
///
/// Deliberately simpler than the in-app screen: one phase, one number, one
/// target — glanceable from across a treadmill console.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenWorkoutView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let tint = WorkoutActivityStyle.tint(forPhaseKind: context.state.phaseKindRaw)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(phaseHeadline(context.state),
                              systemImage: WorkoutActivityStyle.icon(forPhaseKind: context.state.phaseKindRaw))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                        Text(context.state.targetText)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(context.state.effortsDone)/\(context.state.effortsTotal)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        timerText(context.state)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .frame(maxWidth: 64, alignment: .trailing)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let message = context.state.suggestionMessage, !context.isStale {
                        HStack(spacing: 8) {
                            Image(systemName: context.state.suggestionEaseOff
                                  ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                .foregroundStyle(tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(message)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                if let value = context.state.suggestionValue {
                                    Text(value)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                            }
                            Spacer(minLength: 6)
                            Button(intent: AcceptCoachSuggestionIntent()) {
                                Text("Apply")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(tint)
                        }
                        .padding(.horizontal, 4)
                    } else {
                        HStack(spacing: 10) {
                            if let next = context.state.nextText {
                                Text(next)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            Spacer(minLength: 6)
                            if context.state.adjustable && !context.state.inOvertime {
                                adjustButtons(tint: tint)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                Image(systemName: WorkoutActivityStyle.icon(forPhaseKind: context.state.phaseKindRaw))
                    .foregroundStyle(tint)
            } compactTrailing: {
                compactTimer(context.state)
                    .foregroundStyle(tint)
            } minimal: {
                Image(systemName: WorkoutActivityStyle.icon(forPhaseKind: context.state.phaseKindRaw))
                    .foregroundStyle(tint)
            }
            .keylineTint(tint)
        }
    }

    private func phaseHeadline(_ state: WorkoutActivityAttributes.ContentState) -> String {
        if state.inOvertime { return "Complete" }
        if state.paused { return "Paused" }
        return state.phaseTitle
    }

    /// Counts down through the phase; counts up in overtime; freezes on pause.
    @ViewBuilder
    private func timerText(_ state: WorkoutActivityAttributes.ContentState) -> some View {
        if state.paused {
            Text(WorkoutActivityStyle.clock(state.pausedRemaining))
        } else if state.inOvertime {
            Text(state.phaseStart, style: .timer)
        } else {
            Text(timerInterval: state.phaseStart...state.phaseEnd, countsDown: true)
        }
    }

    /// The island's compact slot is tiny — cap the width so a long timer
    /// doesn't push the leading icon out.
    @ViewBuilder
    private func compactTimer(_ state: WorkoutActivityAttributes.ContentState) -> some View {
        Group {
            if state.paused {
                Text(WorkoutActivityStyle.clock(state.pausedRemaining))
            } else if state.inOvertime {
                Text(state.phaseStart, style: .timer)
            } else {
                Text(timerInterval: state.phaseStart...state.phaseEnd, countsDown: true)
            }
        }
        .font(.caption2.weight(.bold))
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 44)
    }

    private func adjustButtons(tint: Color) -> some View {
        HStack(spacing: 8) {
            Button(intent: AdjustLiveTargetIntent(up: false)) {
                Image(systemName: "minus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 30)
            }
            .buttonStyle(.bordered)
            .tint(tint)
            Button(intent: AdjustLiveTargetIntent(up: true)) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 30)
            }
            .buttonStyle(.bordered)
            .tint(tint)
        }
    }
}

// MARK: - Lock screen

private struct LockScreenWorkoutView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    private var isStale: Bool { context.isStale }
    private var state: WorkoutActivityAttributes.ContentState { context.state }
    private var tint: Color { WorkoutActivityStyle.tint(forPhaseKind: state.phaseKindRaw) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(headline.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                } icon: {
                    Image(systemName: WorkoutActivityStyle.icon(forPhaseKind: state.phaseKindRaw))
                }
                .foregroundStyle(tint)
                .lineLimit(1)
                Spacer()
                Text("\(state.effortsDone)/\(state.effortsTotal) efforts")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.targetText)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let next = state.nextText {
                        Text(next)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 8)
                timer
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .frame(maxWidth: 96, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            // The live coach's offer — Apply routes through the same intent
            // bridge as the +/- buttons. Hidden once the activity is stale
            // (the offer expired without the app getting to push an update).
            if let message = state.suggestionMessage, !isStale {
                HStack(spacing: 8) {
                    Image(systemName: state.suggestionEaseOff
                          ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if let value = state.suggestionValue {
                            Text(value)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    Spacer(minLength: 6)
                    Button(intent: AcceptCoachSuggestionIntent()) {
                        Text("Apply")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    Button(intent: DismissCoachSuggestionIntent()) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                }
                .padding(.vertical, 2)
            }

            if !state.inOvertime {
                HStack(spacing: 10) {
                    if !state.paused {
                        ProgressView(timerInterval: state.phaseStart...state.phaseEnd,
                                     countsDown: false, label: { EmptyView() },
                                     currentValueLabel: { EmptyView() })
                            .progressViewStyle(.linear)
                            .tint(tint)
                    }
                    if state.adjustable {
                        Button(intent: AdjustLiveTargetIntent(up: false)) {
                            Image(systemName: "minus")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 46, height: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(tint)
                        Button(intent: AdjustLiveTargetIntent(up: true)) {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 46, height: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(tint)
                    }
                }
            }
        }
        .padding(14)
    }

    private var headline: String {
        if state.inOvertime { return "Complete" }
        if state.paused { return "Paused · \(state.phaseTitle)" }
        return state.phaseTitle
    }

    @ViewBuilder
    private var timer: some View {
        if state.paused {
            Text(WorkoutActivityStyle.clock(state.pausedRemaining))
        } else if state.inOvertime {
            Text(state.phaseStart, style: .timer)
        } else {
            Text(timerInterval: state.phaseStart...state.phaseEnd, countsDown: true)
        }
    }
}
