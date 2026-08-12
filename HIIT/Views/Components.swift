import SwiftUI

struct StatTile: View {
    let title: String
    let value: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The stats block shared by the post-workout summary and the history
/// detail, so a session never reads differently in the two places. The
/// summary leaves `rpe` nil (the rating is collected further down that
/// screen); history shows the saved rating as a tile.
struct SessionStatsGrid: View {
    @Environment(SettingsStore.self) private var settings

    let equipment: Equipment
    let totalSeconds: Double
    let workSeconds: Double
    let completedIntervals: Int
    let totalIntervals: Int
    let calories: Double
    let distanceMeters: Double
    let avgHeartRate: Double?
    let maxHeartRate: Double?
    let hrRecovery: Double?
    let suspendedSeconds: Double
    /// History detail passes true: it adds the saved Effort rating and keeps
    /// "—" placeholders for missing measurements. The summary leaves it
    /// false — it collects the rating further down its own screen, and a
    /// metric that was never measured needs no placeholder there.
    var historyExtras: Bool = false
    var rpe: Int? = nil

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatTile(title: "Duration", value: clockString(totalSeconds), subtitle: "minutes")
                if totalIntervals == 0 {
                    StatTile(title: "Endurance", value: clockString(workSeconds), subtitle: "coached time")
                } else {
                    StatTile(title: "Work time", value: clockString(workSeconds), subtitle: "in the red")
                    StatTile(title: "Intervals", value: "\(completedIntervals)/\(totalIntervals)", subtitle: "completed")
                }
            }
            HStack(spacing: 10) {
                StatTile(title: "Energy", value: "\(Int(calories))", subtitle: "kcal (est.)")
                if equipment == .bike {
                    StatTile(title: "Avg HR", value: avgHeartRate.map { "\(Int($0))" } ?? "—", subtitle: "bpm")
                } else {
                    StatTile(title: "Distance", value: settings.distanceString(distanceMeters), subtitle: "estimated")
                }
                StatTile(title: "Max HR", value: maxHeartRate.map { "\(Int($0))" } ?? "—", subtitle: "bpm")
            }
            // On non-bike plans row 2 spends its slot on distance — average
            // heart rate still deserves a place when it was measured.
            if historyExtras || (equipment != .bike && avgHeartRate != nil) {
                HStack(spacing: 10) {
                    if equipment != .bike {
                        StatTile(title: "Avg HR", value: avgHeartRate.map { "\(Int($0))" } ?? "—", subtitle: "bpm")
                    }
                    if historyExtras {
                        StatTile(title: "Effort", value: rpe.map { "\($0)/10" } ?? "—", subtitle: "your rating")
                    }
                }
            }
            if let hrRecovery {
                StatTile(title: "HR recovery",
                         value: "−\(Int(hrRecovery)) bpm",
                         subtitle: "1-min drop after a hard effort")
            }
            if suspendedSeconds > 30 {
                Label("Includes \(clockString(suspendedSeconds)) while the app was in the background — cues and live heart rate pause when the screen is off or another app is up front.",
                      systemImage: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// "Did this session do its job?" — the graded card shared by the
/// post-workout summary and the history detail. Appears only when a live
/// heart-rate source ran during the workout.
struct ObjectivesCard: View {
    let lines: [SessionObjectives.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Objectives")
                .font(.headline)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(line.verdict))
                        .foregroundStyle(color(line.verdict))
                        .font(.body)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title)
                            .font(.subheadline.weight(.semibold))
                        Text(line.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func icon(_ verdict: SessionObjectives.Verdict?) -> String {
        switch verdict {
        case .met: return "checkmark.circle.fill"
        case .partial: return "circle.bottomhalf.filled"
        case .missed: return "arrow.down.circle"
        case nil: return "info.circle"
        }
    }

    private func color(_ verdict: SessionObjectives.Verdict?) -> Color {
        switch verdict {
        case .met: return Theme.recover
        case .partial: return Theme.steady
        case .missed: return Theme.accent
        case nil: return .secondary
        }
    }
}

struct PhaseRowView: View {
    let phase: IntervalPhase
    let targetLine: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.color(for: phase.kind))
                .frame(width: 5, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(phase.label)
                    .font(.subheadline.weight(.semibold))
                Text(targetLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(clockString(phase.seconds))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct HistoryRow: View {
    let session: WorkoutSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.equipment.icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(session.planName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(session.totalSeconds / 60)) min")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                Text("\(session.completedWorkIntervals)/\(session.totalWorkIntervals) intervals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct RPEPicker: View {
    @Binding var rpe: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How hard was that?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(1...10, id: \.self) { value in
                    Button {
                        rpe = value
                    } label: {
                        Text("\(value)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(
                                rpe == value ? Theme.accent : Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(rpe == value ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Human-readable target line, respecting the user's unit preference.
func targetLine(for target: PhaseTarget, equipment: Equipment, settings: SettingsStore) -> String {
    var parts: [String] = []
    switch equipment {
    case .bike:
        if let resistance = target.resistance { parts.append("Resistance \(resistance)") }
        if let cadence = target.cadenceRPM { parts.append("\(cadence) rpm") }
    case .treadmill:
        if let speed = target.speedMph { parts.append(settings.speedString(speed)) }
        if let incline = target.inclinePercent, incline > 0.5 {
            parts.append(String(format: "%.0f%% incline", incline))
        }
    case .outdoor:
        parts.append(target.effortWords)
        if let speed = target.speedMph { parts.append("~" + settings.speedString(speed)) }
    }
    if parts.isEmpty { parts.append(target.effortWords) }
    return parts.joined(separator: " · ")
}
