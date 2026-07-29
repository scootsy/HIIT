import SwiftUI

struct RootView: View {
    @AppStorage("hiit.hasOnboarded") private var hasOnboarded = false

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
    }

    private var welcomeBinding: Binding<Bool> {
        Binding(get: { !hasOnboarded }, set: { hasOnboarded = !$0 })
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
                        settings.apply(snapshot)
                        connecting = false
                        dismiss()
                    }
                } label: {
                    HStack {
                        if connecting { ProgressView().tint(.white) }
                        Text("Connect Apple Health")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
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
