import ActivityKit
import AppIntents
import SwiftUI

// Compiled into BOTH the app and the widget extension: the Live Activity's
// attributes, the lock-screen App Intents, and the small display helpers the
// widget needs. The widget process cannot import app code, so everything the
// island/lock-screen UI renders lives here as plain, pre-formatted values.

// MARK: - Attributes

struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// PhaseKind.rawValue — a plain string so the widget target doesn't
        /// need the app's model types.
        var phaseKindRaw: String
        /// "Sprint 3 of 15", "Recover", …
        var phaseTitle: String
        /// Anchors for the system-rendered countdown; the timer keeps
        /// ticking even while the app is suspended.
        var phaseStart: Date
        var phaseEnd: Date
        var paused: Bool
        /// Static seconds shown while paused (a date-based timer can't pause).
        var pausedRemaining: Double
        /// Pre-formatted current target, e.g. "6.0 mph · 1%" or "R12 · 90 rpm".
        var targetText: String
        /// Pre-formatted next phase, e.g. "NEXT · RECOVER · 3.4 MPH".
        var nextText: String?
        var effortsDone: Int
        var effortsTotal: Int
        /// True when +/- buttons should show (a speed or resistance target exists).
        var adjustable: Bool
        /// Plan complete, clock counting up from phaseStart.
        var inOvertime: Bool
        /// Live-coach suggestion, pre-formatted for the widget. nil = no chip.
        /// The activity's staleDate carries the chip's expiry — a stale
        /// activity hides it rather than showing a dead offer.
        var suggestionMessage: String? = nil
        /// "DROP TO 6.8 MPH · 2 EFFORTS LEFT"
        var suggestionValue: String? = nil
        /// Ease-off (down arrow, green) vs raise (up arrow, orange).
        var suggestionEaseOff: Bool = true
    }

    var planName: String
    var equipmentRaw: String
}

// MARK: - Display helpers (widget-safe)

enum WorkoutActivityStyle {
    /// Phase tints, kept in sync with Theme.swift by hand — the widget
    /// target doesn't compile the app's Theme/PhaseKind sources.
    static func tint(forPhaseKind raw: String) -> Color {
        switch raw {
        case "warmup": return color(0x3E7BD6)
        case "work": return color(0xFF5F44)
        case "recover": return color(0x29C97A)
        case "steady": return color(0xD9922B)
        case "cooldown": return color(0x8E86F5)
        default: return color(0xFF5F44)
        }
    }

    static func title(forPhaseKind raw: String) -> String {
        switch raw {
        case "warmup": return "Warm up"
        case "work": return "Work"
        case "recover": return "Recover"
        case "steady": return "Steady"
        case "cooldown": return "Cool down"
        default: return "Work"
        }
    }

    static func icon(forPhaseKind raw: String) -> String {
        switch raw {
        case "warmup": return "figure.walk"
        case "work": return "flame.fill"
        case "recover": return "wind"
        case "steady": return "waveform.path.ecg"
        case "cooldown": return "leaf.fill"
        default: return "flame.fill"
        }
    }

    /// "3:05" — for the static paused readout.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255.0,
              green: Double((hex >> 8) & 0xFF) / 255.0,
              blue: Double(hex & 0xFF) / 255.0,
              opacity: 1.0)
    }
}

// MARK: - Intents

/// Handlers the app installs at workout start. The widget target compiles
/// this type too, but never runs it: a LiveActivityIntent's perform() always
/// executes in the app's process, where the handlers are set.
@MainActor
enum WorkoutIntentBridge {
    static var adjust: ((_ up: Bool) -> Void)? = nil
    static var togglePause: (() -> Void)? = nil
    static var acceptSuggestion: (() -> Void)? = nil
    static var dismissSuggestion: (() -> Void)? = nil
}

/// "It said 5.0 but I'm running 5.5" — from the lock screen. Bumps speed by
/// 0.1 mph (or resistance by one level) for this phase and every remaining
/// phase of the same kind, exactly like the in-app steppers.
struct AdjustLiveTargetIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Adjust workout intensity"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Increase", default: true)
    var up: Bool

    init() {}

    init(up: Bool) {
        self.up = up
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        WorkoutIntentBridge.adjust?(up)
        return .result()
    }
}

/// Pause/resume from the lock screen.
struct ToggleWorkoutPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or resume workout"
    static var isDiscoverable: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        WorkoutIntentBridge.togglePause?()
        return .result()
    }
}

/// Apply the live coach's current suggestion from the lock screen — routes
/// through the exact same override path as the in-app APPLY button.
struct AcceptCoachSuggestionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Apply coach suggestion"
    static var isDiscoverable: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        WorkoutIntentBridge.acceptSuggestion?()
        return .result()
    }
}

/// Clear the live coach's current suggestion from the lock screen.
struct DismissCoachSuggestionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Dismiss coach suggestion"
    static var isDiscoverable: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        WorkoutIntentBridge.dismissSuggestion?()
        return .result()
    }
}
