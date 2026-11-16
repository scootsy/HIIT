import Foundation

/// Decides how the next session should change, based on how this one went.
/// The rules follow standard progression practice: advance when a session was
/// completed and felt manageable (RPE ≤ 7–8), hold after maximal efforts, and
/// step back when a session couldn't be finished. Live heart-rate data, when
/// available, vetoes increases after sessions that ran very hot.
enum ProgressionEngine {

    /// One progression level's worth of target change. The generator applies
    /// these when building targets, and WorkoutEngine.buildResult inverts them
    /// to convert mid-workout overrides back into level credit — the two sides
    /// must stay in lockstep, so both read these shared constants.
    static let speedPerLevelMph = 0.2
    static let resistanceFractionPerLevel = 0.015

    /// The lowest a progression level can be pushed — by a run of unfinished
    /// sessions or by an AI-coach "ease off" the user approved. Below this
    /// the tier itself steps down instead (see `tierChange`).
    static let levelFloor = -3.0

    struct Update {
        var newLevel: Double
        var note: String
    }

    static func evaluate(currentLevel: Double, rpe: Int?, completionRatio: Double, avgWorkHRPercent: Double?, workOverrideLevels: Double = 0) -> Update {
        var level = currentLevel
        var note: String

        if completionRatio < 0.8 {
            level = max(levelFloor, level - 0.5)
            note = "We'll ease the targets a touch next time so you can finish strong."
        } else if let rpe {
            switch rpe {
            case ..<5:
                level += 1
                note = "That looked comfortable — next session steps up."
            case 5...7:
                level += 0.5
                note = "Right in the sweet spot. Small bump next time."
            case 8:
                level += 0.25
                note = "Solid effort — we'll nudge things up slightly."
            default:
                note = "That was a max effort. We'll consolidate here before pushing on."
            }
        } else {
            level += 0.5
            note = "Completed in full — next session nudges up."
        }

        // Mid-workout overrides are the strongest signal we have — the user
        // told us, mid-effort, where the targets actually belong. But an
        // unfinished session must never net a step up: positive override
        // credit only counts when the session was actually completed.
        var override = max(-2, min(2, workOverrideLevels))
        if completionRatio < 0.8 {
            override = min(0, override)
        }
        if override > 0.2 {
            level += override
            note = "You ran ahead of the targets today — next session starts where you actually trained."
        } else if override < -0.2 {
            level = max(levelFloor, level + override)
            note = "You dialed it back mid-session, so next time starts at the pace you actually held."
        }

        if let hr = avgWorkHRPercent, hr > 95, level > currentLevel {
            level = currentLevel
            note = "Your heart rate ran very high, so we'll hold the targets steady next time."
        }

        return Update(newLevel: level, note: note)
    }

    // MARK: - Weekly cap

    /// Weekly progression cap: net +1 level (+0.2 mph of work speed) per
    /// rolling 7 days, however comfortable the sessions felt. Uncapped
    /// compounding allowed ~+0.6 mph a week — the classic overuse-injury
    /// setup, and RPE can't catch it because comfort is the trigger.
    static let weeklyCapLevels = 1.0
    static let weeklyCapWindow: TimeInterval = 7 * 86400

    struct CappedLevel: Equatable {
        var level: Double
        /// True when the cap held the level below what the session earned.
        var wasCapped: Bool
        /// The high-water mark to persist: when the level last rose, and to
        /// what. Unchanged unless `anchorMoved`.
        var anchorLevel: Double
        var anchorDate: Date
        var anchorMoved: Bool
    }

    /// Applies the cap to a session's proposed level. The anchor is a
    /// high-water mark whose +1 headroom refills continuously over 7 days —
    /// a tumbling window would allow +2 within hours across its boundary.
    ///
    /// The cap limits *rises* only. Its ceiling never sits below `base` (the
    /// level the session started from), so a level that was legitimately
    /// moved above the anchor since the last save — the user approving an
    /// AI-coach increase, say — is held, never pulled back down and reported
    /// as a "strong week".
    static func applyWeeklyCap(proposed: Double,
                               base: Double,
                               anchorLevel: Double?,
                               anchorDate: Date?,
                               now: Date) -> CappedLevel {
        let anchorDate = anchorDate ?? now.addingTimeInterval(-weeklyCapWindow)
        let anchorLevel = anchorLevel ?? base
        let elapsed = max(0, now.timeIntervalSince(anchorDate))
        let refill = min(weeklyCapLevels, elapsed / weeklyCapWindow * weeklyCapLevels)
        let ceiling = max(anchorLevel + refill, base)

        var level = proposed
        var capped = false
        if level > ceiling {
            level = ceiling
            capped = true
        }
        if level > anchorLevel {
            return CappedLevel(level: level, wasCapped: capped,
                               anchorLevel: level, anchorDate: now, anchorMoved: true)
        }
        return CappedLevel(level: level, wasCapped: capped,
                           anchorLevel: anchorLevel, anchorDate: anchorDate, anchorMoved: false)
    }

    /// Experience promotes/demotes itself from sustained performance.
    /// ~7 progression levels ≈ the target gap between tiers, so rebasing by
    /// `tierLevelSpan` on a change keeps the actual targets continuous —
    /// what changes is the session structure (effort lengths, recoveries,
    /// protocols, HR bands).
    static let tierLevelSpan = 7.0

    static func tierChange(experience: ExperienceLevel, progressLevel: Double, declined: Bool) -> (newExperience: ExperienceLevel, note: String)? {
        if progressLevel >= tierLevelSpan {
            switch experience {
            case .beginner:
                return (.intermediate, "Leveled up — intermediate sessions from now on.")
            case .intermediate:
                return (.advanced, "Leveled up — advanced sessions from now on.")
            case .advanced:
                return nil
            }
        }
        // Demote only when this session's own results drove the level down.
        // A promotion on one machine rebases every other machine's level by
        // -tierLevelSpan, which can park a lightly-trained machine below the
        // threshold — without this gate, the very next session on it would
        // demote the tier and the promotion/demotion would ping-pong forever.
        if declined && progressLevel <= levelFloor {
            switch experience {
            case .beginner:
                return nil
            case .intermediate:
                return (.beginner, "Scaled the structure back to beginner for now.")
            case .advanced:
                return (.intermediate, "Scaled the structure back to intermediate for now.")
            }
        }
        return nil
    }

    /// Detraining after a break: fitness fades when training stops, so after
    /// two weeks off the accumulated level tapers by ~0.5 per missed week.
    /// Decay never pushes the level below zero — the tier baseline stands.
    static func decayedLevel(_ level: Double, daysSince: Int?) -> Double {
        guard let days = daysSince, days > 14, level > 0 else { return level }
        let missedWeeks = Double(days - 14) / 7 + 1
        return max(0, level - 0.5 * missedWeeks)
    }
}
