import SwiftUI

struct SettingsView: View {
    private enum ProfileField: String, Identifiable {
        case age, weight, restingHR, maxHR
        var id: String { rawValue }
    }

    @Environment(SettingsStore.self) private var settings
    @Environment(HealthKitManager.self) private var health
    @State private var apiKey = KeychainHelper.load() ?? ""
    @State private var keySaved = false
    @State private var refreshing = false
    @State private var healthError: String? = nil
    @State private var editingField: ProfileField? = nil
    @State private var showHRMonitor = false

    var body: some View {
        @Bindable var store = settings
        NavigationStack {
            Form {
                profileSection
                Section {
                    Button {
                        showHRMonitor = true
                    } label: {
                        LabeledContent("Heart-rate monitor", value: settings.value.hrMonitorName ?? "Add")
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Live heart rate")
                } footer: {
                    Text("Works with any watch or chest strap that broadcasts standard Bluetooth heart rate (Amazfit, Polar, Garmin, Coospo…). Pair once and every workout connects automatically. Apple Watch users can skip this — just start any workout on the Watch.")
                }
                Section("Training") {
                    Picker("Experience", selection: experienceBinding) {
                        ForEach(ExperienceLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    Toggle("Prefer low impact (incline walking)", isOn: $store.value.preferLowImpact)
                    Picker("Units", selection: $store.value.useMetric) {
                        Text("Miles / mph").tag(false)
                        Text("Kilometers / km/h").tag(true)
                    }
                    Toggle("Sound cues", isOn: $store.value.soundOn)
                    Toggle("Haptic cues", isOn: $store.value.hapticsOn)
                }

                Section("Equipment") {
                    ForEach([Equipment.treadmill, Equipment.bike]) { equipment in
                        NavigationLink {
                            MachineEditView(equipment: equipment)
                        } label: {
                            Label(equipment.label, systemImage: equipment.icon)
                        }
                    }
                }

                Section {
                    SecureField("Anthropic API key (sk-ant-…)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(keySaved ? "Saved ✓" : "Save key") {
                        KeychainHelper.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        keySaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { keySaved = false }
                    }
                } header: {
                    Text("AI Coach (optional)")
                } footer: {
                    Text("Adds an 'Ask the AI coach' button after workouts and in History. Your key is stored in the device Keychain and only ever sent directly to Anthropic. Get one at console.anthropic.com — usage is billed to your account.")
                }

                Section {
                    NavigationLink("The science behind your workouts") {
                        ScienceView()
                    }
                    LabeledContent("Version", value: "1.0")
                } header: {
                    Text("About")
                } footer: {
                    Text("HIIT Coach offers general fitness guidance, not medical advice. Stop any session that causes pain, dizziness, or chest discomfort, and talk to a doctor before starting a new exercise program.")
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $editingField) { field in
                profileEditor(for: field)
                    .presentationDetents([.height(320)])
            }
            .sheet(isPresented: $showHRMonitor) {
                HRMonitorSheet()
            }
            .alert("Couldn't connect Apple Health", isPresented: healthErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(healthError ?? "")
            }
        }
    }

    // MARK: - Profile

    /// Connected: values flow one way, Health → app, shown read-only. These
    /// aren't knobs to fiddle with — age doesn't need a stepper. Manual entry
    /// (via picker sheets) exists only when Health isn't connected.
    private var profileSection: some View {
        Section {
            if settings.value.healthConnected {
                LabeledContent("Age", value: settings.value.age.map(String.init) ?? "—")
                LabeledContent("Weight", value: settings.weightString())
                LabeledContent("Resting heart rate", value: settings.value.restingHR.map { "\(Int($0)) bpm" } ?? "—")
                maxHRRow
                Button {
                    refreshing = true
                    Task {
                        let snapshot = await health.fetchProfile()
                        settings.apply(snapshot)
                        refreshing = false
                    }
                } label: {
                    HStack {
                        Label("Refresh from Apple Health", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if refreshing { ProgressView() }
                    }
                }
            } else {
                Button {
                    Task { await connectHealth() }
                } label: {
                    Label("Connect Apple Health", systemImage: "heart.circle.fill")
                        .font(.body.weight(.medium))
                }
                profileRow("Age", value: settings.value.age.map(String.init) ?? "Set", field: .age)
                profileRow("Weight", value: settings.value.weightKg != nil ? settings.weightString() : "Set", field: .weight)
                profileRow("Resting heart rate", value: settings.value.restingHR.map { "\(Int($0)) bpm" } ?? "Optional", field: .restingHR)
                maxHRRow
            }
        } header: {
            Text("Profile")
        } footer: {
            if settings.value.healthConnected {
                Text("Synced from Apple Health\(lastSyncText). Update values in the Health app, then refresh here. Age sets your heart-rate zones; weight drives calorie estimates; resting HR calibrates starting intensity.")
            } else {
                Text("Best experience: connect Apple Health and this fills itself in. Age sets your heart-rate zones; weight drives calorie estimates; resting HR calibrates starting intensity.")
            }
        }
    }

    private var lastSyncText: String {
        guard let date = settings.value.lastHealthSync else { return "" }
        return " (last synced \(date.formatted(.relative(presentation: .named))))"
    }

    private func profileRow(_ title: String, value: String, field: ProfileField) -> some View {
        Button {
            editingField = field
        } label: {
            LabeledContent(title, value: value)
        }
        .foregroundStyle(.primary)
    }

    private var maxHRRow: some View {
        Button {
            editingField = .maxHR
        } label: {
            LabeledContent("Max heart rate") {
                if let override = settings.value.maxHROverride {
                    Text("\(Int(override)) bpm (custom)")
                } else if let auto = settings.maxHR {
                    Text("\(Int(auto)) bpm (auto)")
                } else {
                    Text("needs age")
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func connectHealth() async {
        if let error = await health.requestAuthorization() {
            healthError = error
            return
        }
        let snapshot = await health.fetchProfile()
        settings.apply(snapshot)
        if snapshot.age == nil && snapshot.weightKg == nil && snapshot.restingHR == nil {
            healthError = "Connected, but no profile data came back. If you declined access, allow it under Health → Profile → Apps → HIIT Coach; otherwise add your details to the Health app and refresh."
        }
    }

    private var healthErrorBinding: Binding<Bool> {
        Binding(get: { healthError != nil }, set: { if !$0 { healthError = nil } })
    }

    // MARK: - Picker sheets (manual entry)

    @ViewBuilder
    private func profileEditor(for field: ProfileField) -> some View {
        switch field {
        case .age:
            NumberPickerSheet(
                title: "Age",
                range: 14...90,
                suffix: "years",
                selection: Binding(
                    get: { settings.value.age ?? 35 },
                    set: { settings.value.age = $0 }))
        case .weight:
            if settings.value.useMetric {
                NumberPickerSheet(
                    title: "Weight",
                    range: 35...200,
                    suffix: "kg",
                    selection: Binding(
                        get: { Int((settings.value.weightKg ?? 75).rounded()) },
                        set: { settings.value.weightKg = Double($0) }))
            } else {
                NumberPickerSheet(
                    title: "Weight",
                    range: 80...440,
                    suffix: "lb",
                    selection: Binding(
                        get: { Int(((settings.value.weightKg ?? 75) * 2.20462).rounded()) },
                        set: { settings.value.weightKg = Double($0) / 2.20462 }))
            }
        case .restingHR:
            NumberPickerSheet(
                title: "Resting heart rate",
                range: 35...100,
                suffix: "bpm",
                selection: Binding(
                    get: { Int(settings.value.restingHR ?? 65) },
                    set: { settings.value.restingHR = Double($0) }))
        case .maxHR:
            MaxHRSheet()
        }
    }

    private var experienceBinding: Binding<ExperienceLevel> {
        Binding(get: { settings.experience }, set: { settings.experience = $0 })
    }
}

/// A single wheel — the right control for set-once numbers.
struct NumberPickerSheet: View {
    let title: String
    let range: ClosedRange<Int>
    let suffix: String
    @Binding var selection: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Picker(title, selection: $selection) {
                ForEach(Array(range), id: \.self) { value in
                    Text("\(value) \(suffix)").tag(value)
                }
            }
            .pickerStyle(.wheel)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Max HR defaults to the Tanaka estimate from age; a custom value only makes
/// sense if it came from a real graded test or a Watch-measured max.
struct MaxHRSheet: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Automatic (from age)", isOn: automaticBinding)
                if settings.value.maxHROverride != nil {
                    Picker("Max heart rate", selection: overrideBinding) {
                        ForEach(Array(130...215), id: \.self) { value in
                            Text("\(value) bpm").tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                } else {
                    LabeledContent("Estimated", value: settings.maxHR.map { "\(Int($0)) bpm" } ?? "add your age first")
                    Text("Uses the Tanaka formula (208 − 0.7 × age). Only set a custom value if you know your real max from a fitness test or a Watch-measured hard effort.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Max heart rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var automaticBinding: Binding<Bool> {
        Binding(
            get: { settings.value.maxHROverride == nil },
            set: { automatic in
                if automatic {
                    settings.value.maxHROverride = nil
                } else {
                    settings.value.maxHROverride = settings.maxHR ?? 180
                }
            })
    }

    private var overrideBinding: Binding<Int> {
        Binding(
            get: { Int(settings.value.maxHROverride ?? 180) },
            set: { settings.value.maxHROverride = Double($0) })
    }
}

struct MachineEditView: View {
    let equipment: Equipment
    @Environment(SettingsStore.self) private var settings
    @State private var machine: MachineProfile

    init(equipment: Equipment) {
        self.equipment = equipment
        _machine = State(initialValue: MachineProfile.defaults(for: equipment))
    }

    var body: some View {
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
                    Picker("Resistance levels", selection: $machine.maxResistance) {
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
        }
        .navigationTitle(equipment.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            machine = settings.machine(for: equipment)
        }
        .onChange(of: machine) { _, newValue in
            settings.setMachine(newValue, for: equipment)
        }
    }
}

struct ScienceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Why intervals?",
                        "High-intensity interval training produces similar or larger improvements in aerobic fitness (VO₂max) than steady cardio, in less time. VO₂max is one of the strongest known predictors of long-term health, which is why every plan in this app is built around repeated hard efforts with genuine recoveries.")
                section("The protocols",
                        "Classic intervals use work:recovery ratios of roughly 1:2.5 for beginners tapering to 1:1 as you advance, following ACSM progression guidance. The Norwegian 4×4 (4 minutes at 85–95% HRmax, 3 minutes active recovery, ×4) comes from Helgerud et al. (2007), one of the most-replicated VO₂max protocols. 10-20-30 (30s easy, 20s moderate, 10s sprint) comes from Gunnarsson & Bangsbo (2012), which showed large fitness gains from remarkably small sprint doses. Hill climbs deliver a similar cardiovascular stimulus with lower joint impact — useful on days you don't want to pound pavement.")
                section("Why the app warns you early",
                        "Treadmill belts take several seconds to change speed. Every plan carries a per-machine warning lead (default 10s on a treadmill), so the screen turns amber and counts down before each change — you hit the buttons early and arrive at the new speed as the interval starts. Protocols with very fast changes, like 10-20-30, are never assigned on a treadmill.")
                section("Heart-rate targets",
                        "Your max heart rate is estimated with the Tanaka formula (208 − 0.7 × age), which outperforms the old 220 − age rule. Work intervals target 75–95% of HRmax depending on your level; recoveries aim below 75%. With a live heart-rate source (an Apple Watch workout or a chest strap), the app nudges you in real time when you're above or below the band.")
                section("The fitness signals",
                        "Cardio Fitness (VO₂max) is the single best-evidenced fitness marker and the outcome HIIT most directly improves — Apple estimates it from outdoor Watch walks and runs, and the History tab charts your trend. Resting heart rate tends to fall as your aerobic engine strengthens. Heart-rate recovery — how far your HR drops in the minute after a hard effort — is measured automatically at the end of your last interval when live HR is available; faster drops track with better cardiovascular fitness (a drop under ~12 bpm is worth mentioning to a doctor).")
                section("Progressive overload",
                        "Fitness improves when the stimulus gradually increases. After each session you rate the effort (RPE). Finish everything at RPE ≤ 7 and the next session's targets step up (~0.2 mph or one resistance notch per step); a maximal or unfinished session holds or steps back. If you override targets mid-workout — running 5.5 when the plan said 5.0 — the next session starts from what you actually did. Roughly every sixth hard session is deliberately lighter — adaptation happens during recovery, and the app schedules it so you don't have to.")
                section("Calorie estimates",
                        "Energy is estimated from the ACSM metabolic equations (speed + incline for treadmill and outdoor work, effort-anchored METs for cycling) scaled by your body weight from Apple Health. Estimates are honest approximations, not measurements.")
                section("References",
                        "• Helgerud J. et al., Med Sci Sports Exerc, 2007 — aerobic high-intensity intervals improve VO₂max.\n• Gunnarsson T.P. & Bangsbo J., J Appl Physiol, 2012 — the 10-20-30 training concept.\n• Tanaka H. et al., J Am Coll Cardiol, 2001 — age-predicted maximal heart rate revisited.\n• Cole C.R. et al., N Engl J Med, 1999 — heart-rate recovery after exercise as a predictor.\n• ACSM's Guidelines for Exercise Testing and Prescription — interval progression and metabolic equations.")
            }
            .padding()
        }
        .navigationTitle("The science")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}
