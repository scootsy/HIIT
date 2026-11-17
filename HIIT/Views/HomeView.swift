import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(SettingsStore.self) private var settings
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @State private var showSetup = false
    @State private var pendingPlan: WorkoutPlan? = nil
    @State private var activePlan: WorkoutPlan? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    if sessions.isEmpty {
                        emptyState
                    } else {
                        weekStats
                        recentSection
                    }
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .readableWidth(720)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { startBar }
            .navigationDestination(for: WorkoutSession.self) { session in
                SessionDetailView(session: session)
            }
        }
        // The workout cover is presented from the setup sheet's onDismiss —
        // sequenced by the framework instead of a wall-clock delay racing
        // the dismissal animation.
        .sheet(isPresented: $showSetup, onDismiss: {
            if let plan = pendingPlan {
                pendingPlan = nil
                activePlan = plan
            }
        }) {
            SetupView { plan in
                pendingPlan = plan
                showSetup = false
            }
        }
        .fullScreenCover(item: $activePlan) { plan in
            ActiveWorkoutContainerView(plan: plan)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date.now, format: .dateTime.weekday(.wide).month().day())
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(greeting)
                .font(.system(.largeTitle, design: .rounded).weight(.heavy))
            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var statusLine: String {
        guard let last = sessions.first else {
            return "Pick a machine and 15 minutes — it builds from there."
        }
        // Calendar days, not elapsed 24-hour periods — a 9pm session must
        // not still read "Trained today" the next morning.
        let calendar = Calendar.current
        if calendar.isDateInToday(last.date) {
            return "Trained today. Going again? Keep it short and easy."
        }
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: last.date),
                                           to: calendar.startOfDay(for: Date())).day ?? 0
        if days >= 4 {
            return "\(days) days off — ease back in."
        }
        return "\(days == 1 ? "1 day" : "\(days) days") since your last \(last.equipment.label.lowercased()) session."
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 132, height: 132)
                Image(systemName: "flame.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var weekStats: some View {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let thisWeek = sessions.filter { $0.date >= weekAgo }
        let minutes = Int(thisWeek.reduce(0) { $0 + $1.totalSeconds } / 60)
        let kcal = Int(thisWeek.reduce(0) { $0 + $1.estimatedCalories })
        // A rolling 7-day window, and labeled as such — "This week" implied
        // the calendar week the History chart actually uses.
        return HStack(spacing: 10) {
            StatTile(title: "Sessions", value: "\(thisWeek.count)", subtitle: "last 7 days")
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
    }

    // MARK: - Start bar

    /// Pinned above the tab bar so the primary action sits under the thumb;
    /// content scrolls beneath and fades out behind it.
    private var startBar: some View {
        Button {
            showSetup = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                Text("Start a workout")
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            // A thumb-width button, not a banner, on wide canvases.
            .frame(maxWidth: 520)
            .padding(.vertical, 19)
            .background(
                LinearGradient(colors: [Theme.accent, Color(hex: 0xC2354F)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(
            // Runs on down through the bottom safe area: where the tab bar
            // sits at the side instead (iPhone Duo's cover display), rows
            // would otherwise show in the strip beneath the button.
            LinearGradient(stops: [.init(color: Color(.systemGroupedBackground).opacity(0), location: 0),
                                   .init(color: Color(.systemGroupedBackground).opacity(0.94), location: 0.42),
                                   .init(color: Color(.systemGroupedBackground), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        )
    }
}
