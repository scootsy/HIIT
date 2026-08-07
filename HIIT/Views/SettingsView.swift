import SwiftUI

struct SettingsView: View {
    private enum ProfileField: String, Identifiable {
        case age, weight, restingHR, maxHR
        var id: String { rawValue }
    }

    @Environment(SettingsStore.self) private var settings
    @Environment(HealthKitManager.self) private var health
    @State private var apiKey = ""
    @State private var keyLoaded = false
    @State private var keySaveResult: Bool? = nil
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
                    Text("Any strap or watch that broadcasts Bluetooth heart rate. Apple Watch: just start a workout on the Watch instead.")
                }
                Section {
                    Picker("Experience", selection: experienceBinding) {
                        ForEach(ExperienceLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    Toggle("Prefer low impact (incline walking)", isOn: $store.value.preferLowImpact)
                    Toggle("Walk during recoveries", isOn: $store.value.preferWalkRecoveries)
                    Picker("Units", selection: $store.value.useMetric) {
                        Text("Miles / mph").tag(false)
                        Text("Kilometers / km/h").tag(true)
                    }
                    Toggle("Sound cues", isOn: $store.value.soundOn)
                    Toggle("Haptic cues", isOn: $store.value.hapticsOn)
                } header: {
                    Text("Training")
                } footer: {
                    Text("Experience adjusts automatically from your results.")
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
                    Picker("Provider", selection: providerBinding) {
                        ForEach(CoachProvider.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    SecureField(settings.coachProvider.keyPlaceholder, text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(keySaveLabel) {
                        keySaveResult = KeychainHelper.save(
                            apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            provider: settings.coachProvider)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { keySaveResult = nil }
                    }
                } header: {
                    Text("AI Coach (optional)")
                } footer: {
                    Text("Each key stays in the device Keychain and is sent only to \(settings.coachProvider.label). Coach requests include your profile numbers (age, weight, resting HR), experience level, recent session stats, and your workout notes. Get a key at \(settings.coachProvider.consoleName).")
                }

                Section {
                    NavigationLink("The science behind your workouts") {
                        ScienceView()
                    }
                    LabeledContent("Version",
                                   value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                } header: {
                    Text("About")
                } footer: {
                    Text("Not medical advice. Stop any session that causes pain, dizziness, or chest discomfort.")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                // One-shot: onAppear re-fires on every tab switch and
                // navigation pop, and must not clobber a typed-but-unsaved key.
                guard !keyLoaded else { return }
                keyLoaded = true
                apiKey = KeychainHelper.load(provider: settings.coachProvider) ?? ""
            }
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

    private var keySaveLabel: String {
        switch keySaveResult {
        case true?: return "Saved ✓"
        case false?: return "Couldn't save — try again"
        case nil: return "Save key"
        }
    }

    // MARK: - Profile

    /// Connected: synced values flow one way, Health → app, shown read-only.
    /// Values Health didn't provide stay manually editable in place — denying
    /// a single Health toggle must never lock a field out of the app. Manual
    /// entry (via picker sheets) is the default when Health isn't connected.
    private var profileSection: some View {
        Section {
            if settings.value.healthConnected {
                if settings.value.age != nil {
                    LabeledContent("Age", value: settings.value.age.map(String.init) ?? "—")
                } else {
                    profileRow("Age", value: "Set", field: .age)
                }
                if settings.value.weightKg != nil {
                    LabeledContent("Weight", value: settings.weightString())
                } else {
                    profileRow("Weight", value: "Set", field: .weight)
                }
                if settings.value.restingHR != nil {
                    LabeledContent("Resting heart rate", value: settings.value.restingHR.map { "\(Int($0)) bpm" } ?? "—")
                } else {
                    profileRow("Resting heart rate", value: "Optional", field: .restingHR)
                }
                maxHRRow
                Button {
                    refreshing = true
                    Task {
                        let snapshot = await health.fetchProfile()
                        // An all-nil snapshot means revoked access or an empty
                        // Health profile — say so instead of silently stopping
                        // the spinner with a stale "last synced" date.
                        if !settings.apply(snapshot) {
                            healthError = "Nothing came back from Health. If you revoked access, re-allow it under Health → Profile → Apps → HIIT Coach — or keep editing your details here."
                        }
                        refreshing = false
                    }
                } label: {
                    HStack {
                        Label("Refresh from Apple Health", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if refreshing { ProgressView() }
                    }
                }
                Button("Disconnect Apple Health", role: .destructive) {
                    settings.disconnectHealth()
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
                Text("Synced from Apple Health\(lastSyncText). Edit in the Health app, then refresh — anything Health doesn't provide can be set here.")
            } else {
                Text("Connect Apple Health to fill this in automatically.")
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
        if !settings.apply(snapshot) {
            healthError = "No profile data came back. If you declined access, allow it under Health → Profile → Apps → HIIT Coach; otherwise add your details to the Health app and try again — or keep entering them manually here."
        }
    }

    private var healthErrorBinding: Binding<Bool> {
        Binding(get: { healthError != nil }, set: { if !$0 { healthError = nil } })
    }

    // MARK: - Picker sheets (manual entry)

    @ViewBuilder
    private func profileEditor(for field: ProfileField) -> some View {
        // Initial values are clamped into each wheel's range (a Health-synced
        // value can sit outside it, which leaves the Picker with no selected
        // row at all); nothing is written until the sheet's Done commits.
        switch field {
        case .age:
            NumberPickerSheet(
                title: "Age",
                range: 14...90,
                suffix: "years",
                initial: settings.value.age ?? 35,
                onSave: { settings.value.age = $0 })
        case .weight:
            if settings.value.useMetric {
                NumberPickerSheet(
                    title: "Weight",
                    range: 35...200,
                    suffix: "kg",
                    initial: Int((settings.value.weightKg ?? 75).rounded()),
                    onSave: { settings.value.weightKg = Double($0) })
            } else {
                NumberPickerSheet(
                    title: "Weight",
                    range: 80...440,
                    suffix: "lb",
                    initial: Int(((settings.value.weightKg ?? 75) * 2.20462).rounded()),
                    onSave: { settings.value.weightKg = Double($0) / 2.20462 })
            }
        case .restingHR:
            NumberPickerSheet(
                title: "Resting heart rate",
                range: 35...100,
                suffix: "bpm",
                initial: Int(settings.value.restingHR ?? 65),
                onSave: { settings.value.restingHR = Double($0) })
        case .maxHR:
            MaxHRSheet()
        }
    }

    private var experienceBinding: Binding<ExperienceLevel> {
        Binding(get: { settings.experience }, set: { settings.experience = $0 })
    }

    /// Switching provider swaps the visible key field to that provider's
    /// stored key — each provider keeps its own Keychain entry.
    private var providerBinding: Binding<CoachProvider> {
        Binding(
            get: { settings.coachProvider },
            set: { provider in
                settings.coachProvider = provider
                apiKey = KeychainHelper.load(provider: provider) ?? ""
                keySaveResult = nil
            })
    }
}

/// A single wheel — the right control for set-once numbers. The value is
/// staged locally and written only when Done commits it: the old
/// binding-backed version had to pre-commit its default the moment the sheet
/// opened (a wheel never calls the setter for an unchanged selection), which
/// silently persisted "age 35 / 75 kg / 65 bpm" even when the user swiped
/// the sheet away.
struct NumberPickerSheet: View {
    let title: String
    let range: ClosedRange<Int>
    let suffix: String
    let initial: Int
    let onSave: (Int) -> Void
    @State private var selection = 0
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
                    Button("Done") {
                        onSave(selection)
                        dismiss()
                    }
                }
            }
            .onAppear {
                selection = min(range.upperBound, max(range.lowerBound, initial))
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
                    LabeledContent("Estimated", value: settings.maxHR.map { "\(Int($0)) bpm" } ?? "needs age")
                    Text("Tanaka estimate (208 − 0.7 × age). Set a custom value only if you know your true max.")
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
            MachineProfileForm(equipment: equipment, machine: $machine)
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
                        "Classic intervals use work:recovery ratios of roughly 1:2.5 for beginners tapering to 1:1 as you advance, following ACSM progression guidance. The Norwegian 4×4 (4 minutes at 90–95% HRmax, 3 minutes of ~70% active recovery, ×3–4, behind a full 8-minute warm-up) comes from Helgerud et al. (2007), one of the most-replicated VO₂max protocols. 10-20-30 (30s easy, 20s moderate, 10s sprint) comes from Gunnarsson & Bangsbo (2012), which showed large fitness gains from remarkably small sprint doses. Hill climbs deliver a similar cardiovascular stimulus with lower joint impact — useful on days you don't want to pound pavement.")
                section("Recovery intervals",
                        "Recoveries are gait-explicit: beginners and intermediates walk (2.8/3.4 mph), advanced runners jog (5.0 mph) — nothing is ever prescribed in the 4.2–4.7 mph range, where humans naturally switch between walking and running and neither gait feels easy (Hreljac, 1993). A settings toggle swaps advanced jog recoveries for brisk walks. After all-out sprints the app prescribes a slow 2.2 mph walk instead: jogging between short sprints diverts oxygen away from the muscles' energy resynthesis and dramatically cuts how much sprinting a session can hold (Dupont et al., 2004). Recovery pace never gets harder as you progress — recoveries exist to make the next effort count, not as a training stimulus of their own.")
                section("Why the app warns you early",
                        "Treadmill belts take several seconds to change speed. Every plan carries a per-machine warning lead (default 10s on a treadmill), so the screen turns amber and counts down before each change — you hit the buttons early and arrive at the new speed as the interval starts. Protocols with very fast changes, like 10-20-30, are never assigned on a treadmill.")
                section("Heart-rate targets",
                        "Your max heart rate is estimated with the Tanaka formula (208 − 0.7 × age), which outperforms the old 220 − age rule. Work intervals target 75–95% of HRmax depending on your level (the Norwegian 4×4 pushes for 90–95% in the back half of each rep); recoveries aim below 75%. With a live heart-rate source (an Apple Watch workout or a chest strap), the app nudges you in real time when you're above or below the band — and gives long efforts a real ramp before asking for more, since heart rate takes about two minutes to catch up to a four-minute push.")
                section("How sessions are graded",
                        "With live heart rate, the summary grades each session the way training studies define compliant execution. The headline metric is time at or above your work-band floor — roughly 7–10 minutes per full session is the dose HIIT is programmed for. Long efforts (60s+) count as achieved when your heart rate enters the band at any point — averages would punish the unavoidable ramp-in — while short sprints are never graded individually, because a maximal 20-second effort can end before your heart rate reacts at all. Only long (2 min+) recoveries are graded on how far your heart rate fell; shorter ones physiologically can't show a drop, and that's normal.")
                section("The fitness signals",
                        "Cardio Fitness (VO₂max) is the single best-evidenced fitness marker and the outcome HIIT most directly improves — Apple estimates it from outdoor Watch walks and runs, and the History tab charts your trend. Resting heart rate tends to fall as your aerobic engine strengthens. Heart-rate recovery — how far your HR drops in the minute after a hard effort — is measured automatically at the end of your last interval when live HR is available; faster drops track with better cardiovascular fitness (a drop under ~12 bpm is worth mentioning to a doctor).")
                section("Progressive overload",
                        "Fitness improves when the stimulus gradually increases. After each session you rate the effort (RPE). Finish everything at RPE ≤ 7 and the next session's targets step up (~0.2 mph or one resistance notch per step); a maximal or unfinished session holds or steps back. If you override targets mid-workout — running 5.5 when the plan said 5.0 — the next session starts from what you actually did. Two guardrails keep the climb safe: targets never rise more than one step in any rolling week, however good the week felt (rapid ramps are the classic overuse-injury setup), and stacking three-plus hard sessions or 150+ interval minutes into seven days earns a gentle suggestion to make the next one easy. Roughly every sixth hard session is deliberately lighter — adaptation happens during recovery, and the app schedules it so you don't have to.")
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
