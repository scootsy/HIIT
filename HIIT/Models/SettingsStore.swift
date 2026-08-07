import Foundation
import Observation

struct AppSettings: Codable {
    var useMetric: Bool = false
    var age: Int? = nil
    var weightKg: Double? = nil
    var heightCm: Double? = nil
    var restingHR: Double? = nil
    var maxHROverride: Double? = nil
    var experienceRaw: String = ExperienceLevel.beginner.rawValue
    var preferLowImpact: Bool = false
    var preferWalkRecoveries: Bool = false
    var soundOn: Bool = true
    var hapticsOn: Bool = true
    var machines: [String: MachineProfile] = [:]
    var lastEquipmentRaw: String? = nil
    var healthConnected: Bool = false
    var lastHealthSync: Date? = nil
    var hrMonitorID: String? = nil
    var hrMonitorName: String? = nil
    var experienceSetOnce: Bool? = nil
    var coachProviderRaw: String = CoachProvider.anthropic.rawValue
    /// Rolling 7-day progression-cap anchors, keyed by equipment raw value:
    /// when the current window started and the level it started from.
    /// Kept in settings (UserDefaults) so no SwiftData schema change.
    var progressWeekAnchorDates: [String: Date] = [:]
    var progressWeekAnchorLevels: [String: Double] = [:]

    init() {}

    // Field-by-field decoding so a blob written by a different app version
    // (fields added, renamed, or removed) degrades to per-field defaults
    // instead of throwing and silently resetting every setting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useMetric = (try? c.decodeIfPresent(Bool.self, forKey: .useMetric)) ?? false
        age = try? c.decodeIfPresent(Int.self, forKey: .age)
        weightKg = try? c.decodeIfPresent(Double.self, forKey: .weightKg)
        heightCm = try? c.decodeIfPresent(Double.self, forKey: .heightCm)
        restingHR = try? c.decodeIfPresent(Double.self, forKey: .restingHR)
        maxHROverride = try? c.decodeIfPresent(Double.self, forKey: .maxHROverride)
        experienceRaw = (try? c.decodeIfPresent(String.self, forKey: .experienceRaw)) ?? ExperienceLevel.beginner.rawValue
        preferLowImpact = (try? c.decodeIfPresent(Bool.self, forKey: .preferLowImpact)) ?? false
        preferWalkRecoveries = (try? c.decodeIfPresent(Bool.self, forKey: .preferWalkRecoveries)) ?? false
        soundOn = (try? c.decodeIfPresent(Bool.self, forKey: .soundOn)) ?? true
        hapticsOn = (try? c.decodeIfPresent(Bool.self, forKey: .hapticsOn)) ?? true
        machines = (try? c.decodeIfPresent([String: MachineProfile].self, forKey: .machines)) ?? [:]
        lastEquipmentRaw = try? c.decodeIfPresent(String.self, forKey: .lastEquipmentRaw)
        healthConnected = (try? c.decodeIfPresent(Bool.self, forKey: .healthConnected)) ?? false
        lastHealthSync = try? c.decodeIfPresent(Date.self, forKey: .lastHealthSync)
        hrMonitorID = try? c.decodeIfPresent(String.self, forKey: .hrMonitorID)
        hrMonitorName = try? c.decodeIfPresent(String.self, forKey: .hrMonitorName)
        experienceSetOnce = try? c.decodeIfPresent(Bool.self, forKey: .experienceSetOnce)
        coachProviderRaw = (try? c.decodeIfPresent(String.self, forKey: .coachProviderRaw)) ?? CoachProvider.anthropic.rawValue
        progressWeekAnchorDates = (try? c.decodeIfPresent([String: Date].self, forKey: .progressWeekAnchorDates)) ?? [:]
        progressWeekAnchorLevels = (try? c.decodeIfPresent([String: Double].self, forKey: .progressWeekAnchorLevels)) ?? [:]
    }
}

@Observable
final class SettingsStore {
    private static let key = "hiit.settings.v1"

    var value: AppSettings {
        didSet { persist() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            if let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
                value = decoded
            } else {
                // Keep the unreadable blob around instead of letting the next
                // persist() overwrite it — the data may be recoverable.
                UserDefaults.standard.set(data, forKey: Self.key + ".backup")
                value = AppSettings()
            }
        } else {
            value = AppSettings()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    var experience: ExperienceLevel {
        get { ExperienceLevel(rawValue: value.experienceRaw) ?? .beginner }
        set { value.experienceRaw = newValue.rawValue }
    }

    var coachProvider: CoachProvider {
        get { CoachProvider(rawValue: value.coachProviderRaw) ?? .anthropic }
        set { value.coachProviderRaw = newValue.rawValue }
    }

    /// Tanaka et al. (2001): HRmax = 208 − 0.7 × age. More accurate than 220 − age.
    var maxHR: Double? {
        if let override = value.maxHROverride { return override }
        guard let age = value.age else { return nil }
        return 208 - 0.7 * Double(age)
    }

    var bmi: Double? {
        guard let w = value.weightKg, let h = value.heightCm, h > 0 else { return nil }
        let meters = h / 100
        return w / (meters * meters)
    }

    func machine(for equipment: Equipment) -> MachineProfile {
        value.machines[equipment.rawValue] ?? .defaults(for: equipment)
    }

    func hasConfiguredMachine(for equipment: Equipment) -> Bool {
        value.machines[equipment.rawValue] != nil
    }

    func setMachine(_ profile: MachineProfile, for equipment: Equipment) {
        value.machines[equipment.rawValue] = profile
    }

    func speedString(_ mph: Double) -> String {
        if value.useMetric {
            return String(format: "%.1f km/h", mph * 1.60934)
        }
        return String(format: "%.1f mph", mph)
    }

    func weightString() -> String {
        guard let kg = value.weightKg else { return "—" }
        if value.useMetric {
            return String(format: "%.0f kg", kg)
        }
        return String(format: "%.0f lb", kg * 2.20462)
    }

    func distanceString(_ meters: Double) -> String {
        if value.useMetric {
            return String(format: "%.2f km", meters / 1000)
        }
        return String(format: "%.2f mi", meters / 1609.34)
    }

    /// Applies a Health profile snapshot. Returns false when the snapshot was
    /// completely empty — HealthKit reports denied read access as "no data",
    /// so an all-nil snapshot must NOT flip the app into connected mode (that
    /// would hide manual entry with nothing to show in its place).
    @discardableResult
    func apply(_ snapshot: HealthKitManager.ProfileSnapshot) -> Bool {
        if let age = snapshot.age { value.age = age }
        if let weight = snapshot.weightKg { value.weightKg = weight }
        if let height = snapshot.heightCm { value.heightCm = height }
        if let resting = snapshot.restingHR { value.restingHR = resting }
        let gotData = snapshot.age != nil || snapshot.weightKg != nil
            || snapshot.heightCm != nil || snapshot.restingHR != nil
        if gotData {
            value.healthConnected = true
            value.lastHealthSync = Date()
        }
        return gotData
    }

    /// Back to manual mode; already-synced values stay editable in place.
    func disconnectHealth() {
        value.healthConnected = false
        value.lastHealthSync = nil
    }
}
