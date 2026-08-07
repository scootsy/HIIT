import Foundation

/// Personal speed→heart-rate calibration. Each completed treadmill/outdoor
/// session with live HR contributes one observed (average work speed,
/// average work %maxHR) point; a least-squares line over the recent points
/// tells the generator where a target zone *actually* lives for this user —
/// better data than the experience-level heuristic once it exists.
///
/// Kept deliberately conservative: no model until three sessions with real
/// speed spread, slope sanity-checked against physiology, and the generator
/// only meets the prediction halfway (±0.6 mph) — a bad strap day degrades
/// to "no calibration", never to a nonsense target.
enum SpeedCalibration {

    struct Point: Codable, Equatable {
        var speedMph: Double
        var hrPct: Double
        var date: Date
    }

    struct Model {
        var interceptPct: Double
        var slopePctPerMph: Double

        /// The speed predicted to produce the given %maxHR.
        func speed(atPercent pct: Double) -> Double {
            (pct - interceptPct) / slopePctPerMph
        }
    }

    /// Rolling window: old fitness shouldn't steer today's targets.
    static let maxPoints = 8
    static let minPoints = 3

    static func fit(_ points: [Point]) -> Model? {
        guard points.count >= minPoints else { return nil }
        let n = Double(points.count)
        let meanSpeed = points.reduce(0) { $0 + $1.speedMph } / n
        let meanPct = points.reduce(0) { $0 + $1.hrPct } / n
        let sxx = points.reduce(0) { $0 + ($1.speedMph - meanSpeed) * ($1.speedMph - meanSpeed) }
        let sxy = points.reduce(0) { $0 + ($1.speedMph - meanSpeed) * ($1.hrPct - meanPct) }
        // Without real speed spread the slope is unidentifiable — sessions
        // all run at one speed can't say how HR responds to speed change.
        guard sxx >= 0.5 else { return nil }
        let slope = sxy / sxx
        // ~4–25 %maxHR per mph brackets plausible human response; anything
        // outside is sensor noise or too-mixed conditions.
        guard slope >= 4, slope <= 25 else { return nil }
        return Model(interceptPct: meanPct - slope * meanSpeed, slopePctPerMph: slope)
    }
}
