import SwiftUI
import SwiftData

@main
struct HIITApp: App {
    @State private var settings = SettingsStore()
    @State private var health = HealthKitManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(health)
                .tint(Theme.accent)
        }
        .modelContainer(for: [WorkoutSession.self, EquipmentProgress.self])
    }
}
