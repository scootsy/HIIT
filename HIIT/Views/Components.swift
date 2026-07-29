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
