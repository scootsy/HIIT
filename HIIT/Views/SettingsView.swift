import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HealthKitManager.self) private var health
    @State private var apiKey = KeychainHelper.load() ?? ""
    @State private var keySaved = false
    @State private var refreshing = false

    var body: some View {
        @Bindable var store = settings
        NavigationStack {
            Form {
                Section {
                    if settings.value.healthConnected {
                        Button {
                            refreshing = true
                            Task {
                                let snapshot = await health.fetchProfile()
                                settings.apply(snapshot)
                                refreshing = false
                            }
                        } label: {
                            HStack {
                                Label("Refresh from Apple Health", systemImage: "heart.circle.fill")
                                Spacer()
                                if refreshing { ProgressView() }
                            }
                        }
                    } else {
                        Button {
                            Task {
                                _ = await health.requestAuthorization()
                                let snapshot = await health.fetchProfile()
                                settings.apply(snapshot)
                            }
                        } label: {
                            Label("Connect Apple Health", systemImage: "heart.circle")
                        }
                    }
                    Stepper("Age: \(settings.value.age.map(String.init) ?? "—")", value: ageBinding, in: 14...90)
                    Stepper("Weight: \(settings.weightString())", value: weightBinding, in: 35...200, step: 1)
                    Stepper("Resting HR: \(settings.value.restingHR.map { "\(Int($0)) bpm" } ?? "—")", value: restingBinding, in: 35...100)
                    LabeledContent("Estimated max HR", value: settings.maxHR.map { "\(Int($0)) bpm" } ?? "add your age")
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Age sets your heart-rate zones (Tanaka formula), weight improves calorie estimates, and resting heart rate helps calibrate starting intensity.")
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
        }
    }

    private var ageBinding: Binding<Int> {
        Binding(get: { settings.value.age ?? 35 }, set: { settings.value.age = $0 })
    }

    private var weightBinding: Binding<Double> {
        Binding(get: { settings.value.weightKg ?? 75 }, set: { settings.value.weightKg = $0 })
    }

    private var restingBinding: Binding<Int> {
        Binding(get: { Int(settings.value.restingHR ?? 65) }, set: { settings.value.restingHR = Double($0) })
    }

    private var experienceBinding: Binding<ExperienceLevel> {
        Binding(get: { settings.experience }, set: { settings.experience = $0 })
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
                section("Progressive overload",
                        "Fitness improves when the stimulus gradually increases. After each session you rate the effort (RPE). Finish everything at RPE ≤ 7 and the next session's targets step up (~0.2 mph or one resistance notch per step); a maximal or unfinished session holds or steps back. Roughly every sixth hard session is deliberately lighter — adaptation happens during recovery, and the app schedules it so you don't have to.")
                section("Calorie estimates",
                        "Energy is estimated from the ACSM metabolic equations (speed + incline for treadmill and outdoor work, effort-anchored METs for cycling) scaled by your body weight from Apple Health. Estimates are honest approximations, not measurements.")
                section("References",
                        "• Helgerud J. et al., Med Sci Sports Exerc, 2007 — aerobic high-intensity intervals improve VO₂max.\n• Gunnarsson T.P. & Bangsbo J., J Appl Physiol, 2012 — the 10-20-30 training concept.\n• Tanaka H. et al., J Am Coll Cardiol, 2001 — age-predicted maximal heart rate revisited.\n• ACSM's Guidelines for Exercise Testing and Prescription — interval progression and metabolic equations.")
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
