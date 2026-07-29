import Foundation

enum Equipment: String, Codable, CaseIterable, Identifiable {
    case treadmill
    case bike
    case outdoor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .treadmill: return "Treadmill"
        case .bike: return "Stationary Bike"
        case .outdoor: return "Outdoor Run"
        }
    }

    var icon: String {
        switch self {
        case .treadmill: return "figure.run"
        case .bike: return "figure.indoor.cycle"
        case .outdoor: return "sun.max.fill"
        }
    }

    var blurb: String {
        switch self {
        case .treadmill: return "Speed & incline targets"
        case .bike: return "Resistance & cadence targets"
        case .outdoor: return "Effort-based surges"
        }
    }
}

/// What the user's actual machine can do. Targets are always clamped to these limits.
struct MachineProfile: Codable, Equatable {
    var maxSpeedMph: Double = 10
    var hasIncline: Bool = true
    var maxInclinePercent: Double = 12
    var maxResistance: Int = 20
    /// How far ahead the app warns before a target change. Treadmills need the
    /// most lead time because belts take seconds to spin up.
    var cueLeadSeconds: Int = 10

    static func defaults(for equipment: Equipment) -> MachineProfile {
        switch equipment {
        case .treadmill:
            return MachineProfile(maxSpeedMph: 10, hasIncline: true, maxInclinePercent: 12, maxResistance: 0, cueLeadSeconds: 10)
        case .bike:
            return MachineProfile(maxSpeedMph: 0, hasIncline: false, maxInclinePercent: 0, maxResistance: 20, cueLeadSeconds: 5)
        case .outdoor:
            return MachineProfile(maxSpeedMph: 12, hasIncline: false, maxInclinePercent: 0, maxResistance: 0, cueLeadSeconds: 3)
        }
    }
}
