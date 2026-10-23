import CoreGraphics

/// Where a hover callout sits over the element it explains: pure arithmetic on the target's rect,
/// the chip's own size and the surface both must stay inside.
///
/// The whole rule is HUG THE TARGET - one gap above it, or one gap below when there is no room
/// above (a row at the top of a panel), held off the surface's own edges either way. So the chip is
/// only ever as close to the hovered element as that element's reported rect is tight: a target
/// spanning a whole strip of rows makes the flip below measure from the STRIP's bottom edge, and
/// the callout then lands a band's height away from the row the pointer was actually on, covering
/// whatever sits under the strip. That is not a fault in this arithmetic and cannot be corrected
/// here - it is fixed by giving the hover to the row rather than the band (the fleet gauge's own
/// bug, 2026-08-04). The comment is here because this is where the symptom shows up.
///
/// Pure geometry in its own file so the rule can be checked without a running app: a placement is
/// exactly the kind of thing that is wrong on screen while everything builds, draws and passes.
enum TooltipPlacement {
    /// Centred on the target, then held inside the surface's margins.
    static func originX(width: CGFloat, anchor: CGRect, bounds: CGSize,
                        margin: CGFloat) -> CGFloat {
        let centred = anchor.midX - width / 2
        let rightmost = max(margin, bounds.width - width - margin)
        return min(max(centred, margin), rightmost)
    }

    /// Above the target, or below it when the chip would not fit above (the top card in a panel).
    /// Below is itself held off the bottom edge, so a target near either edge still shows the whole
    /// chip - and only that clamp may ever put the chip further from the target than one gap.
    static func originY(height: CGFloat, anchor: CGRect, bounds: CGSize,
                        gap: CGFloat, margin: CGFloat) -> CGFloat {
        let above = anchor.minY - gap - height
        if above >= margin { return above }
        let lowest = max(margin, bounds.height - height - margin)
        return min(anchor.maxY + gap, lowest)
    }

    /// Where a beside-the-target chip sits vertically against its anchor: centred on it, or flush
    /// with its top or bottom edge. Every one of them overlaps the anchor's own line, so the chip
    /// stays next to what the pointer is on.
    enum BesideAlign: CaseIterable { case center, top, bottom }

    struct BesideSlot: Equatable {
        var x: CGFloat
        var width: CGFloat
        var align: BesideAlign
    }

    /// Beside the target instead of above or below it (a settings row's title line, B-2649): a row is
    /// shorter than its explanation, so above or below always lands on a neighbouring row's text.
    /// The chip sits to the right of the target at the nearest left edge (the target's own right
    /// edge, then each obstacle's right edge), at the widest of `widths` (descending, chip widths)
    /// and the first vertical alignment where its estimated rect touches no obstacle. `obstacles`
    /// are every label and control of the card, in the same space as `anchor`; the one holding the
    /// anchor (the hovered row's own label, its description included) is not one. Nil: no slot is
    /// clear, and the caller falls back to the hug-the-target rule.
    static func besideSlot(anchor: CGRect, obstacles: [CGRect], bounds: CGSize, gap: CGFloat,
                           margin: CGFloat, widths: [CGFloat],
                           height: (CGFloat) -> CGFloat) -> BesideSlot? {
        let mid = CGPoint(x: anchor.midX, y: anchor.midY)
        let others = obstacles.filter { !$0.contains(mid) }.map { $0.insetBy(dx: -2, dy: -2) }
        let lefts = ([anchor.maxX] + others.map { $0.maxX }.filter { $0 > anchor.maxX }).sorted()
        for left in lefts {
            for width in widths {
                let h = height(width)
                for align in BesideAlign.allCases {
                    let rect = CGRect(x: left + gap, y: besideY(height: h, anchor: anchor, bounds: bounds, margin: margin, align: align),
                                      width: width, height: h)
                    if rect.maxX <= bounds.width - margin, !others.contains(where: { $0.intersects(rect) }) {
                        return BesideSlot(x: rect.minX, width: width, align: align)
                    }
                }
            }
        }
        return nil
    }

    /// Centred on the target's own midline, or flush with its top or bottom, held inside the surface.
    static func besideY(height: CGFloat, anchor: CGRect, bounds: CGSize, margin: CGFloat,
                        align: BesideAlign = .center) -> CGFloat {
        let wanted: CGFloat
        switch align {
        case .center: wanted = anchor.midY - height / 2
        case .top: wanted = anchor.minY
        case .bottom: wanted = anchor.maxY - height
        }
        return min(max(wanted, margin), max(margin, bounds.height - height - margin))
    }

    /// What a callout hugs when its target asks for its row (`tallyTooltip(blocks:hugsRow:)`): the
    /// target's own columns, the row's top and bottom pulled in by `gap`, so the chip's edge lands
    /// ON the seam between two rows. A figure in a table row is shorter than the row, and a table's
    /// rows keep less padding than the callout's gap, so hugging the figure, or the row one gap off,
    /// still puts the chip's edge through the neighbouring row's last line (a table in a private
    /// build's panel section, B-907). No row published: the target itself.
    static func rowAnchor(target: CGRect, row: CGRect?, gap: CGFloat) -> CGRect {
        guard let row else { return target }
        let inset = min(gap, row.height / 2)
        return CGRect(x: target.minX, y: row.minY + inset, width: target.width, height: row.height - 2 * inset)
    }

    /// How far the chip's background reaches past its FAR edge (the top when it opens above the
    /// anchor, the bottom when it flips below) so that edge lands on the nearest seam instead of
    /// through a line of text: the near edge already sits on the row's seam (`rowAnchor`), but the
    /// far edge falls wherever the chip's own height puts it, which in that table was the
    /// column headings or the layout switch above them (B-907). Only the background grows; the
    /// content and the near edge stay put. No seam on that side within `limit` (one row): no stretch,
    /// since a longer reach would cover more of the table than the line it was meant to spare.
    static func farEdgeStretch(top: CGFloat, height: CGFloat, anchor: CGRect, seams: [CGFloat],
                               limit: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let opensUp = top + height <= anchor.minY + 0.5
        let far = opensUp ? top : top + height
        let reach = seams.map { opensUp ? far - $0 : $0 - far }.filter { $0 >= 0 }.min() ?? 0
        let stretch = reach <= limit ? reach : 0
        return opensUp ? (stretch, 0) : (0, stretch)
    }

    /// How far the content moves inside a stretched background so the stretch is shared above and
    /// below it (B-907 r5): a two-line GPU chip stretched to the seam above otherwise kept the whole
    /// stretch over its title. Both edges stay on their seams; only the content moves.
    static func contentShift(_ stretch: (top: CGFloat, bottom: CGFloat)) -> CGFloat {
        (stretch.bottom - stretch.top) / 2
    }
}
