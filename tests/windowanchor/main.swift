import CoreGraphics
import Foundation

// Assertion harness for the resize anchor's geometry (Tally/Core/ResizeAnchor.swift) and for where
// the view-options card stands (Tally/Core/ViewOptionsCardPlacement.swift), compiled against the
// real sources. Both are origin arithmetic in AppKit's bottom-left origin space, which is exactly
// the part that can be wrong without anything failing to build.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}
func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.001) -> Bool { abs(a - b) < tol }

// A surface sitting at x 300...800, y 200...700 (500 x 500).
let before = CGRect(x: 300, y: 200, width: 500, height: 500)
let topEdge = before.maxY
check("the edge a resize has to put back is the surface's top", near(topEdge, 700))

// AppKit resizes a content-driven window about its BOTTOM edge, so both post-resize frames below
// keep origin.y and grow upward or shrink downward from it. That is the raw frame the anchor
// corrects.

// 1. Taller and wider (density switched to something bigger): the surface has to run DOWN the
//    screen - origin.y drops by the height change - and origin.x is left where it is.
let grown = CGRect(x: 300, y: 200, width: 620, height: 640)
let held = ResizeAnchor.origin(for: grown, topEdge: topEdge)
check("the top edge is what stays still", near(held.y + grown.height, topEdge))
check("…and the left edge is never moved", near(held.x, before.origin.x))
check("so a surface that grew runs down the screen", held.y < before.origin.y)

// 2. Shrinking (fewer columns) is the same rule read backwards: the header stays where the reader
//    put it and the surface gives up the height at its bottom.
let shrunk = CGRect(x: 300, y: 200, width: 380, height: 300)
let shrunkHeld = ResizeAnchor.origin(for: shrunk, topEdge: topEdge)
check("a shorter surface keeps its top edge too", near(shrunkHeld.y + shrunk.height, topEdge))
check("…and gives up the height at the bottom", shrunkHeld.y > before.origin.y)
// A width-only change corrects to no move at all, which is why nothing here needs a left edge as an
// argument: a content resize cannot move origin.x.
let wider = CGRect(x: 300, y: 200, width: 620, height: 500)
check("a width-only resize corrects to where the surface already is",
      !ResizeAnchor.needsMove(from: wider.origin,
                              to: ResizeAnchor.origin(for: wider, topEdge: topEdge)))

// 3. A resize that changed nothing must not produce a move: the correction runs on every resize,
//    and writing a sub-point origin back would fire a move notification each pass.
check("an unchanged frame corrects to where it already is",
      !ResizeAnchor.needsMove(from: before.origin,
                              to: ResizeAnchor.origin(for: before, topEdge: topEdge)))
check("sub-point drift is rounding, not a move",
      !ResizeAnchor.needsMove(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 300.4, y: 199.7)))
check("a real difference is a move",
      ResizeAnchor.needsMove(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 288, y: 200)))

// 4. Applying the correction twice is a no-op: the surface has to be able to settle.
let corrected = CGRect(origin: held, size: grown.size)
check("correcting an already-corrected frame moves nothing",
      !ResizeAnchor.needsMove(from: corrected.origin,
                              to: ResizeAnchor.origin(for: corrected, topEdge: corrected.maxY)))

// 5. A size difference worth acting on, and a height change worth telling from a drag.
check("a height change is what tells a resize from a drag",
      ResizeAnchor.changesHeight(from: CGSize(width: 400, height: 300),
                                 to: CGSize(width: 400, height: 336)))
check("…a move of the same window is not one",
      !ResizeAnchor.changesHeight(from: CGSize(width: 400, height: 300),
                                  to: CGSize(width: 400, height: 300)))
check("…nor is sub-point rounding, which would move a window for nothing",
      !ResizeAnchor.changesHeight(from: CGSize(width: 400, height: 300),
                                  to: CGSize(width: 400, height: 300.4)))
check("…and a change of width alone leaves the held edge nothing to do",
      !ResizeAnchor.changesHeight(from: CGSize(width: 400, height: 300),
                                  to: CGSize(width: 480, height: 300)))

// 6. Which is a rule about the surfaces, not about this arithmetic: the correction has to be applied
//    where the resize happens. Read off the source, the way the login suite pins its chain, because
//    AppKit windows cannot be driven from here.
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
check("a finished resize puts the surface back on a screen",
      observer.contains("window.clampOnScreen()"))
// EXACTLY ONE frame write in the whole contract, and it is the content resize. This is the shape of
// the change that retired the card's debt: the put-back that used to move the surface when the card
// closed was a second write, made from a remembered position, and BOTH halves of it were visible on
// screen. A count rather than an absence, so the write that must exist still has to be there.
check("the sizing contract writes exactly one frame, and it is the resize",
      sizerSource.components(separatedBy: "window.setFrame(").count - 1 == 1
          && !sizerSource.contains("setFrameOrigin"))
check("…which holds the top edge it read off the window in the same breath",
      sizerSource.contains("let topEdge = frame.maxY")
          && sizerSource.contains("ResizeAnchor.origin(for: frame, topEdge: topEdge)"))
// And nothing is remembered between resizes. A stored position is what a second corner needs, and
// what a second corner produced was a surface that moved twice per card (see section 8).
check("…and remembers no position between resizes",
      !sizerSource.contains("anchorEdges") && !sizerSource.contains("didMoveNotification"))

// 7. There is exactly ONE implementation of that contract. The panel and the dashboard window each
//    drove their own copy of this plumbing until 2026-08-05, and the window's copy was the one
//    that never got `sizingOptions = []` - so it could not take the anchored-transition fix, and
//    41 of 54 scripted triggers moved the page under the reader. A controller that states any of
//    it again has forked the invariant, which in this file's history is how invariants die.
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

// 7b. The dashboard window is the one surface with a titlebar the user could drag a size out of,
//     and it deliberately offers none: a drag would be a second size authority, and the next
//     content report would write the dragged size straight back out (measured: a frame widened by
//     200pt behind the content's back came back to the content's width on the next report, holding
//     the top edge). The zoom button follows the same mask, so it is inert for the same reason.
let windowSource = code(of: "Tally/MenuBar/MainWindowController.swift")
check("the dashboard window offers no size of its own to drag",
      windowSource.contains("styleMask: [.titled, .closable, .miniaturizable]")
          && !windowSource.contains(".resizable"))

// 7c. And it is never SHOWN at a size nobody has measured. The synchronous flush in `show` usually
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

// 7d. THE PICK PANEL HOLDS ITS TOP EDGE TOO, and it is the one surface here that does so from inside
//     its own `setFrame` rather than through the shared sizing contract: it is sized by
//     `sizingOptions` (one authority, and the only one), so there is no resize notification to
//     answer and nothing here may write a size back. What it corrects is the ORIGIN of a frame
//     AppKit has already decided, in the one case that has an origin worth correcting.
//
//     WHY IT HOLDS ANYTHING AT ALL: the apply bar appears under the columns when a row is circled
//     (`pickApplyBlockHeight`), and AppKit holding the bottom-left origin would push every row up
//     by that much - out from under the pointer that had just circled one.
let pickSource = code(of: "Tally/MenuBar/PickPanelController.swift")
check("the pick panel holds that edge through its own frame writes",
      pickSource.contains("guard keepsTopEdge, ResizeAnchor.changesHeight(from: frame.size, "
          + "to: frameRect.size) else {")
          && pickSource.contains(
              "held.origin = ResizeAnchor.origin(for: frameRect, topEdge: frame.maxY)"))
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

// 8. ONE ANCHOR, FOR EVERYTHING, AND NOTHING MAY CLAIM ANOTHER.
//
//    The rule used to be conditional: the view-options card held the surface's BOTTOM RIGHT while
//    the pointer was on it, so a tile click kept the tile still by walking the panel 333pt down the
//    display, and closing the card jumped it back. Equal and opposite, so it cancelled on paper -
//    and both halves were the panel moving, which is what was reported three times (Albert,
//    2026-08-17). The card is a window of its own now (`ViewOptionsCardPlacement`), so nothing has
//    to move for it, and this asserts that the machinery for a second corner is GONE rather than
//    merely unused: an unused corner is a rule the next reader will find and follow.
//
//    Over every source in the app, enumerated rather than sampled: a name checked in the two files
//    that used to hold it would go green the moment somebody put it in a third.
let appSources: [String] = {
    let root = "Tally"
    guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
    return walker.compactMap { $0 as? String }
        .filter { $0.hasSuffix(".swift") }
        .map { "\(root)/\($0)" }
}()
check("every source in the app was found to read (\(appSources.count))", appSources.count > 40)
//    The names are the machinery's, not SwiftUI's: `.bottomTrailing` on its own is an alignment and
//    says nothing about a window's anchor (`MenuBarStrip` uses one), so what is banned is the corner
//    ARGUMENT and the bookkeeping a second corner needed.
for banned in ["ResizeAnchor.Corner", "ResizeAnchor.Edges", "ResizeAnchor.Hold", "corner: .",
               "resizeAnchor(", "restoreAnchor", "restitution", "cardEdges",
               "isPointerOnViewOptions", "viewOptionsHost", "resizeEdges"] {
    let carriers = appSources.filter { code(of: $0).contains(banned) }
    check("no surface states `\(banned)` any more (found in: \(carriers))", carriers.isEmpty)
}
// And the corner is not merely unspoken, it is not declarable: the enum a second rule would be
// written in terms of is gone from the file that used to hold it.
check("there is no corner left to choose",
      !code(of: "Tally/Core/ResizeAnchor.swift").contains("enum Corner"))
// And the positive half, so the sweep above cannot pass by everything having been deleted: the one
// rule is still applied, in the two places that apply it.
check("the one rule is still what both frame writers use",
      sizerSource.contains("ResizeAnchor.origin(for: frame, topEdge:")
          && pickSource.contains("ResizeAnchor.origin(for: frameRect, topEdge:"))

// 9. WHERE THE CARD STANDS. Above the button that opened it and centred on it, which is where the
//    popover it replaces sat: nothing about the gesture changed, only what happens afterwards.
let display = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
let cardSize = CGSize(width: 268, height: 320)
let button = CGRect(x: 700, y: 240, width: 28, height: 28)
let card = ViewOptionsCardPlacement.frame(size: cardSize, anchor: button, visible: display)
check("the card stands on the button that opened it",
      near(card.minY, button.maxY + ViewOptionsCardPlacement.gap))
check("…centred on it", near(card.midX, button.midX))
check("…at the size its own content laid out at", card.size == cardSize)

// 9b. THE PLACEMENT IS A FUNCTION OF THE BUTTON AND THE SCREEN, AND OF NOTHING ELSE. That is the
//     whole design: the surface behind the card resizes with every click in it, and a card that took
//     the surface as an input would have to be moved every time - which is what an attached popover
//     did, and why the tile walked out from under the pointer.
let sameButtonAgain = ViewOptionsCardPlacement.frame(size: cardSize, anchor: button, visible: display)
check("the same button gives the same place, however often it is asked", sameButtonAgain == card)

// 9c. No room above - the surface was dragged to the top of the display - so it stands under the
//     button instead, the way a popover flips its arrow.
let highButton = CGRect(x: 700, y: 940, width: 28, height: 28)
let flipped = ViewOptionsCardPlacement.frame(size: cardSize, anchor: highButton, visible: display)
check("a card with no room above it hangs under the button",
      near(flipped.maxY, highButton.minY - ViewOptionsCardPlacement.gap))
check("…and is still on the screen", display.contains(flipped))

// 9d. And it is kept inside the display on both axes. Nothing else will do it: the card is its own
//     window, so the surface's clamp does not reach it.
let edgeButton = CGRect(x: 1_580, y: 240, width: 28, height: 28)
let clampedRight = ViewOptionsCardPlacement.frame(size: cardSize, anchor: edgeButton,
                                                  visible: display)
check("a button against the right edge does not push the card off it",
      near(clampedRight.maxX, display.maxX) && clampedRight.minX > display.minX)
let leftButton = CGRect(x: 4, y: 240, width: 28, height: 28)
check("…nor does one against the left",
      near(ViewOptionsCardPlacement.frame(size: cardSize, anchor: leftButton,
                                          visible: display).minX, display.minX))
// A card taller than the room it has keeps its BOTTOM on screen: the low edge wins, because pushing
// it off the top would take the controls with it while leaving the surface behind.
let tall = ViewOptionsCardPlacement.frame(size: CGSize(width: 268, height: 1_400), anchor: button,
                                          visible: display)
check("a card too tall for the display hangs off the top, not the bottom",
      near(tall.minY, display.minY))

// 9e. WHICH DISPLAY IT IS MEASURED AGAINST: the one the BUTTON is on, not the one holding most of
//     the surface. A window straddling two displays answers `screen` with the larger share, so a
//     footer on the right-hand display would have its card clamped into the left-hand one, hundreds
//     of points from the control it belongs to (codex, review of f19f79b). The repo asks anchors
//     this question by their centre everywhere it matters (`StatusItemController.menuBarScreen`).
let leftDisplay = CGRect(x: -1_600, y: 0, width: 1_600, height: 1_000)
let rightDisplay = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
let displays = [leftDisplay, rightDisplay]
check("a button on the right-hand display is placed against that display",
      ViewOptionsCardPlacement.display(for: CGRect(x: 40, y: 240, width: 28, height: 28),
                                       in: displays) == 1)
check("…and one on the left against the left",
      ViewOptionsCardPlacement.display(for: CGRect(x: -900, y: 240, width: 28, height: 28),
                                       in: displays) == 0)
// The seam itself: a button lying across the boundary belongs to whichever display its CENTRE is
// on, which is the one the majority of the control is drawn on.
check("a button across the seam goes with its own centre",
      ViewOptionsCardPlacement.display(for: CGRect(x: -10, y: 240, width: 28, height: 28),
                                       in: displays) == 1)
check("…and a button on no display at all is nobody's, so the caller falls back",
      ViewOptionsCardPlacement.display(for: CGRect(x: 4_000, y: 240, width: 28, height: 28),
                                       in: displays) == nil)

// 10. WHAT PUTS IT AWAY. Everything but the card itself, which is what makes it read as a popover -
//     and one thing more, which is what makes it better than one: a press on the panel's drag
//     regions dismisses the card AND carries the window from the same press (Albert, 2026-08-18).
let toggle = CGRect(x: 700, y: 240, width: 28, height: 28)
check("a press inside the card is the card being used",
      !ViewOptionsCardPlacement.dismisses(press: CGPoint(x: card.midX, y: card.midY),
                                          card: card, toggle: toggle))
check("a press on the surface's drag region puts it away",
      ViewOptionsCardPlacement.dismisses(press: CGPoint(x: 200, y: 600), card: card, toggle: toggle))
check("…as does a press in another app entirely",
      ViewOptionsCardPlacement.dismisses(press: CGPoint(x: -400, y: -400), card: card,
                                         toggle: toggle))
// The button that opened it is exempt, and not as a courtesy: it is a TOGGLE, so dismissing on the
// way down would leave its own action to re-open the card on the way up and the control could never
// close what it opens.
check("the button it came from is exempt, or it could never be closed by it",
      !ViewOptionsCardPlacement.dismisses(press: CGPoint(x: toggle.midX, y: toggle.midY),
                                          card: card, toggle: toggle))
// AND THAT EXEMPTION IS READ LIVE. The surface resizes while the card is up, which moves the footer
// the button sits in - so an exemption remembered from the opening would protect a patch of empty
// panel and stop protecting the button. The card's own rectangle is the opposite: decided once. The
// two together are the design.
let movedToggle = toggle.offsetBy(dx: 0, dy: -333)
check("a footer that moved takes the exemption with it",
      !ViewOptionsCardPlacement.dismisses(press: CGPoint(x: movedToggle.midX, y: movedToggle.midY),
                                          card: card, toggle: movedToggle))
check("…and where the button used to be is now just surface",
      ViewOptionsCardPlacement.dismisses(press: CGPoint(x: toggle.midX, y: toggle.midY),
                                         card: card, toggle: movedToggle))
check("a card whose button has gone is dismissed by any press at all",
      ViewOptionsCardPlacement.dismisses(press: CGPoint(x: toggle.midX, y: toggle.midY),
                                         card: card, toggle: nil))

// 10b. AND THE ARRIVAL NOBODY PRESSED ANYTHING FOR. Command-, opens Settings and Sparkle posts its
//      update alert on a timer: each draws over the surface the card belongs to, while the card
//      floats above it and swallows the Escape that would close it (codex, review of f19f79b). A
//      window of this app becoming key is therefore asked the same question a press is.
check("another window of this app coming forward puts the card away",
      ViewOptionsCardPlacement.dismisses(windowNumber: 42, card: 7, host: 3))
check("…the card's own window does not, it takes key the moment it opens",
      !ViewOptionsCardPlacement.dismisses(windowNumber: 7, card: 7, host: 3))
check("…nor does the surface it belongs to, whose presses the toggle exemption answers",
      !ViewOptionsCardPlacement.dismisses(windowNumber: 3, card: 7, host: 3))

// 11. AND THE WINDOW THAT CARRIES IT, read off the source for the reason section 6 gives.
let cardSource = code(of: "Tally/MenuBar/ViewOptionsCard.swift")
check("the card is placed through that arithmetic, from the button's rectangle on screen",
      cardSource.contains(
        "panel.setFrame(ViewOptionsCardPlacement.frame(size: hosting.fittingSize, anchor: anchorRect,"))
// PLACED ONCE. One frame write in the controller, and nothing watching the surface: an observer of
// the host's moves or resizes is exactly how a card would start following the footer again.
check("…once, and then left alone",
      cardSource.components(separatedBy: "panel.setFrame(").count - 1 == 1
          && !cardSource.contains("didMoveNotification")
          && !cardSource.contains("didResizeNotification"))
// …and against the display the BUTTON is on rather than the one holding most of the window (9e).
check("…measured against the display the button it stands on is on",
      cardSource.contains("ViewOptionsCardPlacement.display(for: anchorRect, in: screens.map(\\.frame))"))
// THE ONE THING IT OBSERVES is which window is in front. Never where the surface is or how big it
// has become: an observer of those is exactly how the card would start following the footer again.
check("…and the only notification it watches is a window coming forward",
      cardSource.components(separatedBy: "addObserver").count - 1 == 1
          && cardSource.contains("forName: NSWindow.didBecomeKeyNotification"))
check("…which is taken down with the card, through the door it was registered at",
      cardSource.contains(
        "for observer in card.observers { NotificationCenter.default.removeObserver(observer) }"))
// THE PRESS IS PASSED ON, which is the drag behaviour in one line: the monitor runs before the event
// reaches the window, so the card is gone by the time the panel's drag region receives the very same
// press. Swallowing it would cost a click; dismissing after would let the press through to a card
// that was still up.
let pressPath = cardSource
    .range(of: "if self.dismisses(pressAt: NSEvent.mouseLocation) { self.dismissAndReport() }")
    .map { String(cardSource[$0.upperBound...].prefix(60)) } ?? ""
check("a press that dismisses the card is still delivered, so the drag it started carries on",
      pressPath.contains("return event") && !pressPath.contains("return nil"))
check("…and the exemption is asked of the anchor at the press, not remembered from the opening",
      cardSource.contains("toggle: { [weak anchor] in anchor?.screenRect }")
          && cardSource.contains("toggle: card.toggle()"))
check("Escape puts it away, through the monitor and through the panel itself",
      cardSource.contains("event.keyCode == 53") && cardSource.contains("func cancelOperation"))
// NOT dismissed on losing key, which is how a popover does it and how this one must not: an
// accessory app's panel is handed the key window and can have it taken straight back while the
// activation request settles, so that reading fires before anybody has seen anything
// (~/.claude/docs/patterns/swiftui-appkit.md, paid for by the pick panel on 2026-08-09).
check("…and never by losing the key window, which fires before anyone has seen it",
      !cardSource.contains("didResignKey"))
// Named per host, so the popover closing behind its own footer cannot take away the pinned panel's
// card - two surfaces can be on screen at once.
check("a host only ever dismisses its own card",
      cardSource.contains("func dismiss(host: SurfaceHost)")
          && cardSource.contains("guard presentation?.host == host else { return }"))
// ONE SIZE AUTHORITY, the red line on this repo's SwiftUI-in-AppKit surfaces: the card is the size
// its content lays out at, and the frame writes here are placement only.
check("the card has one size authority, and the frame it is given is placement only",
      cardSource.contains("hosting.sizingOptions = [.intrinsicContentSize]")
          && cardSource.contains("held.origin = frame.origin") && !cardSource.contains("held.size"))
check("…and it grows upward, away from the button and the pointer on it",
      cardSource.contains("var holdsBottomEdge = false")
          && cardSource.contains("panel.holdsBottomEdge = true"))

// 11b. The surface's end of the same wiring: the button says where it is, the change of state says
//      when, and a surface being torn down takes its card with it (`onChange` never fires for a view
//      that has gone, so this is the only hook there is).
let footerSource = code(of: "Tally/Views/PopoverFooterView.swift")
check("the button that opens the card is what the card stands on",
      footerSource.contains(".viewOptionsAnchor(viewOptionsAnchor)")
          && footerSource.contains("ViewOptionsCard.shared.present("))
check("…and the attached popover is left to the one host that has to have it",
      footerSource.contains("showViewOptions && !host.detachesViewOptionsCard")
          && footerSource.contains("guard host.detachesViewOptionsCard else { return }"))
check("…which the host answers for itself, exhaustively",
      code(of: "Tally/Views/SurfaceTabState.swift").contains("var detachesViewOptionsCard: Bool")
          && code(of: "Tally/Views/SurfaceTabState.swift").contains("case .popover: return false"))
check("a surface torn down with its card up takes the card with it",
      code(of: "Tally/Views/PopoverRootView.swift")
          .contains(".onDisappear { ViewOptionsCard.shared.dismiss(host: host) }"))

checkPopoverAnchor()
checkPanelSummon()

print(failures == 0 ? "\nAll window anchor tests passed." : "\n\(failures) anchor test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
