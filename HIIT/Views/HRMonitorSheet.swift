import SwiftUI

/// Pairing screen for Bluetooth heart-rate monitors, written for someone who
/// has never heard the word "BLE": open it, put the strap in broadcast mode,
/// tap your device when it appears, watch your pulse show up. The choice is
/// remembered and every future workout connects automatically.
struct HRMonitorSheet: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(BluetoothHeartRateManager.self) private var ble
    @Environment(\.dismiss) private var dismiss
    /// The row the user tapped; remembered in settings only once it connects.
    @State private var pendingMonitor: BluetoothHeartRateManager.DiscoveredMonitor? = nil

    var body: some View {
        NavigationStack {
            List {
                if let name = settings.value.hrMonitorName, settings.value.hrMonitorID != nil {
                    savedSection(name: name)
                } else {
                    explainerSection
                    nearbySection
                }
            }
            .navigationTitle("Heart-rate monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if let idString = settings.value.hrMonitorID, let uuid = UUID(uuidString: idString) {
                ble.connectToSaved(id: uuid, name: settings.value.hrMonitorName ?? "your monitor")
            } else {
                ble.startScanning()
            }
        }
        .onDisappear {
            // Don't tear down a connection the live workout screen is using.
            if !ble.workoutActive {
                ble.disconnect()
            }
        }
        // Persist the choice only after the connection succeeds — a mis-tap
        // on a neighbor's strap in a busy gym must not become the device
        // every future workout silently tries to reach.
        .onChange(of: ble.isConnected) { _, connected in
            if connected, let monitor = pendingMonitor {
                settings.value.hrMonitorID = monitor.id.uuidString
                settings.value.hrMonitorName = monitor.name
                pendingMonitor = nil
            }
        }
        .onChange(of: ble.status) { _, newStatus in
            // A timed-out attempt clears the tapped row's "Connecting…" so the
            // list is honest about needing another tap.
            if case .failed = newStatus {
                pendingMonitor = nil
            }
        }
    }

    private func savedSection(name: String) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.headline)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if ble.isConnected, let hr = ble.latestHR {
                    Label("\(Int(hr))", systemImage: "heart.fill")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                        .labelStyle(.titleAndIcon)
                }
            }
            .padding(.vertical, 4)
            Button("Forget this monitor", role: .destructive) {
                ble.disconnect()
                settings.value.hrMonitorID = nil
                settings.value.hrMonitorName = nil
                ble.startScanning()
            }
        } header: {
            Text("Your monitor")
        } footer: {
            Text("Connects automatically every workout.")
        }
    }

    private var statusLine: String {
        switch ble.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .failed: return "Couldn't connect — make sure it's awake and broadcasting"
        case .bluetoothOff: return "Bluetooth is off — turn it on in Control Center"
        case .unauthorized: return "Bluetooth access is off — allow it in Settings → HIIT Coach"
        default: return "Not connected"
        }
    }

    private var explainerSection: some View {
        Section {
            Text("Turn on heart-rate broadcast on your device (Amazfit: in the Zepp app), then pick it below.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var nearbySection: some View {
        Section {
            switch ble.status {
            case .bluetoothOff:
                Label("Bluetooth is off — turn it on in Control Center, then come back.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
            case .unauthorized:
                Label("Bluetooth access is turned off for this app. Allow it in Settings → HIIT Coach → Bluetooth.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
            default:
                if case .failed(let name) = ble.status {
                    Label("Couldn't connect to \(name). Make sure it's awake and broadcasting, then tap it to try again.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
                if ble.discovered.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for heart-rate monitors…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(ble.discovered) { monitor in
                    Button {
                        pendingMonitor = monitor
                        ble.connect(to: monitor.id, name: monitor.name)
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(monitor.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(pendingMonitor?.id == monitor.id ? "Connecting…" : "Tap to connect")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            signalBars(rssi: monitor.rssi)
                        }
                    }
                }
            }
        } header: {
            Text("Nearby monitors")
        } footer: {
            Text("Strongest signal = the one you're wearing.")
        }
    }

    private func signalBars(rssi: Int) -> some View {
        let strength: Int
        if rssi > -60 { strength = 3 } else if rssi > -75 { strength = 2 } else { strength = 1 }
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= strength ? Theme.accent : Color(.systemGray4))
                    .frame(width: 4, height: CGFloat(bar) * 5 + 3)
            }
        }
    }
}
