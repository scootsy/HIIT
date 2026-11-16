import Foundation

/// Progression rules, the weekly cap, the speed→heart-rate fit, and the
/// energy math — the numbers that decide what the next session asks for.
func runProgressionTests() {

    // MARK: Session-to-session progression

    func next(_ level: Double, rpe: Int?, completion: Double = 1, hr: Double? = nil, override: Double = 0) -> Double {
        ProgressionEngine.evaluate(currentLevel: level, rpe: rpe, completionRatio: completion,
                                   avgWorkHRPercent: hr, workOverrideLevels: override).newLevel
    }
    expectClose(next(2, rpe: 3), 3, "a comfortable session steps up a full level")
    expectClose(next(2, rpe: 6), 2.5, "a sweet-spot session steps up half a level")
    expectClose(next(2, rpe: 8), 2.25, "a hard session nudges up a quarter")
    expectClose(next(2, rpe: 10), 2, "a maximal session holds")
    expectClose(next(2, rpe: nil), 2.5, "an unrated but completed session nudges up")
    expectClose(next(2, rpe: 3, completion: 0.5), 1.5, "an unfinished session steps back whatever the rating")
    expectClose(next(-2.8, rpe: 3, completion: 0.5), ProgressionEngine.levelFloor, "the level never drops below the floor")
    expectClose(next(2, rpe: 6, hr: 97), 2, "a very high work heart rate vetoes the increase")
    expectClose(next(2, rpe: 10, hr: 97), 2, "the heart-rate veto never lowers a held level")
    expectClose(next(2, rpe: 6, override: 1.5), 4, "running ahead of the targets is credited on top")
    expectClose(next(2, rpe: 6, override: 9), 4.5, "override credit is clamped to two levels")
    expectClose(next(2, rpe: 6, completion: 0.5, override: 1.5), 1.5, "an unfinished session never nets a step up from overrides")
    expectClose(next(2, rpe: 6, override: -1), 1.5, "dialling back mid-session carries into the next one")
    expectClose(next(-2.5, rpe: 6, override: -2), ProgressionEngine.levelFloor, "a dial-back still respects the floor")

    // MARK: Tier changes

    expect(ProgressionEngine.tierChange(experience: .beginner, progressLevel: 7, declined: false)?.newExperience == .intermediate,
           "seven levels promotes a beginner")
    expect(ProgressionEngine.tierChange(experience: .advanced, progressLevel: 9, declined: false) == nil,
           "advanced has no tier above it")
    expect(ProgressionEngine.tierChange(experience: .intermediate, progressLevel: -3, declined: true)?.newExperience == .beginner,
           "a decline to the floor demotes")
    expect(ProgressionEngine.tierChange(experience: .intermediate, progressLevel: -3, declined: false) == nil,
           "sitting at the floor without a decline does not demote")
    expect(ProgressionEngine.tierChange(experience: .beginner, progressLevel: -3, declined: true) == nil,
           "beginner has no tier below it")

    // MARK: Detraining

    expectClose(ProgressionEngine.decayedLevel(4, daysSince: 10), 4, "two weeks of grace before any decay")
    expectClose(ProgressionEngine.decayedLevel(4, daysSince: 21), 3, "three weeks off costs a level")
    expectClose(ProgressionEngine.decayedLevel(1, daysSince: 120), 0, "decay never goes below the tier baseline")
    expectClose(ProgressionEngine.decayedLevel(-2, daysSince: 120), -2, "a negative level is not decayed further")
    expectClose(ProgressionEngine.decayedLevel(4, daysSince: nil), 4, "no history means no decay")

    // MARK: Weekly cap

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

    // First capped save on this equipment: no anchor yet, so a full level of
    // headroom is available and the anchor is planted at the new level.
    var cap = ProgressionEngine.applyWeeklyCap(proposed: 3, base: 2, anchorLevel: nil, anchorDate: nil, now: now)
    expectClose(cap.level, 3, "one level in a week is allowed")
    expect(!cap.wasCapped && cap.anchorMoved && cap.anchorDate == now, "the rise plants the anchor")
    expectClose(cap.anchorLevel, 3, "the anchor records the new high-water mark")

    // A rise the same day as the last one has no headroom left.
    cap = ProgressionEngine.applyWeeklyCap(proposed: 3.5, base: 3, anchorLevel: 3, anchorDate: now, now: now)
    expectClose(cap.level, 3, "no headroom immediately after a rise")
    expect(cap.wasCapped && !cap.anchorMoved, "a fully capped session leaves the anchor alone")

    // Headroom refills continuously: half a week buys half a level.
    cap = ProgressionEngine.applyWeeklyCap(proposed: 4, base: 3, anchorLevel: 3, anchorDate: daysAgo(3.5), now: now)
    expectClose(cap.level, 3.5, "half a week refills half a level")
    expect(cap.wasCapped && cap.anchorMoved, "a partial rise is capped and re-anchors")

    // …and never beyond one level, however long the gap.
    cap = ProgressionEngine.applyWeeklyCap(proposed: 6, base: 3, anchorLevel: 3, anchorDate: daysAgo(60), now: now)
    expectClose(cap.level, 4, "headroom tops out at one level")

    // A level under the cap passes straight through.
    cap = ProgressionEngine.applyWeeklyCap(proposed: 3.25, base: 3, anchorLevel: 3, anchorDate: daysAgo(7), now: now)
    expectClose(cap.level, 3.25, "a rise within the headroom is untouched")
    expect(!cap.wasCapped, "nothing was capped")

    // A step back is never interfered with and never moves the anchor.
    cap = ProgressionEngine.applyWeeklyCap(proposed: 2.5, base: 3, anchorLevel: 3, anchorDate: daysAgo(1), now: now)
    expectClose(cap.level, 2.5, "the cap never blocks a decrease")
    expect(!cap.wasCapped && !cap.anchorMoved, "a decrease leaves the anchor where it was")

    // The regression this function exists to prevent: the user approved an
    // AI-coach increase (level 2 → 4) after the anchor was set at 2. The
    // next save must hold the approved level, not pull it back to ~2.4 and
    // call that a "strong week".
    cap = ProgressionEngine.applyWeeklyCap(proposed: 4.5, base: 4, anchorLevel: 2, anchorDate: daysAgo(3), now: now)
    expectClose(cap.level, 4, "a level raised since the last save is held, never clawed back")
    expect(cap.wasCapped, "the further rise is what gets capped")
    expect(cap.anchorMoved, "the anchor catches up with the approved level")
    expectClose(cap.anchorLevel, 4, "the anchor catches up to the held level")
    cap = ProgressionEngine.applyWeeklyCap(proposed: 4, base: 4, anchorLevel: 2, anchorDate: daysAgo(3), now: now)
    expectClose(cap.level, 4, "a held session after an approved raise keeps the raise")
    expect(!cap.wasCapped, "holding the base is not a capped rise")

    // MARK: Speed → heart-rate calibration

    func point(_ speed: Double, _ pct: Double) -> SpeedCalibration.Point {
        SpeedCalibration.Point(speedMph: speed, hrPct: pct, date: now)
    }
    expect(SpeedCalibration.fit([point(5, 80), point(6, 90)]) == nil, "two sessions are not enough for a model")
    expect(SpeedCalibration.fit([point(6, 85), point(6, 86), point(6.1, 84)]) == nil,
           "sessions all at one speed cannot identify a slope")
    expect(SpeedCalibration.fit([point(5, 90), point(6, 85), point(7, 80)]) == nil,
           "a negative slope is rejected as noise")
    if let model = SpeedCalibration.fit([point(5, 70), point(6, 80), point(7, 90)]) {
        expectClose(model.slopePctPerMph, 10, "a clean line recovers its slope")
        expectClose(model.speed(atPercent: 88), 6.8, "the model inverts to the speed for a target zone")
    } else {
        expect(false, "three well-spread sessions must produce a model")
    }

    // MARK: Energy math

    expectClose(MetabolicMath.treadmillMETs(speedMph: 3.0, inclinePercent: 0), (0.1 * 3.0 * 26.8224 + 3.5) / 3.5,
                "walking uses the ACSM walking equation")
    expectClose(MetabolicMath.treadmillMETs(speedMph: 6.0, inclinePercent: 0), (0.2 * 6.0 * 26.8224 + 3.5) / 3.5,
                "running uses the ACSM running equation")
    var previous = MetabolicMath.treadmillMETs(speedMph: 2.0, inclinePercent: 1)
    for step in 21...120 {
        let current = MetabolicMath.treadmillMETs(speedMph: Double(step) / 10, inclinePercent: 1)
        expect(current > previous, "energy cost must rise with speed at \(Double(step) / 10) mph")
        expect(current - previous < 0.7, "no cliff in the walk/run blend at \(Double(step) / 10) mph")
        previous = current
    }
    expect(MetabolicMath.treadmillMETs(speedMph: 3.5, inclinePercent: 8) > MetabolicMath.treadmillMETs(speedMph: 3.5, inclinePercent: 0),
           "incline adds energy cost")
    expectClose(MetabolicMath.bikeMETs(effort: 0), 3.0, "an idle spin sits at the floor")
    expectClose(MetabolicMath.bikeMETs(effort: 5), MetabolicMath.bikeMETs(effort: 1), "bike effort is clamped to the ceiling")
    expectClose(MetabolicMath.kilocalories(mets: 10, weightKg: 80, seconds: 600), 140, "kcal = METs × 3.5 × kg / 200 per minute")

    expect(HeartRateZone.zone(forPercent: 59.9) == .z1 && HeartRateZone.zone(forPercent: 60) == .z2
           && HeartRateZone.zone(forPercent: 89.9) == .z4 && HeartRateZone.zone(forPercent: 90) == .z5,
           "zone boundaries sit on the tens")

    print("Progression checks passed")
}
