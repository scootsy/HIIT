import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private let machines: [Equipment: MachineProfile] = [
    .treadmill: MachineProfile(maxSpeedMph: 6, hasIncline: true, maxInclinePercent: 8,
                               maxResistance: 0, cueLeadSeconds: 10),
    .bike: MachineProfile.defaults(for: .bike),
    .outdoor: MachineProfile.defaults(for: .outdoor)
]

for equipment in Equipment.allCases {
    for level in ExperienceLevel.allCases {
        for minutes in [8, 10, 15, 20, 30, 45, 60] {
            for vibe in SessionVibe.allCases {
                let machine = machines[equipment]!
                let plan = WorkoutGenerator.makePlan(GeneratorInput(
                    equipment: equipment, machine: machine, level: level,
                    minutes: minutes, vibe: vibe, progression: 2,
                    sessionCount: 3, hardSessionsSinceEasy: 0))
                expect(abs(plan.totalSeconds - Double(minutes * 60)) < 1,
                       "interval plan must fill \(minutes) minutes")
                expect(plan.phases.allSatisfy { $0.seconds > 0 }, "all phases need positive duration")
                expect(plan.phases.first?.kind == .warmup, "plan must start with warm-up")
                expect(plan.phases.last?.kind == .cooldown, "plan must end with cool-down")
                for phase in plan.phases {
                    if let speed = phase.target.speedMph {
                        expect(speed >= 0.5 && speed <= machine.maxSpeedMph,
                               "speed must respect machine limits")
                    }
                    if let incline = phase.target.inclinePercent {
                        expect(incline >= 0 && incline <= machine.maxInclinePercent,
                               "incline must respect machine limits")
                    }
                    if let resistance = phase.target.resistance {
                        expect(resistance >= 1 && resistance <= machine.maxResistance,
                               "resistance must respect machine limits")
                    }
                }
            }
        }
    }
}

for equipment in Equipment.allCases {
    for level in ExperienceLevel.allCases {
        for minutes in [15, 20, 30, 45, 60] {
            for progression in [0.0, 3.0, 6.0] {
                let machine = machines[equipment]!
                let plan = EnduranceGenerator.makePlan(GeneratorInput(
                    equipment: equipment, machine: machine, level: level,
                    minutes: minutes, vibe: .auto, progression: progression,
                    sessionCount: 3, hardSessionsSinceEasy: 0))
                expect(plan.effectiveMode == .endurance, "endurance mode must be explicit")
                expect(plan.workPhaseCount == 0, "endurance must not masquerade as intervals")
                expect(abs(plan.totalSeconds - Double(minutes * 60)) < 1,
                       "endurance plan must fill \(minutes) minutes")
                expect(plan.phases.map(\.kind) == [.warmup, .steady, .cooldown],
                       "endurance needs warm-up, sustained work, and cool-down")
                let steady = plan.phases[1].target
                expect(steady.hrPercentLow == 65 && steady.hrPercentHigh == 75,
                       "endurance target band must remain sustainable")
                if let speed = steady.speedMph {
                    expect(speed >= 0.5 && speed <= machine.maxSpeedMph,
                           "endurance speed must respect machine limits")
                    expect(!(speed > 4.2 && speed < 4.7),
                           "a sustained block must not sit in the walk/run gait dead zone")
                    if let warm = plan.phases[0].target.speedMph {
                        expect(warm <= speed, "endurance warm-up must not exceed the steady speed")
                    }
                }
                if let resistance = steady.resistance {
                    expect(resistance >= 1 && resistance <= machine.maxResistance,
                           "endurance resistance must respect machine limits")
                }
            }
        }
    }
}

// Endurance dosing must be personalized, not a fixed per-level walk: earned
// progression carries in, and a personal speed→HR line pulls the target
// toward where the aerobic band actually lives for this user.
let fastTreadmill = MachineProfile.defaults(for: .treadmill)
func endurancePlan(progression: Double, model: SpeedCalibration.Model? = nil) -> WorkoutPlan {
    EnduranceGenerator.makePlan(GeneratorInput(
        equipment: .treadmill, machine: fastTreadmill, level: .intermediate,
        minutes: 30, vibe: .auto, progression: progression,
        sessionCount: 3, hardSessionsSinceEasy: 0, hrSpeedModel: model))
}
let baseSteady = endurancePlan(progression: 0).phases[1].target.speedMph ?? 0
let progressedSteady = endurancePlan(progression: 6).phases[1].target.speedMph ?? 0
expect(progressedSteady > baseSteady, "progression must carry into the endurance target")
// For this runner, 70% HRmax lives at 5.0 mph — well above the heuristic.
let calibration = SpeedCalibration.Model(interceptPct: 20, slopePctPerMph: 10)
let calibratedSteady = endurancePlan(progression: 0, model: calibration).phases[1].target.speedMph ?? 0
expect(calibratedSteady > baseSteady, "speed→HR calibration must lift the endurance target")

print("Generator checks passed")

// Checkpoint compatibility: plans saved before `mode` existed must decode as
// interval sessions instead of becoming unreadable.
let legacyPlan = WorkoutGenerator.makePlan(GeneratorInput(
    equipment: .treadmill, machine: machines[.treadmill]!, level: .beginner,
    minutes: 15, vibe: .auto, progression: 0, sessionCount: 0,
    hardSessionsSinceEasy: 0))
let encoded = try JSONEncoder().encode(legacyPlan)
var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
object.removeValue(forKey: "mode")
let legacyData = try JSONSerialization.data(withJSONObject: object)
let decoded = try JSONDecoder().decode(WorkoutPlan.self, from: legacyData)
expect(decoded.effectiveMode == .intervals, "legacy checkpoints must remain interval workouts")

print("Compatibility checks passed")
