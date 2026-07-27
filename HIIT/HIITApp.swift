import SwiftUI
import SwiftData

@main
struct HIITApp: App {
    @State private var settings = SettingsStore()
    @State private var health = HealthKitManager()
    @State private var ble = BluetoothHeartRateManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(health)
                .environment(ble)
                .tint(Theme.accent)
        }
        .modelContainer(for: [WorkoutSession.self, EquipmentProgress.self])
    }
}
