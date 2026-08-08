import SwiftUI
import SwiftData

@main
struct HIITApp: App {
    @State private var settings = SettingsStore()
    @State private var health = HealthKitManager()
    @State private var ble = BluetoothHeartRateManager()

    private let container: ModelContainer
    private let storeLoadFailed: Bool

    init() {
        // Build the container explicitly so a store that fails to open (disk
        // I/O trouble, an incompatible file from a future version) degrades
        // to an in-memory session with a visible warning instead of crashing
        // at launch — a crash loop here could only be fixed by deleting the
        // app, which destroys all workout history.
        let schema = Schema(versionedSchema: HIITSchemaV2.self)
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: HIITMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema)])
            storeLoadFailed = false
        } catch {
            container = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            storeLoadFailed = true
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(storeLoadFailed: storeLoadFailed)
                .environment(settings)
                .environment(health)
                .environment(ble)
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}
