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

// 8. Which is a rule about the surfaces, not about this arithmetic: the edges have to be re-read
//    when a RESIZE finishes, not only when a move does. Read off the source, the way the login
//    suite pins its chain, because AppKit windows cannot be driven from here.
//
//    Assertions from here down match CODE, never comments. The version of this suite that matched
//    raw source went green on a doc comment that merely MENTIONED the rule while the statement
//    itself had moved to another file (2026-08-05, caught by this migration).
func code(of path: String) -> String {
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        // Only a `//` outside a string literal starts a comment.
        var quotes = 0
        for index in line.indices {
            if line[index] == "\"" { quotes += 1 }
            if quotes % 2 == 0, line[index] == "/", line.index(after: index) < line.endIndex,
               line[line.index(after: index)] == "/" {
                return line[..<index]
            }
        }
        return line
    }.joined(separator: "\n")
}

// THE STATUS ITEM CONTROLLER IS THREE FILES (2026-08-15) AND IS READ AS ONE, here rather than in
// either section, because BOTH of them make claims about it and a union built twice is a union that
// can be built differently twice - which is the same failure one file down.
//
// Everything either section says with "and nowhere else" - the placement-correction machinery that
// is gone, the popover window this file no longer moves, the single site the follow rule is asked
// at, the one place the foreground is taken - is a claim about the CONTROLLER, not about a
// filename. Splitting a file is exactly how such a claim goes green while the statement it forbids
// lives on next door, so the split is absorbed here: the union is what the assertions read, and
// each part of it has to be readable or the negatives would pass by having nothing to look at.
let statusControllerFiles = ["Tally/MenuBar/StatusItemController.swift",
                             "Tally/MenuBar/StatusItemButton.swift",
                             "Tally/MenuBar/StatusItemCommands.swift"]
check("all three of the controller's files were found to read (\(statusControllerFiles.count))",
      statusControllerFiles.allSatisfy { !code(of: $0).isEmpty })
let statusControllerSource = statusControllerFiles.map { code(of: $0) }.joined(separator: "\n")

let sizerSource = code(of: "Tally/MenuBar/SurfaceSizer.swift")
guard let observerStart = sizerSource.range(of: "forName: NSWindow.didResizeNotification"),
      let observerEnd = sizerSource.range(of: "\n        }\n",
                                          range: observerStart.upperBound ..< sizerSource.endIndex)
else {
    check("the shared sizing contract's resize observer was found to read", false)
    exit(1)
}
let observer = String(sizerSource[observerStart.upperBound ..< observerEnd.lowerBound])
check("a finished resize re-reads the edges the next one anchors against",
      observer.contains("anchorEdges = ") && observer.contains("resizeEdges"))
// 9. And it asks about ITS OWN host. The menu-bar popover does not close the dashboard, so both
//    surfaces can be up at once reading the same settings, and a question that only asked "is a
//    card open somewhere" swapped the corner on the window the user was not even pointing at.
//    The answer itself belongs to the store, so that the rule has one statement (see below).
check("the sizing contract asks the store for its host's anchor",
      sizerSource.contains("SettingsStore.shared.resizeAnchor(for: host)"))
check("…and does not decide the corner for itself",
      !sizerSource.contains("? .bottomTrailing"))

// 9b. There is exactly ONE implementation of that contract. The panel and the dashboard window each
//     drove their own copy of this plumbing until 2026-08-05, and the window's copy was the one
//     that never got `sizingOptions = []` - so it could not take the anchored-transition fix, and
//     41 of 54 scripted triggers moved the page under the reader. A controller that states any of
//     it again has forked the invariant, which in this file's history is how invariants die.
for (name, path, host) in [("dashboard window", "Tally/MenuBar/MainWindowController.swift", "window"),
                           ("pinned panel", "Tally/MenuBar/PinnedPanelController.swift", "panel")] {
    let source = code(of: path)
    check("the \(name) hands its size to the shared contract, for its own host",
          source.contains("SurfaceSizer(window:") && source.contains("host: .\(host)")
              && source.contains("onContentSize: sizer.onContentSize"))
    for forked in ["sizingOptions", "ResizeAnchor.origin", "didResizeNotification", "setFrame(",
                   "setContentSize", "setFrameAutosaveName"] {
        check("…and does not state `\(forked)` for itself", !source.contains(forked))
    }
}

// 9c. The dashboard window is the one surface with a titlebar the user could drag a size out of,
//     and it deliberately offers none: a drag would be a second size authority, and the next
//     content report would write the dragged size straight back out (measured: a frame widened by
//     200pt behind the content's back came back to the content's width on the next report, holding
//     the top edge). The zoom button follows the same mask, so it is inert for the same reason.
let windowSource = code(of: "Tally/MenuBar/MainWindowController.swift")
check("the dashboard window offers no size of its own to drag",
      windowSource.contains("styleMask: [.titled, .closable, .miniaturizable]")
          && !windowSource.contains(".resizable"))

// 9d. And it is never SHOWN at a size nobody has measured. The synchronous flush in `show` usually
//     settles the size before anything is on screen, but the report goes through a SwiftUI update
//     and can be a run-loop turn behind - measured with that turn injected (2026-08-05, found by
//     review): the window appeared opaque at the 500x400 placeholder on the wrong display and then
//     jumped 3076pt. So it comes up transparent and is revealed by the pass that sizes it.
//
//     The two halves are asserted as a PAIR because either one alone is a bug, in opposite
//     directions: hiding without queueing the reveal is a window that never appears at all, and
//     queueing without hiding is the flash this exists to remove.
check("a window being opened is hidden until it has been measured",
      windowSource.contains("window?.alphaValue = 0"))
check("…and the same pass that sizes it is what reveals it",
      windowSource.contains("sizer?.whenSized { $0.alphaValue = 1 }"))
//     Ordering it front is NOT conditional on any of that, and that is load-bearing: an unordered
//     window is not laid out, and the measurement being waited for is a product of that layout, so
//     holding the order back would wait for something only ordering can produce.
check("…and it is ordered front regardless, because that is what gets it laid out",
      windowSource.contains("window?.makeKeyAndOrderFront(nil)")
          && !windowSource.contains("whenSized { $0.makeKeyAndOrderFront"))

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

// 10b. And a host that does not place itself by this rule at all cannot be told a corner. The
//      popover is attached to the status item's arrow by AppKit and `applyPopoverSize` only ever
//      writes a content size, so answering "bottom right" for it would have the surface wait
//      against an edge nothing keeps still. Found by review after the first fix shipped it
//      (2026-08-05); the switch is exhaustive so a fourth surface has to answer for itself.
guard let popoverCase = rule.range(of: "case .popover:") else {
    check("the rule answers for the popover explicitly", false)
    exit(1)
}
let afterPopover = rule[popoverCase.upperBound...]
let popoverAnswer = afterPopover.range(of: "case .panel").map { String(afterPopover[..<$0.lowerBound]) }
    ?? String(afterPopover)
check("the popover is never told a resize will hold a corner it does not implement",
      popoverAnswer.contains(".topLeading") && !popoverAnswer.contains("bottomTrailing"))
check("…and it says so on its own, not by sharing a case with a host that does place itself",
      !rule.contains("case .popover, ") && !rule.contains(", .popover"))

// 10b. THE PICK PANEL HOLDS ITS TOP EDGE, and it is the one surface here that does so from inside
//      its own `setFrame` rather than through the shared sizing contract: it is sized by
//      `sizingOptions` (one authority, and the only one), so there is no resize notification to
//      answer and nothing here may write a size back. What it corrects is the ORIGIN of a frame
//      AppKit has already decided, in the one case that has an origin worth correcting.
//
//      WHY IT HOLDS ANYTHING AT ALL: the apply bar appears under the columns when a row is circled
//      (`pickApplyBlockHeight`), and AppKit holding the bottom-left origin would push every row up
//      by that much - out from under the pointer that had just circled one.
check("a taller frame keeps the top edge, so the surface grows downward",
      near(ResizeAnchor.origin(for: grown, edges: edges, corner: .topLeading).y + grown.height,
           edges.top))
check("…and a height change is what tells a resize from a drag",
      ResizeAnchor.changesHeight(from: CGSize(width: 400, height: 300),
                                 to: CGSize(width: 400, height: 336)))
check("…a move of the same window is not one",
      !ResizeAnchor.changesHeight(from: CGSize(width: 400, height: 300),
                                  to: CGSize(width: 400, height: 300)))
check("…nor is sub-point rounding, which would move a window for nothing",
      !ResizeAnchor.changesHeight(from: CGSize(width: 400, height: 300),
                                  to: CGSize(width: 400, height: 300.4)))
// A width-only write is a move as far as this edge is concerned: the edge being held is horizontal,
// and the left one is where it was already (`ResizeAnchor.origin`).
check("…and a change of width alone leaves the held edge nothing to do",
      !ResizeAnchor.changesHeight(from: CGSize(width: 400, height: 300),
                                  to: CGSize(width: 480, height: 300)))
let pickSource = code(of: "Tally/MenuBar/PickPanelController.swift")
check("the pick panel holds that edge through its own frame writes",
      pickSource.contains("guard keepsTopEdge, ResizeAnchor.changesHeight(from: frame.size, "
          + "to: frameRect.size) else {")
          && pickSource.contains(
              "held.origin = ResizeAnchor.origin(for: frameRect, edges: resizeEdges, "
              + "corner: .topLeading)"))
// The size is AppKit's, passed through: a panel that wrote one back would be the two-authorities
// crash this repo has already paid for once (~/.claude/docs/patterns/swiftui-appkit.md).
check("…rewriting the origin only, never the size",
      pickSource.contains("var held = frameRect") && !pickSource.contains("held.size")
          && !pickSource.contains("setContentSize"))
// AND BACK ON SCREEN AFTERWARDS, which is the other half of holding a top edge: the panel is
// draggable, so it can be sitting on the bottom edge of the display when the apply bar adds its 36pt
// (`pickApplyBlockHeight`) and pushes the Apply button off the screen. The shared sizing contract
// does this after every content-driven resize (`clampOnScreen`, and its own comment says why), and
// this is the one surface that resizes inside its own `setFrame` rather than through that contract -
// so it is the one place that has to call it itself.
let heldWrite = pickSource.range(of: "super.setFrame(held, display: displays)")
check("…and the grown panel is put back on the screen it grew off",
      heldWrite.map { pickSource[$0.upperBound...].contains("clampOnScreen()") } ?? false)
// Origin only, so the clamp cannot become a second size authority, and bounded: the frame write it
// makes keeps the height, which is the pass-through branch above rather than another corner to hold.
check("…through the shared origin-only clamp, not a frame write of its own",
      code(of: "Tally/Core/WindowPlacement.swift")
          .contains("if origin != frame.origin { setFrameOrigin(origin) }"))
check("…and its one size authority is still the hosting view's own option",
      pickSource.contains("hosting.sizingOptions = [.intrinsicContentSize]"))
// Armed after the placement, because everything before it is the panel getting its first size from
// the zero rect it was created with - held from that, it would anchor to the bottom of the screen.
// Read as an ORDER rather than as adjacent lines: what matters is that the placement has happened
// first, and a comment between the two is not a change of behaviour.
let armedAfterPlacement = pickSource.range(of: "panel.centerOnPointerScreen()").flatMap { placed in
    pickSource.range(of: "panel.keepsTopEdge = true").map { placed.upperBound <= $0.lowerBound }
} ?? false
check("…armed only once the panel has been placed, and off until then",
      pickSource.contains("var keepsTopEdge = false") && armedAfterPlacement)

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

checkPopoverAnchor()
checkPanelSummon()

print(failures == 0 ? "\nAll window anchor tests passed." : "\n\(failures) anchor test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
