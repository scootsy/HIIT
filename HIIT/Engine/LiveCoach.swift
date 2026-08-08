import Foundation

/// Rule-based mid-session coaching — no LLM, no network. Watches live heart
/// rate against the phase's target band and the same objective thresholds the
/// post-session grading uses, and when the day's execution has drifted, offers
/// a one-tap target correction. It never applies anything itself: the user
/// ratifies every change, which lets accepted suggestions flow through the
/// ordinary override machinery (clamping, later-phase propagation, and
/// next-session progression credit) unchanged.
///
/// Foreground-only by the same design as the rest of the live session: the
/// engine tick that drives evaluation stops while the app is suspended.
final class LiveCoach {

    struct Suggestion: Identifiable, Equatable {
        enum Trigger: String {
            /// Sustained HR above the work/steady band.
            case overBand
            /// Consecutive completed efforts never reached the band.
            case underBandEfforts
            /// Long recoveries aren't bringing heart rate down.
            case insufficientRecovery
            /// 1-minute heart-rate recovery under the clinical flag.
            case lowHRR
        }
        let id: UUID
        let trigger: Trigger
        /// Signed steps in the manual-adjust units (±0.1 mph / ±1 resistance).
        let steps: Int
        /// Phase whose kind anchors the same propagation scope adjustTarget uses.
        let anchorIndex: Int
        /// Human sentence — the view renders the numeric value line itself.
        let message: String
        let createdAt: Date
        let expiresAt: Date
    }

    /// Every live-coach tunable in one place. Thresholds shared with the
    /// post-session grading live on SessionObjectives so the two can't drift.
    enum Rules {
        /// A sample must be this fresh to count toward sustained-over time.
        static let hrFreshSeconds = 10.0
        /// Any suggestion at all needs a live source no older than this.
        static let hrRecentSeconds = 60.0
        /// Over the band top by this much starts the sustain clock (the same
        /// margin the plain "ease off" message uses)…
        static let overBandTriggerPct = 3.0
        /// …and this far over earns a two-step ease-off instead of one.
        static let overBandHardPct = 5.0
        static let overBandSustainSeconds = 20.0
        /// Hysteresis: the sustain clock resets once back under top + 1.
        static let overBandResetPct = 1.0
        /// HR lags effort by 20–50s — never judge a work phase's early ramp.
        static let overBandMinPhaseElapsed = 45.0
        /// Chip lifetime before it quietly expires.
        static let displaySeconds = 20.0
        /// Minimum quiet time between any two chips.
        static let cooldownSeconds = 60.0
        /// |cumulative accepted steps| allowed per session — the coach may
        /// correct a day, never rewrite it.
        static let maxAcceptedSteps = 3
        /// The walk/run gait dead zone. A suggestion must never *move* a speed
        /// into the open interval — targets already inside it (beginner jogs
        /// are prescribed at 4.5 on purpose) step freely, matching the manual
        /// stepper.
        static let deadZoneLowMph = 4.2
        static let deadZoneHighMph = 4.7
    }

    private(set) var offeredCount = 0
    private(set) var acceptedCount = 0

    private var active: Suggestion? = nil
    private var activePhaseIndex = -1
    private var lastChipEndedAt = Date.distantPast
    private var lastRuleEvalAt: Date? = nil
    private var acceptedStepTotal = 0
    /// After an accepted ease-off, raises stay off for the session — the two
    /// see-sawing would mean the thresholds need adjusting, not the user.
    private var acceptedEaseOff = false
    private var overBandSeconds = 0.0
    private var overBandHardSeconds = 0.0
    private var overBandPhaseIndex = -1
    private var overBandFiredPhase = -1
    /// Completed-gradeable-effort count already consumed by a raise offer.
    private var underBandWatermark = 0
    /// recoveryMinPcts entries already consumed by a recovery offer.
    private var recoveryWatermark = 0
    private var lastHRRSeen: Double? = nil
    private var hrrFired = false
    private var lastAppliedTargets: [PhaseTarget]? = nil

    /// "DROP TO 6.8 MPH · 2 EFFORTS LEFT" — the projected value after the
    /// same clamping adjustTarget will apply, in the user's units. Shared by
    /// the in-app chip and the lock-screen Live Activity so the two never
    /// show different numbers.
    static func valueText(for suggestion: Suggestion, engine: WorkoutEngine, useMetric: Bool) -> String {
        guard suggestion.anchorIndex < engine.appliedTargets.count else { return "" }
        let verb = suggestion.steps < 0 ? "DROP TO" : "RAISE TO"
        let target = engine.appliedTargets[suggestion.anchorIndex]
        var value: String
        if engine.plan.equipment == .bike, let resistance = target.resistance {
            let projected = max(1, min(engine.machine.maxResistance, resistance + suggestion.steps))
            value = "\(verb) R\(projected)"
        } else if let speed = target.speedMph {
            let raw = ((speed + 0.1 * Double(suggestion.steps)) * 10).rounded() / 10
            let projected = max(0.5, min(engine.machine.maxSpeedMph, raw))
            let display = useMetric
                ? String(format: "%.1f KM/H", projected * 1.60934)
                : String(format: "%.1f MPH", projected)
            value = "\(verb) \(display)"
        } else {
            return ""
        }
        if engine.plan.phases[suggestion.anchorIndex].kind == .work {
            let remaining = engine.plan.phases.indices.filter {
                $0 >= engine.phaseIndex && engine.plan.phases[$0].kind == .work
            }.count
            value += remaining == 1 ? " · LAST EFFORT" : " · \(remaining) EFFORTS LEFT"
        }
        return value
    }

    // MARK: - Lifecycle notes from the engine

    func noteAccepted(_ suggestion: Suggestion) {
        acceptedCount += 1
        acceptedStepTotal += suggestion.steps
        if suggestion.steps < 0 { acceptedEaseOff = true }
        active = nil
        lastChipEndedAt = Date()
    }

    func noteDismissed(_ suggestion: Suggestion) {
        active = nil
        lastChipEndedAt = Date()
    }

    // MARK: - Evaluation

    /// Called from the engine tick. Owns the chip's lifetime (expiry, phase
    /// change), cooldowns, and rule arming; returns what should be visible.
    func evaluate(engine: WorkoutEngine, now: Date = Date()) -> Suggestion? {
        // The active chip's lifecycle runs at full tick rate so expiry and
        // phase-boundary re-anchoring are prompt.
        if let current = active {
            if now >= current.expiresAt {
                active = nil
                lastChipEndedAt = now
                return nil
            }
            if engine.phaseIndex != activePhaseIndex {
                // A phase boundary used to dismiss the chip outright — which
                // took an offer made in an effort's closing seconds off the
                // screen just as the user got a hand free to act on it. The
                // chip now lives out its normal lifetime as long as the
                // suggestion still has something to change.
                activePhaseIndex = engine.phaseIndex
                active = reanchored(current, engine: engine)
                if active == nil {
                    lastChipEndedAt = now
                    return nil
                }
            }
            return active
        }

        // Rule evaluation itself only needs ~1 Hz.
        let dt: Double
        if let last = lastRuleEvalAt {
            let sinceLast = now.timeIntervalSince(last)
            guard sinceLast >= 1 else { return nil }
            // A pause or suspension gap must not accumulate as sustained time.
            dt = min(2, sinceLast)
        } else {
            dt = 0
        }
        lastRuleEvalAt = now

        // Bookkeeping that runs even while the gates below hold suggestions
        // back, so nothing stale carries across phases or user edits.
        if engine.phaseIndex != overBandPhaseIndex {
            overBandPhaseIndex = engine.phaseIndex
            overBandSeconds = 0
            overBandHardSeconds = 0
        }
        if lastAppliedTargets != engine.appliedTargets {
            // Any target change — stepper, lock screen, past-effort edit, or
            // an accepted chip — re-arms the raise rule, so a suggestion never
            // stacks on top of a change the user just made.
            lastAppliedTargets = engine.appliedTargets
            underBandWatermark = gradeableEffortFlags(engine: engine).count
        }
        if let maxHR = engine.maxHR, maxHR > 0,
           engine.state == .running,
           engine.currentPhase.kind == .work || engine.currentPhase.kind == .steady,
           let hi = engine.currentTarget.hrPercentHigh,
           let hr = engine.latestHR, let hrDate = engine.latestHRDate,
           now.timeIntervalSince(hrDate) <= Rules.hrFreshSeconds {
            let pct = hr / maxHR * 100
            if pct > hi + Rules.overBandTriggerPct {
                overBandSeconds += dt
                if pct > hi + Rules.overBandHardPct { overBandHardSeconds += dt }
            } else if pct < hi + Rules.overBandResetPct {
                overBandSeconds = 0
                overBandHardSeconds = 0
            }
        }

        // Global gates for offering anything new.
        guard engine.state == .running,
              !engine.inOvertime,
              !engine.isWarning,
              engine.currentPhase.kind != .warmup,
              engine.currentPhase.kind != .cooldown,
              engine.maxHR != nil,
              let hrDate = engine.latestHRDate,
              now.timeIntervalSince(hrDate) <= Rules.hrRecentSeconds,
              now.timeIntervalSince(lastChipEndedAt) >= Rules.cooldownSeconds
        else { return nil }

        let easyDay = engine.plan.vibe == .easy || engine.plan.isDeload == true

        // R1 — sustained over-band (safety first; allowed on easy days).
        if engine.currentPhase.kind == .work || engine.currentPhase.kind == .steady,
           overBandFiredPhase != engine.phaseIndex,
           overBandSeconds >= Rules.overBandSustainSeconds,
           engine.phaseElapsed >= Rules.overBandMinPhaseElapsed {
            let isWork = engine.currentPhase.kind == .work
            let hard = isWork && overBandHardSeconds >= Rules.overBandSustainSeconds
            let message: String
            if !isWork {
                message = "Running hot — ease this block back"
            } else if hard {
                message = "Well above the zone — take these efforts down a notch"
            } else {
                message = "Running hot — ease the remaining efforts back"
            }
            if let s = offer(.overBand, steps: hard ? -2 : -1, anchor: engine.phaseIndex,
                             message: message, engine: engine, now: now) {
                overBandFiredPhase = engine.phaseIndex
                return s
            }
        }

        // R2 — 1-minute heart-rate recovery under the clinical flag. Only
        // consumed here (not pre-gate) so a reading that lands while a chip
        // is up can still prompt once the lane is clear; once per session.
        let hrrChanged = engine.hrRecovery != lastHRRSeen
        lastHRRSeen = engine.hrRecovery
        if hrrChanged, !hrrFired,
           let hrr = engine.hrRecovery, hrr < SessionObjectives.hrrFlagBPM,
           let anchor = nextEffortIndex(engine: engine),
           let s = offer(.lowHRR, steps: -1, anchor: anchor,
                         message: "Slow recovery after that effort — ease off and keep an eye on it",
                         engine: engine, now: now) {
            hrrFired = true
            return s
        }

        // R3 — long recoveries not coming down (allowed on easy days; only
        // fires on protocols with ≥120s recoveries, where the measurement
        // physiologically exists).
        if engine.recoveryMinPcts.count >= recoveryWatermark + 2,
           engine.recoveryMinPcts.suffix(2).allSatisfy({ $0 > SessionObjectives.recoveryPartialPct }),
           let anchor = nextEffortIndex(engine: engine),
           let s = offer(.insufficientRecovery, steps: -1, anchor: anchor,
                         message: "Heart rate isn't settling between efforts — ease the remaining pushes",
                         engine: engine, now: now) {
            recoveryWatermark = engine.recoveryMinPcts.count
            return s
        }

        // R4 — consecutive completed efforts that never reached the band.
        // Judged only on phases long enough to grade fairly (HR can't catch
        // a short bout at all), and never on a day meant to be easy.
        if !easyDay, !acceptedEaseOff {
            let flags = gradeableEffortFlags(engine: engine)
            if flags.count >= underBandWatermark + 2,
               flags.suffix(2).allSatisfy({ !$0 }),
               let anchor = nextEffortIndex(engine: engine),
               let s = offer(.underBandEfforts, steps: 1, anchor: anchor,
                             message: "Efforts aren't reaching the zone — you've got more in you",
                             engine: engine, now: now) {
                underBandWatermark = flags.count
                return s
            }
        }

        return nil
    }

    /// The surviving form of an active suggestion after a phase boundary, or
    /// nil when no legal change remains. An anchor that slipped into the past
    /// hops to the next not-yet-run phase of the same kind, so accepting
    /// after the flip can't rewrite a completed phase's record. The id is
    /// kept: it's the same offer, so no new-chip haptic or speech fires.
    private func reanchored(_ suggestion: Suggestion, engine: WorkoutEngine) -> Suggestion? {
        var anchor = suggestion.anchorIndex
        if anchor < engine.phaseIndex {
            let kind = engine.plan.phases[anchor].kind
            let next = (engine.phaseIndex..<engine.plan.phases.count).first {
                engine.plan.phases[$0].kind == kind
                    && (kind != .work || engine.plan.phases[$0].seconds >= SessionObjectives.minGradeableEffortSeconds)
            }
            guard let next else { return nil }
            anchor = next
        }
        guard isLegal(steps: suggestion.steps, anchor: anchor, engine: engine) else { return nil }
        guard anchor != suggestion.anchorIndex else { return suggestion }
        return Suggestion(id: suggestion.id,
                          trigger: suggestion.trigger,
                          steps: suggestion.steps,
                          anchorIndex: anchor,
                          message: suggestion.message,
                          createdAt: suggestion.createdAt,
                          expiresAt: suggestion.expiresAt)
    }

    // MARK: - Offer construction

    /// Trims the requested steps to the session budget and the legality of
    /// every affected phase, then activates the suggestion — or returns nil
    /// (consuming nothing) when no legal change remains.
    private func offer(_ trigger: Suggestion.Trigger, steps: Int, anchor: Int,
                       message: String, engine: WorkoutEngine, now: Date) -> Suggestion? {
        let sign = steps < 0 ? -1 : 1
        var magnitude = abs(steps)
        while magnitude > 0 && abs(acceptedStepTotal) + magnitude > Rules.maxAcceptedSteps {
            magnitude -= 1
        }
        while magnitude > 0 && !isLegal(steps: sign * magnitude, anchor: anchor, engine: engine) {
            magnitude -= 1
        }
        guard magnitude > 0 else { return nil }
        let suggestion = Suggestion(id: UUID(),
                                    trigger: trigger,
                                    steps: sign * magnitude,
                                    anchorIndex: anchor,
                                    message: message,
                                    createdAt: now,
                                    expiresAt: now.addingTimeInterval(Rules.displaySeconds))
        active = suggestion
        activePhaseIndex = engine.phaseIndex
        offeredCount += 1
        return suggestion
    }

    /// Mirrors adjustTarget's scope and clamping: the change must actually
    /// move the anchor phase, and no affected speed may cross from outside
    /// the walk/run dead zone to inside it.
    private func isLegal(steps: Int, anchor: Int, engine: WorkoutEngine) -> Bool {
        let phases = engine.plan.phases
        guard phases.indices.contains(anchor), anchor < engine.appliedTargets.count else { return false }
        let kind = phases[anchor].kind
        var movesAnchor = false
        for i in phases.indices where phases[i].kind == kind && (i == anchor || i >= engine.phaseIndex) {
            if engine.plan.equipment == .bike {
                guard let resistance = engine.appliedTargets[i].resistance else { continue }
                let projected = max(1, min(engine.machine.maxResistance, resistance + steps))
                if i == anchor && projected != resistance { movesAnchor = true }
            } else {
                guard let speed = engine.appliedTargets[i].speedMph else { continue }
                let raw = ((speed + 0.1 * Double(steps)) * 10).rounded() / 10
                let projected = max(0.5, min(engine.machine.maxSpeedMph, raw))
                let wasInside = speed > Rules.deadZoneLowMph + 0.01 && speed < Rules.deadZoneHighMph - 0.01
                let isInside = projected > Rules.deadZoneLowMph + 0.01 && projected < Rules.deadZoneHighMph - 0.01
                if isInside && !wasInside { return false }
                if i == anchor && abs(projected - speed) > 0.001 { movesAnchor = true }
            }
        }
        return movesAnchor
    }

    // MARK: - Engine readings

    /// Band-attainment flags, in order, for completed efforts that can be
    /// fairly judged: planned and actually run ≥60s, with HR data present.
    private func gradeableEffortFlags(engine: WorkoutEngine) -> [Bool] {
        var flags: [Bool] = []
        for (i, phase) in engine.plan.phases.enumerated()
        where i < engine.phaseIndex
            && phase.kind == .work
            && phase.seconds >= SessionObjectives.minGradeableEffortSeconds
            && i < engine.workPhaseHadHR.count && engine.workPhaseHadHR[i]
            && i < engine.actualSeconds.count
            && engine.actualSeconds[i] >= SessionObjectives.minGradeableEffortSeconds {
            flags.append(engine.workPhaseHitBand[i])
        }
        return flags
    }

    /// First not-yet-finished work phase long enough for a target change to
    /// matter. nil (no remaining effort) blocks every effort-scoped rule.
    private func nextEffortIndex(engine: WorkoutEngine) -> Int? {
        for i in engine.phaseIndex..<engine.plan.phases.count
        where engine.plan.phases[i].kind == .work
            && engine.plan.phases[i].seconds >= SessionObjectives.minGradeableEffortSeconds {
            return i
        }
        return nil
    }
}
