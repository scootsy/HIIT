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

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "flame.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent)
            Text("HIIT Coach")
                .font(.system(.largeTitle, design: .rounded).weight(.heavy))
            VStack(alignment: .leading, spacing: 18) {
                featureRow(icon: "wand.and.stars", title: "Workouts built for you",
                           text: "Pick your machine and how long you've got — a research-based interval session is built around your level.")
                featureRow(icon: "timer", title: "Guided in real time",
                           text: "Big timers, clear targets, and early warnings before every speed or resistance change.")
                featureRow(icon: "chart.line.uptrend.xyaxis", title: "Progress that compounds",
                           text: "Each session feeds the next: finish strong and the targets step up, struggle and they ease off.")
            }
            .padding(.horizontal, 8)
            Spacer()
            Text("General fitness guidance, not medical advice. Check with a doctor before starting a new exercise program.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button {
                    connecting = true
                    Task {
                        _ = await health.requestAuthorization()
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

                Button("Set up manually later") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
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
