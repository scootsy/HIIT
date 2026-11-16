import SwiftUI

// Layout building blocks for screens that must look right at any size: a
// phone in either orientation, iPhone Duo's short cover display, its large
// inner display, half of that display in Split View, and the two halves of a
// partially folded one. Nothing here asks what device it's on — decisions
// come from the space the view was actually given.

// MARK: - Readable width

extension View {
    /// Keeps text-and-cards content from stretching edge to edge on wide
    /// canvases (the Duo's inner display, landscape): capped at a readable
    /// measure and centred. On a phone in portrait it changes nothing.
    func readableWidth(_ maxWidth: CGFloat = 640) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - The fold

/// Where the display folds, in the coordinates of the view that read it.
struct FoldDivision: Equatable {
    var frame: CGRect

    /// Folded like a book: the crease runs top to bottom, content sits side
    /// by side. Otherwise it's folded like a laptop and content stacks.
    var isVertical: Bool { frame.height > frame.width }
}

extension GeometryProxy {
    /// The crease currently crossing this view, if any. Only a partially
    /// open iPhone Duo has one — flat (fully open or closed) and on every
    /// other device this is nil. Anything straddling the crease is hard to
    /// read and to tap, so a full-screen layout arranges itself on either
    /// side of it.
    var foldDivision: FoldDivision? {
        guard #available(iOS 27.1, *) else { return nil }
        guard let region = reservedRegions(kind: .division).first else { return nil }
        let frame = region.frame
        let division = FoldDivision(frame: frame)
        // Ignore a crease that leaves no usable room on one side — better
        // one sound layout than a sliver.
        let smallest: CGFloat = 140
        if division.isVertical {
            guard frame.minX >= smallest, size.width - frame.maxX >= smallest else { return nil }
        } else {
            guard frame.minY >= smallest, size.height - frame.maxY >= smallest else { return nil }
        }
        return division
    }
}

// MARK: - Flexible vertical stack

private struct FlexHeightKey: LayoutValueKey {
    static let defaultValue: FlexHeight? = nil
}

extension View {
    /// Marks a child of `FlexVStack` as height-flexible. The child must be
    /// able to draw at any height in `min...max` (it's told the height it
    /// got); children without this modifier keep their natural height.
    func flexHeight(min: CGFloat, ideal: CGFloat, max: CGFloat, weight: CGFloat = 1, yields: Bool = false) -> some View {
        layoutValue(key: FlexHeightKey.self,
                    value: FlexHeight(min: min,
                                      ideal: Swift.max(min, Swift.min(ideal, max)),
                                      max: Swift.max(min, max),
                                      weight: Swift.max(0.01, weight),
                                      yields: yields))
    }
}

/// A vertical stack for full-screen compositions. Fixed children take their
/// natural height; the height that's left is divided among the children
/// marked `.flexHeight(…)`, so the whole stack exactly fills the space it's
/// given — a big timer on a tall screen, a smaller one on a short screen,
/// nothing pushed off the bottom.
///
/// When even the minimums don't fit, the stack reports its true (taller)
/// height. Put it in a `ScrollView` with `.frame(minHeight:)` set to the
/// viewport height and it fills the screen when it can and scrolls when it
/// can't.
struct FlexVStack: Layout {
    var spacing: CGFloat = 12
    /// Height beyond every child's maximum is spread into the gaps, up to
    /// this much per gap; the rest is split above and below.
    var maxExtraGap: CGFloat = 26

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = resolvedWidth(proposal: proposal, subviews: subviews)
        let fixed = fixedHeights(width: width, subviews: subviews)
        let gaps = spacing * CGFloat(Swift.max(0, subviews.count - 1))
        let minimum = total(fixed, flex: subviews.map { $0[FlexHeightKey.self]?.min }) + gaps

        guard let proposed = proposal.height else {
            // "How tall would you like to be?" — as short as possible, so a
            // surrounding scroll view only scrolls when it truly has to.
            return CGSize(width: width, height: minimum)
        }
        if proposed.isInfinite {
            let maximum = total(fixed, flex: subviews.map { $0[FlexHeightKey.self]?.max }) + gaps
            return CGSize(width: width, height: maximum.isFinite ? maximum : minimum)
        }
        return CGSize(width: width, height: Swift.max(minimum, proposed))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let fixed = fixedHeights(width: bounds.width, subviews: subviews)
        let gapCount = CGFloat(subviews.count - 1)
        let fixedTotal = fixed.reduce(0) { $0 + ($1 ?? 0) }
        let available = bounds.height - fixedTotal - spacing * gapCount
        let flexible = FlexMath.distribute(available, among: subviews.map { $0[FlexHeightKey.self] })

        var heights: [CGFloat] = []
        heights.reserveCapacity(subviews.count)
        for index in subviews.indices {
            heights.append(fixed[index] ?? flexible[index] ?? 0)
        }

        // Spare height (everything is already at its maximum) loosens the
        // gaps a little, then pads top and bottom evenly.
        let used = heights.reduce(0, +) + spacing * gapCount
        let spare = Swift.max(0, bounds.height - used)
        let extraGap = gapCount > 0 ? Swift.min(maxExtraGap, spare / gapCount) : 0
        let inset = (spare - extraGap * gapCount) / 2

        var y = bounds.minY + inset
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.midX, y: y),
                          anchor: .top,
                          proposal: ProposedViewSize(width: bounds.width, height: heights[index]))
            y += heights[index] + spacing + extraGap
        }
    }

    private func resolvedWidth(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        if let width = proposal.width, width.isFinite { return width }
        return subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }

    /// Natural heights of the fixed children at this width; nil for the
    /// flexible ones.
    private func fixedHeights(width: CGFloat, subviews: Subviews) -> [CGFloat?] {
        subviews.map { subview in
            guard subview[FlexHeightKey.self] == nil else { return nil }
            return subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
    }

    private func total(_ fixed: [CGFloat?], flex: [CGFloat?]) -> CGFloat {
        var sum: CGFloat = 0
        for index in fixed.indices {
            sum += fixed[index] ?? flex[index] ?? 0
        }
        return sum
    }
}
