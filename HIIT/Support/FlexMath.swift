import Foundation

// The arithmetic behind `FlexVStack` (see AdaptiveLayout.swift), kept free of
// SwiftUI so the unit tests can check the allocations directly.

/// How a child of `FlexVStack` shares the height left over once the
/// fixed-height children are placed.
struct FlexHeight: Equatable {
    /// Never smaller than this.
    var min: CGFloat
    /// The size at which the child is comfortable. When there's room for
    /// every flexible child's `ideal`, they all get it before anyone grows
    /// further.
    var ideal: CGFloat
    /// Never larger than this.
    var max: CGFloat
    /// Share of the spare height relative to the other flexible children.
    var weight: CGFloat
    /// When there isn't room for every `ideal`, a yielding child stays at
    /// its `min` and gives its share to the others — "drop the chart before
    /// shrinking the timer".
    var yields: Bool
}

enum FlexMath {
    /// Splits `available` height among the flexible children (nil entries
    /// are fixed children and stay nil).
    ///
    /// Room for every `ideal`: start there and grow by weight toward each
    /// maximum. Not enough: start at the minimums, let the non-yielding
    /// children grow first, and only then the yielding ones.
    static func distribute(_ available: CGFloat, among flex: [FlexHeight?]) -> [CGFloat?] {
        var sizes: [CGFloat?] = flex.map { $0?.min }
        let indices = flex.indices.filter { flex[$0] != nil }
        guard !indices.isEmpty else { return sizes }

        let minimum = indices.reduce(0) { $0 + flex[$1]!.min }
        let ideal = indices.reduce(0) { $0 + flex[$1]!.ideal }
        guard available > minimum else { return sizes }

        func grow(_ group: [Int], by amount: CGFloat) -> CGFloat {
            // Water-filling: hand out by weight, capping at each maximum and
            // re-sharing what the capped children couldn't take.
            var remaining = amount
            var active = group.filter { (sizes[$0] ?? 0) < flex[$0]!.max - 0.01 }
            while remaining > 0.01, !active.isEmpty {
                let weight = active.reduce(0) { $0 + flex[$1]!.weight }
                var saturated: [Int] = []
                var taken: CGFloat = 0
                for index in active {
                    let share = remaining * flex[index]!.weight / weight
                    let room = flex[index]!.max - (sizes[index] ?? 0)
                    if share >= room {
                        sizes[index] = flex[index]!.max
                        taken += room
                        saturated.append(index)
                    }
                }
                if saturated.isEmpty {
                    for index in active {
                        sizes[index] = (sizes[index] ?? 0) + remaining * flex[index]!.weight / weight
                    }
                    return 0
                }
                remaining -= taken
                active.removeAll { saturated.contains($0) }
            }
            return Swift.max(0, remaining)
        }

        if available >= ideal {
            for index in indices { sizes[index] = flex[index]!.ideal }
            _ = grow(indices, by: available - ideal)
        } else {
            let firm = indices.filter { !flex[$0]!.yields }
            let yielding = indices.filter { flex[$0]!.yields }
            let left = grow(firm, by: available - minimum)
            _ = grow(yielding, by: left)
        }
        return sizes
    }
}
