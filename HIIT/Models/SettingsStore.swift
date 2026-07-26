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
    var soundOn: Bool = true
    var hapticsOn: Bool = true
    var machines: [String: MachineProfile] = [:]
    var lastEquipmentRaw: String? = nil
    var healthConnected: Bool = false
}

@Observable
final class SettingsStore {
    private static let key = "hiit.settings.v1"

    var value: AppSettings {
        didSet { persist() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = decoded
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

    func apply(_ snapshot: HealthKitManager.ProfileSnapshot) {
        if let age = snapshot.age { value.age = age }
        if let weight = snapshot.weightKg { value.weightKg = weight }
        if let height = snapshot.heightCm { value.heightCm = height }
        if let resting = snapshot.restingHR { value.restingHR = resting }
        value.healthConnected = true
    }
}
