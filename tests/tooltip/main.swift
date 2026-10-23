import CoreGraphics
import Foundation

// Assertion harness for the hover callout's placement (Tally/Core/TooltipPlacement.swift), compiled
// against the real source. Where a callout lands is the half of a tooltip that is wrong on screen
// while everything still builds, draws and passes - so the rule it follows is pinned here.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}
func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.001) -> Bool { abs(a - b) < tol }

// The app's own numbers (TallyTooltip.gap / .margin) and a single-column pinned panel.
let gap: CGFloat = 6
let margin: CGFloat = 6
let panel = CGSize(width: 380, height: 620)

// MARK: - hugging the target, both ways up

// A row in the middle of the panel: there is room above, which is the standing choice.
let midRow = CGRect(x: 12, y: 300, width: 356, height: 24)
let chip = CGSize(width: 256, height: 62)
let aboveY = TooltipPlacement.originY(height: chip.height, anchor: midRow, bounds: panel,
                                      gap: gap, margin: margin)
check("above the target, the chip's bottom sits exactly one gap off its top edge",
      near(aboveY + chip.height, midRow.minY - gap))

// A row at the top of the panel (the fleet gauge's own case): no room above, so it flips below and
// hugs the target's OWN bottom edge - not the bottom of whatever container the target sits in.
let topRow = CGRect(x: 12, y: 56, width: 356, height: 40)
let belowY = TooltipPlacement.originY(height: chip.height, anchor: topRow, bounds: panel,
                                      gap: gap, margin: margin)
check("with no room above, the chip flips below and hugs the target's bottom edge",
      near(belowY, topRow.maxY + gap))
check("…and the flip is what a chip too tall to fit above takes",
      topRow.minY - gap - chip.height < margin)

// THE BUG this file was written for (fleet strip, 2026-08-04): the hover belonged to the whole
// strip - both providers' rows plus the band's 8pt padding - so the flip measured from the BAND's
// bottom and the callout landed a band's height below the row the pointer was on, over the cards.
// The arithmetic was never wrong; the target was. Both readings are pinned so the penalty a
// broadened target carries is a number rather than an impression.
let wholeStrip = CGRect(x: 0, y: 48, width: 380, height: 112)
let stripY = TooltipPlacement.originY(height: chip.height, anchor: wholeStrip, bounds: panel,
                                      gap: gap, margin: margin)
check("a strip-sized target puts the same chip 64pt lower than the row inside it does",
      near(stripY - belowY, wholeStrip.maxY - topRow.maxY) && near(stripY - belowY, 64))
check("the row-sized target is the one that keeps the chip one gap from what was hovered",
      near(belowY - topRow.maxY, gap) && stripY - topRow.maxY > gap)

// MARK: - the surface's own edges

// A short surface (a fleet folded down to its gauges) where the target has room on neither side:
// the clamp holds the chip inside the surface, which is the ONLY case allowed to land anywhere but
// one gap from the target.
let shortPanel = CGSize(width: 380, height: 120)
let squeezed = CGRect(x: 12, y: 60, width: 356, height: 40)
let clampedY = TooltipPlacement.originY(height: chip.height, anchor: squeezed, bounds: shortPanel,
                                        gap: gap, margin: margin)
check("a chip that would run off the bottom is held inside the surface",
      near(clampedY + chip.height, shortPanel.height - margin) && clampedY < squeezed.maxY + gap)
// The same target on the full-height panel: above fits, so it is taken outright and the clamp is
// never reached. The clamp is a last resort, not a second placement.
let bottomRow = CGRect(x: 12, y: 590, width: 356, height: 24)
check("…and above still wins outright whenever it fits, so the clamp is the last resort",
      near(TooltipPlacement.originY(height: chip.height, anchor: bottomRow, bounds: panel,
                                    gap: gap, margin: margin) + chip.height, bottomRow.minY - gap))

// A surface shorter than the chip itself (a fleet folded down to nothing): the chip is pinned to
// the top margin rather than pushed off the surface entirely.
let tiny = CGSize(width: 380, height: 40)
check("a chip taller than the whole surface still starts at the top margin",
      near(TooltipPlacement.originY(height: chip.height, anchor: CGRect(x: 0, y: 0, width: 380,
                                                                       height: 20),
                                    bounds: tiny, gap: gap, margin: margin), margin))

// MARK: - across the target

check("the chip is centred on the target",
      near(TooltipPlacement.originX(width: chip.width, anchor: midRow, bounds: panel,
                                    margin: margin),
           midRow.midX - chip.width / 2))
// A narrow target at either edge: centring alone would hang the chip off the surface.
let leftEdge = CGRect(x: 6, y: 300, width: 40, height: 20)
check("a target at the leading edge holds the chip inside the margin",
      near(TooltipPlacement.originX(width: chip.width, anchor: leftEdge, bounds: panel,
                                    margin: margin), margin))
let rightEdge = CGRect(x: 334, y: 300, width: 40, height: 20)
check("a target at the trailing edge holds the chip off the far margin",
      near(TooltipPlacement.originX(width: chip.width, anchor: rightEdge, bounds: panel,
                                    margin: margin), panel.width - chip.width - margin))
// A chip wider than the surface has no inside to be held to: it starts at the near margin rather
// than at a negative origin, which would clip its leading end (the end a path is read from).
check("a chip wider than the surface still starts at the near margin",
      near(TooltipPlacement.originX(width: 500, anchor: midRow, bounds: panel, margin: margin),
           margin))

// A figure in a table row hugs the row (B-907): the chip's edge lands on the seam between this row
// and the next, not one gap above the figure (inside the row above) nor one gap above the row (still
// inside the row above's last line, since a table row keeps less padding than the gap).
let figure = CGRect(x: 200, y: 343, width: 50, height: 26)
let tableRow = CGRect(x: 10, y: 337, width: 360, height: 34)
let hugged = TooltipPlacement.rowAnchor(target: figure, row: tableRow, gap: gap)
check("a row anchor keeps the figure's own columns, so the chip stays centred on the figure",
      near(hugged.minX, 200) && near(hugged.width, 50))
check("…puts the chip's bottom exactly on the row's top edge",
      near(TooltipPlacement.originY(height: chip.height, anchor: hugged, bounds: panel, gap: gap,
                                    margin: margin) + chip.height, 337))
check("…and, flipped below a row near the top, the chip's top exactly on the row's bottom edge",
      near(TooltipPlacement.originY(height: chip.height,
                                    anchor: TooltipPlacement.rowAnchor(target: CGRect(x: 200, y: 26, width: 50, height: 26),
                                                                       row: CGRect(x: 10, y: 20, width: 360, height: 34), gap: gap),
                                    bounds: panel, gap: gap, margin: margin), 54))
check("a row thinner than two gaps collapses to its middle line rather than inverting",
      TooltipPlacement.rowAnchor(target: figure, row: CGRect(x: 10, y: 337, width: 360, height: 8), gap: gap).height >= 0)
check("no row published leaves the target as it was",
      TooltipPlacement.rowAnchor(target: figure, row: nil, gap: gap) == figure)

// The far edge reaches the nearest seam (B-907): a chip whose top lands inside the column
// headings stretches its background up to the headings' top edge, not through them.
let up = CGRect(x: 200, y: 340, width: 50, height: 20)          // anchor: chip opens above it
let seams: [CGFloat] = [250, 270, 300, 334]                     // headings 250..270, a row 300..334
check("opening up, the top edge stretches to the nearest seam above it",
      TooltipPlacement.farEdgeStretch(top: 262, height: 72, anchor: up, seams: seams, limit: 34) == (12, 0))
check("…not at all when the top already sits on a seam",
      TooltipPlacement.farEdgeStretch(top: 270, height: 64, anchor: up, seams: seams, limit: 34) == (0, 0))
check("…not at all when no seam was published",
      TooltipPlacement.farEdgeStretch(top: 262, height: 72, anchor: up, seams: [], limit: 34) == (0, 0))
check("…and not at all when the nearest seam is more than a row away",
      TooltipPlacement.farEdgeStretch(top: 240, height: 94, anchor: up, seams: [200], limit: 34) == (0, 0))
let down = CGRect(x: 200, y: 20, width: 50, height: 20)         // chip flipped below it
check("flipped below, the bottom edge stretches down to the nearest seam below it",
      TooltipPlacement.farEdgeStretch(top: 46, height: 60, anchor: down, seams: [40, 110, 140], limit: 34) == (0, 4))
check("the content moves half the stretch toward it: up when the top stretched, down when the bottom did",
      TooltipPlacement.contentShift((12, 0)) == -6 && TooltipPlacement.contentShift((0, 4)) == 2
      && TooltipPlacement.contentShift((0, 0)) == 0)

// Beside the target (a settings row label, B-2649): the chip sits right of the label, centred on it,
// and only where it touches no other label or control of the card.
let label = CGRect(x: 56, y: 100, width: 140, height: 40)              // the hovered row's label
let rowAbove = CGRect(x: 56, y: 40, width: 300, height: 44)            // a wider subtitle above
let rowBelow = CGRect(x: 56, y: 156, width: 300, height: 44)
let toggles = [CGRect(x: 640, y: 50, width: 40, height: 24), CGRect(x: 640, y: 108, width: 40, height: 24)]
let card = CGSize(width: 730, height: 400)
let obstacles = [label, rowAbove, rowBelow] + toggles
let short = TooltipPlacement.besideSlot(anchor: label, obstacles: obstacles, bounds: card, gap: gap,
                                        margin: margin, widths: [316, 210, 120], height: { _ in 30 })
check("a short chip sits one gap right of the label at the widest width",
      short?.x == label.maxX + gap && short?.width == 316)
let tall = TooltipPlacement.besideSlot(anchor: label, obstacles: obstacles, bounds: card, gap: gap,
                                       margin: margin, widths: [316, 210, 120], height: { _ in 110 })
check("a chip taller than its row jumps past the neighbours' text and narrows to fit before the controls",
      tall != nil && tall!.x > rowAbove.maxX && tall!.x + tall!.width < toggles[0].minX)
check("a slot is only ever clear of every other obstacle",
      [short, tall].compactMap { $0 }.allSatisfy { slot in
          let h: CGFloat = slot.width == 316 ? 30 : 110
          let rect = CGRect(x: slot.x, y: TooltipPlacement.besideY(height: h, anchor: label, bounds: card, margin: margin),
                            width: slot.width, height: h)
          return !(obstacles.dropFirst().contains { $0.intersects(rect) })
      })
check("no clear slot gives nil, so the caller hugs the target",
      TooltipPlacement.besideSlot(anchor: label, obstacles: obstacles, bounds: card, gap: gap,
                                  margin: margin, widths: [316], height: { _ in 110 }) == nil)

// The title line is the anchor, the label around it holds the description (B-2649 r4): the hovered
// row's own description is not an obstacle (the chip may cover it), a neighbouring row's still is.
let title = CGRect(x: 56, y: 100, width: 140, height: 20)
let ownLabel = CGRect(x: 56, y: 100, width: 300, height: 44)           // wider description under the title
let neighbours = [CGRect(x: 56, y: 40, width: 300, height: 44), CGRect(x: 56, y: 150, width: 300, height: 44)]
let hung = TooltipPlacement.besideSlot(anchor: title, obstacles: [ownLabel] + neighbours, bounds: card, gap: gap,
                                       margin: margin, widths: [316], height: { _ in 40 })
check("a long chip hangs one gap right of the title even when its own description is wider",
      hung?.x == title.maxX + gap && hung?.width == 316)
let blocked = TooltipPlacement.besideSlot(anchor: title, obstacles: [ownLabel] + neighbours, bounds: card, gap: gap,
                                          margin: margin, widths: [316], height: { _ in 110 })
check("a chip too tall for the gap between neighbouring rows' text is pushed past them, never over them",
      blocked.map { $0.x > neighbours[0].maxX } ?? false)

print(failures == 0 ? "\nAll tooltip placement assertions passed."
                    : "\n\(failures) assertion(s) failed.")
exit(failures == 0 ? 0 : 1)
