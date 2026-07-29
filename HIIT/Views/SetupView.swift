import SwiftUI
import SwiftData

/// Guided setup: equipment → (machine details, first time only) → session
/// length & vibe → plan preview. Machine details are remembered per equipment.
struct SetupView: View {
    enum Step { case equipment, machine, session, preview }

    let onStart: (WorkoutPlan) -> Void

    @Environment(SettingsStore.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .equipment
    @State private var equipment: Equipment = .treadmill
    @State private var machine = MachineProfile.defaults(for: .treadmill)
    @State private var level: ExperienceLevel = .beginner
    @State private var minutes = 20
    @State private var vibe: SessionVibe = .auto
    @State private var plan: WorkoutPlan? = nil
    @State private var shuffleOffset = 0

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .equipment: equipmentStep
                case .machine: machineStep
                case .session: sessionStep
                case .preview: previewStep
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
        case .session: return "Today's session"
        case .preview: return "Your workout"
        }
    }

    private func goBack() {
        switch step {
        case .equipment: break
        case .machine: step = .equipment
        case .session: step = settings.hasConfiguredMachine(for: equipment) && equipment != .outdoor ? .machine : .equipment
        case .preview: step = .session
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
                            step = .session
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
            if equipment == .treadmill {
                Section("Speed") {
                    VStack(alignment: .leading) {
                        Text("Top speed you'd ever use: \(settings.speedString(machine.maxSpeedMph))")
                            .font(.subheadline)
                        Slider(value: $machine.maxSpeedMph, in: 5...15, step: 0.5)
                    }
                    Picker("Speed buttons react", selection: $machine.cueLeadSeconds) {
                        Text("Fast (5s warning)").tag(5)
                        Text("Normal (10s warning)").tag(10)
                        Text("Slow (15s warning)").tag(15)
                    }
                }
                Section("Incline") {
                    Toggle("Has incline", isOn: $machine.hasIncline)
                    if machine.hasIncline {
                        VStack(alignment: .leading) {
                            Text("Max incline: \(Int(machine.maxInclinePercent))%")
                                .font(.subheadline)
                            Slider(value: $machine.maxInclinePercent, in: 4...15, step: 1)
                        }
                    }
                }
            } else {
                Section("Resistance") {
                    Picker("Resistance levels on your bike", selection: $machine.maxResistance) {
                        Text("8").tag(8)
                        Text("10").tag(10)
                        Text("16").tag(16)
                        Text("20").tag(20)
                        Text("24").tag(24)
                        Text("32").tag(32)
                        Text("100 (Peloton-style)").tag(100)
                    }
                }
            }
            Section {
                Button {
                    settings.setMachine(machine, for: equipment)
                    step = .session
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Step 3: session shape

    private var sessionStep: some View {
        Form {
            // Asked once; after that it lives in Settings and adjusts itself
            // from results.
            if settings.value.experienceSetOnce != true {
                Section("Experience") {
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
            }
            Section("How long have you got?") {
                HStack(spacing: 8) {
                    ForEach([10, 15, 20, 30, 45], id: \.self) { preset in
                        Button {
                            minutes = preset
                        } label: {
                            Text("\(preset)")
                                .font(.subheadline.weight(.semibold))
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
                Stepper("Custom: \(minutes) minutes", value: $minutes, in: 8...60)
            }
            Section("Feel") {
                Picker("Feel", selection: $vibe) {
                    ForEach(SessionVibe.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Button {
                    buildPlan()
                    step = .preview
                } label: {
                    Text("Build my workout")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Step 4: preview

    private var previewStep: some View {
        Group {
            if let plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
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
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan.phases) { phase in
                                PhaseRowView(phase: phase, targetLine: targetLine(for: phase.target, equipment: plan.equipment, settings: settings))
                            }
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

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

    private func buildPlan() {
        if settings.value.experienceSetOnce != true {
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
            preferLowImpact: settings.value.preferLowImpact)
        plan = WorkoutGenerator.makePlan(input)
    }

    private func fetchProgress() -> EquipmentProgress? {
        let all = try? context.fetch(FetchDescriptor<EquipmentProgress>())
        return all?.first { $0.equipmentRaw == equipment.rawValue }
    }
}
