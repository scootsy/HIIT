import Foundation
import Observation
import UIKit
import AudioToolbox

/// Live-session state machine: drives the phase timer, fires haptic/sound cues
/// (including the early "change coming" warning sized to the machine's lag),
/// aggregates heart-rate samples, and produces the final SessionResult.
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

    private(set) var latestHR: Double? = nil
    private(set) var latestHRDate: Date? = nil
    private(set) var maxObservedHR: Double? = nil
    private(set) var coachMessage: String = ""

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

    init(plan: WorkoutPlan) {
        self.plan = plan
        self.actualSeconds = Array(repeating: 0, count: plan.phases.count)
    }

    // MARK: - Derived state

    var currentPhase: IntervalPhase {
        plan.phases[min(phaseIndex, plan.phases.count - 1)]
    }

    var nextPhase: IntervalPhase? {
        phaseIndex + 1 < plan.phases.count ? plan.phases[phaseIndex + 1] : nil
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
        guard state == .running, let next = nextPhase else { return false }
        return phaseRemaining <= effectiveCueLead && next.target != currentPhase.target
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
        if phaseIndex + 1 >= plan.phases.count {
            finish(early: false)
            return
        }
        phaseIndex += 1
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
    }

    private func updateCoachMessage() {
        guard Date().timeIntervalSince(coachUpdatedAt) > 8 else { return }
        var message = ""
        if let maxHR, let hr = latestHR, let hrDate = latestHRDate,
           Date().timeIntervalSince(hrDate) < 25 {
            let pct = hr / maxHR * 100
            switch currentPhase.kind {
            case .work:
                if let hi = currentPhase.target.hrPercentHigh, pct > hi + 3 {
                    message = "Ease off a touch — heart rate is above target"
                } else if let lo = currentPhase.target.hrPercentLow, pct < lo - 6, phaseElapsed > 20 {
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
            records.append(PhaseRecord(
                kind: phase.kind.rawValue,
                label: phase.label,
                plannedSeconds: phase.seconds,
                actualSeconds: actualSeconds[i],
                speedMph: phase.target.speedMph,
                inclinePercent: phase.target.inclinePercent,
                resistance: phase.target.resistance))
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
            estimatedCalories: estimate.kcal,
            estimatedDistanceMeters: estimate.meters,
            endedEarly: endedEarly)
    }
}
