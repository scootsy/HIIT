import Foundation

/// Turns a finished session's live heart-rate data into a plain-language
/// answer to "did this workout do what HIIT is supposed to do?".
///
/// The grading rules follow how training studies define compliant execution:
/// - **High-intensity dose** — time at/above the session's work-band floor
///   (~7–10 minutes is the per-session target in longer sessions; 60% of
///   the prescribed work time in shorter ones). This, not average HR, is
///   the accepted per-session effectiveness criterion.
/// - **Interval attainment** — an interval ≥60s counts as achieved when HR
///   *enters* the band at any point before it ends; heart rate lags effort
///   by 20–50s, so grading averages would fail every honest ramp. Bouts
///   under 60s are never graded individually — a maximal 20s sprint can
///   end before HR reacts at all.
/// - **Long-recovery quality** — only recoveries ≥120s (the 4×4's) are
///   graded, against reaching ≤75% of max HR; shorter recoveries cannot
///   physiologically show a drop, so they are left alone.
/// - **1-minute heart-rate recovery** — the drop after the final hard
///   effort; <12 bpm is the validated clinical flag (Cole 1999), ≥25
///   tracks with good aerobic fitness.
enum SessionObjectives {

    // Thresholds shared with the engine's zone accounting and the live
    // coach's trigger rules, so live nudges and these grades can't drift.

    /// Points of tolerance under every band floor — the bands sit on an
    /// *estimated* max HR (age formulas carry ~7–11 bpm of individual error).
    static let bandTolerancePct = 2.0
    /// Bouts under a minute are never judged on HR — a maximal 20s sprint
    /// can end before heart rate reacts at all.
    static let minGradeableEffortSeconds = 60.0
    /// HR must cover this share of the prescribed work before the intensity
    /// dose is graded — a strap dropout must not read as "under the zone".
    static let hrCoverageFraction = 0.8
    /// Long-recovery low point, as %maxHR: real reset vs "didn't come down".
    static let recoveryMetPct = 75.0
    static let recoveryPartialPct = 80.0
    /// 1-minute heart-rate recovery: ≥25 tracks with good aerobic fitness,
    /// <12 is the validated clinical flag (Cole 1999).
    static let hrrGoodBPM = 25.0
    static let hrrFlagBPM = 12.0

    /// Raw values are persisted inside WorkoutSession.objectivesData —
    /// renaming a case would silently blank every stored session's grades.
    enum Verdict: String, Codable {
        case met = "met"
        case partial = "partial"
        case missed = "missed"
    }

    /// Codable so the grades persist with the saved session — the history
    /// detail replays the exact card the post-workout summary showed.
    struct Line: Codable, Equatable {
        /// nil = informational only (e.g. an easy day has no intensity target).
        var verdict: Verdict?
        var title: String
        var detail: String

        /// The JSON in objectivesData is a persistence contract: these keys
        /// must stay stable even if the properties are renamed, or old
        /// sessions' cards vanish (decode falls back to empty).
        private enum CodingKeys: String, CodingKey {
            case verdict, title, detail
        }
    }

    static func evaluate(engine: WorkoutEngine) -> [Line]? {
        guard let maxHR = engine.maxHR, maxHR > 0, engine.maxObservedHR != nil else { return nil }
        var lines: [Line] = []

        let easyDay = engine.plan.vibe == .easy || engine.plan.isDeload == true
        let workPhases = engine.plan.phases.filter { $0.kind == .work }
        let prescribedWork = workPhases.reduce(0) { $0 + $1.seconds }
        let floor = Int(engine.dosePctFloor)

        // 1. High-intensity dose
        if engine.workHRSeconds >= 60 || engine.sessionSecondsAtFloor > 0 {
            let dose = engine.sessionSecondsAtFloor
            let doseText = "\(clockString(dose)) at ≥\(floor)% of max heart rate"
            if easyDay {
                lines.append(Line(verdict: nil,
                                  title: doseText,
                                  detail: "An easy day on purpose — no intensity target today."))
            } else if prescribedWork > 0, engine.workHRSeconds < hrCoverageFraction * prescribedWork {
                // A strap dropout must not read as "under the zone": grade
                // the dose only when HR actually covered most of the work.
                lines.append(Line(verdict: nil,
                                  title: doseText,
                                  detail: "Heart rate was only measured for part of the session, so the intensity dose can't be graded today."))
            } else if prescribedWork > 0 {
                // ~7–10 min in zone is the target for full-size sessions;
                // shorter sessions are graded pro-rata at 60% of prescribed
                // work (the 4×4 expects most of its work time in zone).
                let norwegianLike = (workPhases.first?.target.hrPercentLow ?? 0) >= 90
                let threshold = norwegianLike
                    ? min(600, 0.75 * prescribedWork)
                    : (prescribedWork >= 600 ? 420 : 0.6 * prescribedWork)
                let verdict: Verdict = dose >= threshold ? .met : (dose >= threshold / 2 ? .partial : .missed)
                let detail: String
                switch verdict {
                case .met: detail = "A full dose of the high-intensity stimulus this session was built for."
                case .partial: detail = "Some time in the zone — arriving at each effort's target a little sooner would earn more."
                case .missed: detail = "Heart rate stayed under the zone — the targets may be set too easy for you now."
                }
                lines.append(Line(verdict: verdict, title: doseText, detail: detail))
            }
        }

        // 2. Per-interval attainment (long intervals only)
        var gradeable = 0
        var achieved = 0
        for (index, phase) in engine.plan.phases.enumerated()
        where phase.kind == .work && phase.seconds >= minGradeableEffortSeconds && index < engine.workPhaseHadHR.count && engine.workPhaseHadHR[index] {
            gradeable += 1
            if engine.workPhaseHitBand[index] { achieved += 1 }
        }
        if !easyDay, gradeable >= 2 {
            let fraction = Double(achieved) / Double(gradeable)
            let verdict: Verdict = fraction >= 0.75 ? .met : (fraction >= 0.5 ? .partial : .missed)
            let detail: String
            switch verdict {
            case .met: detail = "Nearly every effort reached its target zone — exactly as prescribed."
            case .partial: detail = "Some efforts stopped short of the zone — hold each one a touch harder or longer."
            case .missed: detail = "Most efforts never reached the zone — next session's targets may need a nudge up."
            }
            lines.append(Line(verdict: verdict,
                              title: "\(achieved) of \(gradeable) efforts reached the target zone",
                              detail: detail))
        }

        // 3. Long-recovery quality (≥120s recoveries only)
        if engine.recoveryMinPcts.count >= 1 {
            let avgLow = engine.recoveryMinPcts.reduce(0, +) / Double(engine.recoveryMinPcts.count)
            if avgLow <= recoveryMetPct {
                lines.append(Line(verdict: .met,
                                  title: String(format: "Recoveries reached %.0f%% of max heart rate", avgLow),
                                  detail: "Real recoveries between the long pushes — that's what makes the next one count."))
            } else if avgLow <= recoveryPartialPct {
                lines.append(Line(verdict: .partial,
                                  title: String(format: "Recoveries reached %.0f%% of max heart rate", avgLow),
                                  detail: "Close — easing the recovery pace slightly would buy a fuller reset."))
            } else {
                // Consistent with guidelines rather than a validated
                // threshold — advise, don't fail.
                lines.append(Line(verdict: nil,
                                  title: String(format: "Recoveries stayed near %.0f%% of max heart rate", avgLow),
                                  detail: "Heart rate didn't come down much between pushes — worth easing right off during recoveries."))
            }
        }

        // 4. 1-minute heart-rate recovery after the last hard effort
        if let hrr = engine.hrRecovery {
            let verdict: Verdict = hrr >= hrrGoodBPM ? .met : (hrr >= hrrFlagBPM ? .partial : .missed)
            let detail: String
            switch verdict {
            case .met: detail = "A fast fall-off after the last effort — a strong fitness marker."
            case .partial: detail = "A normal recovery. This number tends to climb as fitness builds."
            case .missed: detail = "Under 12 bpm in a minute is worth mentioning to a doctor if it keeps happening."
            }
            lines.append(Line(verdict: verdict,
                              title: String(format: "−%.0f bpm one minute after the last effort", hrr),
                              detail: detail))
        }

        // 5. Live-coach activity — informational only. Accepted corrections
        // are already baked into the grades above and next session's start.
        if engine.coachSuggestionsOffered > 0 {
            let offered = engine.coachSuggestionsOffered
            let word = offered == 1 ? "suggestion" : "suggestions"
            lines.append(Line(verdict: nil,
                              title: "Live coach: \(engine.coachSuggestionsAccepted) of \(offered) \(word) applied",
                              detail: "Mid-session corrections you approved are already counted in today's grades and next session's targets."))
        }

        return lines.isEmpty ? nil : lines
    }
}
