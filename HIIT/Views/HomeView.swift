import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(SettingsStore.self) private var settings
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @State private var showSetup = false
    @State private var activePlan: WorkoutPlan? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    startCard
                    suggestionCard
                    weekStats
                    if !sessions.isEmpty {
                        recentSection
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Train")
        }
        .sheet(isPresented: $showSetup) {
            SetupView { plan in
                showSetup = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    activePlan = plan
                }
            }
        }
        .fullScreenCover(item: $activePlan) { plan in
            ActiveWorkoutContainerView(plan: plan)
        }
    }

    private var startCard: some View {
        Button {
            showSetup = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start a workout")
                        .font(.title2.weight(.bold))
                    Text("Equipment · time · go")
                        .font(.subheadline)
                        .opacity(0.85)
                }
                Spacer()
                Image(systemName: "bolt.fill")
                    .font(.system(size: 40))
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [Theme.accent, Color(hex: 0xC2354F)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private var suggestionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(Theme.steady)
            Text(suggestionText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var suggestionText: String {
        guard let last = sessions.first else {
            return "Pick a machine and 15 minutes — it builds from there."
        }
        let days = Calendar.current.dateComponents([.day], from: last.date, to: Date()).day ?? 0
        if days == 0 {
            return "Trained today. Going again? Keep it short and easy."
        }
        if days >= 4 {
            return "\(days) days off — ease back in."
        }
        return "\(days == 1 ? "1 day" : "\(days) days") since your last \(last.equipment.label.lowercased()) session — prime time for the next one."
    }

    private var weekStats: some View {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let thisWeek = sessions.filter { $0.date >= weekAgo }
        let minutes = Int(thisWeek.reduce(0) { $0 + $1.totalSeconds } / 60)
        let kcal = Int(thisWeek.reduce(0) { $0 + $1.estimatedCalories })
        return HStack(spacing: 10) {
            StatTile(title: "This week", value: "\(thisWeek.count)", subtitle: "sessions")
            StatTile(title: "Minutes", value: "\(minutes)", subtitle: "last 7 days")
            StatTile(title: "Energy", value: "\(kcal)", subtitle: "kcal (est.)")
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(.headline)
            ForEach(sessions.prefix(3)) { session in
                NavigationLink(value: session) {
                    HistoryRow(session: session)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(for: WorkoutSession.self) { session in
            SessionDetailView(session: session)
        }
    }
}
