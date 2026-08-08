import Foundation
import SwiftData

/// Versioned schema so model changes ship a proper migration stage instead
/// of crashing existing installs at launch. Every version freezes its model
/// definitions as nested types; the app-facing names alias the newest
/// version at the bottom of this file.
enum HIITSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [WorkoutSession.self, EquipmentProgress.self] }

    @Model
    final class WorkoutSession {
        var id: UUID = UUID()
        var date: Date = Date()
        var equipmentRaw: String = ""
        var levelRaw: String = ""
        var planName: String = ""
        var planFocus: String = ""
        var plannedMinutes: Int = 0
        var totalSeconds: Double = 0
        var workSeconds: Double = 0
        var completedWorkIntervals: Int = 0
        var totalWorkIntervals: Int = 0
        var estimatedCalories: Double = 0
        var estimatedDistanceMeters: Double = 0
        var avgHeartRate: Double?
        var maxHeartRate: Double?
        var hrRecovery: Double?
        var rpe: Int?
        var notes: String = ""
        var nextTimeNote: String = ""
        var savedToHealth: Bool = false
        var phasesData: Data = Data()

        init() {}
    }

    @Model
    final class EquipmentProgress {
        var equipmentRaw: String = ""
        var level: Double = 0
        var sessionsCompleted: Int = 0
        var hardSessionsSinceEasy: Int = 0
        var lastSessionDate: Date?

        init() {}
    }
}

/// V2 stores the post-workout analysis with the session — the graded
/// objectives and the suspended-time disclosure — so the history detail can
/// replay the same screen the user saw right after the workout instead of a
/// thinner reconstruction.
enum HIITSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [WorkoutSession.self, EquipmentProgress.self] }

    @Model
    final class WorkoutSession {
        var id: UUID = UUID()
        var date: Date = Date()
        var equipmentRaw: String = ""
        var levelRaw: String = ""
        var planName: String = ""
        var planFocus: String = ""
        var plannedMinutes: Int = 0
        var totalSeconds: Double = 0
        var workSeconds: Double = 0
        var completedWorkIntervals: Int = 0
        var totalWorkIntervals: Int = 0
        var estimatedCalories: Double = 0
        var estimatedDistanceMeters: Double = 0
        var avgHeartRate: Double?
        var maxHeartRate: Double?
        var hrRecovery: Double?
        var rpe: Int?
        var notes: String = ""
        var nextTimeNote: String = ""
        var savedToHealth: Bool = false
        var phasesData: Data = Data()
        /// Wall-clock seconds credited while the app was suspended, disclosed
        /// on both summary screens.
        var suspendedSeconds: Double = 0
        /// JSON-encoded [SessionObjectives.Line] as graded at save time.
        /// Empty for pre-V2 sessions, checkpoint recoveries, and sessions
        /// without a live HR source.
        var objectivesData: Data = Data()

        init(result: SessionResult) {
            self.id = UUID()
            self.date = result.startDate
            self.equipmentRaw = result.plan.equipment.rawValue
            self.levelRaw = result.plan.level.rawValue
            self.planName = result.plan.name
            self.planFocus = result.plan.focus
            self.plannedMinutes = result.plan.minutes
            self.totalSeconds = result.totalSeconds
            self.workSeconds = result.workSeconds
            self.completedWorkIntervals = result.completedWorkIntervals
            self.totalWorkIntervals = result.plan.workPhaseCount
            self.estimatedCalories = result.estimatedCalories
            self.estimatedDistanceMeters = result.estimatedDistanceMeters
            self.avgHeartRate = result.avgHeartRate
            self.maxHeartRate = result.maxHeartRate
            self.hrRecovery = result.hrRecovery
            self.phasesData = (try? JSONEncoder().encode(result.records)) ?? Data()
        }
    }

    @Model
    final class EquipmentProgress {
        var equipmentRaw: String = ""
        var level: Double = 0
        var sessionsCompleted: Int = 0
        var hardSessionsSinceEasy: Int = 0
        var lastSessionDate: Date?

        init(equipmentRaw: String) {
            self.equipmentRaw = equipmentRaw
        }
    }
}

enum HIITMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HIITSchemaV1.self, HIITSchemaV2.self] }
    static var stages: [MigrationStage] {
        // V1 → V2 only adds defaulted columns — no data massaging needed.
        [.lightweight(fromVersion: HIITSchemaV1.self, toVersion: HIITSchemaV2.self)]
    }
}

typealias WorkoutSession = HIITSchemaV2.WorkoutSession

/// Per-equipment progressive-overload state. `level` rises in small steps as
/// sessions are completed and drives the generator's target speeds/resistance.
typealias EquipmentProgress = HIITSchemaV2.EquipmentProgress

extension WorkoutSession {
    var equipment: Equipment { Equipment(rawValue: equipmentRaw) ?? .treadmill }
    var records: [PhaseRecord] { (try? JSONDecoder().decode([PhaseRecord].self, from: phasesData)) ?? [] }
    /// The objective grades exactly as the post-workout summary showed them;
    /// empty when none were stored.
    var objectives: [SessionObjectives.Line] {
        (try? JSONDecoder().decode([SessionObjectives.Line].self, from: objectivesData)) ?? []
    }
}
