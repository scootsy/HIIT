import Foundation
import Observation
import UIKit
import AudioToolbox

/// Live-session state machine: drives the phase timer, fires haptic/sound cues
/// (including the early "change coming" warning sized to the machine's lag),
/// aggregates heart-rate samples, supports mid-workout target overrides, and
/// produces the final SessionResult.
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

    var soundOn = true
    var hapticsOn = true
    var maxHR: Double? = nil
    var machine: MachineProfile

    private(set) var latestHR: Double? = nil
    private(set) var latestHRDate: Date? = nil
    private(set) var maxObservedHR: Double? = nil
    private(set) var coachMessage: String = ""
    private(set) var hrRecovery: Double? = nil

    /// The targets actually in play. Starts as a copy of the plan; mid-workout
    /// overrides mutate the current phase and every later phase of the same kind.
    private(set) var appliedTargets: [PhaseTarget]

    private var timer: Timer? = nil
    private var phaseStart = Date()
    private var pauseBegan: Date? = nil
    private var actualSeconds: [Double]
    private var lastBeepSecond = -1
    private var hrSum = 0.0
    private var hrCount = 0.0
    private var workHRSum = 0.0
    private var workHRCount = 0.0
    private var coachUpdatedAt = Date.distantPast
    private var recoveryAnchor: (time: Date, hr: Double)? = nil

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
        var t = min(phaseElapsed, currentPhase.seconds)
        for i in 0..<phaseIndex { t += actualSeconds[i] }
        return t
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

    /// True when a target change is imminent — the UI turns amber so the user
    /// can start adjusting the machine before the phase actually flips.
    var isWarning: Bool {
        guard state == .running, let next = nextTarget else { return false }
        return phaseRemaining <= effectiveCueLead && next != currentTarget
    }

    // MARK: - Mid-workout overrides

    /// "It said 5.0 but I'm running 5.5": bump speed by 0.1 mph (or resistance
    /// by 1 level) for this phase and every remaining phase of the same kind,
    /// clamped to the machine. Records, calories, distance, and next-session
    /// progression all follow the adjusted numbers.
    func adjustCurrentTarget(up: Bool) {
        guard state == .running || state == .paused else { return }
        let kind = currentPhase.kind
        if plan.equipment == .bike {
            let step = up ? 1 : -1
            for i in phaseIndex..<plan.phases.count where plan.phases[i].kind == kind {
                if let resistance = appliedTargets[i].resistance {
                    appliedTargets[i].resistance = max(1, min(machine.maxResistance, resistance + step))
                }
            }
        } else {
            let step = up ? 0.1 : -0.1
            for i in phaseIndex..<plan.phases.count where plan.phases[i].kind == kind {
                if let speed = appliedTargets[i].speedMph {
                    let adjusted = ((speed + step) * 10).rounded() / 10
                    appliedTargets[i].speedMph = max(0.5, min(machine.maxSpeedMph, adjusted))
                }
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
        actualSeconds[phaseIndex] = min(phaseElapsed, currentPhase.seconds)
        finish(early: phaseIndex < plan.phases.count - 1)
    }

    // MARK: - Timer

    private func tick() {
        guard state == .running else { return }
        phaseElapsed = Date().timeIntervalSince(phaseStart)
        let remaining = currentPhase.seconds - phaseElapsed

        if remaining <= 3.2 && nextPhase != nil {
            let s = Int(remaining.rounded(.up))
            if s != lastBeepSecond && s >= 1 && s <= 3 {
                lastBeepSecond = s
                cue(.tick)
            }
        }
        if remaining <= 0 {
            advance(auto: true, overshoot: -remaining)
        }
        updateCoachMessage()
    }

    private func advance(auto: Bool, overshoot: Double) {
        actualSeconds[phaseIndex] = auto ? currentPhase.seconds : min(phaseElapsed, currentPhase.seconds)
        lastBeepSecond = -1
        let leavingKind = currentPhase.kind
        if phaseIndex + 1 >= plan.phases.count {
            finish(early: false)
            return
        }
        phaseIndex += 1
        // Leaving a hard effort with fresh HR data: anchor a 1-minute
        // heart-rate-recovery measurement (a well-studied fitness marker).
        if leavingKind == .work && currentPhase.kind != .work,
           let hr = latestHR, let hrDate = latestHRDate,
           Date().timeIntervalSince(hrDate) < 15 {
            recoveryAnchor = (Date(), hr)
        }
        let carry = max(0, min(overshoot, 1))
        phaseStart = Date().addingTimeInterval(-carry)
        phaseElapsed = carry
        cue(currentPhase.kind == .work ? .workStart : .phaseChange)
    }

    private func finish(early: Bool) {
        endedEarly = early
        endDate = Date()
        state = .finished
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        cue(.finish)
    }

    // MARK: - Heart rate

    func recordHeartRate(_ bpm: Double, at date: Date) {
        latestHR = bpm
        latestHRDate = date
        guard state == .running else { return }
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

    private enum Cue { case tick, workStart, phaseChange, finish }

    private func cue(_ kind: Cue) {
        if hapticsOn {
            switch kind {
            case .tick:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .workStart:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .phaseChange:
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case .finish:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        if soundOn {
            switch kind {
            case .tick:
                AudioServicesPlaySystemSound(1103)
            case .workStart, .phaseChange:
                AudioServicesPlaySystemSound(1104)
            case .finish:
                AudioServicesPlaySystemSound(1025)
            }
        }
    }

    // MARK: - Result

    func makeResult(machine: MachineProfile, weightKg: Double?) -> SessionResult {
        var records: [PhaseRecord] = []
        for (i, phase) in plan.phases.enumerated() {
            let target = appliedTargets[i]
            records.append(PhaseRecord(
                kind: phase.kind.rawValue,
                label: phase.label,
                plannedSeconds: phase.seconds,
                actualSeconds: actualSeconds[i],
                speedMph: target.speedMph,
                inclinePercent: target.inclinePercent,
                resistance: target.resistance))
        }
        let estimate = MetabolicMath.estimate(records: records, equipment: plan.equipment, machine: machine, weightKg: weightKg)

        var completedWork = 0
        var workSecs = 0.0
        var total = 0.0
        for (i, phase) in plan.phases.enumerated() {
            total += actualSeconds[i]
            if phase.kind == .work {
                workSecs += actualSeconds[i]
                if actualSeconds[i] >= phase.seconds * 0.9 { completedWork += 1 }
            }
        }

        // Express any manual override in "progression levels" so the next
        // session starts where the user actually trained. The generator adds
        // 0.2 mph (or ~1.5% of max resistance) per level.
        var overrideSum = 0.0
        var overrideCount = 0.0
        for (i, phase) in plan.phases.enumerated() where phase.kind == .work {
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
            overrideLevels = overrideAvg / max(1.0, 0.015 * Double(machine.maxResistance))
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
            avgHeartRate: hrCount > 0 ? hrSum / hrCount : nil,
            maxHeartRate: maxObservedHR,
            avgWorkHeartRate: workHRCount > 0 ? workHRSum / workHRCount : nil,
            hrRecovery: hrRecovery,
            workOverrideLevels: overrideLevels,
            estimatedCalories: estimate.kcal,
            estimatedDistanceMeters: estimate.meters,
            endedEarly: endedEarly)
    }
}
