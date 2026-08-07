import SwiftUI
import SwiftData

/// Suggestion-first setup: pick where you're training → (machine details,
/// first time only) → the app proposes a complete workout, length included.
/// The whole point of the app is coaching people who don't know how to build
/// workouts, so the plan arrives ready to start — duration and feel are
/// controls for overriding it, and every change regenerates the plan.
struct SetupView: View {
    enum Step { case equipment, machine, suggestion }

    let onStart: (WorkoutPlan) -> Void

    @Environment(SettingsStore.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .equipment
    @State private var equipment: Equipment = .treadmill
    @State private var machine = MachineProfile.defaults(for: .treadmill)
    @State private var level: ExperienceLevel = .beginner
    @State private var minutes = 20
    @State private var suggestedMinutes = 20
    @State private var vibe: SessionVibe = .auto
    @State private var plan: WorkoutPlan? = nil
    @State private var shuffleOffset = 0
    /// Captured when the suggestion step is entered: keeps the first-run
    /// experience picker on screen for the whole visit even though the
    /// answer is persisted on the first plan build.
    @State private var askExperience = false
    /// Non-nil when the weekly load guard fired — shown as an overridable
    /// suggestion banner, never a block.
    @State private var loadAdvice: String? = nil
    /// False when this configuration has exactly one candidate protocol —
    /// shuffling would provably regenerate the identical plan, so the
    /// "Mix it up" button hides instead of silently doing nothing.
    @State private var canShuffle = true

    private let presets = [10, 15, 20, 30, 45]

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .equipment: equipmentStep
                case .machine: machineStep
                case .suggestion: suggestionStep
                }
            }
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step != .equipment {
                        Button("Back") { goBack() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            level = settings.experience
            if let raw = settings.value.lastEquipmentRaw, let saved = Equipment(rawValue: raw) {
                equipment = saved
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case .equipment: return "Where are you training?"
        case .machine: return "Your \(equipment.label.lowercased())"
        case .suggestion: return "Your next workout"
        }
    }

    private func goBack() {
        switch step {
        case .equipment: break
        case .machine: step = .equipment
        case .suggestion: step = settings.hasConfiguredMachine(for: equipment) && equipment != .outdoor ? .machine : .equipment
        }
    }

    // MARK: - Step 1: equipment

    private var equipmentStep: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(Equipment.allCases) { option in
                    Button {
                        equipment = option
                        machine = settings.machine(for: option)
                        if option == .outdoor || settings.hasConfiguredMachine(for: option) {
                            enterSuggestion()
                        } else {
                            step = .machine
                        }
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: option.icon)
                                .font(.title)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.label)
                                    .font(.headline)
                                Text(option.blurb)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Step 2: machine details

    private var machineStep: some View {
        Form {
            MachineProfileForm(equipment: equipment, machine: $machine)
            Section {
                Button {
                    settings.setMachine(machine, for: equipment)
                    enterSuggestion()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Step 3: the suggested workout

    private var suggestionStep: some View {
        Group {
            if let plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Asked once; after that it lives in Settings and
                        // adjusts itself from results.
                        if askExperience {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Experience")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Picker("Experience", selection: $level) {
                                    ForEach(ExperienceLevel.allCases) { option in
                                        Text(option.label).tag(option)
                                    }
                                }
                                .pickerStyle(.segmented)
                                Text(level.blurb)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                            .onChange(of: level) { _, _ in
                                resuggest()
                            }
                        }

                        if let advice = loadAdvice, vibe != .easy {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "moon.zzz.fill")
                                    .foregroundStyle(Theme.steady)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(advice)
                                        .font(.footnote)
                                    Button("Make it easy") {
                                        vibe = .easy
                                        buildPlan()
                                    }
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(14)
                            .background(Theme.steady.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan.name)
                                .font(.title2.weight(.bold))
                            Text(plan.focus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            StatTile(title: "Total", value: clockString(plan.totalSeconds), subtitle: "min")
                            StatTile(title: "Efforts", value: "\(plan.workPhaseCount)", subtitle: "work intervals")
                            StatTile(title: "Energy", value: "\(previewKcal)", subtitle: "kcal (est.)")
                        }

                        durationControl
                        feelControl

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan.phases) { phase in
                                PhaseRowView(phase: phase, targetLine: targetLine(for: phase.target, equipment: plan.equipment, settings: settings))
                            }
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                        if canShuffle {
                            Button {
                                shuffleOffset += 1
                                buildPlan()
                            } label: {
                                // Styling inside the label keeps the whole bar
                                // tappable — outside a .plain button, only the
                                // text itself would respond.
                                Label("Mix it up", systemImage: "shuffle")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            onStart(plan)
                        } label: {
                            Label("Start", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
            } else {
                ProgressView()
            }
        }
    }

    /// Duration chips with the coach's suggestion marked; any tap or stepper
    /// change is a user override and regenerates the plan immediately.
    private var durationControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Length")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if minutes != suggestedMinutes {
                    Button {
                        minutes = suggestedMinutes
                        buildPlan()
                    } label: {
                        Text("Coach suggests \(suggestedMinutes) min")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        minutes = preset
                        buildPlan()
                    } label: {
                        VStack(spacing: 1) {
                            Text("\(preset)")
                                .font(.subheadline.weight(.semibold))
                            if preset == suggestedMinutes {
                                Circle()
                                    .fill(minutes == preset ? Color.white : Theme.accent)
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            minutes == preset ? Theme.accent : Color(.tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(minutes == preset ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Stepper("Custom: \(minutes) minutes", value: minutesBinding, in: 8...60)
                .font(.subheadline)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var feelControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feel")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Feel", selection: $vibe) {
                ForEach(SessionVibe.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: vibe) { _, _ in
                buildPlan()
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { minutes },
            set: { newValue in
                minutes = newValue
                buildPlan()
            })
    }

    private var previewKcal: Int {
        guard let plan else { return 0 }
        let records = plan.phases.map { phase in
            PhaseRecord(kind: phase.kind.rawValue,
                        label: phase.label,
                        plannedSeconds: phase.seconds,
                        actualSeconds: phase.seconds,
                        speedMph: phase.target.speedMph,
                        inclinePercent: phase.target.inclinePercent,
                        resistance: phase.target.resistance)
        }
        let estimate = MetabolicMath.estimate(records: records, equipment: plan.equipment, machine: machine, weightKg: settings.value.weightKg)
        return Int(estimate.kcal)
    }

    // MARK: - Plan generation

    /// Entering the suggestion step: the app picks the session length from
    /// training history and builds the plan before the screen appears.
    private func enterSuggestion() {
        askExperience = settings.value.experienceSetOnce != true
        if !askExperience {
            level = settings.experience
        }
        computeSuggestion()
        minutes = suggestedMinutes
        vibe = .auto
        loadAdvice = weeklyLoadAdvice()
        buildPlan()
        step = .suggestion
    }

    /// A first-run experience change re-runs the suggestion too — length
    /// depends on level, and the user hasn't overridden anything yet.
    private func resuggest() {
        computeSuggestion()
        minutes = suggestedMinutes
        buildPlan()
    }

    private func computeSuggestion() {
        let progress = fetchProgress()
        let daysSince = progress?.lastSessionDate.map {
            Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0
        }
        suggestedMinutes = WorkoutGenerator.suggestMinutes(
            level: level,
            progression: ProgressionEngine.decayedLevel(progress?.level ?? 0, daysSince: daysSince),
            sessionsCompleted: progress?.sessionsCompleted ?? 0,
            hardSessionsSinceEasy: progress?.hardSessionsSinceEasy ?? 0)
    }

    /// Weekly load guard: 2–3 hard sessions a week with ~48h between them is
    /// where HIIT adaptations actually land — stacking more mostly adds
    /// injury and overreaching risk. A triggered guard only *suggests* an
    /// easier day; the user can always ignore it.
    private func weeklyLoadAdvice() -> String? {
        let descriptor = FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        guard let sessions = try? context.fetch(descriptor), let last = sessions.first else { return nil }
        let now = Date()
        let week = sessions.filter { now.timeIntervalSince($0.date) < 7 * 86400 }
        let weekMinutes = week.reduce(0.0) { $0 + $1.totalSeconds } / 60
        if weekMinutes > 150 {
            return "That's over 150 interval minutes in 7 days — more isn't better. An easier session today protects the gains."
        }
        if week.count >= 3 {
            return "Three or more sessions in the last 7 days — hard training lands best with real recovery between doses."
        }
        if now.timeIntervalSince(last.date) < 40 * 3600 && week.count >= 2 {
            return "Less than two days since your last session. Back-to-back hard days blunt the adaptation you trained for."
        }
        return nil
    }

    private func buildPlan() {
        // On the first run the picker's answer is persisted immediately —
        // askExperience keeps the control visible for the rest of the visit.
        if askExperience {
            settings.experience = level
            settings.value.experienceSetOnce = true
        } else {
            level = settings.experience
        }
        settings.value.lastEquipmentRaw = equipment.rawValue
        let progress = fetchProgress()
        // After a long break the accumulated level tapers off, so a returning
        // user eases back in instead of resuming at full pre-break targets.
        let daysSince = progress?.lastSessionDate.map {
            Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0
        }
        let effectiveLevel = ProgressionEngine.decayedLevel(progress?.level ?? 0, daysSince: daysSince)
        let input = GeneratorInput(
            equipment: equipment,
            machine: machine,
            level: level,
            minutes: minutes,
            vibe: vibe,
            progression: effectiveLevel,
            sessionCount: (progress?.sessionsCompleted ?? 0) + shuffleOffset,
            hardSessionsSinceEasy: progress?.hardSessionsSinceEasy ?? 0,
            maxHR: settings.maxHR,
            restingHR: settings.value.restingHR,
            bmi: settings.bmi,
            age: settings.value.age,
            preferLowImpact: settings.value.preferLowImpact,
            preferWalkRecoveries: settings.value.preferWalkRecoveries)
        canShuffle = WorkoutGenerator.candidateProtocols(input).count > 1
        plan = WorkoutGenerator.makePlan(input)
    }

    private func fetchProgress() -> EquipmentProgress? {
        let all = try? context.fetch(FetchDescriptor<EquipmentProgress>())
        return all?.first { $0.equipmentRaw == equipment.rawValue }
    }
}
