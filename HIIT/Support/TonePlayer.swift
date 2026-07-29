import AVFoundation

/// Synthesized countdown beeps. System sounds (AudioServicesPlaySystemSound)
/// are silenced by the ringer switch and won't play over music — which is
/// exactly the state of a phone at the gym. So we render short sine tones
/// ourselves and play them through a `.playback` session mixed over whatever
/// else is playing.
final class TonePlayer {
    static let shared = TonePlayer()

    enum Tone {
        /// Countdown tick — the "low beep" of the low-low-low-HIGH pattern.
        case low
        /// GO — the phase flipped to something harder.
        case high
        /// Effort finished — you made it, ease off now.
        case done
        /// Plan or workout complete.
        case fanfare
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Tone: AVAudioPCMBuffer] = [:]
    private var wired = false
    private var active = false

    private init() {}

    var isActive: Bool { active }

    func prepare() {
        guard !active else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if buffers.isEmpty {
            buffers[.low] = makeBuffer(notes: [(880, 0.12)])
            buffers[.high] = makeBuffer(notes: [(1318.5, 0.45)])
            buffers[.done] = makeBuffer(notes: [(1318.5, 0.14), (988.0, 0.22)])
            buffers[.fanfare] = makeBuffer(notes: [(880, 0.12), (1108.7, 0.12), (1318.5, 0.32)])
        }
        if !wired {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            wired = true
        }
        engine.prepare()
        active = (try? engine.start()) != nil
        if active { player.play() }
    }

    func deactivate() {
        guard active else { return }
        player.stop()
        engine.stop()
        active = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Returns false when the tone couldn't be played so the caller can fall
    /// back to a system sound. A failed initial `prepare()` (e.g. a workout
    /// started during a phone call) is retried here, so cues recover as soon
    /// as the audio session becomes available again instead of staying silent
    /// for the whole session.
    @discardableResult
    func play(_ tone: Tone) -> Bool {
        play(tone, after: 0)
    }

    /// Schedules a tone `delay` seconds from now on the audio engine's own
    /// sample clock, compensated for the output route's latency (Bluetooth
    /// earbuds add 150–300 ms) — so countdown beeps land exactly on their
    /// boundary instead of audibly trailing the on-screen number.
    @discardableResult
    func play(_ tone: Tone, after delay: TimeInterval) -> Bool {
        if !active { prepare() }
        guard active, let buffer = buffers[tone] else { return false }
        if !engine.isRunning {
            // A phone call or Siri stopped the engine; pick back up.
            guard (try? engine.start()) != nil else { return false }
            player.play()
        }
        let latency = AVAudioSession.sharedInstance().outputLatency
        let lead = delay - latency
        if lead > 0.01,
           let nodeTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: nodeTime) {
            let target = AVAudioTime(
                sampleTime: playerTime.sampleTime + AVAudioFramePosition(lead * format.sampleRate),
                atRate: format.sampleRate)
            player.scheduleBuffer(buffer, at: target, options: [], completionHandler: nil)
        } else {
            player.scheduleBuffer(buffer, completionHandler: nil)
        }
        if !player.isPlaying { player.play() }
        return true
    }

    /// Sine notes with a quick attack and release so they don't click.
    private func makeBuffer(notes: [(frequency: Double, duration: Double)], gap: Double = 0.06) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = notes.reduce(0) { $0 + $1.duration } + gap * Double(max(0, notes.count - 1))
        let frames = AVAudioFrameCount(total * rate) + 64
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let data = buffer.floatChannelData?[0] else { return nil }
        for i in 0..<Int(frames) { data[i] = 0 }

        var offset = 0.0
        for note in notes {
            let start = Int(offset * rate)
            let count = Int(note.duration * rate)
            let attack = min(0.008, note.duration / 4)
            let release = min(0.06, note.duration / 3)
            for f in 0..<count where start + f < Int(frames) {
                let t = Double(f) / rate
                var amp = 0.85
                if t < attack { amp *= t / attack }
                let tail = note.duration - t
                if tail < release { amp *= tail / release }
                data[start + f] = Float(amp * sin(2 * .pi * note.frequency * t))
            }
            offset += note.duration + gap
        }
        return buffer
    }
}
