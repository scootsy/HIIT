import SwiftUI
import SwiftData

struct RootView: View {
    var storeLoadFailed: Bool = false

    @AppStorage("hiit.hasOnboarded") private var hasOnboarded = false
    @Environment(SettingsStore.self) private var settings
    @Environment(HealthKitManager.self) private var health
    @Environment(\.modelContext) private var context
    @State private var pendingCheckpoint: WorkoutCheckpoint? = nil
    @State private var showStoreWarning = false

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Train", systemImage: "flame.fill") }
            HistoryView()
                .tabItem { Label("History", systemImage: "chart.bar.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .sheet(isPresented: welcomeBinding) {
            WelcomeView()
        }
        .onAppear {
            showStoreWarning = storeLoadFailed
            // A leftover checkpoint means a workout was interrupted (crash,
            // jetsam, force-quit) before it could be saved — offer it back.
            if pendingCheckpoint == nil, let checkpoint = WorkoutCheckpoint.load() {
                if checkpoint.totalSeconds >= 60 {
                    pendingCheckpoint = checkpoint
                } else {
                    WorkoutCheckpoint.clear()
                }
            }
        }
        .alert("Recover unsaved workout?", isPresented: recoveryBinding) {
            Button("Save workout") { recoverCheckpoint() }
            Button("Discard", role: .destructive) {
                WorkoutCheckpoint.clear()
                pendingCheckpoint = nil
            }
        } message: {
            if let checkpoint = pendingCheckpoint {
                Text("A \(Int(checkpoint.totalSeconds / 60))-minute \(checkpoint.plan.equipment.label.lowercased()) session from \(checkpoint.savedAt.formatted(date: .abbreviated, time: .shortened)) ended before it was saved.")
            }
        }
        .alert("Workout history unavailable", isPresented: $showStoreWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your saved workouts couldn't be opened, so this session won't be recorded. Restarting the app usually fixes this; your history has not been deleted.")
        }
    }

    private var welcomeBinding: Binding<Bool> {
        Binding(get: { !hasOnboarded }, set: { hasOnboarded = !$0 })
    }

    private var recoveryBinding: Binding<Bool> {
        Binding(get: { pendingCheckpoint != nil && hasOnboarded },
                set: { if !$0 { pendingCheckpoint = nil } })
    }

    private func recoverCheckpoint() {
        guard let checkpoint = pendingCheckpoint else { return }
        let result = checkpoint.makeResult(
            machine: settings.machine(for: checkpoint.plan.equipment),
            weightKg: settings.value.weightKg)
        let outcome = SessionSaver.save(result: result, rpe: nil, notes: "",
                                        context: context, settings: settings)
        pendingCheckpoint = nil
        let session = outcome.session
        Task { @MainActor in
            let ok = await health.saveWorkout(result: result)
            session.savedToHealth = (ok == .saved)
            try? context.save()
        }
    }
}

struct WelcomeView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HealthKitManager.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var healthError: String? = nil

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "flame.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent)
            Text("HIIT Coach")
                .font(.system(.largeTitle, design: .rounded).weight(.heavy))
            VStack(alignment: .leading, spacing: 18) {
                featureRow(icon: "wand.and.stars", title: "Built around you",
                           text: "Your machine, your time, your level.")
                featureRow(icon: "timer", title: "Guided live",
                           text: "Clear targets, early warnings before changes.")
                featureRow(icon: "chart.line.uptrend.xyaxis", title: "Progressive",
                           text: "Finish strong and the next session steps up.")
            }
            .padding(.horizontal, 8)
            Spacer()
            Text("Not medical advice — check with a doctor before starting a new exercise program.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button {
                    connecting = true
                    Task {
                        if let error = await health.requestAuthorization() {
                            healthError = error
                            connecting = false
                            return
                        }
                        let snapshot = await health.fetchProfile()
                        let gotData = settings.apply(snapshot)
                        connecting = false
                        if gotData {
                            dismiss()
                        } else {
                            // Access denied on the sheet, or an empty Health
                            // profile — don't dismiss as if it worked.
                            healthError = "No profile data came back. If you declined access, you can allow it later under Health → Profile → Apps → HIIT Coach — or just enter your details manually in Settings."
                        }
                    }
                } label: {
                    HStack {
                        if connecting { ProgressView().tint(.white) }
                        Text("Connect Apple Health")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(connecting)

                Button("Skip") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .alert("Couldn't connect Apple Health", isPresented: Binding(
            get: { healthError != nil },
            set: { if !$0 { healthError = nil } })) {
            Button("Continue without Health") { dismiss() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(healthError ?? "")
        }
    }

    private func featureRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
