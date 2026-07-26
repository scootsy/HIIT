import SwiftUI
import SwiftData

struct SummaryView: View {
    let engine: WorkoutEngine
    let onDone: () -> Void

    @Environment(SettingsStore.self) private var settings
    @Environment(HealthKitManager.self) private var health
    @Environment(\.modelContext) private var context

    @State private var rpe: Int? = nil
    @State private var notes = ""
    @State private var saved = false
    @State private var healthSaved: Bool? = nil
    @State private var nextNote = ""
    @State private var showCoach = false
    @State private var coachSummary = ""

    private var result: SessionResult {
        engine.makeResult(machine: settings.machine(for: engine.plan.equipment),
                          weightKg: settings.value.weightKg)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statsGrid
                    if !saved {
                        RPEPicker(rpe: $rpe)
                        TextField("Notes (optional)", text: $notes, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                        saveButtons
                    } else {
                        afterSave
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(engine.endedEarly ? "Session ended" : "Nice work!")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(isPresented: $showCoach) {
            CoachSheetView(summary: coachSummary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.recover)
                    .font(.title2)
                    .symbolEffect(.bounce, value: saved)
                Text(engine.plan.name)
                    .font(.title3.weight(.bold))
            }
            Text("\(engine.plan.equipment.label) · \(engine.plan.level.label)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statsGrid: some View {
        let r = result
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatTile(title: "Duration", value: clockString(r.totalSeconds), subtitle: "minutes")
                StatTile(title: "Work time", value: clockString(r.workSeconds), subtitle: "in the red")
                StatTile(title: "Intervals", value: "\(r.completedWorkIntervals)/\(r.plan.workPhaseCount)", subtitle: "completed")
            }
            HStack(spacing: 10) {
                StatTile(title: "Energy", value: "\(Int(r.estimatedCalories))", subtitle: "kcal (est.)")
                if r.plan.equipment == .bike {
                    StatTile(title: "Avg HR", value: r.avgHeartRate.map { "\(Int($0))" } ?? "—", subtitle: "bpm")
                } else {
                    StatTile(title: "Distance", value: settings.distanceString(r.estimatedDistanceMeters), subtitle: "estimated")
                }
                StatTile(title: "Max HR", value: r.maxHeartRate.map { "\(Int($0))" } ?? "—", subtitle: "bpm")
            }
            if let recovery = r.hrRecovery {
                StatTile(title: "Heart-rate recovery (1 min)",
                         value: "−\(Int(recovery)) bpm",
                         subtitle: "how fast your HR fell after the last hard effort — bigger drops track with a fitter heart")
            }
        }
    }

    private var saveButtons: some View {
        VStack(spacing: 10) {
            Button {
                save()
            } label: {
                Text("Save workout")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .buttonStyle(.plain)

            Button("Discard", role: .destructive) { onDone() }
                .font(.subheadline)
        }
    }

    private var afterSave: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.up.forward.circle.fill")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next time")
                        .font(.subheadline.weight(.semibold))
                    Text(nextNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

            if let healthSaved {
                Label(healthSaved ? "Saved to Apple Health" : "Couldn't save to Apple Health (check permissions in the Health app)",
                      systemImage: healthSaved ? "heart.circle.fill" : "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(healthSaved ? Theme.recover : .secondary)
            } else {
                Label("Saving to Apple Health…", systemImage: "heart.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if KeychainHelper.load()?.isEmpty == false {
                Button {
                    showCoach = true
                } label: {
                    Label("Ask the AI coach", systemImage: "sparkles")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .buttonStyle(.plain)
            }

            Button {
                onDone()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
    }

    private func save() {
        let r = result
        let session = WorkoutSession(result: r)
        session.rpe = rpe
        session.notes = notes

        let completion = r.plan.workPhaseCount > 0
            ? Double(r.completedWorkIntervals) / Double(r.plan.workPhaseCount)
            : 1
        var hrPercent: Double? = nil
        if let maxHR = settings.maxHR, let avgWork = r.avgWorkHeartRate {
            hrPercent = avgWork / maxHR * 100
        }

        let progress = fetchOrCreateProgress(for: r.plan.equipment)
        let update = ProgressionEngine.evaluate(
            currentLevel: progress.level,
            rpe: rpe,
            completionRatio: completion,
            avgWorkHRPercent: hrPercent,
            workOverrideLevels: r.workOverrideLevels)
        progress.level = update.newLevel
        progress.sessionsCompleted += 1
        progress.lastSessionDate = r.endDate
        if r.plan.vibe == .easy || r.plan.name.contains("Recovery") {
            progress.hardSessionsSinceEasy = 0
        } else {
            progress.hardSessionsSinceEasy += 1
        }
        session.nextTimeNote = update.note
        nextNote = update.note

        context.insert(session)
        try? context.save()
        saved = true

        coachSummary = "The user just finished this session — give feedback with it in mind.\n"
            + CoachService.buildSummary(sessions: [session], settings: settings)

        Task {
            let ok = await health.saveWorkout(result: r)
            healthSaved = ok
            session.savedToHealth = ok
            try? context.save()
        }
    }

    private func fetchOrCreateProgress(for equipment: Equipment) -> EquipmentProgress {
        let all = (try? context.fetch(FetchDescriptor<EquipmentProgress>())) ?? []
        if let existing = all.first(where: { $0.equipmentRaw == equipment.rawValue }) {
            return existing
        }
        let fresh = EquipmentProgress(equipmentRaw: equipment.rawValue)
        context.insert(fresh)
        return fresh
    }
}

struct CoachSheetView: View {
    let summary: String

    @Environment(\.dismiss) private var dismiss
    @State private var text: String? = nil
    @State private var errorMessage: String? = nil
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if loading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Thinking about your training…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if let text {
                        Text(text)
                            .font(.callout)
                            .textSelection(.enabled)
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("AI Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let key = KeychainHelper.load(), !key.isEmpty else {
            errorMessage = "Add your Anthropic API key in Settings → AI Coach first."
            loading = false
            return
        }
        do {
            text = try await CoachService.feedback(apiKey: key, summary: summary)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}
