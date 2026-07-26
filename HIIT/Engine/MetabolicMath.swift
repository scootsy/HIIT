import Foundation

/// Energy and heart-rate math, based on the ACSM metabolic equations and the
/// Tanaka HRmax formula (see SettingsStore.maxHR).
enum MetabolicMath {

    /// ACSM walking/running VO₂ equations, converted to METs.
    /// Walking (< 3.7 mph): VO₂ = 0.1·v + 1.8·v·grade + 3.5
    /// Running (≥ 3.7 mph): VO₂ = 0.2·v + 0.9·v·grade + 3.5   (v in m/min)
    static func treadmillMETs(speedMph: Double, inclinePercent: Double) -> Double {
        let mPerMin = speedMph * 26.8224
        let grade = max(0, inclinePercent) / 100
        let vo2: Double
        if speedMph < 3.7 {
            vo2 = 0.1 * mPerMin + 1.8 * mPerMin * grade + 3.5
        } else {
            vo2 = 0.2 * mPerMin + 0.9 * mPerMin * grade + 3.5
        }
        return vo2 / 3.5
    }

    /// Indoor cycling estimate from effort (fraction of the rider's hard ceiling).
    /// Anchored to compendium values: easy spin ≈ 3.5 METs, vigorous ≈ 8–11 METs.
    static func bikeMETs(effort: Double) -> Double {
        let e = max(0, min(1, effort))
        return 3.0 + 8.5 * pow(e, 1.4)
    }

    static func mets(speedMph: Double?, inclinePercent: Double?, resistance: Int?, equipment: Equipment, machine: MachineProfile) -> Double {
        switch equipment {
        case .treadmill, .outdoor:
            guard let speed = speedMph else { return 4 }
            return treadmillMETs(speedMph: speed, inclinePercent: inclinePercent ?? 0)
        case .bike:
            let effort = Double(resistance ?? 0) / Double(max(1, machine.maxResistance))
            return bikeMETs(effort: effort)
        }
    }

    /// kcal = METs × 3.5 × kg / 200 per minute (ACSM).
    static func kilocalories(mets: Double, weightKg: Double, seconds: Double) -> Double {
        mets * 3.5 * weightKg / 200 * (seconds / 60)
    }

    static func estimate(records: [PhaseRecord], equipment: Equipment, machine: MachineProfile, weightKg: Double?) -> (kcal: Double, meters: Double) {
        let kg = weightKg ?? 75
        var kcal = 0.0
        var meters = 0.0
        for record in records {
            let m = mets(speedMph: record.speedMph,
                         inclinePercent: record.inclinePercent,
                         resistance: record.resistance,
                         equipment: equipment,
                         machine: machine)
            kcal += kilocalories(mets: m, weightKg: kg, seconds: record.actualSeconds)
            if equipment != .bike, let speed = record.speedMph {
                meters += speed * 0.44704 * record.actualSeconds
            }
        }
        return (kcal, meters)
    }
}

enum HeartRateZone: Int, CaseIterable {
    case z1 = 1, z2 = 2, z3 = 3, z4 = 4, z5 = 5

    static func zone(forPercent percent: Double) -> HeartRateZone {
        if percent < 60 { return .z1 }
        if percent < 70 { return .z2 }
        if percent < 80 { return .z3 }
        if percent < 90 { return .z4 }
        return .z5
    }

    var label: String { "Zone \(rawValue)" }
}
