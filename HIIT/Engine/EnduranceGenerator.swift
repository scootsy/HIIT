import Foundation

/// Builds a deliberately simple steady-cardio session. The live coach makes
/// small, user-confirmed adjustments after heart rate has had time to settle;
/// without live HR, the RPE and conversation cues remain fully usable.
enum EnduranceGenerator {
    /// The steady block's aerobic band, % of max HR — conversational and
    /// sustainable. The live coach nudges toward it and the generator aims
    /// the starting intensity at its middle.
    static let bandLow = 65.0
    static let bandHigh = 75.0

    static func makePlan(_ input: GeneratorInput) -> WorkoutPlan {
        let total = Double(max(15, input.minutes) * 60)
        let warmup = min(300, max(180, total * 0.2))
        let cooldown = min(300, max(180, total * 0.15))
        let steady = max(360, total - warmup - cooldown)

        let targets = targets(input)
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
            equipment: input.equipment,
            level: input.level,
            vibe: .auto,
            minutes: input.minutes,
            cueLeadSeconds: input.machine.cueLeadSeconds,
            mode: .endurance,
            phases: phases)
    }

    /// Steady targets start from the same personalized speed math interval
    /// sessions use — experience level plus health proxies, progression, and
    /// the speed→HR calibration — not a fixed per-level guess. A fixed walking
    /// speed parks anyone above beginner fitness far below the aerobic band,
    /// and the coach's small confirmed steps can't close a 2 mph gap.
    private static func targets(_ input: GeneratorInput)
        -> (warm: PhaseTarget, steady: PhaseTarget, cool: PhaseTarget) {
        switch input.equipment {
        case .treadmill:
            let s = WorkoutGenerator.treadmillSpeeds(input)
            // The interval generator's own conversational anchor for
            // Zone-2 steady blocks…
            var speed = (s.easy + s.work) / 2 - 0.3
            // …aimed straight at the band's middle once a personal speed→HR
            // line exists: met halfway and bounded ±0.6 mph, the same blend
            // the work-speed calibration uses.
            if let model = input.hrSpeedModel {
                let personal = model.speed(atPercent: (bandLow + bandHigh) / 2)
                let blended = (speed + personal) / 2
                speed = max(speed - 0.6, min(speed + 0.6, blended))
            }
            speed = (speed * 10).rounded() / 10
            speed = max(1.5, min(speed, input.machine.maxSpeedMph))
            // A 20–50 minute block can't live in the walk/run gait dead zone
            // (4.2–4.7 mph): snap to the nearest edge, resolving down for
            // walking preferences or a machine that can't fund the jog side.
            if speed > 4.2 && speed < 4.7 {
                let down = input.preferLowImpact || input.preferWalkRecoveries
                    || speed < 4.45 || input.machine.maxSpeedMph < 4.7
                speed = down ? 4.2 : 4.7
            }
            let warm = max(1.5, min(s.warm, speed - 0.3))
            let cool = max(1.5, min(min(s.warm, 3.8) - 0.3, speed))
            return (
                PhaseTarget(speedMph: warm, inclinePercent: 0, rpe: 2, effortWords: "Very easy", hrPercentLow: 50, hrPercentHigh: 65),
                PhaseTarget(speedMph: speed, inclinePercent: 0, rpe: 4, effortWords: "Full sentences", hrPercentLow: bandLow, hrPercentHigh: bandHigh),
                PhaseTarget(speedMph: cool, inclinePercent: 0, rpe: 2, effortWords: "Easy", hrPercentLow: 45, hrPercentHigh: 65))
        case .bike:
            let b = WorkoutGenerator.bikeEfforts(input)
            // Between the recovery spin and the work resistance — the same
            // conversational midpoint interval plans use for steady blocks.
            let steadyRes = max(1, (b.easyRes + b.workRes) / 2)
            return (
                PhaseTarget(resistance: max(1, b.easyRes - 1), cadenceRPM: 70, rpe: 2, effortWords: "Very easy", hrPercentLow: 50, hrPercentHigh: 65),
                PhaseTarget(resistance: steadyRes, cadenceRPM: 75, rpe: 4, effortWords: "Full sentences", hrPercentLow: bandLow, hrPercentHigh: bandHigh),
                PhaseTarget(resistance: max(1, b.easyRes - 1), cadenceRPM: 65, rpe: 2, effortWords: "Easy", hrPercentLow: 45, hrPercentHigh: 65))
        case .outdoor:
            return (
                PhaseTarget(rpe: 2, effortWords: "Very easy", hrPercentLow: 50, hrPercentHigh: 65),
                PhaseTarget(rpe: 4, effortWords: "Full sentences", hrPercentLow: bandLow, hrPercentHigh: bandHigh),
                PhaseTarget(rpe: 2, effortWords: "Easy", hrPercentLow: 45, hrPercentHigh: 65))
        }
    }
}
