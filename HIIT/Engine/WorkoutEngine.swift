import Foundation
import Observation
import UIKit
import AudioToolbox

/// Live-session state machine: drives the phase timer, fires haptic/sound cues,
/// aggregates heart-rate samples, supports mid-workout target overrides, and
/// produces the final SessionResult.
///
/// Cue design: only *harder* upcoming targets get the amber warning and its
/// countdown (low beeps at the lead mark, 10, 6, 3, 2, 1 — then a high GO),
/// because that's when the machine needs ramp time. Slow-downs get no warning
/// at all — braking early just cuts the effort short — but a finishing work
/// phase counts itself out with the same beeps and a distinct "done" tone.
///
/// Beep timing: countdown tones are pre-scheduled a fraction of a second ahead
/// on the audio engine's own clock (compensating for tick granularity and the
/// output route's latency) so they land exactly as the on-screen number ticks
/// over. Haptics fire from the timer tick that crosses the same boundary.
@Observable
final class WorkoutEngine {

    enum State { case ready, running, paused, finished }

    let plan: WorkoutPlan
    private(set) var state: State = .ready
    private(set) var phaseIndex = 0
    private(set) var phaseElapsed: Double = 0
    private(set) var startDate = Date()
    private(set) var endDate = Date()
    private(set) var endedEarly = false
    /// True after the plan's last phase finishes: the workout keeps running
    /// (timer counts up, heart rate keeps logging) until the user ends it.
    private(set) var inOvertime = false

    var soundOn = true
    var hapticsOn = true
    var maxHR: Double? = nil
    var machine: MachineProfile

    private(set) var latestHR: Double? = nil
    private(set) var latestHRDate: Date? = nil
    private(set) var maxObservedHR: Double? = nil
    private(set) var coachMessage: String = ""
    private(set) var hrRecovery: Double? = nil
    /// Every reading from any source (~1 per 2s), for the live workout graph.
    private(set) var hrHistory: [HRSample] = []

    /// The targets actually in play. Starts as a copy of the plan; mid-workout
    /// overrides mutate the current phase and every later phase of the same kind.
    private(set) var appliedTargets: [PhaseTarget]

    private var timer: Timer? = nil
    private var phaseStart = Date()
    private var pauseBegan: Date? = nil
    /// Read by the live kcal/distance estimate so skipped phases count correctly.
    private(set) var actualSeconds: [Double]
    private var lastBeepSecond = -1
    /// Marks whose tone has been handed to the audio engine this phase.
    private var scheduledBeeps: Set<Int> = []
    /// Marks whose scheduling failed — play the system-sound fallback instead.
    private var fallbackBeeps: Set<Int> = []
    /// True once this phase's GO/done tone is queued on the audio clock.
    private var endToneScheduled = false
    /// How far ahead a tick may pre-schedule audio; just over one tick interval.
    private let audioLookahead = 0.15
    private var hrSum = 0.0
    private var hrCount = 0.0
    private var workHRSum = 0.0
    private var workHRCount = 0.0
    private var coachUpdatedAt = Date.distantPast
    private var recoveryAnchor: (time: Date, hr: Double)? = nil
    private var storedHRSamples: [HRSample] = []

    init(plan: WorkoutPlan) {
        self.plan = plan
        self.machine = .defaults(for: plan.equipment)
        self.actualSeconds = Array(repeating: 0, count: plan.phases.count)
        self.appliedTargets = plan.phases.map { $0.target }
    }

    // MARK: - Derived state

    var currentPhase: IntervalPhase {
        plan.phases[min(phaseIndex, plan.phases.count - 1)]
    }

    var nextPhase: IntervalPhase? {
        phaseIndex + 1 < plan.phases.count ? plan.phases[phaseIndex + 1] : nil
    }

    var currentTarget: PhaseTarget {
        appliedTargets[min(phaseIndex, appliedTargets.count - 1)]
    }

    var nextTarget: PhaseTarget? {
        phaseIndex + 1 < appliedTargets.count ? appliedTargets[phaseIndex + 1] : nil
    }

    /// True when the user has nudged the current phase away from the plan.
    var currentTargetAdjusted: Bool {
        currentTarget != currentPhase.target
    }

    var phaseRemaining: Double { max(0, currentPhase.seconds - phaseElapsed) }

    var phaseProgress: Double {
        currentPhase.seconds > 0 ? min(1, phaseElapsed / currentPhase.seconds) : 1
    }

    var totalElapsed: Double {
        var t = inOvertime ? phaseElapsed : min(phaseElapsed, currentPhase.seconds)
        for i in 0..<phaseIndex { t += actualSeconds[i] }
        return t
    }

    var overtimeSeconds: Double {
        inOvertime ? max(0, phaseElapsed - currentPhase.seconds) : 0
    }

    /// "4 of 9" — work efforts fully behind you, visible during recoveries too.
    var workEffortsDone: Int {
        var count = 0
        for i in 0..<min(phaseIndex, plan.phases.count) where plan.phases[i].kind == .work {
            count += 1
        }
        if inOvertime && currentPhase.kind == .work { count += 1 }
        return count
    }

    var totalRemaining: Double {
        var t = phaseRemaining
        if phaseIndex + 1 < plan.phases.count {
            for i in (phaseIndex + 1)..<plan.phases.count {
                t += plan.phases[i].seconds
            }
        }
        return t
    }

    /// Warnings can't be longer than half the phase or they'd flash constantly.
    var effectiveCueLead: Double {
        min(Double(plan.cueLeadSeconds), currentPhase.seconds / 2)
    }

    /// A change is "harder" when any axis steps up. Only those need machine
    /// lead time — easing off can happen after the effort ends, so warning
    /// about a slow-down would just invite cutting the effort short.
    private func isHarder(_ next: PhaseTarget, than current: PhaseTarget) -> Bool {
        if let a = next.speedMph, let b = current.speedMph, a > b + 0.01 { return true }
        if let a = next.inclinePercent, let b = current.inclinePercent, a > b + 0.01 { return true }
        if let a = next.resistance, let b = current.resistance, a > b { return true }
        return false
    }

    /// True when a *harder* target is imminent — the UI turns amber so the
    /// user can start ramping the machine before the phase actually flips.
    var isWarning: Bool {
        guard state == .running, !inOvertime, let next = nextTarget else { return false }
        return phaseRemaining <= effectiveCueLead && isHarder(next, than: currentTarget)
    }

    // MARK: - Countdown cues

    /// How the current phase should end: counting down into a harder target
    /// (ramp the machine, then GO), counting an effort out (push to the line,
    /// then ease off — no early warning, no amber), or quietly.
    private enum PhaseEndCue { case rampUp, effortDone, none }

    private var phaseEndCue: PhaseEndCue {
        guard !inOvertime else { return .none }
        if let next = nextTarget, isHarder(next, than: currentTarget) { return .rampUp }
        if currentPhase.kind == .work { return .effortDone }
        return .none
    }

    /// Seconds-remaining marks that get a low beep: lead, 10, 6, 3, 2, 1 —
    /// low-low-low, then the phase change lands the high GO (or done) tone.
    private var beepSchedule: [Int] {
        let lead: Double
        switch phaseEndCue {
        case .rampUp: lead = effectiveCueLead
        case .effortDone: lead = min(10, currentPhase.seconds / 2)
        case .none: return []
        }
        var marks = [10, 6, 3, 2, 1].filter { Double($0) <= lead }
        let leadMark = Int(lead.rounded())
        if leadMark > 3 && !marks.contains(leadMark) {
            marks.insert(leadMark, at: 0)
        }
        return marks
    }

    // MARK: - Mid-workout overrides

    /// "It said 5.0 but I'm running 5.5": bump speed by 0.1 mph (or resistance
    /// by 1 level) for this phase and every remaining phase of the same kind,
    /// clamped to the machine. Records, calories, distance, and next-session
    /// progression all follow the adjusted numbers.
    func adjustCurrentTarget(up: Bool) {
        adjustTarget(phaseAt: phaseIndex, up: up)
    }

    /// Also callable for a *completed* phase ("that sprint was actually 5.5"):
    /// corrects that phase's record and recalibrates every not-yet-run phase
    /// of the same kind. Other already-finished phases keep what they were.
    func adjustTarget(phaseAt index: Int, up: Bool) {
        guard state == .running || state == .paused else { return }
        guard plan.phases.indices.contains(index) else { return }
        let kind = plan.phases[index].kind
        for i in plan.phases.indices where plan.phases[i].kind == kind && (i == index || i >= phaseIndex) {
            if plan.equipment == .bike {
                if let resistance = appliedTargets[i].resistance {
                    let step = up ? 1 : -1
                    appliedTargets[i].resistance = max(1, min(machine.maxResistance, resistance + step))
                }
            } else if let speed = appliedTargets[i].speedMph {
                let step = up ? 0.1 : -0.1
                let adjusted = ((speed + step) * 10).rounded() / 10
                appliedTargets[i].speedMph = max(0.5, min(machine.maxSpeedMph, adjusted))
            }
        }
        if hapticsOn {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: - Control

    func start() {
        guard state == .ready else { return }
        state = .running
        startDate = Date()
        phaseStart = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        if soundOn { TonePlayer.shared.prepare() }
        cue(.phaseChange)
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        guard state == .running else { return }
        state = .paused
        pauseBegan = Date()
    }

    func resume() {
        guard state == .paused, let began = pauseBegan else { return }
        phaseStart = phaseStart.addingTimeInterval(Date().timeIntervalSince(began))
        pauseBegan = nil
        state = .running
    }

    func skip() {
        guard state == .running else { return }
        advance(auto: false, overshoot: 0)
    }

    func endWorkout() {
        guard state == .running || state == .paused else { return }
        // Overtime counts as real training time at the final phase's targets.
        actualSeconds[phaseIndex] = inOvertime ? phaseElapsed : min(phaseElapsed, currentPhase.seconds)
        finish(early: !inOvertime && phaseIndex < plan.phases.count - 1)
    }

    // MARK: - Timer

    private func tick() {
        guard state == .running else { return }
        phaseElapsed = Date().timeIntervalSince(phaseStart)
        let remaining = currentPhase.seconds - phaseElapsed

        if remaining > 0 && !inOvertime {
            let schedule = beepSchedule
            // Hand each countdown tone to the audio clock just before its
            // boundary so it plays exactly as the displayed second flips.
            if soundOn {
                for mark in schedule where !scheduledBeeps.contains(mark) {
                    let untilMark = remaining - Double(mark)
                    if untilMark <= audioLookahead {
                        scheduledBeeps.insert(mark)
                        if !TonePlayer.shared.play(.low, after: max(0, untilMark)) {
                            fallbackBeeps.insert(mark)
                        }
                    }
                }
                // Same for the phase-end tone (GO into a harder phase, or the
                // "done" tone that ends a counted-out effort).
                if !endToneScheduled, remaining <= audioLookahead {
                    let tone: TonePlayer.Tone?
                    switch phaseEndCue {
                    case .rampUp: tone = .high
                    case .effortDone: tone = .done
                    case .none: tone = nil
                    }
                    if let tone {
                        endToneScheduled = TonePlayer.shared.play(tone, after: max(0, remaining))
                    }
                }
            }
            // Haptics (and the system-sound fallback) fire on the tick that
            // crosses the mark — in step with the on-screen countdown.
            let s = Int(remaining.rounded(.up))
            if s != lastBeepSecond && schedule.contains(s) {
                lastBeepSecond = s
                if hapticsOn {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                if soundOn && fallbackBeeps.contains(s) {
                    fallbackBeeps.remove(s)
                    AudioServicesPlaySystemSound(1103)
                }
            }
        }
        if remaining <= 0 && !inOvertime {
            if phaseIndex + 1 < plan.phases.count {
                advance(auto: true, overshoot: -remaining)
            } else {
                // Plan complete — chime, but never end on the user's behalf.
                inOvertime = true
                cue(.finish)
            }
        }
        updateCoachMessage()
    }

    private func advance(auto: Bool, overshoot: Double) {
        actualSeconds[phaseIndex] = auto ? currentPhase.seconds : min(phaseElapsed, currentPhase.seconds)
        lastBeepSecond = -1
        scheduledBeeps.removeAll()
        fallbackBeeps.removeAll()
        let endToneAlreadyPlayed = endToneScheduled
        endToneScheduled = false
        let leavingKind = currentPhase.kind
        let endCue = phaseEndCue
        if phaseIndex + 1 >= plan.phases.count {
            // Manual skip on the final phase: straight to overtime, not out.
            inOvertime = true
            cue(.finish)
            return
        }
        phaseIndex += 1
        // A new work phase closes any pending heart-rate-recovery window —
        // samples from here on would measure the new effort, not the drop.
        if currentPhase.kind == .work {
            recoveryAnchor = nil
        } else if leavingKind == .work,
                  let hr = latestHR, let hrDate = latestHRDate,
                  Date().timeIntervalSince(hrDate) < 15 {
            // Leaving a hard effort with fresh HR data: anchor a 1-minute
            // heart-rate-recovery measurement (a well-studied fitness marker).
            recoveryAnchor = (Date(), hr)
        }
        // If the app was suspended (screen locked, another app foregrounded)
        // the timer stopped firing and the overshoot can span whole phases.
        // Walk the wall-clock gap through the plan so no time is lost: each
        // fully-covered phase is credited at its planned duration and the
        // workout lands mid-phase exactly where the clock says it should.
        var carry = auto ? max(0, overshoot) : 0
        var walkedPhases = false
        while carry >= currentPhase.seconds {
            actualSeconds[phaseIndex] = currentPhase.seconds
            carry -= currentPhase.seconds
            walkedPhases = true
            recoveryAnchor = nil
            if phaseIndex + 1 >= plan.phases.count {
                // The gap ran past the end of the plan — straight to overtime,
                // with the leftover carry counted as overtime seconds.
                inOvertime = true
                phaseStart = Date().addingTimeInterval(-(currentPhase.seconds + carry))
                phaseElapsed = currentPhase.seconds + carry
                cue(.finish)
                return
            }
            phaseIndex += 1
        }
        phaseStart = Date().addingTimeInterval(-carry)
        phaseElapsed = carry
        if walkedPhases {
            // Catching up after a suspension: one neutral cue, not a replay
            // of every skipped transition.
            cue(.phaseChange)
            return
        }
        switch endCue {
        case .rampUp: cue(.go, skipSound: endToneAlreadyPlayed)
        case .effortDone: cue(.done, skipSound: endToneAlreadyPlayed)
        case .none: cue(.phaseChange)
        }
    }

    private func finish(early: Bool) {
        endedEarly = early
        endDate = Date()
        state = .finished
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        cue(.finish)
        // Give the fanfare a moment to sound before releasing the session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            TonePlayer.shared.deactivate()
        }
    }

    // MARK: - Heart rate

    func recordHeartRate(_ bpm: Double, at date: Date, fromBLE: Bool = false) {
        latestHR = bpm
        latestHRDate = date
        guard state == .running else { return }
        if let last = hrHistory.last {
            if date.timeIntervalSince(last.date) >= 2 {
                hrHistory.append(HRSample(date: date, bpm: bpm))
            }
        } else {
            hrHistory.append(HRSample(date: date, bpm: bpm))
        }
        // Keep strap readings (≈1 per 5s) so the workout saved to Health
        // carries a real heart-rate trace; Health-sourced readings are
        // already in Health and would only duplicate.
        if fromBLE {
            if let last = storedHRSamples.last {
                if date.timeIntervalSince(last.date) >= 4.5 {
                    storedHRSamples.append(HRSample(date: date, bpm: bpm))
                }
            } else {
                storedHRSamples.append(HRSample(date: date, bpm: bpm))
            }
        }
        hrSum += bpm
        hrCount += 1
        maxObservedHR = max(maxObservedHR ?? 0, bpm)
        if currentPhase.kind == .work {
            workHRSum += bpm
            workHRCount += 1
        }
        if let anchor = recoveryAnchor {
            let dt = date.timeIntervalSince(anchor.time)
            if dt >= 55 && dt <= 80 {
                let drop = anchor.hr - bpm
                if drop > 0 { hrRecovery = drop }
                recoveryAnchor = nil
            } else if dt > 80 {
                recoveryAnchor = nil
            }
        }
    }

    private func updateCoachMessage() {
        guard Date().timeIntervalSince(coachUpdatedAt) > 8 else { return }
        var message = ""
        if let maxHR, let hr = latestHR, let hrDate = latestHRDate,
           Date().timeIntervalSince(hrDate) < 25 {
            let pct = hr / maxHR * 100
            switch currentPhase.kind {
            case .work:
                if let hi = currentTarget.hrPercentHigh, pct > hi + 3 {
                    message = "Ease off a touch — heart rate is above target"
                } else if let lo = currentTarget.hrPercentLow, pct < lo - 6, phaseElapsed > 20 {
                    message = "You've got headroom — push a little harder"
                } else {
                    message = "Right in the zone — hold this"
                }
            case .recover, .cooldown:
                if pct > 80 {
                    message = "Slow right down and let your heart rate fall"
                }
            default:
                break
            }
        }
        if message != coachMessage {
            coachMessage = message
            coachUpdatedAt = Date()
        }
    }

    // MARK: - Cues

    private enum Cue { case tick, go, done, phaseChange, finish }

    /// Plays the haptic and, unless the tone was already pre-scheduled on the
    /// audio clock, the matching sound (with a system-sound fallback).
    private func cue(_ kind: Cue, skipSound: Bool = false) {
        if hapticsOn {
            switch kind {
            case .tick:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .go:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .phaseChange:
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case .done, .finish:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        if soundOn && !skipSound {
            let tone: TonePlayer.Tone
            switch kind {
            case .tick, .phaseChange: tone = .low
            case .go: tone = .high
            case .done: tone = .done
            case .finish: tone = .fanfare
            }
            if !TonePlayer.shared.play(tone) {
                // Engine unavailable — at least try the old system sounds.
                AudioServicesPlaySystemSound(kind == .tick ? 1103 : 1104)
            }
        }
    }

    // MARK: - Result

    func makeResult(machine: MachineProfile, weightKg: Double?) -> SessionResult {
        Self.buildResult(
            plan: plan,
            startDate: startDate,
            endDate: endDate,
            appliedTargets: appliedTargets,
            actualSeconds: actualSeconds,
            machine: machine,
            weightKg: weightKg,
            avgHeartRate: hrCount > 0 ? hrSum / hrCount : nil,
            maxHeartRate: maxObservedHR,
            avgWorkHeartRate: workHRCount > 0 ? workHRSum / workHRCount : nil,
            hrRecovery: hrRecovery,
            heartRateSamples: storedHRSamples,
            endedEarly: endedEarly)
    }

    /// Snapshot of everything needed to rebuild a saveable result — written
    /// to disk during the session so a crash or jetsam can't lose the workout.
    func makeCheckpoint() -> WorkoutCheckpoint {
        var actuals = actualSeconds
        if state != .finished, plan.phases.indices.contains(phaseIndex) {
            actuals[phaseIndex] = inOvertime ? phaseElapsed : min(phaseElapsed, currentPhase.seconds)
        }
        return WorkoutCheckpoint(
            plan: plan,
            startDate: startDate,
            savedAt: Date(),
            appliedTargets: appliedTargets,
            actualSeconds: actuals,
            avgHeartRate: hrCount > 0 ? hrSum / hrCount : nil,
            maxHeartRate: maxObservedHR,
            avgWorkHeartRate: workHRCount > 0 ? workHRSum / workHRCount : nil,
            hrRecovery: hrRecovery,
            heartRateSamples: storedHRSamples)
    }

    /// Assembles a SessionResult from raw session state — shared between the
    /// live engine and checkpoint recovery so both produce identical math.
    static func buildResult(plan: WorkoutPlan,
                            startDate: Date,
                            endDate: Date,
                            appliedTargets: [PhaseTarget],
                            actualSeconds: [Double],
                            machine: MachineProfile,
                            weightKg: Double?,
                            avgHeartRate: Double?,
                            maxHeartRate: Double?,
                            avgWorkHeartRate: Double?,
                            hrRecovery: Double?,
                            heartRateSamples: [HRSample],
                            endedEarly: Bool) -> SessionResult {
        var records: [PhaseRecord] = []
        for (i, phase) in plan.phases.enumerated() {
            let target = i < appliedTargets.count ? appliedTargets[i] : phase.target
            records.append(PhaseRecord(
                kind: phase.kind.rawValue,
                label: phase.label,
                plannedSeconds: phase.seconds,
                actualSeconds: i < actualSeconds.count ? actualSeconds[i] : 0,
                speedMph: target.speedMph,
                inclinePercent: target.inclinePercent,
                resistance: target.resistance))
        }
        let estimate = MetabolicMath.estimate(records: records, equipment: plan.equipment, machine: machine, weightKg: weightKg)

        var completedWork = 0
        var workSecs = 0.0
        var total = 0.0
        for (i, phase) in plan.phases.enumerated() {
            let actual = records[i].actualSeconds
            total += actual
            if phase.kind == .work {
                workSecs += actual
                if actual >= phase.seconds * 0.9 { completedWork += 1 }
            }
        }

        // Express any manual override in "progression levels" so the next
        // session starts where the user actually trained. The generator adds
        // 0.2 mph (or 1.5% of max resistance) per level.
        var overrideSum = 0.0
        var overrideCount = 0.0
        for (i, phase) in plan.phases.enumerated() where phase.kind == .work && i < appliedTargets.count {
            if plan.equipment == .bike {
                if let applied = appliedTargets[i].resistance, let planned = phase.target.resistance {
                    overrideSum += Double(applied - planned)
                    overrideCount += 1
                }
            } else if let applied = appliedTargets[i].speedMph, let planned = phase.target.speedMph {
                overrideSum += applied - planned
                overrideCount += 1
            }
        }
        let overrideAvg = overrideCount > 0 ? overrideSum / overrideCount : 0
        let overrideLevels: Double
        if plan.equipment == .bike {
            // One generator level is worth 0.015 × maxResistance resistance
            // units, so divide by that step (floored well below one unit —
            // flooring at 1.0 silently swallowed overrides on every bike with
            // 32 levels or fewer). ProgressionEngine clamps the credit to ±2.
            overrideLevels = overrideAvg / max(0.12, 0.015 * Double(machine.maxResistance))
        } else {
            overrideLevels = overrideAvg / 0.2
        }

        return SessionResult(
            plan: plan,
            startDate: startDate,
            endDate: endDate,
            records: records,
            completedWorkIntervals: completedWork,
            workSeconds: workSecs,
            totalSeconds: total,
            avgHeartRate: avgHeartRate,
            maxHeartRate: maxHeartRate,
            avgWorkHeartRate: avgWorkHeartRate,
            hrRecovery: hrRecovery,
            workOverrideLevels: overrideLevels,
            heartRateSamples: heartRateSamples,
            estimatedCalories: estimate.kcal,
            estimatedDistanceMeters: estimate.meters,
            endedEarly: endedEarly)
    }
}
