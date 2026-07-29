import Foundation
import SwiftData

/// Versioned schema so future model changes can ship a proper migration
/// stage instead of crashing existing installs at launch.
enum HIITSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [WorkoutSession.self, EquipmentProgress.self] }
}

enum HIITMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HIITSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

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

    var equipment: Equipment { Equipment(rawValue: equipmentRaw) ?? .treadmill }
    var records: [PhaseRecord] { (try? JSONDecoder().decode([PhaseRecord].self, from: phasesData)) ?? [] }
}

/// Per-equipment progressive-overload state. `level` rises in small steps as
/// sessions are completed and drives the generator's target speeds/resistance.
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
