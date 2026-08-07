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
    @State private var saveFailed = false
    @State private var confirmDiscard = false
    @State private var healthSaved: HealthKitManager.WorkoutSaveOutcome? = nil
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
        .alert("Couldn't save this workout", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nothing was recorded — your phone may be low on storage. Try Save again; if it keeps failing, the workout will be offered for recovery on the next launch.")
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard workout", role: .destructive) {
                WorkoutCheckpoint.clear()
                onDone()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The session won't be saved to your history.")
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
                StatTile(title: "HR recovery",
                         value: "−\(Int(recovery)) bpm",
                         subtitle: "1-min drop after a hard effort")
            }
            if engine.suspendedSeconds > 30 {
                Label("Includes \(clockString(engine.suspendedSeconds)) while the app was in the background — cues and live heart rate pause when the screen is off or another app is up front.",
                      systemImage: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var saveButtons: some View {
        VStack(spacing: 10) {
            Button {
                save()
            } label: {
                // Styling lives inside the label so the whole bar is
                // tappable, not just the word (the old pattern left dead
                // flanks that read as a broken button).
                Text("Save workout")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button("Discard", role: .destructive) { confirmDiscard = true }
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

            switch healthSaved {
            case .saved?:
                Label("Saved to Apple Health", systemImage: "heart.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.recover)
            case .failed?:
                Label("Couldn't save to Apple Health — check sharing under Health → Profile → Apps",
                      systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .notAuthorized?:
                // Health was never connected — an expected state, not an error.
                EmptyView()
            case nil:
                Label("Saving to Apple Health…", systemImage: "heart.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if CoachService.isConfigured(settings.coachProvider) {
                Button {
                    showCoach = true
                } label: {
                    Label("Ask the AI coach", systemImage: "sparkles")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            Button {
                onDone()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private func save() {
        // A double-registered tap must not insert the session twice and
        // advance progression twice. (This runs synchronously on the main
        // actor, so a second tap can't interleave before `saved` flips.)
        guard !saved else { return }

        let r = result
        let outcome = SessionSaver.save(result: r, rpe: rpe, notes: notes,
                                        context: context, settings: settings)
        guard let session = outcome.session else {
            // Nothing was persisted and the checkpoint is still on disk —
            // say so instead of flipping to the success state.
            saveFailed = true
            return
        }
        saved = true
        nextNote = outcome.note

        coachSummary = "The user just finished this session — give feedback with it in mind.\n"
            + CoachService.buildSummary(sessions: [session], settings: settings)

        Task { @MainActor in
            let ok = await health.saveWorkout(result: r)
            healthSaved = ok
            session.savedToHealth = (ok == .saved)
            try? context.save()
        }
    }
}

struct CoachSheetView: View {
    let summary: String

    @Environment(SettingsStore.self) private var settings
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
                        VStack(alignment: .leading, spacing: 14) {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            // Several failure modes are transient (offline,
                            // rate limit) — offer the retry the error text
                            // promises instead of dismiss-and-reopen.
                            Button("Try again") {
                                loading = true
                                self.errorMessage = nil
                                Task { await load() }
                            }
                            .buttonStyle(.bordered)
                        }
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
        let provider = settings.coachProvider
        guard let key = KeychainHelper.load(provider: provider), !key.isEmpty else {
            errorMessage = "Add your \(provider.label) API key in Settings → AI Coach first."
            loading = false
            return
        }
        do {
            text = try await CoachService.feedback(provider: provider, apiKey: key, summary: summary)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}
