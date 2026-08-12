import Foundation

/// Builds a deliberately simple steady-cardio session. The live coach makes
/// small, user-confirmed adjustments after heart rate has had time to settle;
/// without live HR, the RPE and conversation cues remain fully usable.
enum EnduranceGenerator {
    static func makePlan(equipment: Equipment,
                         machine: MachineProfile,
                         level: ExperienceLevel,
                         minutes: Int) -> WorkoutPlan {
        let total = Double(max(15, minutes) * 60)
        let warmup = min(300, max(180, total * 0.2))
        let cooldown = min(300, max(180, total * 0.15))
        let steady = max(360, total - warmup - cooldown)

        let targets = targets(equipment: equipment, machine: machine, level: level)
        let phases = [
            IntervalPhase(kind: .warmup, seconds: warmup, label: "Warm up",
                          cue: "Start easy and let your body settle", target: targets.warm),
            IntervalPhase(kind: .steady, seconds: steady, label: "Endurance",
                          cue: "Comfortable breathing — full sentences", target: targets.steady),
            IntervalPhase(kind: .cooldown, seconds: cooldown, label: "Cool down",
                          cue: "Ease down gradually", target: targets.cool)
        ]
        return WorkoutPlan(
            name: "Endurance Coach",
            focus: "Sustainable cardio. You should be able to speak in full sentences; with live heart rate, the coach suggests small adjustments as you settle in.",
            equipment: equipment,
            level: level,
            vibe: .auto,
            minutes: minutes,
            cueLeadSeconds: machine.cueLeadSeconds,
            mode: .endurance,
            phases: phases)
    }

    private static func targets(equipment: Equipment, machine: MachineProfile,
                                level: ExperienceLevel) -> (warm: PhaseTarget, steady: PhaseTarget, cool: PhaseTarget) {
        switch equipment {
        case .treadmill:
            let steadySpeed: Double
            switch level {
            case .beginner: steadySpeed = 2.8
            case .intermediate: steadySpeed = 3.3
            case .advanced: steadySpeed = 3.7
            }
            let speed = min(machine.maxSpeedMph, steadySpeed)
            let warm = max(0.5, min(speed - 0.5, machine.maxSpeedMph))
            return (
                PhaseTarget(speedMph: warm, inclinePercent: 0, rpe: 2, effortWords: "Very easy", hrPercentLow: 50, hrPercentHigh: 65),
                PhaseTarget(speedMph: speed, inclinePercent: 0, rpe: 4, effortWords: "Full sentences", hrPercentLow: 65, hrPercentHigh: 75),
                PhaseTarget(speedMph: max(0.5, warm - 0.3), inclinePercent: 0, rpe: 2, effortWords: "Easy", hrPercentLow: 45, hrPercentHigh: 65))
        case .bike:
            let resistance = max(1, min(machine.maxResistance, Int((Double(machine.maxResistance) * 0.35).rounded())))
            return (
                PhaseTarget(resistance: max(1, resistance - 2), cadenceRPM: 70, rpe: 2, effortWords: "Very easy", hrPercentLow: 50, hrPercentHigh: 65),
                PhaseTarget(resistance: resistance, cadenceRPM: 75, rpe: 4, effortWords: "Full sentences", hrPercentLow: 65, hrPercentHigh: 75),
                PhaseTarget(resistance: max(1, resistance - 3), cadenceRPM: 65, rpe: 2, effortWords: "Easy", hrPercentLow: 45, hrPercentHigh: 65))
        case .outdoor:
            return (
                PhaseTarget(rpe: 2, effortWords: "Very easy", hrPercentLow: 50, hrPercentHigh: 65),
                PhaseTarget(rpe: 4, effortWords: "Full sentences", hrPercentLow: 65, hrPercentHigh: 75),
                PhaseTarget(rpe: 2, effortWords: "Easy", hrPercentLow: 45, hrPercentHigh: 65))
        }
    }
}
