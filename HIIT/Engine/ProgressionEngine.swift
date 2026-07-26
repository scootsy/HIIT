import Foundation

/// Decides how the next session should change, based on how this one went.
/// The rules follow standard progression practice: advance when a session was
/// completed and felt manageable (RPE ≤ 7–8), hold after maximal efforts, and
/// step back when a session couldn't be finished. Live heart-rate data, when
/// available, vetoes increases after sessions that ran very hot.
enum ProgressionEngine {

    struct Update {
        var newLevel: Double
        var note: String
    }

    static func evaluate(currentLevel: Double, rpe: Int?, completionRatio: Double, avgWorkHRPercent: Double?, workOverrideLevels: Double = 0) -> Update {
        var level = currentLevel
        var note: String

        if completionRatio < 0.8 {
            level = max(0, level - 0.5)
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
        // told us, mid-effort, where the targets actually belong.
        let override = max(-2, min(2, workOverrideLevels))
        if override > 0.2 {
            level += override
            note = "You ran ahead of the targets today — next session starts where you actually trained."
        } else if override < -0.2 {
            level = max(0, level + override)
            note = "You dialed it back mid-session, so next time starts at the pace you actually held."
        }

        if let hr = avgWorkHRPercent, hr > 95, level > currentLevel {
            level = currentLevel
            note = "Your heart rate ran very high, so we'll hold the targets steady next time."
        }

        return Update(newLevel: level, note: note)
    }
}
