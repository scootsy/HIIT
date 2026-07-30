import Foundation
import SwiftData
import os

/// Persists a finished session and applies progression — the single save path
/// shared by the post-workout summary and checkpoint recovery, so both apply
/// identical rules (level update, deload counter, tier changes, decay).
@MainActor
enum SessionSaver {

    struct Outcome {
        /// nil when the persist failed — nothing was recorded and the workout
        /// checkpoint is still on disk for another attempt.
        let session: WorkoutSession?
        let note: String
    }

    @discardableResult
    static func save(result: SessionResult,
                     rpe: Int?,
                     notes: String,
                     context: ModelContext,
                     settings: SettingsStore) -> Outcome {
        let session = WorkoutSession(result: result)
        session.rpe = rpe
        session.notes = notes

        let completion = result.plan.workPhaseCount > 0
            ? Double(result.completedWorkIntervals) / Double(result.plan.workPhaseCount)
            : 1
        var hrPercent: Double? = nil
        if let maxHR = settings.maxHR, let avgWork = result.avgWorkHeartRate {
            hrPercent = avgWork / maxHR * 100
        }

        let progress = fetchOrCreateProgress(for: result.plan.equipment, context: context)
        // A long break decays the effective level (the generator applied the
        // same taper to this session's targets); persist from the decayed
        // base so the comeback session doesn't snap straight back.
        let gapDays = progress.lastSessionDate.map {
            Calendar.current.dateComponents([.day], from: $0, to: result.startDate).day ?? 0
        }
        let baseLevel = ProgressionEngine.decayedLevel(progress.level, daysSince: gapDays)
        let update = ProgressionEngine.evaluate(
            currentLevel: baseLevel,
            rpe: rpe,
            completionRatio: completion,
            avgWorkHRPercent: hrPercent,
            workOverrideLevels: result.workOverrideLevels)
        let declined = update.newLevel < baseLevel
        progress.level = update.newLevel
        progress.sessionsCompleted += 1
        progress.lastSessionDate = result.endDate
        if result.plan.vibe == .easy || result.plan.isDeload == true {
            progress.hardSessionsSinceEasy = 0
        } else {
            progress.hardSessionsSinceEasy += 1
        }

        // Sustained performance moves the experience tier itself; rebasing
        // every equipment's level keeps targets continuous across the change.
        // The settings write is deferred until the context saves: settings
        // live in UserDefaults, which stays durable even when the SwiftData
        // store doesn't.
        var note = update.note
        var newExperience: ExperienceLevel? = nil
        if let change = ProgressionEngine.tierChange(experience: settings.experience,
                                                    progressLevel: progress.level,
                                                    declined: declined) {
            newExperience = change.newExperience
            let delta = progress.level >= ProgressionEngine.tierLevelSpan
                ? -ProgressionEngine.tierLevelSpan
                : ProgressionEngine.tierLevelSpan
            let allProgress = (try? context.fetch(FetchDescriptor<EquipmentProgress>())) ?? []
            for entry in allProgress {
                entry.level += delta
            }
            note = change.note
        }
        session.nextTimeNote = note

        context.insert(session)
        do {
            try context.save()
        } catch {
            // Roll back the progression mutations and the inserted session so
            // a retry applies them exactly once, and keep the checkpoint on
            // disk — it is now the only recoverable copy of this workout.
            AppLog.save.error("session save failed: \(error.localizedDescription, privacy: .public)")
            context.rollback()
            return Outcome(session: nil, note: note)
        }
        if let newExperience {
            settings.experience = newExperience
        }
        WorkoutCheckpoint.clear()
        return Outcome(session: session, note: note)
    }

    static func fetchOrCreateProgress(for equipment: Equipment, context: ModelContext) -> EquipmentProgress {
        let all = (try? context.fetch(FetchDescriptor<EquipmentProgress>())) ?? []
        if let existing = all.first(where: { $0.equipmentRaw == equipment.rawValue }) {
            return existing
        }
        let fresh = EquipmentProgress(equipmentRaw: equipment.rawValue)
        context.insert(fresh)
        return fresh
    }
}
