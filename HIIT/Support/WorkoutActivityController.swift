import ActivityKit
import Foundation
import UIKit

/// Owns the workout's Live Activity: starts it with the session, pushes a new
/// content state at every phase boundary / pause / adjustment, and ends it
/// when the session leaves the screen. The countdown itself is date-based and
/// rendered by the system, so it keeps ticking while the app is suspended —
/// only phase *changes* need the app awake, which matches how the engine
/// already works (cues pause in the background, time is credited on return).
@MainActor
final class WorkoutActivityController {

    private var activity: Activity<WorkoutActivityAttributes>? = nil
    /// The last coach suggestion pushed to the activity — a *new* one while
    /// the app is backgrounded gets an alerting update that lights the screen.
    private var lastSuggestionID: UUID? = nil

    func start(engine: WorkoutEngine, settings: SettingsStore) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let attributes = WorkoutActivityAttributes(
            planName: engine.plan.name,
            equipmentRaw: engine.plan.equipment.rawValue)
        let content = ActivityContent(state: contentState(engine: engine, settings: settings),
                                      staleDate: nil)
        // Denied/failed requests (user toggled Live Activities off, activity
        // budget exhausted) just mean no island pill — never fail the workout.
        activity = try? Activity.request(attributes: attributes, content: content)
    }

    func update(engine: WorkoutEngine, settings: SettingsStore) {
        guard let activity else { return }
        // While a suggestion is showing, its expiry is the activity's stale
        // date: if the app dies before pushing the cleared state, the system
        // marks the activity stale and the widget hides the dead offer.
        let content = ActivityContent(state: contentState(engine: engine, settings: settings),
                                      staleDate: engine.liveSuggestion?.expiresAt)
        let suggestion = engine.liveSuggestion
        var alert: AlertConfiguration? = nil
        if let suggestion, suggestion.id != lastSuggestionID,
           UIApplication.shared.applicationState != .active {
            alert = AlertConfiguration(title: "Coach",
                                       body: "\(suggestion.message)",
                                       sound: .default)
        }
        lastSuggestionID = suggestion?.id
        Task { await activity.update(content, alertConfiguration: alert) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Cleans up activities orphaned by a crash or force-quit — called at
    /// launch, when no workout can be running.
    static func endOrphaned() {
        Task {
            for orphan in Activity<WorkoutActivityAttributes>.activities {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Content state

    private func contentState(engine: WorkoutEngine, settings: SettingsStore) -> WorkoutActivityAttributes.ContentState {
        let now = Date()
        let phaseStart: Date
        let phaseEnd: Date
        if engine.inOvertime {
            phaseStart = now.addingTimeInterval(-engine.overtimeSeconds)
            phaseEnd = now.addingTimeInterval(1)
        } else {
            phaseStart = now.addingTimeInterval(-engine.phaseElapsed)
            phaseEnd = now.addingTimeInterval(engine.phaseRemaining)
        }
        let paused = engine.state == .paused
        let phase = engine.currentPhase
        var title = phase.label
        if title.isEmpty { title = phase.kind.title }
        return WorkoutActivityAttributes.ContentState(
            phaseKindRaw: phase.kind.rawValue,
            phaseTitle: title,
            phaseStart: phaseStart,
            phaseEnd: phaseEnd,
            paused: paused,
            // In overtime the countdown is exhausted — freeze the overtime
            // elapsed instead (the widget checks paused before inOvertime).
            pausedRemaining: engine.inOvertime ? engine.overtimeSeconds : engine.phaseRemaining,
            targetText: targetText(engine.currentTarget, equipment: engine.plan.equipment, settings: settings),
            nextText: nextText(engine: engine, settings: settings),
            effortsDone: engine.workEffortsDone,
            effortsTotal: engine.plan.workPhaseCount,
            adjustable: engine.plan.equipment == .bike
                ? engine.currentTarget.resistance != nil
                : engine.currentTarget.speedMph != nil,
            inOvertime: engine.inOvertime,
            suggestionMessage: engine.liveSuggestion?.message,
            suggestionValue: engine.liveSuggestion.map {
                LiveCoach.valueText(for: $0, engine: engine, useMetric: settings.value.useMetric)
            },
            suggestionEaseOff: (engine.liveSuggestion?.steps ?? -1) < 0)
    }

    private func targetText(_ target: PhaseTarget, equipment: Equipment, settings: SettingsStore) -> String {
        switch equipment {
        case .bike:
            if let resistance = target.resistance {
                if let cadence = target.cadenceRPM { return "R\(resistance) · \(cadence) rpm" }
                return "R\(resistance)"
            }
            return target.effortWords
        case .treadmill, .outdoor:
            guard let speed = target.speedMph else { return target.effortWords }
            var text = String(format: "%.1f %@",
                              settings.value.useMetric ? speed * 1.60934 : speed,
                              settings.value.useMetric ? "km/h" : "mph")
            if let incline = target.inclinePercent, incline > 0.5 {
                text += String(format: " · %.0f%%", incline)
            }
            return text
        }
    }

    private func nextText(engine: WorkoutEngine, settings: SettingsStore) -> String? {
        guard !engine.inOvertime,
              let next = engine.nextPhase, let target = engine.nextTarget else { return nil }
        let value = targetText(target, equipment: engine.plan.equipment, settings: settings)
        return "NEXT · \(next.kind.title.uppercased()) · \(value.uppercased())"
    }
}
