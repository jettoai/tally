import CoreGraphics
import Foundation

// Assertion harness for the resize anchor's geometry (Tally/Core/ResizeAnchor.swift), compiled
// against the real source. The whole change is origin arithmetic in AppKit's bottom-left origin
// space, which is exactly the part that can be wrong without anything failing to build.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}
func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.001) -> Bool { abs(a - b) < tol }

// A surface sitting at x 300...800, y 200...700 (500 x 500).
let before = CGRect(x: 300, y: 200, width: 500, height: 500)
let edges = ResizeAnchor.Edges(frame: before)
check("edges read the three screen edges a resize can move",
      near(edges.top, 700) && near(edges.bottom, 200) && near(edges.right, 800))

// AppKit resizes a content-driven window about its BOTTOM edge, so both post-resize frames below
// keep origin.y and grow upward or shrink downward from it. That is the raw frame the anchor
// corrects.

// 1. Taller and wider (density switched to something bigger): the top-leading rule holds the header
//    still, so the surface has to run DOWN the screen - origin.y drops by the height change, and
//    origin.x is left where it is.
let grown = CGRect(x: 300, y: 200, width: 620, height: 640)
let topLeft = ResizeAnchor.origin(for: grown, edges: edges, corner: .topLeading)
check("top-leading keeps the top edge", near(topLeft.y + grown.height, edges.top))
check("top-leading never moves the left edge", near(topLeft.x, before.origin.x))

// 2. The same growth with the view-options card open: the bottom edge does not move at all and the
//    right edge is held, so the surface grows up and to the left - which is what keeps the card's
//    controls under the pointer.
let bottomRight = ResizeAnchor.origin(for: grown, edges: edges, corner: .bottomTrailing)
check("bottom-trailing leaves origin.y alone", near(bottomRight.y, before.origin.y))
check("bottom-trailing holds the right edge", near(bottomRight.x + grown.width, edges.right))
check("…which means the width change comes off origin.x",
      near(bottomRight.x, before.origin.x - (grown.width - before.width)))
check("and the surface grows upward, not downward",
      bottomRight.y + grown.height > before.maxY)

// 3. Shrinking (fewer columns) is the same rule read backwards: the right edge still does not move,
//    so origin.x travels right by the width lost.
let shrunk = CGRect(x: 300, y: 200, width: 380, height: 300)
let shrunkAnchor = ResizeAnchor.origin(for: shrunk, edges: edges, corner: .bottomTrailing)
check("a narrower surface keeps its right edge too",
      near(shrunkAnchor.x + shrunk.width, edges.right) && near(shrunkAnchor.y, before.origin.y))
check("a shorter surface still sits on the same bottom edge",
      near(shrunkAnchor.y, edges.bottom))

// 4. A resize that changed nothing must not produce a move: the correction runs on every resize
//    notification, and writing a sub-point origin back would fire a move notification each pass
//    (which is what re-reads the edges, so it would also be self-feeding).
let same = ResizeAnchor.origin(for: before, edges: edges, corner: .bottomTrailing)
check("an unchanged frame corrects to where it already is",
      !ResizeAnchor.needsMove(from: before.origin, to: same))
let sameTop = ResizeAnchor.origin(for: before, edges: edges, corner: .topLeading)
check("…under either corner", !ResizeAnchor.needsMove(from: before.origin, to: sameTop))
check("sub-point drift is rounding, not a move",
      !ResizeAnchor.needsMove(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 300.4, y: 199.7)))
check("a real difference is a move",
      ResizeAnchor.needsMove(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 288, y: 200)))

// 5. Applying the correction twice is a no-op: the anchor is re-read at every move, and the move
//    the correction itself makes must not walk the surface across the screen.
let corrected = CGRect(origin: bottomRight, size: grown.size)
let again = ResizeAnchor.origin(for: corrected, edges: ResizeAnchor.Edges(frame: corrected),
                                corner: .bottomTrailing)
check("correcting an already-corrected frame moves nothing",
      !ResizeAnchor.needsMove(from: corrected.origin, to: again))

print(failures == 0 ? "\nAll window anchor tests passed." : "\n\(failures) anchor test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
