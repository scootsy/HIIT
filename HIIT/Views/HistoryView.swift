import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HealthKitManager.self) private var health
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @State private var showCoach = false
    @State private var coachSummary = ""
    @State private var vo2Series: [HealthKitManager.SamplePoint] = []
    @State private var restingSeries: [HealthKitManager.SamplePoint] = []

    var body: some View {
        NavigationStack {
            Group {
                // Health trends deserve showing even before the first saved
                // workout — the full empty state only when there is truly
                // nothing to display.
                if sessions.isEmpty && vo2Series.isEmpty && restingSeries.isEmpty {
                    ContentUnavailableView(
                        "No workouts yet",
                        systemImage: "flame",
                        description: Text("Finished sessions land here, along with your trends."))
                } else {
                    List {
                        if !vo2Series.isEmpty || !restingSeries.isEmpty {
                            Section {
                                if !vo2Series.isEmpty {
                                    FitnessSignalRow(
                                        title: "Cardio Fitness (VO₂max)",
                                        unit: "mL/kg·min",
                                        series: vo2Series,
                                        higherIsBetter: true,
                                        explainer: "The headline fitness number — HIIT's main target.")
                                }
                                if !restingSeries.isEmpty {
                                    FitnessSignalRow(
                                        title: "Resting heart rate",
                                        unit: "bpm",
                                        series: restingSeries,
                                        higherIsBetter: false,
                                        explainer: "Falls as fitness improves.")
                                }
                            } header: {
                                Text("Fitness signals")
                            } footer: {
                                Text("Apple Health · last 6 months")
                            }
                        }
                        if sessions.isEmpty {
                            Section("Sessions") {
                                Text("Finished sessions land here.")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Section("Minutes") {
                                MinutesTrendChart(sessions: sessions)
                                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                            }
                            Section("Sessions") {
                                ForEach(sessions) { session in
                                    NavigationLink(value: session) {
                                        HistoryRow(session: session)
                                    }
                                }
                                .onDelete(perform: delete)
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: WorkoutSession.self) { session in
                SessionDetailView(session: session)
            }
            .toolbar {
                if !sessions.isEmpty && CoachService.isConfigured(settings.coachProvider) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            coachSummary = CoachService.buildSummary(sessions: sessions, settings: settings)
                            showCoach = true
                        } label: {
                            Label("AI Coach", systemImage: "sparkles")
                        }
                    }
                }
            }
            .sheet(isPresented: $showCoach) {
                CoachSheetView(summary: coachSummary)
            }
            .task {
                // Refetch on every visit (two cheap, bounded queries) so the
                // trends appear as soon as Health access is granted — a
                // one-shot latch used to hide them until the next app launch.
                vo2Series = await health.fetchSeries(.vo2Max, unit: HealthKitManager.vo2MaxUnit, daysBack: 180)
                restingSeries = await health.fetchSeries(.restingHeartRate, unit: HealthKitManager.bpmUnit, daysBack: 180)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            context.delete(sessions[index])
        }
        try? context.save()
    }
}

/// Latest value, trend over the window, and a small sparkline. Coloring is
/// about direction of *improvement*, not direction of the number.
struct FitnessSignalRow: View {
    let title: String
    let unit: String
    let series: [HealthKitManager.SamplePoint]
    let higherIsBetter: Bool
    let explainer: String

    private var latest: Double { series.last?.value ?? 0 }
    private var delta: Double { latest - (series.first?.value ?? latest) }
    private var improving: Bool { higherIsBetter ? delta >= 0 : delta <= 0 }

    /// The span the delta actually covers — the query window is 6 months, but
    /// two samples a week apart must not claim "over 6 months".
    private var spanText: String {
        guard let first = series.first?.date, let last = series.last?.date, last > first else { return "" }
        let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
        if days >= 60 { return "over \(days / 30) months" }
        if days >= 14 { return "over \(days / 7) weeks" }
        return "over \(max(1, days)) day\(days == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", latest))
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        Text(unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if abs(delta) >= 0.05 {
                        Text(String(format: "%+.1f ", delta) + spanText)
                            .font(.caption)
                            .foregroundStyle(improving ? Theme.recover : Theme.steady)
                    }
                }
                Spacer()
                Chart(series) { point in
                    // A one-point LineMark draws nothing — show the sample as
                    // a dot instead of a blank chart area.
                    if series.count == 1 {
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Value", point.value))
                            .foregroundStyle(improving ? Theme.recover : Theme.steady)
                    } else {
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Value", point.value))
                            .foregroundStyle(improving ? Theme.recover : Theme.steady)
                            .interpolationMethod(.catmullRom)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(width: 96, height: 44)
            }
            Text(explainer)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct MinutesTrendChart: View {
    enum Scale: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case weekly = "Weekly"
        case monthly = "Monthly"

        var id: String { rawValue }

        var component: Calendar.Component {
            switch self {
            case .daily: return .day
            case .weekly: return .weekOfYear
            case .monthly: return .month
            }
        }

        /// How many buckets to show, including the current one.
        var count: Int {
            switch self {
            case .daily: return 14
            case .weekly: return 8
            case .monthly: return 6
            }
        }
    }

    let sessions: [WorkoutSession]
    @State private var scale: Scale = .weekly

    private struct Bucket: Identifiable {
        let id: Date
        let minutes: Double
    }

    private var buckets: [Bucket] {
        let calendar = Calendar.current
        guard let currentStart = calendar.dateInterval(of: scale.component, for: Date())?.start else { return [] }
        var result: [Bucket] = []
        for offset in stride(from: -(scale.count - 1), through: 0, by: 1) {
            guard let start = calendar.date(byAdding: scale.component, value: offset, to: currentStart),
                  let end = calendar.date(byAdding: scale.component, value: 1, to: start) else { continue }
            let minutes = sessions
                .filter { $0.date >= start && $0.date < end }
                .reduce(0.0) { $0 + $1.totalSeconds / 60 }
            result.append(Bucket(id: start, minutes: minutes))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 14) {
            Picker("Range", selection: $scale) {
                ForEach(Scale.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Date", bucket.id, unit: scale.component),
                    y: .value("Minutes", bucket.minutes))
                    .foregroundStyle(Theme.accent.gradient)
                    .cornerRadius(4)
            }
            .frame(height: 150)
        }
    }
}

struct SessionDetailView: View {
    let session: WorkoutSession

    @Environment(SettingsStore.self) private var settings
    @Environment(HealthKitManager.self) private var health
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var showCoach = false
    @State private var coachSummary = ""
    @State private var confirmDelete = false
    @State private var retryingHealth = false
    @State private var healthRetryOutcome: HealthKitManager.WorkoutSaveOutcome? = nil

    var body: some View {
        // The model can be deleted out from under this view — from the other
        // tab's copy of the detail screen, or mid-pop after our own delete.
        // Reading properties of a deleted @Model is undefined; show a
        // placeholder instead.
        if session.isDeleted {
            ContentUnavailableView("Session deleted", systemImage: "trash")
        } else {
            detail
        }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.planName)
                        .font(.title2.weight(.bold))
                    Text("\(session.equipment.label) · \(session.date.formatted(date: .long, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !session.planFocus.isEmpty {
                        Text(session.planFocus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // The same grid and objectives card the post-workout summary
                // shows — a session must read identically in both places.
                SessionStatsGrid(
                    equipment: session.equipment,
                    totalSeconds: session.totalSeconds,
                    workSeconds: session.workSeconds,
                    completedIntervals: session.completedWorkIntervals,
                    totalIntervals: session.totalWorkIntervals,
                    calories: session.estimatedCalories,
                    distanceMeters: session.estimatedDistanceMeters,
                    avgHeartRate: session.avgHeartRate,
                    maxHeartRate: session.maxHeartRate,
                    hrRecovery: session.hrRecovery,
                    suspendedSeconds: session.suspendedSeconds,
                    historyExtras: true,
                    rpe: session.rpe)

                if !session.objectives.isEmpty {
                    ObjectivesCard(lines: session.objectives)
                }

                if !session.nextTimeNote.isEmpty {
                    Label(session.nextTimeNote, systemImage: "arrow.up.forward.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !session.savedToHealth {
                    healthRetryRow
                }
                if !session.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.headline)
                        Text(session.notes).font(.callout)
                    }
                }

                if !session.records.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Phases").font(.headline)
                        ForEach(Array(session.records.enumerated()), id: \.offset) { _, record in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.color(for: record.kindValue))
                                    .frame(width: 5, height: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(record.label)
                                        .font(.subheadline)
                                    Text(recordTarget(record))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(clockString(record.actualSeconds)) / \(clockString(record.plannedSeconds))")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(record.actualSeconds >= record.plannedSeconds * 0.9 ? .secondary : Color.orange)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding()
            .readableWidth(680)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if CoachService.isConfigured(settings.coachProvider) {
                        Button {
                            coachSummary = CoachService.buildSummary(sessions: [session], settings: settings)
                            // Same context the post-workout coach gets: the
                            // stored grades say *why* the session landed as
                            // it did.
                            if !session.objectives.isEmpty {
                                coachSummary += "\nHow the session graded against its objectives:\n"
                                    + session.objectives.map { "- \($0.title). \($0.detail)" }.joined(separator: "\n")
                            }
                            showCoach = true
                        } label: {
                            Label("Ask the AI coach", systemImage: "sparkles")
                        }
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete session", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showCoach) {
            CoachSheetView(summary: coachSummary)
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                context.delete(session)
                try? context.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// A failed (or never-authorized) Health export used to be recorded and
    /// then forgotten — this is the one place it can be seen and retried.
    /// The strap HR trace isn't persisted, so a retry saves the workout,
    /// energy, and distance without it.
    private var healthRetryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.slash")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not saved to Apple Health")
                    .font(.footnote)
                if healthRetryOutcome == .failed {
                    Text("Still couldn't save — check sharing under Health → Profile → Apps")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if healthRetryOutcome == .notAuthorized {
                    Text("Health sharing is off for workouts")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if retryingHealth {
                ProgressView()
            } else {
                Button("Save now") {
                    retryingHealth = true
                    Task { @MainActor in
                        let ok = await health.saveWorkout(session: session)
                        healthRetryOutcome = ok
                        if ok == .saved {
                            session.savedToHealth = true
                            try? context.save()
                        }
                        retryingHealth = false
                    }
                }
                .font(.footnote.weight(.medium))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func recordTarget(_ record: PhaseRecord) -> String {
        var parts: [String] = []
        if session.equipment == .bike {
            if let resistance = record.resistance { parts.append("Resistance \(resistance)") }
        } else {
            if let speed = record.speedMph { parts.append(settings.speedString(speed)) }
            if let incline = record.inclinePercent, incline > 0.5 {
                parts.append(String(format: "%.0f%% incline", incline))
            }
        }
        return parts.isEmpty ? record.kindValue.title : parts.joined(separator: " · ")
    }
}
