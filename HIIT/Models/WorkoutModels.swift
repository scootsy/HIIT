import Foundation

enum ExperienceLevel: String, Codable, CaseIterable, Identifiable {
    case beginner, intermediate, advanced

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var blurb: String {
        switch self {
        case .beginner: return "New to intervals, or returning after a break"
        case .intermediate: return "Exercise regularly, comfortable pushing hard"
        case .advanced: return "Train often and want maximal sessions"
        }
    }
}

enum SessionVibe: String, Codable, CaseIterable, Identifiable {
    case auto, push, easy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Coach's pick"
        case .push: return "Push me"
        case .easy: return "Easier today"
        }
    }
}

enum PhaseKind: String, Codable {
    case warmup, work, recover, steady, cooldown

    var title: String {
        switch self {
        case .warmup: return "Warm up"
        case .work: return "Work"
        case .recover: return "Recover"
        case .steady: return "Steady"
        case .cooldown: return "Cool down"
        }
    }
}

struct PhaseTarget: Codable, Equatable {
    var speedMph: Double? = nil
    var inclinePercent: Double? = nil
    var resistance: Int? = nil
    var cadenceRPM: Int? = nil
    var rpe: Int = 3
    var effortWords: String = "Easy"
    var hrPercentLow: Double? = nil
    var hrPercentHigh: Double? = nil
}

struct IntervalPhase: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: PhaseKind
    var seconds: Double
    var label: String
    var cue: String
    var target: PhaseTarget
}

struct WorkoutPlan: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var focus: String
    var equipment: Equipment
    var level: ExperienceLevel
    var vibe: SessionVibe
    var minutes: Int
    var cueLeadSeconds: Int
    var phases: [IntervalPhase]

    var totalSeconds: Double { phases.reduce(0) { $0 + $1.seconds } }
    var workPhaseCount: Int { phases.filter { $0.kind == .work }.count }
}

/// One phase as it actually happened, persisted with the session.
struct PhaseRecord: Codable {
    var kind: String
    var label: String
    var plannedSeconds: Double
    var actualSeconds: Double
    var speedMph: Double? = nil
    var inclinePercent: Double? = nil
    var resistance: Int? = nil

    var kindValue: PhaseKind { PhaseKind(rawValue: kind) ?? .work }
}

struct SessionResult {
    var plan: WorkoutPlan
    var startDate: Date
    var endDate: Date
    var records: [PhaseRecord]
    var completedWorkIntervals: Int
    var workSeconds: Double
    var totalSeconds: Double
    var avgHeartRate: Double? = nil
    var maxHeartRate: Double? = nil
    var avgWorkHeartRate: Double? = nil
    /// Heart-rate drop 1 minute after the last hard effort, when live HR allowed measuring it.
    var hrRecovery: Double? = nil
    /// Mid-workout manual overrides, expressed in progression levels (positive = user went harder than planned).
    var workOverrideLevels: Double = 0
    var estimatedCalories: Double
    var estimatedDistanceMeters: Double
    var endedEarly: Bool
}
