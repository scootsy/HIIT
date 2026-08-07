import AVFoundation

/// Spoken workout cues — short utterances announcing what's coming so the
/// session is fully eyes-free ("Next: push — 6.8, incline 2"). Kept apart
/// from TonePlayer's beep path: the synthesizer manages its own audio
/// session so speech behaves like spoken-audio (ducking other playback)
/// instead of fighting the music at equal volume.
final class SpeechCoach: NSObject {
    static let shared = SpeechCoach()

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = false
    }

    /// Newer information wins: a fresh cue cuts off a stale one mid-word
    /// rather than queueing behind it — by the time "halfway" would finish
    /// after "next: recover", it's wrong.
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Turns engine speech events into short spoken lines, in the user's units.
/// Numbers stay bare ("6.8", not "6.8 miles per hour") — treadmill users
/// know their dial, and brevity is what makes mid-effort speech usable.
enum SpeechScript {

    static func line(for event: WorkoutEngine.SpeechEvent, useMetric: Bool) -> String? {
        switch event {
        case .prep(let next, let target):
            return "Next: " + phrase(kind: next.kind, target: target, useMetric: useMetric)
        case .phaseStart(let phase, let target):
            let text = phrase(kind: phase.kind, target: target, useMetric: useMetric)
            return text.prefix(1).uppercased() + String(text.dropFirst())
        case .halfway:
            return "Halfway"
        case .suggestion(let suggestion):
            return "Coach: " + suggestion.message
        }
    }

    private static func phrase(kind: PhaseKind, target: PhaseTarget, useMetric: Bool) -> String {
        let kindWord: String
        switch kind {
        case .warmup: kindWord = "warm up"
        case .work: kindWord = "push"
        case .recover: kindWord = "recover"
        case .steady: kindWord = "steady"
        case .cooldown: kindWord = "cool down"
        }
        var values: [String] = []
        if let speed = target.speedMph {
            values.append(String(format: "%.1f", useMetric ? speed * 1.60934 : speed))
            if let incline = target.inclinePercent, incline > 0.5 {
                values.append(String(format: "incline %.0f", incline))
            }
        } else if let resistance = target.resistance {
            values.append("resistance \(resistance)")
            if let cadence = target.cadenceRPM {
                values.append("cadence \(cadence)")
            }
        } else if !target.effortWords.isEmpty {
            values.append(target.effortWords.lowercased())
        }
        return values.isEmpty ? kindWord : kindWord + " — " + values.joined(separator: ", ")
    }
}
