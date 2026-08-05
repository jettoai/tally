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

// 6. Every resize moves at least one of the three remembered edges, so edges read before one are
//    stale after it. Under the top-leading rule the top is restored and the left never moves, which
//    leaves the bottom and the right somewhere new - and those two are exactly what a later
//    bottom-trailing pass anchors on.
let afterTopLeft = CGRect(origin: topLeft, size: grown.size)
let refreshed = ResizeAnchor.Edges(frame: afterTopLeft)
check("a top-leading resize leaves the bottom and the right edges somewhere new",
      near(refreshed.top, edges.top) && !near(refreshed.bottom, edges.bottom)
          && !near(refreshed.right, edges.right))
// Anchoring the next resize on the refreshed edges holds the shape that is actually on screen…
let next = CGRect(origin: afterTopLeft.origin, size: CGSize(width: 700, height: 700))
let freshAnchor = ResizeAnchor.origin(for: next, edges: refreshed, corner: .bottomTrailing)
check("bottom-trailing off refreshed edges holds the frame that is on screen",
      near(freshAnchor.y, afterTopLeft.minY) && near(freshAnchor.x + next.width, afterTopLeft.maxX))
// …where the pre-resize edges would have thrown it back to a shape two layouts old. That gap is
// the whole bug: the size change posts no move notification, so nothing else re-reads the edges.
let staleAnchor = ResizeAnchor.origin(for: next, edges: edges, corner: .bottomTrailing)
check("stale edges would have moved it somewhere else entirely",
      ResizeAnchor.needsMove(from: freshAnchor, to: staleAnchor))

// 7. The case a move notification can never cover: growing only in width under the top-leading
//    rule corrects to the origin the surface is already at, so no move is written and no move
//    notification fires - while the right edge, the one this resize did move, is now stale.
let wider = CGRect(x: 300, y: 200, width: 620, height: 500)
let widerTopLeft = ResizeAnchor.origin(for: wider, edges: edges, corner: .topLeading)
check("a width-only top-leading resize corrects to no move at all",
      !ResizeAnchor.needsMove(from: wider.origin, to: widerTopLeft))
check("…yet its right edge is no longer the one the anchor remembers",
      !near(ResizeAnchor.Edges(frame: wider).right, edges.right))

// 8. Which is a rule about the controllers, not about this arithmetic: both surfaces have to
//    re-read their edges when a RESIZE finishes, not only when a move does. Read off the source,
//    the way the login suite pins its chain, because AppKit windows cannot be driven from here.
for (name, path, host) in [("dashboard window", "Tally/MenuBar/MainWindowController.swift", ".window"),
                           ("pinned panel", "Tally/MenuBar/PinnedPanelController.swift", ".panel")] {
    let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    // The observer's closure, bounded by its own closing brace at the enclosing member's indent.
    guard let start = source.range(of: "forName: NSWindow.didResizeNotification"),
          let end = source.range(of: "\n        }\n", range: start.upperBound ..< source.endIndex)
    else {
        check("the \(name)'s resize observer was found to read", false)
        continue
    }
    let observer = String(source[start.upperBound ..< end.lowerBound])
    check("the \(name) re-reads its anchor edges when a resize finishes",
          observer.contains("anchorEdges = ") && observer.contains("resizeEdges"))
    // 9. And it asks about ITS OWN host. The menu-bar popover does not close the dashboard, so both
    //    surfaces can be up at once reading the same settings, and a question that only asked "is a
    //    card open somewhere" swapped the corner on the window the user was not even pointing at.
    //    The answer itself belongs to the store, so that the rule has one statement (see below).
    check("the \(name) asks the store for its own host's anchor",
          source.contains("SettingsStore.shared.resizeAnchor(for: \(host))"))
    check("…and does not decide the corner for itself",
          !source.contains("? .bottomTrailing"))
}
let settingsSource = (try? String(contentsOfFile: "Tally/Stores/SettingsStore.swift",
                                  encoding: .utf8)) ?? ""
// Closing is not symmetric with opening: one surface's card going away must not cancel an anchor
// another surface is still relying on, so a close only clears the slot it owns - and it drops the
// pointer claim with it, so a card that goes away cannot leave its corner behind.
check("a close clears the open flag only for the host that owns it",
      settingsSource.contains("if open { viewOptionsHost = host }")
          && settingsSource.contains(
              "else if viewOptionsHost == host { viewOptionsHost = nil; isPointerOnViewOptions = false }"))

// 10. The rule itself, and the reason this file exists at all: the bottom-right corner is claimed,
//     never inherited. Holding it needs BOTH the card being this host's AND the pointer being on
//     it; everything else in the surface - a project row, the tab switch, the range picker, a
//     provider heading, whatever is added next - gets the top left without having to ask for it.
//
//     The previous shape was the other way round (the card being open was enough, and each reading
//     control had to opt out) and it was wrong for three of them at once: with the card open, the
//     tab switch moved the whole surface 32pt (measured 2026-08-05). A rule the open set has to opt
//     out of is a rule that is wrong for whichever member was written last.
guard let ruleStart = settingsSource.range(of: "func resizeAnchor(for host: SurfaceHost)"),
      let ruleEnd = settingsSource.range(of: "\n    }\n", range: ruleStart.upperBound ..< settingsSource.endIndex)
else {
    check("the anchor rule was found to read", false)
    exit(1)
}
let rule = String(settingsSource[ruleStart.upperBound ..< ruleEnd.lowerBound])
check("the anchor rule needs the card to be this host's AND the pointer to be on it",
      rule.contains("viewOptionsHost == host && isPointerOnViewOptions ? .bottomTrailing"))
check("…and everything else gets the top left",
      rule.contains(": .topLeading"))

// 11. And the claim has exactly one claimant. If any view other than the card could report the
//     pointer, the open set would be back: something in the reading region could hold the card's
//     corner without anyone noticing until a surface jumped.
let viewFiles = (try? FileManager.default.contentsOfDirectory(atPath: "Tally/Views")) ?? []
let claimants = viewFiles.filter { file in
    guard file.hasSuffix(".swift") else { return false }
    let text = (try? String(contentsOfFile: "Tally/Views/\(file)", encoding: .utf8)) ?? ""
    return text.contains("viewOptionsPointer(inside:")
}
check("only the view-options card itself claims the anchor (found: \(claimants))",
      claimants == ["PopoverFooterView.swift"])

print(failures == 0 ? "\nAll window anchor tests passed." : "\n\(failures) anchor test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
