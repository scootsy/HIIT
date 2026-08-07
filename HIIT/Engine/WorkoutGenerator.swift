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
    /// Advanced runners default to jog recoveries (5.0 mph); this swaps
    /// them for a brisk walk (≤3.7 mph, optional incline) instead.
    var preferWalkRecoveries: Bool = false
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

        // Warm-up floors follow the studied protocols (Bishop 2003: 5–10 min
        // of active warm-up; Helgerud warmed up ~10 min before the 4×4):
        // never below 3:00 — short sessions shrink the core, not the warm-up.
        // Sprint protocols get 90 extra seconds spent on two fast pickups.
        // Cool-downs depend on how the session ends: ≥3:00 after finishing
        // on a hard effort, 4:00 after the 4×4 or sprint-heavy work (ACSM:
        // light activity guards against post-exercise pooling). The very
        // shortest sessions keep 1:30 — an 8-minute budget can't fund more.
        // A Zone-2 steady finish keeps the original short cool-down below.
        func budget(for kind: ProtocolKind) -> (warmup: Double, cooldown: Double, sprintPrep: Bool) {
            let sprintPrep = kind == .tenTwentyThirty || kind == .surges
            var warmup: Double
            if kind == .norwegian {
                warmup = 480
            } else if input.minutes <= 12 {
                warmup = 180
            } else if input.minutes <= 20 {
                warmup = 240
            } else {
                warmup = 300
            }
            if sprintPrep { warmup += 90 }
            let cooldown: Double
            if input.minutes <= 12 {
                cooldown = 90
            } else {
                switch kind {
                case .norwegian, .tenTwentyThirty, .surges: cooldown = 240
                default: cooldown = 180
                }
            }
            return (warmup, cooldown, sprintPrep)
        }

        // A core builder can fall back to classic intervals when its own
        // protocol doesn't fit the time budget — when that happens the
        // warm-up and cool-down must follow the fallback too (no sprint
        // pickups or sprint-sized cool-down on a classic session), so the
        // budget is recomputed and the core rebuilt once. The fallback kind
        // is always .classic, which cannot fall back again.
        var (warmupSecs, cooldownMin, sprintPrep) = budget(for: requestedProtocol)
        var coreResult = buildCore(requestedProtocol, core: max(120, total - warmupSecs - cooldownMin), input: input, kit: kit)
        if coreResult.kind != requestedProtocol {
            (warmupSecs, cooldownMin, sprintPrep) = budget(for: coreResult.kind)
            coreResult = buildCore(coreResult.kind, core: max(120, total - warmupSecs - cooldownMin), input: input, kit: kit)
        }
        var corePhases = coreResult.phases
        let protocolKind = coreResult.kind

        var phases: [IntervalPhase] = []
        let rampSecs = warmupSecs - (sprintPrep ? 90 : 0)
        phases.append(IntervalPhase(kind: .warmup, seconds: (rampSecs * 0.6).rounded(), label: "Warm up", cue: "Find your rhythm", target: kit.warm))
        phases.append(IntervalPhase(kind: .warmup, seconds: (rampSecs * 0.4).rounded(), label: "Warm up", cue: "Open up a little", target: kit.build))
        if sprintPrep {
            // Prime leg turnover before the first all-out effort: two 15s
            // pickups near sprint pace, each shaken out with 30s easy.
            let pickup = input.equipment == .bike ? kit.surgeWork : kit.sprint
            phases.append(IntervalPhase(kind: .warmup, seconds: 15, label: "Pickup", cue: "Fast for a moment", target: pickup))
            phases.append(IntervalPhase(kind: .warmup, seconds: 30, label: "Warm up", cue: "Shake it out", target: kit.warm))
            phases.append(IntervalPhase(kind: .warmup, seconds: 15, label: "Pickup", cue: "Once more — fast", target: pickup))
            phases.append(IntervalPhase(kind: .warmup, seconds: 30, label: "Warm up", cue: "Nearly there", target: kit.warm))
        }

        // Spend any leftover time as an easy steady block, then cool down —
        // extra Zone-2 minutes are far more useful than a padded cooldown,
        // and a steady finish only needs the short 2:30 wind-down.
        let used = corePhases.reduce(0) { $0 + $1.seconds }
        var remainder = total - warmupSecs - used
        if remainder >= cooldownMin + 150 {
            let steadyCooldown = 150.0
            corePhases.append(IntervalPhase(kind: .steady, seconds: (remainder - steadyCooldown).rounded(), label: "Steady", cue: "Settle into a rhythm", target: kit.steady))
            remainder = steadyCooldown
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
            // Name the session by the reps that actually fit: with the full
            // 8-minute warm-up, 4 rounds need ~37 minutes, so a 30–36 minute
            // budget honestly gets a "3×4".
            let reps = corePhases.filter { $0.kind == .work }.count
            name = "Norwegian \(reps)×4"
            focus = "Long 4-minute pushes at 90–95% of max heart rate — the classic VO₂max builder (Helgerud et al., 2007)."
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
            isDeload: deload,
            phases: phases)
    }

    // MARK: - Session-length suggestion

    /// The app picks the session length, not the user — this is a coaching
    /// app for people who don't know how to build workouts. Bases of
    /// 15/25/30 minutes by tier grow +5 minutes per ~3 progression levels
    /// (duration progresses before intensity, per ACSM), capped per tier;
    /// every 4th session goes long (~+30%, the natural Norwegian 4×4 slot)
    /// and deload days drop to ~65% of the working length. The user can
    /// always override.
    static func suggestMinutes(level: ExperienceLevel, progression: Double, sessionsCompleted: Int, hardSessionsSinceEasy: Int) -> Int {
        let base: Int
        let cap: Int
        switch level {
        case .beginner: base = 15; cap = 20
        case .intermediate: base = 25; cap = 30
        case .advanced: base = 30; cap = 40
        }
        var minutes = min(cap, base + 5 * max(0, Int(progression / 3)))
        if hardSessionsSinceEasy >= 5 {
            // The generator converts the next auto session into a deload —
            // "lighter" should mean lighter in time too.
            minutes = max(12, Int((Double(minutes) * 0.65 / 5).rounded()) * 5)
        } else if level != .beginner && sessionsCompleted >= 3 && sessionsCompleted % 4 == 3 {
            // The long day: enough room for the 4×4's 8-minute warm-up,
            // three-to-four 4-minute pushes, and a full cool-down.
            minutes = min(45, max(30, Int((Double(minutes) * 1.3 / 5).rounded()) * 5))
        }
        return minutes
    }

    // MARK: - Protocol selection

    /// The protocols this configuration can rotate through. Also used by the
    /// setup UI to hide "Mix it up" when there is provably nothing to mix
    /// (one candidate ⇒ every shuffle regenerates the identical plan).
    static func candidateProtocols(_ inputRaw: GeneratorInput) -> [ProtocolKind] {
        var input = inputRaw
        if input.vibe == .auto && input.hardSessionsSinceEasy >= 5 { input.vibe = .easy }
        if input.vibe == .easy { return [.classic] }
        switch input.equipment {
        case .treadmill:
            if input.level == .beginner {
                return input.machine.hasIncline ? [.classic, .hills] : [.classic]
            }
            var options: [ProtocolKind] = [.classic, .pyramid]
            if input.machine.hasIncline { options.append(.hills) }
            if input.minutes >= 30 { options.append(.norwegian) }
            return options
        case .bike:
            if input.level == .beginner { return [.classic] }
            var options: [ProtocolKind] = [.classic]
            if sprintProtocolFits(.surges, minutes: input.minutes) { options.append(.surges) }
            if input.minutes >= 15 {
                if sprintProtocolFits(.tenTwentyThirty, minutes: input.minutes) { options.append(.tenTwentyThirty) }
                options.append(.pyramid)
            }
            if input.minutes >= 30 { options.append(.norwegian) }
            return options
        case .outdoor:
            if input.level == .beginner { return [.classic] }
            var options: [ProtocolKind] = [.classic, .pyramid]
            if input.minutes >= 15 && sprintProtocolFits(.tenTwentyThirty, minutes: input.minutes) {
                options.append(.tenTwentyThirty)
            }
            if input.minutes >= 30 { options.append(.norwegian) }
            return options
        }
    }

    /// Whether a sprint protocol's minimum core fits the session budget once
    /// its (larger) warm-up and cool-down are funded — the candidate list
    /// must match the same arithmetic makePlan uses, or the rotation would
    /// advertise protocols that always silently fall back to classic.
    private static func sprintProtocolFits(_ kind: ProtocolKind, minutes: Int) -> Bool {
        var warmup: Double = minutes <= 12 ? 180 : (minutes <= 20 ? 240 : 300)
        warmup += 90 // the sprint pickups
        let cooldown: Double = minutes <= 12 ? 90 : 240
        // 720 = two 10-20-30 blocks + the rest between; 300 = 4 surges + 3 recoveries.
        let minCore: Double = kind == .tenTwentyThirty ? 720 : 300
        return Double(minutes * 60) - warmup - cooldown >= minCore
    }

    /// Rotates protocols session-to-session so training stays varied, gated by
    /// experience, session length, and what the machine supports. Rapid speed
    /// changes (10-20-30) are never assigned on a treadmill — belts can't keep up.
    ///
    /// Norwegian rotates inside the candidate list rather than claiming a fixed
    /// sessionCount residue: the old `% 3 == 2` slot shadowed whichever
    /// protocol shared its index, leaving treadmill Hill Climbs and outdoor
    /// 10-20-30 unreachable in every 26+ minute session.
    static func chooseProtocol(_ input: GeneratorInput) -> ProtocolKind {
        if input.vibe == .easy { return .classic }
        // Beginner treadmills keep their gentler weighting: hills only every
        // third session, classic otherwise.
        if input.equipment == .treadmill && input.level == .beginner {
            return input.machine.hasIncline && input.sessionCount % 3 == 1 ? .hills : .classic
        }
        let options = candidateProtocols(input)
        return options[input.sessionCount % options.count]
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
        /// Near-passive relief after all-out sprints (Dupont 2004: an easy
        /// jog between short sprints steals the oxygen the muscles need to
        /// recharge — time-to-exhaustion more than halves).
        var sprintRest: PhaseTarget
        /// The 4×4's prescribed ~70% HRmax recovery jog — a plain walk drops
        /// most users well below it and shrinks time-in-zone in the next rep.
        var norwegianRest: PhaseTarget
    }

    private static func treadmillSpeeds(_ input: GeneratorInput) -> Speeds {
        // Recovery speeds are gait-explicit: beginners and intermediates
        // walk (2.8 / 3.4 mph), advanced users jog (5.0 mph). Humans switch
        // gait at ~4.3–4.9 mph (Hreljac 1993), so nothing between 4.2 and
        // 4.7 is ever prescribed flat — it's a fast, awkward walk for some
        // and a too-slow jog for others, which defeats a recovery interval.
        // Recovery speed does NOT scale with progression: recoveries exist
        // to enable the next effort, not as a progressively loaded stimulus.
        var easy: Double
        var work: Double
        switch input.level {
        case .beginner:
            easy = 2.8; work = 4.5
        case .intermediate:
            easy = 3.4; work = 6.0
        case .advanced:
            easy = 5.0; work = 7.5
        }
        // Fitness proxies pulled from Apple Health: a high resting HR, high BMI,
        // or older age all argue for a gentler starting point.
        if let resting = input.restingHR, resting > 72 { work -= 0.4 }
        if let bmi = input.bmi, bmi >= 30 { work -= 0.5; easy = min(easy, 3.4) }
        if let age = input.age, age >= 55 { work -= 0.4 }
        switch input.vibe {
        case .easy: work -= 0.6
        case .push: work += 0.3
        case .auto: break
        }
        // Progressive overload: each level step is worth +0.2 mph on the work speed.
        work += ProgressionEngine.speedPerLevelMph * input.progression

        // Walking recoveries on request (and always in low-impact mode):
        // capped below the gait-transition zone.
        let lowImpact = input.preferLowImpact && input.equipment == .treadmill && input.machine.hasIncline
        if lowImpact || input.preferWalkRecoveries {
            easy = min(easy, 3.7)
        }

        easy = max(1.5, min(easy, input.machine.maxSpeedMph - 1))
        // A slow machine can drag the advanced 5.0 jog into the gait band —
        // a jog that can't be funded degrades to the brisk-walk recovery.
        if easy >= 4.2 && easy < 4.8 { easy = 3.7 }
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
        if lowImpact {
            work = min(work, 4.2)
            workIncline = min(max(6, 5 + 0.5 * input.progression), input.machine.maxInclinePercent)
        }

        var sprint = min(work + 1.8, input.machine.maxSpeedMph)
        if lowImpact { sprint = min(sprint, 4.2) }
        // Warm-ups stay walk-based even when recoveries are jogged — the
        // building segment and pickups are where the jog arrives.
        let warm = max(1.5, min(easy - 0.4, 3.8))
        return Speeds(warm: round1(warm), easy: round1(easy), work: round1(work), sprint: round1(sprint), workIncline: workIncline, easyIncline: easyIncline)
    }

    private static func bikeEfforts(_ input: GeneratorInput) -> BikeEfforts {
        let maxR = max(4, input.machine.maxResistance)
        // Resistance fractions are a first-session starting guess only —
        // "% of max resistance" means something different on every bike, so
        // the real calibration loop is the user's mid-workout ± overrides,
        // which feed straight into the next session's targets.
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
        workFrac += ProgressionEngine.resistanceFractionPerLevel * input.progression
        workFrac = max(0.45, min(0.9, workFrac))
        let easyFrac = 0.35
        let sprintFrac = min(0.95, workFrac + 0.12)

        // Sprint cadence scales with experience — holding form at 105+ rpm
        // is a coordination skill novices don't have yet.
        let sprintCadence: Int
        switch input.level {
        case .beginner: sprintCadence = 95
        case .intermediate: sprintCadence = 100
        case .advanced: sprintCadence = 110
        }

        func res(_ fraction: Double) -> Int {
            max(1, min(maxR, Int((fraction * Double(maxR)).rounded())))
        }
        return BikeEfforts(
            easyRes: res(easyFrac),
            workRes: res(workFrac),
            sprintRes: res(sprintFrac),
            easyCadence: 75,
            workCadence: 90,
            sprintCadence: sprintCadence,
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
            // 4×4 recovery targets ~70% HRmax (Helgerud's prescription): a
            // jog for jog-recovery users, otherwise a bumped-up pace — and
            // when recoveries must stay walks, a brisk incline walk instead.
            let walkBased = s.easy < 4.8
            var norwegianRestSpeed = walkBased ? max(s.easy + 0.8, round1(norwegianSpeed * 0.6)) : s.easy
            var norwegianRestIncline = 0.0
            // When the push itself is clamped down to easy + 0.8 there is no
            // room for a bumped-up recovery below it — plain easy pace then.
            if norwegianRestSpeed >= norwegianSpeed { norwegianRestSpeed = s.easy }
            // The bump must not land in the 4.2–4.7 gait band: cap at 4.0
            // and carry the ~70% target with a touch of incline instead.
            if walkBased && norwegianRestSpeed > 4.0 {
                norwegianRestSpeed = 4.0
                norwegianRestIncline = input.machine.hasIncline ? min(2, input.machine.maxInclinePercent) : 0
            }
            if lowImpact || input.preferWalkRecoveries {
                norwegianRestSpeed = min(norwegianRestSpeed, 3.7)
                norwegianRestIncline = input.machine.hasIncline ? min(3, input.machine.maxInclinePercent) : 0
            }
            let norwegianRestWords = norwegianRestSpeed >= 4.8 ? "Easy jog" : "Brisk walk"
            return TargetKit(
                warm: treadTarget(speed: s.warm, incline: s.easyIncline, rpe: 2, words: "Very comfortable", hr: hrBand(for: .warmup, level: input.level)),
                build: treadTarget(speed: round1((s.warm + s.work) / 2), incline: s.easyIncline, rpe: 4, words: "Getting warmer", hr: hrBand(for: .warmup, level: input.level)),
                easy: treadTarget(speed: s.easy, incline: s.easyIncline, rpe: 3, words: s.easy >= 4.8 ? "Recovery jog" : "Catch your breath", hr: hrBand(for: .recover, level: input.level)),
                work: treadTarget(speed: s.work, incline: s.workIncline, rpe: 8, words: "Hard — a few words at most", hr: workBand),
                sprint: treadTarget(speed: s.sprint, incline: s.workIncline, rpe: 9, words: "Near max", hr: workBand),
                moderate: treadTarget(speed: round1((s.easy + s.work) / 2), incline: s.easyIncline, rpe: 5, words: "Comfortably brisk", hr: (70, 82)),
                steady: treadTarget(speed: round1((s.easy + s.work) / 2 - 0.3), incline: s.easyIncline, rpe: 4, words: "Conversational", hr: hrBand(for: .steady, level: input.level)),
                cool: treadTarget(speed: max(1.5, round1(min(s.warm, 3.8) - 0.3)), incline: 0, rpe: 2, words: "Wind it down", hr: hrBand(for: .cooldown, level: input.level)),
                hillWork: treadTarget(speed: round1(min(s.work * 0.72, 4.5)), incline: min(max(6, 5 + 0.5 * input.progression), max(1, input.machine.maxInclinePercent)), rpe: 8, words: "Strong climb", hr: workBand),
                surgeWork: treadTarget(speed: s.sprint, incline: s.workIncline, rpe: 9, words: "Fast", hr: workBand),
                norwegianWork: treadTarget(speed: norwegianSpeed, incline: s.workIncline, rpe: 7, words: "Hard but sustainable", hr: (90, 95)),
                sprintRest: treadTarget(speed: 2.2, incline: 0, rpe: 2, words: "Slow walk", hr: (nil, 70)),
                norwegianRest: treadTarget(speed: round1(norwegianRestSpeed), incline: norwegianRestIncline, rpe: 3, words: norwegianRestWords, hr: (65, 75)))
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
                surgeWork: bikeTarget(resistance: b.workRes, cadence: b.sprintCadence, rpe: 8, words: "Fast legs!", hr: workBand),
                norwegianWork: bikeTarget(resistance: max(1, b.workRes - 1), cadence: 85, rpe: 7, words: "Hard but sustainable", hr: (90, 95)),
                sprintRest: bikeTarget(resistance: max(1, b.easyRes - 1), cadence: 60, rpe: 2, words: "Very light spin", hr: (nil, 70)),
                norwegianRest: bikeTarget(resistance: b.easyRes, cadence: 75, rpe: 3, words: "Steady recovery spin", hr: (65, 75)))
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
        case .surges: return surgesCore(core: core, input: input, kit: kit)
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
        // Fit guard: the forced 3-rep minimum can overrun the shortest cores.
        // classicCore is the terminal fallback, so it can't fall back itself —
        // shrink the recoveries (30s floor, 5s steps) to honor the budget.
        if Double(n) * work + Double(n - 1) * rec > core {
            rec = max(30, ((core - Double(n) * work) / Double(n - 1) / 5).rounded(.down) * 5)
        }

        // The short advanced session is all-out sprints — its relief is a
        // near-passive slow walk (kit.sprintRest), not the usual active
        // recovery: an easy jog between sprints starves the muscles' energy
        // resynthesis and halves how much sprinting a session can hold.
        let sprintVariant = input.minutes <= 12 && input.level == .advanced
        let target = sprintVariant ? kit.sprint : kit.work
        let rest = sprintVariant ? kit.sprintRest : kit.easy
        let restCue = sprintVariant ? "Slow right down — walk it" : "Ease right off — talking pace"
        var phases: [IntervalPhase] = []
        for i in 1...n {
            phases.append(IntervalPhase(kind: .work, seconds: work, label: "Interval", cue: "Push!", target: target))
            if i < n {
                phases.append(IntervalPhase(kind: .recover, seconds: rec, label: "Recover", cue: restCue, target: rest))
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
                phases.append(IntervalPhase(kind: .recover, seconds: recSecs, label: "Recover", cue: "Active recovery — stay around 70%", target: kit.norwegianRest))
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

    private static func surgesCore(core: Double, input: GeneratorInput, kit: TargetKit) -> (phases: [IntervalPhase], kind: ProtocolKind) {
        let work = 30.0
        let rec = 60.0
        let cycle = work + rec
        var n = Int(((core + rec) / cycle).rounded(.down))
        n = max(4, min(n, 16))
        // The 4-surge minimum can't fit the shortest sessions — fall back to
        // classic intervals (like every other builder) instead of overrunning
        // the core and squeezing the cooldown to its floor.
        if Double(n) * work + Double(n - 1) * rec > core {
            return (classicCore(core: core, input: input, kit: kit), .classic)
        }
        var phases: [IntervalPhase] = []
        for i in 1...n {
            phases.append(IntervalPhase(kind: .work, seconds: work, label: "Surge", cue: "Spin fast!", target: kit.surgeWork))
            if i < n {
                phases.append(IntervalPhase(kind: .recover, seconds: rec, label: "Recover", cue: "Smooth and light", target: kit.easy))
            }
        }
        return (phases, .surges)
    }
}
