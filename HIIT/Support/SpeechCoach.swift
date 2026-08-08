import AVFoundation

/// Spoken workout cues — short utterances announcing what's coming so the
/// session is fully eyes-free ("Next: push — 6.8, incline 2"). Speech ducks
/// other apps' playback while it talks (at equal volume the music swallows
/// the words), and the duck is lifted as soon as the utterance ends.
///
/// The ducking runs on the shared application session, managed here. It used
/// to be delegated to the synthesizer's own private session
/// (usesApplicationAudioSession = false) — but iOS only releases a duck when
/// the app's session deactivates, and TonePlayer holds ours active for the
/// whole workout as the background lifeline, so other apps' audio stayed
/// dimmed from the first announcement to the end of the session.
final class SpeechCoach: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechCoach()

    private let synthesizer = AVSpeechSynthesizer()
    private var ducking = false
    /// Bumped on every new utterance so a duck release scheduled for a cue
    /// that has since been superseded quietly stands down.
    private var generation = 0
    private var releaseAttempts = 0

    private override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = true
        synthesizer.delegate = self
    }

    /// Newer information wins: a fresh cue cuts off a stale one mid-word
    /// rather than queueing behind it — by the time "halfway" would finish
    /// after "next: recover", it's wrong.
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        generation += 1
        beginDucking()
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

    // MARK: - Ducking

    /// Unconditional on purpose: a cue can arrive while a failed release is
    /// still mid-retry, after the category was already stripped back to
    /// plain mixing — re-applying every time guarantees each utterance
    /// actually gets its duck, and costs a few no-op session calls at most.
    private func beginDucking() {
        ducking = true
        releaseAttempts = 0
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
        // (Re)activating with .duckOthers in place is what engages the dim.
        try? session.setActive(true)
    }

    /// iOS lifts a duck only when the session deactivates — and deactivation
    /// fails while the tone engine's render loop is running, so park it for
    /// the bounce and bring it straight back. Either half can fail
    /// transiently (the synthesizer's output winding down, background
    /// reactivation hiccups), so the whole bounce retries until both halves
    /// land — an un-reactivated session would end the app's background
    /// lifeline and freeze the workout, which is far worse than a duck that
    /// lifts a beat late.
    private func endDucking() {
        guard ducking else { return }
        let session = AVAudioSession.sharedInstance()
        let tones = TonePlayer.shared
        tones.pauseEngine()
        let released: Bool
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            released = true
        } catch {
            released = false
        }
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        var restored = true
        if tones.isActive {
            do { try session.setActive(true) } catch { restored = false }
            if !tones.resumeEngine() { restored = false }
        }
        if released && restored {
            ducking = false
            releaseAttempts = 0
        } else if releaseAttempts < 5 {
            releaseAttempts += 1
            scheduleDuckRelease(after: 0.5)
        } else {
            // Give up on the duck bookkeeping, never on the lifeline: make a
            // last unconditional attempt to leave the session active and the
            // render loop running.
            ducking = false
            releaseAttempts = 0
            if tones.isActive {
                try? session.setActive(true)
                tones.resumeEngine()
            }
        }
    }

    private func scheduleDuckRelease(after delay: TimeInterval = 0.4) {
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == expected, !self.synthesizer.isSpeaking else { return }
            self.endDucking()
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    // The release rides the utterance-finished callbacks with a short grace
    // period, so back-to-back cues don't pump other apps' volume up and down.
    // Delegate calls aren't guaranteed on the main thread; the session work
    // is funneled there.

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.scheduleDuckRelease() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.scheduleDuckRelease() }
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
