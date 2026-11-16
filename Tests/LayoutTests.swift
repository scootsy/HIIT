import Foundation

/// The height allocation behind the live workout screen: the timer ring and
/// the heart-rate panel share whatever the fixed rows leave over. These are
/// the cases that decide whether the screen fits without scrolling.
func runLayoutTests() {
    // The live screen's two flexible rows, as ActiveWorkoutView declares them.
    let ring = FlexHeight(min: 150, ideal: 200, max: 360, weight: 1, yields: false)
    let panel = FlexHeight(min: 58, ideal: 150, max: 330, weight: 0.55, yields: true)

    func split(_ available: CGFloat) -> (ring: CGFloat, panel: CGFloat) {
        // nil entries stand for fixed rows around the flexible ones.
        let sizes = FlexMath.distribute(available, among: [nil, ring, nil, panel, nil])
        expect(sizes[0] == nil && sizes[2] == nil && sizes[4] == nil, "fixed rows are left alone")
        return (sizes[1] ?? -1, sizes[3] ?? -1)
    }

    // Too little room even for the minimums: everyone sits at minimum and
    // the stack reports that it needs to scroll.
    var result = split(100)
    expectClose(Double(result.ring), 150, "ring at minimum when space is short")
    expectClose(Double(result.panel), 58, "panel at minimum when space is short")

    // A short screen (iPhone Duo closed): not enough for both ideals, so
    // the panel yields — header only — and the ring takes what there is.
    result = split(256)
    expectClose(Double(result.panel), 58, "the panel yields on a short screen")
    expectClose(Double(result.ring), 198, "the ring takes the rest on a short screen")

    // Just under the both-ideals threshold the ring is still the priority…
    result = split(349)
    expectClose(Double(result.ring), 291, "the ring keeps growing until both ideals fit")
    expectClose(Double(result.panel), 58, "the panel still yields just under the threshold")

    // …and from the threshold up, the chart appears and both grow by weight.
    result = split(350)
    expectClose(Double(result.ring), 200, "at the threshold both rows get their ideal")
    expectClose(Double(result.panel), 150, "at the threshold the panel has room for its chart")
    result = split(375)
    expectClose(Double(result.ring), 200 + 25 / 1.55, "spare height goes to the ring by weight")
    expectClose(Double(result.panel), 150 + 25 * 0.55 / 1.55, "spare height goes to the panel by weight")
    expectClose(Double(result.ring + result.panel), 375, "nothing is lost in the split")

    // One row hitting its maximum hands its share to the other.
    result = split(650)
    expectClose(Double(result.ring), 360, "the ring stops at its maximum")
    expectClose(Double(result.panel), 290, "what the ring can't use goes to the panel")

    // Both at maximum: the remainder is left for the stack to spread as gaps.
    result = split(2000)
    expectClose(Double(result.ring), 360, "ring capped")
    expectClose(Double(result.panel), 330, "panel capped")

    // Whenever the space is between the minimums and the maximums, the
    // rows use exactly what they're given, within their own limits.
    for available in stride(from: 208.0, through: 690.0, by: 7.0) {
        let pair = split(CGFloat(available))
        expectClose(Double(pair.ring + pair.panel), available, "the rows fill the space at \(available)")
        expect(pair.ring >= 150 && pair.ring <= 360, "ring within its limits at \(available)")
        expect(pair.panel >= 58 && pair.panel <= 330, "panel within its limits at \(available)")
    }

    // A single flexible row simply absorbs the space (a pane with one
    // stretchy child), and a tight yielding-only stack still grows.
    let alone = FlexMath.distribute(240, among: [nil, panel])
    expectClose(Double(alone[1] ?? -1), 240, "a lone yielding row still takes the space")
    let none = FlexMath.distribute(500, among: [nil, nil])
    expect(none.allSatisfy { $0 == nil }, "no flexible rows, nothing to distribute")
    expect(FlexMath.distribute(500, among: []).isEmpty, "an empty stack distributes nothing")

    // Three rows, two firm: firm rows share by weight before the yielding one.
    let wide = FlexHeight(min: 10, ideal: 100, max: 400, weight: 3, yields: false)
    let narrow = FlexHeight(min: 10, ideal: 100, max: 400, weight: 1, yields: false)
    let shy = FlexHeight(min: 10, ideal: 100, max: 400, weight: 1, yields: true)
    let three = FlexMath.distribute(110, among: [wide, narrow, shy])
    expectClose(Double(three[0] ?? -1), 10 + 60, "the heavier firm row takes three quarters of the spare")
    expectClose(Double(three[1] ?? -1), 10 + 20, "the lighter firm row takes one quarter")
    expectClose(Double(three[2] ?? -1), 10, "the yielding row waits")

    print("Layout checks passed")
}
