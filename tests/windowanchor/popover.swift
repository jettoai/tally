import CoreGraphics
import Foundation

// The popover's half of the window anchor suite, split out when this file passed 500 lines. It is
// the one surface here that AppKit places rather than this code, which is also why it is the section
// that reads a controller's source instead of only exercising arithmetic. The harness itself (check,
// near, code, precedes) is main.swift's and is shared from there.
func checkPopoverAnchor() {
    // 12. The popover's anchor, which is the one surface here that AppKit places rather than this code:
    //     it is placed AGAIN on every content-driven resize (`fitShownPopoverToScreen`, so a panel that
    //     widens cannot walk off the right of the display), and a re-placement is only as good as the
    //     anchor it is measured from. With "Automatically hide and show the menu bar" on and the bar
    //     hidden, the status item's window is in the strip ABOVE its display, so AppKit puts the popover
    //     in the display's top-left corner with the arrow pointing back at that corner - what the user
    //     saw on 2026-08-11 by switching the gauges between used and remaining with the bar hidden.
    let display = CGRect(x: 0, y: 0, width: 2048, height: 1152)
    // The status item as the bar draws it: at the top of the display, inside the frame.
    let barShown = CGRect(x: 1700, y: display.maxY - 24, width: 44, height: 24)
    // The same item with the bar hidden: the strip it lives in has slid off the top of the display.
    let barHidden = CGRect(x: 1700, y: display.maxY, width: 44, height: 24)
    check("an item in the visible menu bar is an anchor a popover can be placed against",
          StatusAnchor.isOnScreen(buttonWindow: barShown, screen: display))
    check("…and the same item in the hidden strip above the display is not",
          !StatusAnchor.isOnScreen(buttonWindow: barHidden, screen: display))
    // The reason the question takes the bar's OWN screen rather than "some screen": with a display
    // stacked above this one, the hidden strip is inside that display's frame, so a check that scanned
    // the screens would answer yes for the exact case this exists to catch.
    let stackedAbove = CGRect(x: 0, y: display.maxY, width: 2048, height: 1152)
    check("the hidden strip really does fall inside a display stacked above (the trap, stated)",
          stackedAbove.contains(CGPoint(x: barHidden.midX, y: barHidden.midY)))
    check("…and asking about the bar's own display still answers no",
          !StatusAnchor.isOnScreen(buttonWindow: barHidden, screen: display))
    // Mid-reveal the strip straddles the top edge; it counts as whichever side most of it is on, so a
    // point of rounding at the edge cannot read as hidden.
    check("a strip mostly back on the display counts as visible",
          StatusAnchor.isOnScreen(buttonWindow: barShown.offsetBy(dx: 0, dy: 10), screen: display))
    check("…and one mostly still above it does not",
          !StatusAnchor.isOnScreen(buttonWindow: barShown.offsetBy(dx: 0, dy: 14), screen: display))
    check("a window with no size at all is not an anchor (an item that never installed)",
          !StatusAnchor.isOnScreen(buttonWindow: .zero, screen: display))

    // 12b. A RESIZE IS A PLACEMENT TOO, and that is the half the guard below cannot cover: handing
    //      NSPopover a contentSize makes it re-derive the anchor from the positioning view's window, so
    //      a size that really did change re-places the surface against the strip whatever the guard
    //      decides afterwards. Measured with a real popover on this machine (2026-08-12): with a display
    //      stacked above the bar's own, the surface was thrown 350pt up onto that display; with nothing
    //      stacked there it landed at x=0 against the host's top edge, 833pt from where it was being
    //      read - the corner in the report. So the frame is put back by hand, and this is that
    //      arithmetic: the top edge and the centre it already had, at the size it now is.
    //
    //      The numbers below are the measured ones from that run, so the geometry and the surface it
    //      corrects cannot drift apart quietly.
    let hidden = CGRect(x: 0, y: 1152, width: 2048, height: 1152)
    let readingAt = CGRect(x: 833, y: 1978, width: 426, height: 326)
    let grownPopover = CGSize(width: 546, height: 386)
    let held = StatusAnchor.heldOrigin(previous: readingAt, size: grownPopover, within: hidden)
    check("a widened popover keeps the top edge it was standing on",
          near(held.y + grownPopover.height, readingAt.maxY))
    check("…and grows about its centre, which is where its arrow is",
          near(held.x + grownPopover.width / 2, readingAt.midX))
    check("…which is the frame AppKit threw to the corner, put back (measured 773, 1918)",
          near(held.x, 773) && near(held.y, 1918))
    // A report that changes nothing must not move the surface, for the same reason a resize correction
    // must not: this runs on a live window, and a move it makes for nothing is a move the user sees.
    check("a size that did not change corrects to the origin it already has",
          StatusAnchor.heldOrigin(previous: readingAt, size: readingAt.size, within: hidden) == readingAt.origin)

    // The clamp is measured against the BAR'S display, not against whichever one the widened surface
    // now mostly covers: an item near the right of the bar puts more than half of a wide popover onto
    // the display next door, and a clamp that asked the window where it was would park it there.
    let nearRight = CGRect(x: 1622, y: 1978, width: 426, height: 326)
    let wide = CGSize(width: 926, height: 386)
    let clamped = StatusAnchor.heldOrigin(previous: nearRight, size: wide, within: hidden)
    check("a surface too wide to stay centred is pulled back onto the bar's own display (measured 1122)",
          near(clamped.x, 1122) && near(clamped.x + wide.width, hidden.maxX))
    check("…and one that would run off the left is pulled back the other way",
          near(StatusAnchor.heldOrigin(previous: CGRect(x: 10, y: 1978, width: 426, height: 326),
                                       size: wide, within: hidden).x, hidden.minX))
    // Wider than the display keeps the LEFT edge, the edge the content is read from (`clampOnScreen`),
    // rather than being pinned to the right by a clamp that ran second.
    check("…and one wider than the display keeps its left edge",
          near(StatusAnchor.heldOrigin(previous: readingAt, size: CGSize(width: 2200, height: 386),
                                       within: hidden).x, hidden.minX))
    // On a display whose own origin is not zero, because "clamped to the screen" and "clamped to zero"
    // look identical on the one display where they are the same thing.
    let offsetDisplay = CGRect(x: 2048, y: -288, width: 2560, height: 1440)
    check("the clamp is measured from the display's own edges, not from the origin of the desktop",
          near(StatusAnchor.heldOrigin(previous: CGRect(x: 2060, y: 1000, width: 426, height: 326),
                                       size: wide, within: offsetDisplay).x, offsetDisplay.minX))
    // Nothing clamps the vertical: a surface taller than the display is pinned to the top and keeps its
    // overflow below (`ScreenFitStack`), and a bottom clamp here would be a second answer to the
    // question the held top edge just answered.
    let tall = StatusAnchor.heldOrigin(previous: readingAt, size: CGSize(width: 426, height: 1400),
                                       within: hidden)
    check("a surface taller than its display still holds the top edge, overflow below",
          near(tall.y + 1400, readingAt.maxY) && tall.y < hidden.minY)

    // And the popover asks. Read off the source for the same reason as everything above: the status
    // item's window cannot be driven from here.
    let statusSource = code(of: "Tally/MenuBar/StatusItemController.swift")
    guard let fitStart = statusSource.range(of: "private func fitShownPopoverToScreen()"),
          let fitEnd = statusSource.range(of: "\n    }\n", range: fitStart.upperBound ..< statusSource.endIndex)
    else {
        check("the popover's re-placement was found to read", false)
        exit(1)
    }
    let fit = String(statusSource[fitStart.upperBound ..< fitEnd.lowerBound])
    check("the popover is re-placed only against an anchor that is on its own screen",
          fit.contains("guard anchorIsPlaceable"))
    // The question itself, stated ONCE. Two callers need the same answer for opposite reasons - the
    // placement declines to make one, the sizing pass undoes one AppKit made anyway - and a second
    // statement of it is how they would drift apart while both halves still read correctly alone.
    guard let anchorStart = statusSource.range(of: "private var anchorIsPlaceable: Bool"),
          let anchorEnd = statusSource.range(of: "\n    }\n",
                                             range: anchorStart.upperBound ..< statusSource.endIndex)
    else {
        check("the anchor question was found to read", false)
        exit(1)
    }
    let placeable = String(statusSource[anchorStart.upperBound ..< anchorEnd.lowerBound])
    check("…and that question is the pure geometry, asked about the bar's own display",
          placeable.contains("StatusAnchor.isOnScreen(buttonWindow: window.frame, screen: screen.frame)")
              && placeable.contains("menuBarScreen()"))
    check("…asked in exactly one place, so the guard and the repair cannot answer differently",
          statusSource.components(separatedBy: "StatusAnchor.isOnScreen").count == 2)
    // Order matters as much as presence here: a check made after the anchor has been handed back is a
    // check of nothing at all.
    func precedes(_ first: String, _ second: String, in body: String) -> Bool {
        guard let a = body.range(of: first), let b = body.range(of: second) else { return false }
        return a.upperBound <= b.lowerBound
    }
    check("…and that question is asked BEFORE the anchor is handed back",
          precedes("anchorIsPlaceable", "popover.positioningRect", in: fit))
    // AND DECLINING IT LEAVES A DEBT. The size has already been applied by the time this declines, so
    // the surface is standing where a smaller one fitted; without the debt the next report is the same
    // size, the guard below returns on it, and nothing ever calls this again - the popover stayed off
    // screen until it was resized once more or closed and reopened (codex review of 06d734f). The two
    // guards cancelled each other out, and the assertion below used to pin that as the intent.
    // Read as two halves of the anchor question, so each assertion is about the branch it names: what
    // the declining branch leaves behind, and what the placement that happened takes away.
    let declined = fit.range(of: "anchorIsPlaceable").map { String(fit[$0.upperBound...]) } ?? ""
    check("an anchor nobody can see leaves a placement owed",
          precedes("repositionOwed = true", "popover.positioningRect", in: declined))
    check("…and a placement that really happened clears it",
          precedes("popover.positioningRect", "repositionOwed = false", in: declined))
    // A debt cannot outlive the surface that incurred it: NSPopover places itself from scratch when it
    // is shown, so a closed popover owes nothing.
    let beforeAnchor = fit.range(of: "anchorIsPlaceable").map { String(fit[..<$0.lowerBound]) } ?? ""
    check("…and a closed popover owes nothing at all",
          precedes("guard popover.isShown else", "repositionOwed = false", in: beforeAnchor))

    // The second half, and the one that keeps the first from ever being needed on this path: a content
    // report that is the size the popover already is stops before any of it. Switching the gauges
    // between used and remaining does not change the surface's size, so the re-placement that jumped
    // was made for a resize that never happened.
    guard let applyStart = statusSource.range(of: "private func applyPopoverSize(_ size: CGSize)"),
          let applyEnd = statusSource.range(of: "\n    }\n",
                                            range: applyStart.upperBound ..< statusSource.endIndex)
    else {
        check("the popover's sizing pass was found to read", false)
        exit(1)
    }
    let apply = String(statusSource[applyStart.upperBound ..< applyEnd.lowerBound])
    check("a report of the size the popover already is applies nothing",
          apply.contains("guard ResizeAnchor.needsResize(from: self.popover.contentSize, to: size)"))
    check("…checked before the size is written and the anchor is handed back",
          precedes("ResizeAnchor.needsResize", "self.popover.contentSize = size", in: apply)
              && apply.contains("self.fitShownPopoverToScreen()"))
    // AND THE WRITE THAT GETS THROUGH IS PUT BACK. A size that really changed is a placement AppKit
    // makes on its own, before anything below it declines one, so the frame the surface is standing at
    // is read FIRST - and only when it is standing somewhere at all and the anchor is one nobody can
    // see, because on a visible anchor AppKit's placement is the correct one and undoing it would pin
    // the popover to a bar it should be following.
    check("the frame is read before the size is written, and only against an unusable anchor",
          apply.contains("let held = self.popover.isShown && !self.anchorIsPlaceable "
              + "? self.popoverWindow?.frame : nil")
              && precedes("let held", "self.popover.contentSize = size", in: apply))
    check("…and put back after it, at the size the window now is",
          precedes("self.popover.contentSize = size", "setFrameOrigin(StatusAnchor.heldOrigin", in: apply)
              && apply.contains("previous: held, size: window.frame.size"))
    // Measured against the bar's own display, which is the whole reason this is not the shared
    // `clampOnScreen`: that one asks the window which screen it is on, and a wide popover put back over
    // the boundary would be tidied onto the display next door.
    check("…clamped to the display the bar is on, not to the one the surface now covers",
          apply.contains("let screen = self.menuBarScreen()") && apply.contains("within: screen.visibleFrame"))
    // Origin only. A size written from here would be the two-authorities crash this repo has already
    // paid for once (~/.claude/docs/patterns/swiftui-appkit.md), and the content is the one authority.
    check("…rewriting the origin only, never the size",
          !apply.contains("setContentSize") && !apply.contains("window.setFrame("))
    // Before the debt is settled, because what this pass must not do is write down a debt for a surface
    // it has not finished putting back. Read off the part AFTER the size write, since the placement is
    // also called up in the early return that pays an older debt - and a search from the top of the
    // function would have found that one and passed on it (this assertion did, until it was scoped).
    let afterWrite = apply.range(of: "self.popover.contentSize = size")
        .map { String(apply[$0.upperBound...]) } ?? ""
    check("…and the surface is back where it was before any of that is written down",
          precedes("StatusAnchor.heldOrigin", "self.fitShownPopoverToScreen()", in: afterWrite))
    // …EXCEPT WHEN A PLACEMENT IS OWED, which is the one thing that guard may not swallow: the size it
    // compares against was applied while the anchor was off screen, so "nothing changed" is true of the
    // size and false of the position. This report is the only thing that pays that debt, so it has to be
    // collected INSIDE the early return rather than after it.
    check("…unless a placement is owed, which that return may not swallow",
          precedes("guard ResizeAnchor.needsResize", "if self.repositionOwed", in: apply)
              && precedes("if self.repositionOwed { self.fitShownPopoverToScreen() }",
                          "self.popover.contentSize = size", in: apply))
    // One owner, and exactly one place that can put a debt on the books: a second writer of the true
    // value would be a placement owed by a path that never skipped one.
    check("…and the debt is this controller's own state, incurred in one place",
          statusSource.contains("private var repositionOwed = false")
              && statusSource.components(separatedBy: "repositionOwed = true").count == 2)
    // Sub-point rounding is not a resize here either, for the same reason it is not a move: the tolerance
    // is stated once, in ResizeAnchor.
    check("…and the sameness it uses is the shared one, tolerance included",
          !ResizeAnchor.needsResize(from: CGSize(width: 560, height: 700),
                                    to: CGSize(width: 560, height: 700.4))
              && ResizeAnchor.needsResize(from: CGSize(width: 560, height: 700),
                                          to: CGSize(width: 834, height: 700)))
}
