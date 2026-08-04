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
}
