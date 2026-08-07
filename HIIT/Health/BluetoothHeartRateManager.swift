import Foundation
import CoreBluetooth
import Observation
import os

/// Direct BLE connection to any monitor speaking the standard Bluetooth Heart
/// Rate profile (Amazfit broadcast mode, Polar/Garmin/Coospo straps, etc.).
///
/// Why this exists: Apple Health is a database, not a live sensor feed —
/// third-party watch apps batch their writes, so polling Health can lag by
/// minutes. Reading the strap directly gives second-by-second heart rate;
/// the finished workout (with the captured samples) still goes to Health.
///
/// The CBCentralManager is created lazily so the iOS Bluetooth permission
/// prompt appears only when the user actually opens the pairing screen or
/// starts a workout with a saved monitor — never at app launch.
@Observable
final class BluetoothHeartRateManager: NSObject {

    enum Status: Equatable {
        case idle
        case bluetoothOff
        case unauthorized
        case scanning
        case connecting(String)
        case connected(String)
        /// A user-initiated pairing attempt timed out — surfaced in the
        /// pairing sheet so "Connecting…" can't spin forever.
        case failed(String)
    }

    struct DiscoveredMonitor: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateMeasurement = CBUUID(string: "2A37")

    private(set) var status: Status = .idle
    private(set) var discovered: [DiscoveredMonitor] = []
    private(set) var latestHR: Double? = nil
    private(set) var latestHRDate: Date? = nil

    /// Set by the workout container so the pairing sheet knows not to tear
    /// down a connection the live session is using.
    var workoutActive = false

    /// Direct sample tap for the workout engine. SwiftUI's onChange can go
    /// quiet while the app is backgrounded, but this closure fires from the
    /// CoreBluetooth callback itself — with the bluetooth-central background
    /// mode, it's what keeps live HR (and the live coach) working with the
    /// screen off.
    @ObservationIgnored var onSample: ((Double, Date) -> Void)? = nil

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    var connectedName: String? {
        if case .connected(let name) = status { return name }
        return nil
    }

    private var central: CBCentralManager? = nil
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral? = nil
    private var targetID: UUID? = nil
    private var savedName = ""
    private var shouldReconnect = false
    /// Times out user-initiated pairing attempts. Saved-monitor reconnects
    /// during a workout deliberately keep retrying forever instead.
    private var connectTimeout: DispatchWorkItem? = nil

    private enum Intent {
        case none
        case scan
        case connectSaved(UUID)
    }
    private var intent: Intent = .none

    // MARK: - Public API

    func startScanning() {
        intent = .scan
        ensureCentral()
        beginIfReady()
    }

    func stopScanning() {
        central?.stopScan()
        if status == .scanning { status = .idle }
    }

    /// Pairing: connect to a monitor the user tapped in the discovered list.
    func connect(to id: UUID, name: String) {
        connectTimeout?.cancel()
        // CoreBluetooth connect requests never time out on their own; a
        // pending connect to a previously tapped monitor could complete
        // later, leaving two straps streaming and the wrong one persisted.
        if let previous = connectedPeripheral, previous.identifier != id {
            central?.cancelPeripheralConnection(previous)
        }
        targetID = id
        savedName = name
        shouldReconnect = true
        central?.stopScan()
        guard let peripheral = peripherals[id] else { return }
        connectedPeripheral = peripheral
        peripheral.delegate = self
        status = .connecting(name)
        central?.connect(peripheral)
        let timeout = DispatchWorkItem { [weak self] in
            self?.connectAttemptTimedOut(id: id, name: name)
        }
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func connectAttemptTimedOut(id: UUID, name: String) {
        guard targetID == id, !isConnected else { return }
        AppLog.ble.error("pairing attempt to \(name, privacy: .public) timed out")
        shouldReconnect = false
        targetID = nil
        if let peripheral = connectedPeripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        status = .failed(name)
        // Keep the nearby list fresh so the user can simply tap to retry.
        central?.scanForPeripherals(withServices: [Self.heartRateService], options: nil)
    }

    /// Workout start: reconnect to the remembered monitor with no user action.
    func connectToSaved(id: UUID, name: String) {
        savedName = name
        intent = .connectSaved(id)
        ensureCentral()
        beginIfReady()
    }

    func disconnect() {
        connectTimeout?.cancel()
        shouldReconnect = false
        targetID = nil
        intent = .none
        central?.stopScan()
        if let peripheral = connectedPeripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        latestHR = nil
        latestHRDate = nil
        status = .idle
    }

    // MARK: - Internals

    private func ensureCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    private func beginIfReady() {
        guard let central, central.state == .poweredOn else { return }
        switch intent {
        case .none:
            return
        case .scan:
            discovered = []
            status = .scanning
            central.scanForPeripherals(withServices: [Self.heartRateService], options: nil)
        case .connectSaved(let id):
            targetID = id
            shouldReconnect = true
            status = .connecting(savedName)
            if let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first {
                peripherals[id] = peripheral
                connectedPeripheral = peripheral
                peripheral.delegate = self
                central.connect(peripheral)
            } else {
                // iOS doesn't know the device yet — scan until it shows up.
                central.scanForPeripherals(withServices: [Self.heartRateService], options: nil)
            }
        }
        intent = .none
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothHeartRateManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Recovering from a Bluetooth power-cycle (Control Center toggle,
            // Airplane Mode, bluetoothd reset): clear the stale off status
            // and, if a monitor was in use, re-issue the connection — without
            // this the status stays "Bluetooth is off" for the rest of the
            // workout even though Bluetooth is back.
            if status == .bluetoothOff || status == .unauthorized {
                status = .idle
            }
            if case .none = intent, shouldReconnect, let target = targetID {
                connectedPeripheral = nil
                intent = .connectSaved(target)
            }
            beginIfReady()
        case .poweredOff:
            // Power-off invalidates peripherals and pending connects.
            connectedPeripheral = nil
            latestHR = nil
            latestHRDate = nil
            status = .bluetoothOff
        case .unauthorized:
            status = .unauthorized
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Heart-rate monitor"
        if let index = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[index].name = name
            discovered[index].rssi = RSSI.intValue
        } else {
            discovered.append(DiscoveredMonitor(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
        }
        // Hunting for the saved monitor: grab it the moment it appears.
        if let target = targetID, peripheral.identifier == target, connectedPeripheral == nil {
            central.stopScan()
            connectedPeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // A stale connect (to a monitor the user has since navigated away
        // from) can still complete — don't adopt a peripheral we no longer
        // want.
        guard peripheral.identifier == targetID else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverServices([Self.heartRateService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        AppLog.ble.error("connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        guard shouldReconnect, peripheral.identifier == targetID else { return }
        // Brief pause before retrying so a monitor that rejects the attempt
        // outright doesn't produce a hot connect loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.shouldReconnect, peripheral.identifier == self.targetID else { return }
            self.central?.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == targetID else { return }
        if let error {
            AppLog.ble.error("monitor disconnected: \(error.localizedDescription, privacy: .public)")
        }
        latestHR = nil
        latestHRDate = nil
        if shouldReconnect {
            status = .connecting(peripheral.name ?? savedName)
            central.connect(peripheral)
        } else {
            status = .idle
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothHeartRateManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, peripheral.identifier == targetID else { return }
        for service in peripheral.services ?? [] where service.uuid == Self.heartRateService {
            peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, peripheral.identifier == targetID else { return }
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.heartRateMeasurement {
            peripheral.setNotifyValue(true, for: characteristic)
            connectTimeout?.cancel()
            status = .connected(peripheral.name ?? savedName)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              peripheral.identifier == targetID,
              characteristic.uuid == Self.heartRateMeasurement,
              let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        // Bluetooth Heart Rate Measurement: flag bit 0 selects UInt8 vs UInt16 bpm.
        let bpm: Int
        if bytes[0] & 0x01 != 0 {
            guard bytes.count >= 3 else { return }
            bpm = Int(bytes[1]) | (Int(bytes[2]) << 8)
        } else {
            bpm = Int(bytes[1])
        }
        guard bpm > 20, bpm < 250 else { return }
        let now = Date()
        latestHR = Double(bpm)
        latestHRDate = now
        onSample?(Double(bpm), now)
    }
}
