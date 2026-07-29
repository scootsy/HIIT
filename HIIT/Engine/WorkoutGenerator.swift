import Foundation

struct GeneratorInput {
    var equipment: Equipment
    var machine: MachineProfile
    var level: ExperienceLevel
    var minutes: Int
    var vibe: SessionVibe
    var progression: Double
    var sessionCount: Int
    var hardSessionsSinceEasy: Int
    var maxHR: Double? = nil
    var restingHR: Double? = nil
    var bmi: Double? = nil
    var age: Int? = nil
    var preferLowImpact: Bool = false
}

/// Builds a complete session from the user's equipment, experience, time budget
/// and progression history. Protocols are drawn from the interval-training
/// literature (Helgerud 4×4, Gunnarsson & Bangsbo 10-20-30, classic 1:1–1:2.5
/// work:recovery intervals) and every target is clamped to what the user's
/// machine can actually do.
enum WorkoutGenerator {

    enum ProtocolKind {
        case classic, pyramid, norwegian, tenTwentyThirty, hills, surges
    }

    // MARK: - Entry point

    static func makePlan(_ inputRaw: GeneratorInput) -> WorkoutPlan {
        var input = inputRaw
        var deload = false
        // Every ~6th hard session, quietly schedule a lighter one: adaptation
        // happens in recovery, and most people won't schedule it themselves.
        if input.vibe == .auto && input.hardSessionsSinceEasy >= 5 {
            input.vibe = .easy
            deload = true
        }

        let requestedProtocol = chooseProtocol(input)
        let kit = makeKit(input, protocolKind: requestedProtocol)
        let total = Double(max(8, input.minutes) * 60)

        let warmupSecs: Double
        if requestedProtocol == .norwegian {
            warmupSecs = 300
        } else if input.minutes <= 12 {
            warmupSecs = 120
        } else if input.minutes <= 20 {
            warmupSecs = 180
        } else {
            warmupSecs = 240
        }
        let cooldownMin: Double = input.minutes <= 12 ? 90 : 150

        var phases: [IntervalPhase] = []
        phases.append(IntervalPhase(kind: .warmup, seconds: (warmupSecs * 0.6).rounded(), label: "Warm up", cue: "Find your rhythm", target: kit.warm))
        phases.append(IntervalPhase(kind: .warmup, seconds: (warmupSecs * 0.4).rounded(), label: "Warm up", cue: "Open up a little", target: kit.build))

        let core = max(120, total - warmupSecs - cooldownMin)
        // A core builder can fall back to classic intervals when its own
        // protocol doesn't fit the time budget — name the plan after what
        // was actually built, not what was requested.
        let coreResult = buildCore(requestedProtocol, core: core, input: input, kit: kit)
        var corePhases = coreResult.phases
        let protocolKind = coreResult.kind

        // Spend any leftover time as an easy steady block, then cool down —
        // extra Zone-2 minutes are far more useful than a padded cooldown.
        let used = corePhases.reduce(0) { $0 + $1.seconds }
        var remainder = total - warmupSecs - used
        if remainder >= cooldownMin + 150 {
            corePhases.append(IntervalPhase(kind: .steady, seconds: (remainder - cooldownMin).rounded(), label: "Steady", cue: "Settle into a rhythm", target: kit.steady))
            remainder = cooldownMin
        }
        phases.append(contentsOf: corePhases)
        phases.append(IntervalPhase(kind: .cooldown, seconds: max(60, remainder.rounded()), label: "Cool down", cue: "Bring it all the way down", target: kit.cool))

        // Number the work efforts: "Sprint 3 of 15", "Interval 2 of 8", …
        let workTotal = phases.filter { $0.kind == .work }.count
        var counter = 0
        for i in phases.indices where phases[i].kind == .work {
            counter += 1
            phases[i].label = "\(phases[i].label) \(counter) of \(workTotal)"
        }

        var name: String
        var focus: String
        switch protocolKind {
        case .classic:
            name = "Classic Intervals"
            focus = "Repeated hard efforts with real recoveries — the bread and butter of interval training."
        case .pyramid:
            name = "Pyramid"
            focus = "Efforts climb, peak, then descend — teaches pacing and keeps the middle honest."
        case .norwegian:
            name = "Norwegian 4×4"
            focus = "Long 4-minute pushes at 85–95% of max heart rate — the classic VO₂max builder (Helgerud et al., 2007)."
        case .tenTwentyThirty:
            name = "10-20-30"
            focus = "30s easy, 20s moderate, 10s sprint — outsized fitness gains from tiny sprints (Gunnarsson & Bangsbo, 2012)."
        case .hills:
            name = "Hill Climbs"
            focus = "Incline does the work: a big cardio stimulus with far less pounding on your joints."
        case .surges:
            name = "Cadence Surges"
            focus = "Fast-leg bursts against moderate resistance — builds leg speed and top-end power."
        }
        if deload {
            name += " · Recovery week"
            focus = "You've stacked several hard sessions, so today is deliberately lighter — that's when the fitness lands. " + focus
        } else if input.vibe == .easy {
            name += " · Easy"
        }

        // Short segments need shorter warnings or the whole phase flashes amber.
        let cueLead = protocolKind == .tenTwentyThirty ? min(input.machine.cueLeadSeconds, 5) : input.machine.cueLeadSeconds

        return WorkoutPlan(
            name: name,
            focus: focus,
            equipment: input.equipment,
            level: input.level,
            vibe: inputRaw.vibe,
            minutes: input.minutes,
            cueLeadSeconds: cueLead,
            phases: phases)
    }

    // MARK: - Protocol selection

    /// Rotates protocols session-to-session so training stays varied, gated by
    /// experience, session length, and what the machine supports. Rapid speed
    /// changes (10-20-30) are never assigned on a treadmill — belts can't keep up.
    static func chooseProtocol(_ input: GeneratorInput) -> ProtocolKind {
        if input.vibe == .easy { return .classic }
        if input.minutes >= 26 && input.level != .beginner && input.sessionCount % 3 == 2 {
            return .norwegian
        }
        switch input.equipment {
        case .treadmill:
            if input.level == .beginner {
                return input.machine.hasIncline && input.sessionCount % 3 == 1 ? .hills : .classic
            }
            var options: [ProtocolKind] = [.classic, .pyramid]
            if input.machine.hasIncline { options.append(.hills) }
            return options[input.sessionCount % options.count]
        case .bike:
            if input.level == .beginner { return .classic }
            let options: [ProtocolKind] = input.minutes >= 15 ? [.classic, .surges, .tenTwentyThirty, .pyramid] : [.classic, .surges]
            return options[input.sessionCount % options.count]
        case .outdoor:
            if input.level == .beginner { return .classic }
            let options: [ProtocolKind] = input.minutes >= 15 ? [.classic, .pyramid, .tenTwentyThirty] : [.classic, .pyramid]
            return options[input.sessionCount % options.count]
        }
    }

    // MARK: - Intensity targets

    private struct Speeds {
        var warm: Double
        var easy: Double
        var work: Double
        var sprint: Double
        var workIncline: Double
        var easyIncline: Double
    }

    private struct BikeEfforts {
        var easyRes: Int
        var workRes: Int
        var sprintRes: Int
        var easyCadence: Int
        var workCadence: Int
        var sprintCadence: Int
        var maxResistance: Int
    }

    private struct TargetKit {
        var warm: PhaseTarget
        var build: PhaseTarget
        var easy: PhaseTarget
        var work: PhaseTarget
        var sprint: PhaseTarget
        var moderate: PhaseTarget
        var steady: PhaseTarget
        var cool: PhaseTarget
        var hillWork: PhaseTarget
        var surgeWork: PhaseTarget
        var norwegianWork: PhaseTarget
    }

    private static func treadmillSpeeds(_ input: GeneratorInput) -> Speeds {
        var easy: Double
        var work: Double
        switch input.level {
        case .beginner:
            easy = 2.8; work = 4.5
        case .intermediate:
            easy = 3.4; work = 6.0
        case .advanced:
            easy = 4.2; work = 7.5
        }
        // Fitness proxies pulled from Apple Health: a high resting HR, high BMI,
        // or older age all argue for a gentler starting point.
        if let resting = input.restingHR, resting > 72 { work -= 0.4 }
        if let bmi = input.bmi, bmi >= 30 { work -= 0.5; easy -= 0.3 }
        if let age = input.age, age >= 55 { work -= 0.4 }
        switch input.vibe {
        case .easy: work -= 0.6
        case .push: work += 0.3
        case .auto: break
        }
        // Progressive overload: each level step is worth +0.2 mph on the work speed.
        work += 0.2 * input.progression
        easy += 0.05 * input.progression

        easy = max(1.5, min(easy, input.machine.maxSpeedMph - 1))
        work = max(easy + 0.8, min(work, input.machine.maxSpeedMph))

        var workIncline = 0.0
        let easyIncline = 0.0
        if input.equipment == .treadmill && input.machine.hasIncline {
            workIncline = 1 // 1% offsets the missing wind resistance vs outdoors
        }
        // Low-impact mode swaps running speed for incline walking. The cap
        // applies to every work-intensity target — sprints included — or the
        // hardest phases would put a user who opted out of running right
        // back into a 6 mph sprint at 6% incline.
        let lowImpact = input.preferLowImpact && input.equipment == .treadmill && input.machine.hasIncline
        if lowImpact {
            work = min(work, 4.2)
            workIncline = min(max(6, 5 + 0.5 * input.progression), input.machine.maxInclinePercent)
        }

        var sprint = min(work + 1.8, input.machine.maxSpeedMph)
        if lowImpact { sprint = min(sprint, 4.2) }
        let warm = max(1.5, easy - 0.4)
        return Speeds(warm: round1(warm), easy: round1(easy), work: round1(work), sprint: round1(sprint), workIncline: workIncline, easyIncline: easyIncline)
    }

    private static func bikeEfforts(_ input: GeneratorInput) -> BikeEfforts {
        let maxR = max(4, input.machine.maxResistance)
        var workFrac: Double
        switch input.level {
        case .beginner: workFrac = 0.55
        case .intermediate: workFrac = 0.65
        case .advanced: workFrac = 0.75
        }
        if let bmi = input.bmi, bmi >= 30 { workFrac -= 0.05 }
        switch input.vibe {
        case .easy: workFrac -= 0.08
        case .push: workFrac += 0.04
        case .auto: break
        }
        workFrac += 0.015 * input.progression
        workFrac = max(0.45, min(0.9, workFrac))
        let easyFrac = 0.35
        let sprintFrac = min(0.95, workFrac + 0.12)

        func res(_ fraction: Double) -> Int {
            max(1, min(maxR, Int((fraction * Double(maxR)).rounded())))
        }
        return BikeEfforts(
            easyRes: res(easyFrac),
            workRes: res(workFrac),
            sprintRes: res(sprintFrac),
            easyCadence: 75,
            workCadence: 90,
            sprintCadence: 105,
            maxResistance: maxR)
    }

    /// Heart-rate bands as % of HRmax. Work bands widen with experience;
    /// the Norwegian protocol overrides to its canonical 85–95%.
    private static func hrBand(for kind: PhaseKind, level: ExperienceLevel) -> (Double?, Double?) {
        switch kind {
        case .warmup: return (50, 70)
        case .work:
            switch level {
            case .beginner: return (75, 88)
            case .intermediate: return (82, 92)
            case .advanced: return (85, 95)
            }
        case .recover: return (60, 75)
        case .steady: return (65, 78)
        case .cooldown: return (nil, 65)
        }
    }

    private static func makeKit(_ input: GeneratorInput, protocolKind: ProtocolKind) -> TargetKit {
        switch input.equipment {
        case .treadmill, .outdoor:
            let s = treadmillSpeeds(input)
            let workBand = hrBand(for: .work, level: input.level)
            // Norwegian efforts sit just under the classic work speed; in
            // low-impact mode they get the same walking cap as every other
            // work target (the ≥6% incline carries the intensity instead).
            let lowImpact = input.preferLowImpact && input.equipment == .treadmill && input.machine.hasIncline
            var norwegianSpeed = round1(max(s.easy + 0.8, s.work - 0.6))
            if lowImpact { norwegianSpeed = min(norwegianSpeed, 4.2) }
            return TargetKit(
                warm: treadTarget(speed: s.warm, incline: s.easyIncline, rpe: 2, words: "Very comfortable", hr: hrBand(for: .warmup, level: input.level)),
                build: treadTarget(speed: round1((s.warm + s.work) / 2), incline: s.easyIncline, rpe: 4, words: "Getting warmer", hr: hrBand(for: .warmup, level: input.level)),
                easy: treadTarget(speed: s.easy, incline: s.easyIncline, rpe: 3, words: "Catch your breath", hr: hrBand(for: .recover, level: input.level)),
                work: treadTarget(speed: s.work, incline: s.workIncline, rpe: 8, words: "Hard — a few words at most", hr: workBand),
                sprint: treadTarget(speed: s.sprint, incline: s.workIncline, rpe: 9, words: "Near max", hr: workBand),
                moderate: treadTarget(speed: round1((s.easy + s.work) / 2), incline: s.easyIncline, rpe: 5, words: "Comfortably brisk", hr: (70, 82)),
                steady: treadTarget(speed: round1((s.easy + s.work) / 2 - 0.3), incline: s.easyIncline, rpe: 4, words: "Conversational", hr: hrBand(for: .steady, level: input.level)),
                cool: treadTarget(speed: max(1.5, round1(s.warm - 0.3)), incline: 0, rpe: 2, words: "Wind it down", hr: hrBand(for: .cooldown, level: input.level)),
                hillWork: treadTarget(speed: round1(min(s.work * 0.72, 4.5)), incline: min(max(6, 5 + 0.5 * input.progression), max(1, input.machine.maxInclinePercent)), rpe: 8, words: "Strong climb", hr: workBand),
                surgeWork: treadTarget(speed: s.sprint, incline: s.workIncline, rpe: 9, words: "Fast", hr: workBand),
                norwegianWork: treadTarget(speed: norwegianSpeed, incline: s.workIncline, rpe: 7, words: "Hard but sustainable", hr: (85, 95)))
        case .bike:
            let b = bikeEfforts(input)
            let workBand = hrBand(for: .work, level: input.level)
            return TargetKit(
                warm: bikeTarget(resistance: max(1, b.easyRes - 1), cadence: 70, rpe: 2, words: "Very comfortable", hr: hrBand(for: .warmup, level: input.level)),
                build: bikeTarget(resistance: b.easyRes, cadence: 80, rpe: 4, words: "Getting warmer", hr: hrBand(for: .warmup, level: input.level)),
                easy: bikeTarget(resistance: b.easyRes, cadence: b.easyCadence, rpe: 3, words: "Catch your breath", hr: hrBand(for: .recover, level: input.level)),
                work: bikeTarget(resistance: b.workRes, cadence: b.workCadence, rpe: 8, words: "Hard — a few words at most", hr: workBand),
                sprint: bikeTarget(resistance: b.sprintRes, cadence: b.sprintCadence, rpe: 9, words: "Near max", hr: workBand),
                moderate: bikeTarget(resistance: max(1, (b.easyRes + b.workRes) / 2), cadence: 85, rpe: 5, words: "Comfortably brisk", hr: (70, 82)),
                steady: bikeTarget(resistance: max(1, (b.easyRes + b.workRes) / 2), cadence: 80, rpe: 4, words: "Conversational", hr: hrBand(for: .steady, level: input.level)),
                cool: bikeTarget(resistance: max(1, b.easyRes - 1), cadence: 65, rpe: 2, words: "Wind it down", hr: hrBand(for: .cooldown, level: input.level)),
                hillWork: bikeTarget(resistance: min(b.maxResistance, b.workRes + 2), cadence: 70, rpe: 8, words: "Grind it out", hr: workBand),
                surgeWork: bikeTarget(resistance: b.workRes, cadence: 105, rpe: 8, words: "Fast legs!", hr: workBand),
                norwegianWork: bikeTarget(resistance: max(1, b.workRes - 1), cadence: 85, rpe: 7, words: "Hard but sustainable", hr: (85, 95)))
        }
    }

    private static func treadTarget(speed: Double, incline: Double, rpe: Int, words: String, hr: (Double?, Double?)) -> PhaseTarget {
        PhaseTarget(speedMph: speed, inclinePercent: incline, resistance: nil, cadenceRPM: nil, rpe: rpe, effortWords: words, hrPercentLow: hr.0, hrPercentHigh: hr.1)
    }

    private static func bikeTarget(resistance: Int, cadence: Int, rpe: Int, words: String, hr: (Double?, Double?)) -> PhaseTarget {
        PhaseTarget(speedMph: nil, inclinePercent: nil, resistance: resistance, cadenceRPM: cadence, rpe: rpe, effortWords: words, hrPercentLow: hr.0, hrPercentHigh: hr.1)
    }

    private static func round1(_ x: Double) -> Double {
        (x * 10).rounded() / 10
    }

    // MARK: - Core builders

    /// Returns the phases plus the protocol that was actually built, so the
    /// plan's name/focus/cue lead can follow a fallback to classic intervals.
    private static func buildCore(_ kind: ProtocolKind, core: Double, input: GeneratorInput, kit: TargetKit) -> (phases: [IntervalPhase], kind: ProtocolKind) {
        switch kind {
        case .classic: return (classicCore(core: core, input: input, kit: kit), .classic)
        case .pyramid: return pyramidCore(core: core, input: input, kit: kit)
        case .norwegian: return norwegianCore(core: core, input: input, kit: kit)
        case .tenTwentyThirty: return tenTwentyThirtyCore(core: core, input: input, kit: kit)
        case .hills: return hillsCore(core: core, input: input, kit: kit)
        case .surges: return (surgesCore(core: core, input: input, kit: kit), .surges)
        }
    }

    /// Work:recovery ratios by level — beginners get ~1:2.5, advanced ~1:1,
    /// in line with ACSM interval-progression guidance.
    private static func classicCore(core: Double, input: GeneratorInput, kit: TargetKit) -> [IntervalPhase] {
        var work: Double
        var rec: Double
        switch input.level {
        case .beginner:
            work = 30; rec = input.minutes <= 12 ? 60 : 75
        case .intermediate:
            work = input.minutes <= 12 ? 30 : 60
            rec = input.minutes <= 12 ? 45 : 75
        case .advanced:
            work = input.minutes <= 12 ? 20 : 60
            rec = input.minutes <= 12 ? 40 : 60
        }
        if input.vibe == .easy { rec = (rec * 1.5).rounded() }
        let cycle = work + rec
        let cap: Int
        switch input.level {
        case .beginner: cap = 10
        case .intermediate: cap = 14
        case .advanced: cap = 16
        }
        var n = Int(((core + rec) / cycle).rounded(.down))
        n = max(3, min(n, cap))

        let target = (input.minutes <= 12 && input.level == .advanced) ? kit.sprint : kit.work
        var phases: [IntervalPhase] = []
        for i in 1...n {
            phases.append(IntervalPhase(kind: .work, seconds: work, label: "Interval", cue: "Push!", target: target))
            if i < n {
                phases.append(IntervalPhase(kind: .recover, seconds: rec, label: "Recover", cue: "Ease right off", target: kit.easy))
            }
        }
        return phases
    }

    private static func pyramidCore(core: Double, input: GeneratorInput, kit: TargetKit) -> (phases: [IntervalPhase], kind: ProtocolKind) {
        let base: Double
        switch input.level {
        case .beginner: base = 40
        case .intermediate: base = 60
        case .advanced: base = 75
        }
        var steps: [Double] = [0.5, 0.75, 1.0, 0.75, 0.5]
        if input.level != .beginner && core > 900 {
            steps = [0.5, 0.75, 1.0, 1.25, 1.0, 0.75, 0.5]
        }
        var phases: [IntervalPhase] = []
        var used = 0.0
        for (i, step) in steps.enumerated() {
            let w = (base * step / 5).rounded() * 5
            let r = input.vibe == .easy ? (w * 1.5 / 5).rounded() * 5 : w
            let needed = w + (i < steps.count - 1 ? r : 0)
            if used + needed > core { break }
            phases.append(IntervalPhase(kind: .work, seconds: w, label: "Effort", cue: step >= 1.0 ? "The peak — dig in" : "Push!", target: kit.work))
            used += w
            if i < steps.count - 1 {
                phases.append(IntervalPhase(kind: .recover, seconds: r, label: "Recover", cue: "Ease right off", target: kit.easy))
                used += r
            }
        }
        if phases.filter({ $0.kind == .work }).count < 3 {
            return (classicCore(core: core, input: input, kit: kit), .classic)
        }
        return (phases, .pyramid)
    }

    private static func norwegianCore(core: Double, input: GeneratorInput, kit: TargetKit) -> (phases: [IntervalPhase], kind: ProtocolKind) {
        let workSecs = 240.0
        let recSecs = 180.0
        var reps = 4
        while reps > 2 && Double(reps) * workSecs + Double(reps - 1) * recSecs > core {
            reps -= 1
        }
        if reps < 3 {
            return (classicCore(core: core, input: input, kit: kit), .classic)
        }
        var phases: [IntervalPhase] = []
        for i in 1...reps {
            phases.append(IntervalPhase(kind: .work, seconds: workSecs, label: "Push", cue: "Hard but steady — settle in", target: kit.norwegianWork))
            if i < reps {
                phases.append(IntervalPhase(kind: .recover, seconds: recSecs, label: "Recover", cue: "Active recovery — keep moving", target: kit.easy))
            }
        }
        return (phases, .norwegian)
    }

    private static func tenTwentyThirtyCore(core: Double, input: GeneratorInput, kit: TargetKit) -> (phases: [IntervalPhase], kind: ProtocolKind) {
        let blockSecs = 300.0 // 5 × (30 easy + 20 moderate + 10 sprint)
        let restSecs = 120.0
        var blocks = Int(((core + restSecs) / (blockSecs + restSecs)).rounded(.down))
        blocks = max(2, min(4, blocks))
        if Double(blocks) * blockSecs + Double(blocks - 1) * restSecs > core {
            return (classicCore(core: core, input: input, kit: kit), .classic)
        }
        var phases: [IntervalPhase] = []
        for b in 1...blocks {
            for _ in 1...5 {
                phases.append(IntervalPhase(kind: .recover, seconds: 30, label: "Easy", cue: "Float along", target: kit.easy))
                phases.append(IntervalPhase(kind: .steady, seconds: 20, label: "Moderate", cue: "Lift the pace", target: kit.moderate))
                phases.append(IntervalPhase(kind: .work, seconds: 10, label: "Sprint", cue: "All out!", target: kit.sprint))
            }
            if b < blocks {
                phases.append(IntervalPhase(kind: .recover, seconds: restSecs, label: "Between blocks", cue: "Full recovery", target: kit.easy))
            }
        }
        return (phases, .tenTwentyThirty)
    }

    private static func hillsCore(core: Double, input: GeneratorInput, kit: TargetKit) -> (phases: [IntervalPhase], kind: ProtocolKind) {
        let work: Double = input.level == .beginner ? 45 : 60
        let rec: Double = input.level == .beginner ? 90 : 75
        let cycle = work + rec
        var n = Int(((core + rec) / cycle).rounded(.down))
        n = max(3, min(n, 12))
        // Very short sessions can't fit even the 3-climb minimum — fall back
        // to classic intervals instead of overrunning the time budget.
        if Double(n) * work + Double(n - 1) * rec > core {
            return (classicCore(core: core, input: input, kit: kit), .classic)
        }
        var phases: [IntervalPhase] = []
        for i in 1...n {
            phases.append(IntervalPhase(kind: .work, seconds: work, label: "Climb", cue: "Drive with your legs", target: kit.hillWork))
            if i < n {
                phases.append(IntervalPhase(kind: .recover, seconds: rec, label: "Recover", cue: "Flat and easy", target: kit.easy))
            }
        }
        return (phases, .hills)
    }

    private static func surgesCore(core: Double, input: GeneratorInput, kit: TargetKit) -> [IntervalPhase] {
        let work = 30.0
        let rec = 60.0
        let cycle = work + rec
        var n = Int(((core + rec) / cycle).rounded(.down))
        n = max(4, min(n, 16))
        var phases: [IntervalPhase] = []
        for i in 1...n {
            phases.append(IntervalPhase(kind: .work, seconds: work, label: "Surge", cue: "Spin fast!", target: kit.surgeWork))
            if i < n {
                phases.append(IntervalPhase(kind: .recover, seconds: rec, label: "Recover", cue: "Smooth and light", target: kit.easy))
            }
        }
        return phases
    }
}
