import Foundation

/// Disk snapshot of an in-progress (or finished-but-unsaved) workout, written
/// at every phase change and whenever the app leaves the foreground. If the
/// app crashes, is jetsammed during a phone call, or is swiped away before
/// the user taps Save, the next launch offers to recover the session instead
/// of silently losing 10–60 minutes of training.
struct WorkoutCheckpoint: Codable {
    var plan: WorkoutPlan
    var startDate: Date
    var savedAt: Date
    var appliedTargets: [PhaseTarget]
    var actualSeconds: [Double]
    var avgHeartRate: Double?
    var maxHeartRate: Double?
    var avgWorkHeartRate: Double?
    var hrRecovery: Double?
    var heartRateSamples: [HRSample]

    var totalSeconds: Double { actualSeconds.reduce(0, +) }

    /// Rebuilds a saveable result using the same math as the live engine.
    func makeResult(machine: MachineProfile, weightKg: Double?) -> SessionResult {
        WorkoutEngine.buildResult(
            plan: plan,
            startDate: startDate,
            endDate: savedAt,
            appliedTargets: appliedTargets,
            actualSeconds: actualSeconds,
            machine: machine,
            weightKg: weightKg,
            avgHeartRate: avgHeartRate,
            maxHeartRate: maxHeartRate,
            avgWorkHeartRate: avgWorkHeartRate,
            hrRecovery: hrRecovery,
            heartRateSamples: heartRateSamples,
            endedEarly: totalSeconds < plan.totalSeconds - 1)
    }

    // MARK: - Storage

    private static var fileURL: URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("workout-checkpoint.json")
    }

    static func save(_ checkpoint: WorkoutCheckpoint) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> WorkoutCheckpoint? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkoutCheckpoint.self, from: data)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
