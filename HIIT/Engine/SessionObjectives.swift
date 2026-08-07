import Foundation

/// Turns a finished session's live heart-rate data into a plain-language
/// answer to "did this workout do what HIIT is supposed to do?".
///
/// The graded objectives, with thresholds kept here so they're easy to tune:
/// - **High-intensity dose** — total time at ≥85% of max HR. Accumulating
///   minutes in this zone is the canonical stimulus HIIT is programmed for
///   (Helgerud-style protocols prescribe 4-minute pushes at 85–95%).
/// - **Work-interval intensity** — share of measured work time at or above
///   the session's target-band floor. Graded only when intervals are long
///   enough (≥45s) for heart rate to actually respond within them.
/// - **Between-interval recovery** — average HR drop achieved during
///   recovery phases. Too small a drop means the recoveries are too short
///   or the recovery pace is too hot to recover at.
/// - **1-minute heart-rate recovery** — the drop after the final hard
///   effort; an established fitness marker (<12 bpm is the clinical flag,
///   ≥25 tracks with good aerobic fitness).
enum SessionObjectives {

    enum Verdict {
        case met, partial, missed
    }

    struct Line: Identifiable {
        let id = UUID()
        /// nil = informational only (e.g. an easy day has no intensity target).
        var verdict: Verdict?
        var title: String
        var detail: String
    }

    static func evaluate(engine: WorkoutEngine) -> [Line]? {
        guard let maxHR = engine.maxHR, maxHR > 0, engine.maxObservedHR != nil else { return nil }
        var lines: [Line] = []

        let easyDay = engine.plan.vibe == .easy || engine.plan.isDeload == true
        let workPhases = engine.plan.phases.filter { $0.kind == .work }
        let typicalWork = workPhases.isEmpty ? 0 :
            workPhases.reduce(0) { $0 + $1.seconds } / Double(workPhases.count)

        // 1. High-intensity dose
        let dose = engine.sessionSecondsAt85
        if dose > 0 || engine.workHRSeconds >= 60 {
            let doseText = clockString(dose)
            if easyDay {
                lines.append(Line(verdict: nil,
                                  title: "\(doseText) at ≥85% of max heart rate",
                                  detail: "An easy day on purpose — no intensity target today."))
            } else if engine.plan.level == .beginner {
                lines.append(Line(verdict: nil,
                                  title: "\(doseText) at ≥85% of max heart rate",
                                  detail: "At your level the target zone starts lower — this number will grow as you progress."))
            } else {
                let verdict: Verdict = dose >= 240 ? .met : (dose >= 90 ? .partial : .missed)
                let detail: String
                switch verdict {
                case .met: detail = "That's a solid dose of the high-intensity stimulus HIIT is built around."
                case .partial: detail = "Some time in the zone — pushing the efforts slightly harder would earn more."
                case .missed: detail = "Heart rate stayed below the high-intensity zone — the efforts may be set too easy."
                }
                lines.append(Line(verdict: verdict,
                                  title: "\(doseText) at ≥85% of max heart rate",
                                  detail: detail))
            }
        }

        // 2. Work-interval intensity (long intervals only — short sprints
        // end before heart rate can catch up, so a per-interval grade
        // would punish exactly the sessions that went hardest)
        if !easyDay, typicalWork >= 45, engine.workHRSeconds >= 120 {
            let fraction = engine.workHRSecondsAtIntensity / engine.workHRSeconds
            let pct = Int((fraction * 100).rounded())
            let verdict: Verdict = fraction >= 0.7 ? .met : (fraction >= 0.4 ? .partial : .missed)
            let detail: String
            switch verdict {
            case .met: detail = "Right where the plan wanted you during the efforts."
            case .partial: detail = "Partly in the zone — hold the target a little longer into each effort."
            case .missed: detail = "Mostly under the target band — next session's targets may need a nudge up, or longer efforts."
            }
            lines.append(Line(verdict: verdict,
                              title: "\(pct)% of work time in the target zone",
                              detail: detail))
        }

        // 3. Between-interval recovery
        if engine.recoveryDrops.count >= 2 {
            let avg = engine.recoveryDrops.reduce(0, +) / Double(engine.recoveryDrops.count)
            let verdict: Verdict = avg >= 15 ? .met : (avg >= 8 ? .partial : .missed)
            let detail: String
            switch verdict {
            case .met: detail = "Real recoveries between efforts — exactly what makes the next effort count."
            case .partial: detail = "Heart rate came down some — slowing the recovery pace would buy more."
            case .missed: detail = "Heart rate barely fell between efforts — ease right off during recoveries."
            }
            lines.append(Line(verdict: verdict,
                              title: String(format: "−%.0f bpm average drop between efforts", avg),
                              detail: detail))
        }

        // 4. 1-minute heart-rate recovery after the last hard effort
        if let hrr = engine.hrRecovery {
            let verdict: Verdict = hrr >= 25 ? .met : (hrr >= 12 ? .partial : .missed)
            let detail: String
            switch verdict {
            case .met: detail = "A fast fall-off after the last effort — a strong fitness marker."
            case .partial: detail = "A normal recovery. This number tends to climb as fitness builds."
            case .missed: detail = "Under 12 bpm in a minute is worth mentioning to a doctor if it repeats."
            }
            lines.append(Line(verdict: verdict,
                              title: String(format: "−%.0f bpm one minute after the last effort", hrr),
                              detail: detail))
        }

        return lines.isEmpty ? nil : lines
    }
}
