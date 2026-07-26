import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @State private var showCoach = false
    @State private var coachSummary = ""

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No workouts yet",
                        systemImage: "flame",
                        description: Text("Finished sessions land here, along with your weekly trend."))
                } else {
                    List {
                        Section("Weekly minutes") {
                            WeeklyMinutesChart(sessions: sessions)
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
            .navigationTitle("History")
            .navigationDestination(for: WorkoutSession.self) { session in
                SessionDetailView(session: session)
            }
            .toolbar {
                if !sessions.isEmpty && KeychainHelper.load()?.isEmpty == false {
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
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            context.delete(sessions[index])
        }
        try? context.save()
    }
}

struct WeeklyMinutesChart: View {
    let sessions: [WorkoutSession]

    private struct Week: Identifiable {
        let id: Date
        let minutes: Double
    }

    private var weeks: [Week] {
        let calendar = Calendar.current
        let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        var buckets: [Week] = []
        for offset in stride(from: -7, through: 0, by: 1) {
            guard let start = calendar.date(byAdding: .weekOfYear, value: offset, to: thisWeekStart),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { continue }
            let minutes = sessions
                .filter { $0.date >= start && $0.date < end }
                .reduce(0.0) { $0 + $1.totalSeconds / 60 }
            buckets.append(Week(id: start, minutes: minutes))
        }
        return buckets
    }

    var body: some View {
        Chart(weeks) { week in
            BarMark(
                x: .value("Week", week.id, unit: .weekOfYear),
                y: .value("Minutes", week.minutes))
                .foregroundStyle(Theme.accent.gradient)
                .cornerRadius(4)
        }
        .frame(height: 150)
    }
}

struct SessionDetailView: View {
    let session: WorkoutSession

    @Environment(SettingsStore.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var showCoach = false
    @State private var coachSummary = ""
    @State private var confirmDelete = false

    var body: some View {
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

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        StatTile(title: "Duration", value: clockString(session.totalSeconds), subtitle: "minutes")
                        StatTile(title: "Intervals", value: "\(session.completedWorkIntervals)/\(session.totalWorkIntervals)", subtitle: "completed")
                        StatTile(title: "Energy", value: "\(Int(session.estimatedCalories))", subtitle: "kcal (est.)")
                    }
                    HStack(spacing: 10) {
                        StatTile(title: "Avg HR", value: session.avgHeartRate.map { "\(Int($0))" } ?? "—", subtitle: "bpm")
                        StatTile(title: "Max HR", value: session.maxHeartRate.map { "\(Int($0))" } ?? "—", subtitle: "bpm")
                        StatTile(title: "Effort", value: session.rpe.map { "\($0)/10" } ?? "—", subtitle: "your rating")
                    }
                }

                if !session.nextTimeNote.isEmpty {
                    Label(session.nextTimeNote, systemImage: "arrow.up.forward.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !session.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.headline)
                        Text(session.notes).font(.callout)
                    }
                }

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
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if KeychainHelper.load()?.isEmpty == false {
                        Button {
                            coachSummary = CoachService.buildSummary(sessions: [session], settings: settings)
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
                    Image(systemName: "ellipsis.circle")
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
