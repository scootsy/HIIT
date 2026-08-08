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
    @State private var maxHRPromptDone = false

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
                    if let objectives = SessionObjectives.evaluate(engine: engine) {
                        ObjectivesCard(lines: objectives)
                    }
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
        return SessionStatsGrid(
            equipment: r.plan.equipment,
            totalSeconds: r.totalSeconds,
            workSeconds: r.workSeconds,
            completedIntervals: r.completedWorkIntervals,
            totalIntervals: r.plan.workPhaseCount,
            calories: r.estimatedCalories,
            distanceMeters: r.estimatedDistanceMeters,
            avgHeartRate: r.avgHeartRate,
            maxHeartRate: r.maxHeartRate,
            hrRecovery: r.hrRecovery,
            suspendedSeconds: engine.suspendedSeconds)
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

            // Max-HR calibration: every band and grade sits on an *estimated*
            // max (±7–11 bpm of individual error). A genuinely observed higher
            // max is better data — offered once, never applied silently.
            if !maxHRPromptDone,
               let observed = engine.maxObservedHR,
               let assumed = settings.maxHR,
               observed >= assumed + 2, observed <= 215 {
                maxHRCard(observed: observed, assumed: assumed)
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

    private func maxHRCard(observed: Double, assumed: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bolt.heart.fill")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("You hit \(Int(observed)) bpm today")
                        .font(.subheadline.weight(.semibold))
                    Text("Your zones assume a max of \(Int(assumed)). Using the observed number makes every target and grade more accurate — keep the estimate if this looks like a sensor spike.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button("Use \(Int(observed))") {
                    settings.value.maxHROverride = observed
                    maxHRPromptDone = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                Button("Keep \(Int(assumed))") {
                    maxHRPromptDone = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func save() {
        // A double-registered tap must not insert the session twice and
        // advance progression twice. (This runs synchronously on the main
        // actor, so a second tap can't interleave before `saved` flips.)
        guard !saved else { return }

        let r = result
        let lines = SessionObjectives.evaluate(engine: engine)
        let outcome = SessionSaver.save(result: r, rpe: rpe, notes: notes,
                                        objectives: lines,
                                        suspendedSeconds: engine.suspendedSeconds,
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
        // The objective grades tell the coach *why* a session landed the way
        // it did — feedback gets dramatically more specific with them.
        if let lines {
            coachSummary += "\nHow the session graded against its objectives:\n"
                + lines.map { "- \($0.title). \($0.detail)" }.joined(separator: "\n")
        }

        // In the degraded in-memory launch the checkpoint stays on disk (see
        // SessionSaver) and the next healthy launch re-saves this workout —
        // exporting to Health now too would duplicate it there. Skip quietly
        // (.notAuthorized renders nothing); the recovery path exports instead.
        guard !context.container.configurations.contains(where: { $0.isStoredInMemoryOnly }) else {
            healthSaved = .notAuthorized
            return
        }
        Task { @MainActor in
            let ok = await health.saveWorkout(result: r)
            healthSaved = ok
            session.savedToHealth = (ok == .saved)
            try? context.save()
        }
    }
}

/// The AI coach as a small chat: opens with feedback on the passed summary,
/// then takes follow-up questions. The model can propose plan changes from a
/// fixed menu — rendered as Apply buttons; nothing changes without a tap.
struct CoachSheetView: View {
    let summary: String

    @Environment(SettingsStore.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private struct Bubble: Identifiable {
        let id = UUID()
        var fromCoach: Bool
        var text: String
    }

    /// Full model-facing history (includes the machine summary and hidden
    /// applied-action notes); `bubbles` is only what the user sees.
    @State private var turns: [CoachService.ChatTurn] = []
    @State private var bubbles: [Bubble] = []
    @State private var pendingActions: [CoachService.CoachAction] = []
    @State private var appliedActionIDs: Set<UUID> = []
    @State private var input = ""
    @State private var loading = true
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(bubbles) { bubble in
                                bubbleView(bubble)
                                    .id(bubble.id)
                            }
                            if !pendingActions.isEmpty {
                                actionsCard
                            }
                            if loading {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Thinking about your training…")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, bubbles.isEmpty ? 40 : 4)
                                .frame(maxWidth: .infinity)
                            }
                            if let errorMessage {
                                VStack(alignment: .leading, spacing: 14) {
                                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.secondary)
                                    // Several failure modes are transient
                                    // (offline, rate limit) — offer the retry
                                    // the error text promises.
                                    Button("Try again") {
                                        loading = true
                                        self.errorMessage = nil
                                        Task { await request() }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding()
                    }
                    .onChange(of: bubbles.count) { _, _ in
                        if let last = bubbles.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                inputBar
            }
            .navigationTitle("AI Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            guard turns.isEmpty else { return }
            turns = [.init(role: .user, text: summary)]
            await request()
        }
    }

    private func bubbleView(_ bubble: Bubble) -> some View {
        HStack {
            if !bubble.fromCoach { Spacer(minLength: 40) }
            Text(bubble.text)
                .font(.callout)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(bubble.fromCoach
                            ? AnyShapeStyle(Color(.secondarySystemGroupedBackground))
                            : AnyShapeStyle(Theme.accent.opacity(0.9)),
                            in: RoundedRectangle(cornerRadius: 15))
                .foregroundStyle(bubble.fromCoach ? Color.primary : Color.white)
            if bubble.fromCoach { Spacer(minLength: 40) }
        }
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PROPOSED CHANGES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(pendingActions) { action in
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(Theme.accent)
                    Text(action.label)
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    if appliedActionIDs.contains(action.id) {
                        Label("Applied", systemImage: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.recover)
                    } else {
                        Button("Apply") { apply(action) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("Changes happen only when you tap Apply — the coach can't change anything on its own.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask the coach…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit { sendUserMessage() }
            Button {
                sendUserMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(loading || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func sendUserMessage() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !loading else { return }
        input = ""
        bubbles.append(Bubble(fromCoach: false, text: trimmed))
        turns.append(.init(role: .user, text: trimmed))
        pendingActions = []
        errorMessage = nil
        loading = true
        Task { await request() }
    }

    private func request() async {
        let provider = settings.coachProvider
        guard let key = KeychainHelper.load(provider: provider), !key.isEmpty else {
            errorMessage = "Add your \(provider.label) API key in Settings → AI Coach first."
            loading = false
            return
        }
        do {
            let reply = try await CoachService.chat(provider: provider, apiKey: key, turns: turns)
            // Keep the raw reply (ACTION lines included) in the model-facing
            // history so the model remembers what it proposed.
            turns.append(.init(role: .assistant, text: reply))
            let parsed = CoachService.parseActions(from: reply)
            if !parsed.text.isEmpty {
                bubbles.append(Bubble(fromCoach: true, text: parsed.text))
            }
            pendingActions = parsed.actions
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func apply(_ action: CoachService.CoachAction) {
        guard !appliedActionIDs.contains(action.id) else { return }
        switch action.type {
        case "adjust_level":
            guard let raw = action.equipment, let equipment = Equipment(rawValue: raw),
                  let delta = action.delta else { return }
            let progress = SessionSaver.fetchOrCreateProgress(for: equipment, context: context)
            progress.level += Double(max(-2, min(2, delta)))
            try? context.save()
        case "set_next_minutes":
            guard let minutes = action.minutes else { return }
            settings.value.coachRequestedMinutes = min(60, max(8, minutes))
        case "prefer_walk_recoveries":
            guard let enabled = action.enabled else { return }
            settings.value.preferWalkRecoveries = enabled
        default:
            return
        }
        appliedActionIDs.insert(action.id)
        // Tell the model without cluttering the visible thread — sent along
        // with the user's next message.
        turns.append(.init(role: .user,
                           text: "[app note: the user tapped Apply on \"\(action.label)\" — it is now in effect]"))
    }
}
