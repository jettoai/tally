import CoreGraphics
import Foundation

// The popover's half of the window anchor suite. It is the one surface here whose position belongs
// to AppKit rather than to this code, which is also why it is the section that reads a controller's
// source instead of only exercising arithmetic. The harness itself (check, near, code, precedes) is
// main.swift's and is shared from there.
//
// THIS SECTION SHRANK ON 2026-08-12, and that is the point. Three rounds of it asserted the shape of
// machinery that put the popover back after AppKit had moved it: held constants, a clamp, a resident
// enforcement observer. All of it lost to a resident placement model and all of it is now deleted,
// replaced by giving the popover an anchor nothing outside this app can move. What is asserted here
// is what is left: the geometry of the one question still asked, and the shape of the decoy.
func checkPopoverAnchor() {
    // 12. THE QUESTION THAT SURVIVED. The status item's window moves without this app asking: into
    //     the strip above the display when the bar hides, and onto another display entirely when the
    //     system parks it (measured 2026-08-12). It used to gate whether AppKit could place the
    //     surface; it now gates whether the decoy follows the item there.
    let display = CGRect(x: 0, y: 0, width: 2048, height: 1152)
    let barShown = CGRect(x: 1700, y: display.maxY - 24, width: 44, height: 24)
    let barHidden = CGRect(x: 1700, y: display.maxY, width: 44, height: 24)
    check("an item in the visible menu bar is one the decoy may follow",
          StatusAnchor.isOnScreen(buttonWindow: barShown, screen: display))
    check("…and the same item in the hidden strip above the display is not",
          !StatusAnchor.isOnScreen(buttonWindow: barHidden, screen: display))
    // The reason the question takes ONE NAMED display rather than "some screen": with a display
    // stacked above this one, the hidden strip is inside that display's frame, so a check that
    // scanned the screens would answer yes for the exact case this exists to catch.
    let stackedAbove = CGRect(x: 0, y: display.maxY, width: 2048, height: 1152)
    check("the hidden strip really does fall inside a display stacked above (the trap, stated)",
          stackedAbove.contains(CGPoint(x: barHidden.midX, y: barHidden.midY)))
    check("…and asking about the popover's own display still answers no",
          !StatusAnchor.isOnScreen(buttonWindow: barHidden, screen: display))
    // Mid-reveal the strip straddles the top edge; it counts as whichever side most of it is on, so a
    // point of rounding at the edge cannot read as hidden.
    check("a strip mostly back on the display counts as visible",
          StatusAnchor.isOnScreen(buttonWindow: barShown.offsetBy(dx: 0, dy: 10), screen: display))
    check("…and one mostly still above it does not",
          !StatusAnchor.isOnScreen(buttonWindow: barShown.offsetBy(dx: 0, dy: 14), screen: display))
    check("a window with no size at all is not an anchor (an item that never installed)",
          !StatusAnchor.isOnScreen(buttonWindow: .zero, screen: display))

    // 12a. WHICH DISPLAY A SURFACE IS STANDING ON, the other half of that question and what makes it
    //      about two independent facts instead of one. Same centre rule, so a surface straddling a
    //      boundary belongs to the display holding its middle, and one standing on nothing says so
    //      rather than picking a neighbour.
    let machine = [CGRect(x: 0, y: 0, width: 2048, height: 1152),
                   CGRect(x: 0, y: 1152, width: 2048, height: 1152),
                   CGRect(x: 2048, y: 1152, width: 2560, height: 1440),
                   CGRect(x: 2048, y: -288, width: 2560, height: 1440)]
    check("a popover standing on the big display is found there",
          StatusAnchor.screenFrame(containing: CGRect(x: 3069, y: 2220, width: 406, height: 257),
                                   among: machine) == machine[2])
    check("…and one on the main display is found there instead",
          StatusAnchor.screenFrame(containing: CGRect(x: 479, y: 869, width: 406, height: 257),
                                   among: machine) == machine[0])
    let straddling = CGRect(x: 1800, y: 400, width: 400, height: 200)
    check("a surface straddling two displays belongs to the one holding its centre",
          straddling.maxX > machine[0].maxX
              && StatusAnchor.screenFrame(containing: straddling, among: machine) == machine[0])
    check("…and the answer moves with the centre, not with the overlap",
          StatusAnchor.screenFrame(containing: straddling.offsetBy(dx: 200, dy: 0),
                                   among: machine) == machine[3])
    check("a surface on a display that is no longer in the list belongs to nothing",
          StatusAnchor.screenFrame(containing: CGRect(x: 6000, y: 6000, width: 400, height: 200),
                                   among: machine) == nil)
    check("…and no display at all is an answer of nothing, not a crash",
          StatusAnchor.screenFrame(containing: straddling, among: []) == nil)
    check("…as is a window with no size (an item that never installed)",
          StatusAnchor.screenFrame(containing: .zero, among: machine) == nil)

    // 12b. THE MACHINE'S OWN NUMBERS. At 02:05:50.694 the popover opened against an item on the big
    //      display; 110ms later the item's window had been parked on the main display's bar strip and
    //      the popover was still where it opened. Both shipped guards answered "placeable" - correctly
    //      for the question they asked, which was whether the anchor was on the ANCHOR's display.
    let parkedAnchor = CGRect(x: 503, y: 1122, width: 360, height: 30)
    let popoverStandingOn = machine[2]
    check("the parked anchor is NOT on the display the popover is standing on, so the decoy freezes",
          !StatusAnchor.isOnScreen(buttonWindow: parkedAnchor, screen: popoverStandingOn))
    check("…while the old self-referential question answered yes about it (the bug, stated)",
          StatusAnchor.isOnScreen(buttonWindow: parkedAnchor, screen: machine[0]))
    let anchorAtShow = CGRect(x: 3063, y: 2562, width: 360, height: 30)
    check("the anchor the popover opened against IS one the decoy follows",
          StatusAnchor.isOnScreen(buttonWindow: anchorAtShow, screen: popoverStandingOn))

    // 12c. AND THE CONTROLLER IS BUILT THAT WAY. Read off the source for the same reason as
    //      everything above: the status item's window cannot be driven from here.
    // Read as ONE source across the controller's three files (`statusControllerFiles`, stated in
    //      main.swift with the reason).
    let statusSource = statusControllerSource
    func precedes(_ first: String, _ second: String, in body: String) -> Bool {
        guard let a = body.range(of: first), let b = body.range(of: second) else { return false }
        return a.upperBound <= b.lowerBound
    }

    // The popover hangs off an anchor of ours, never off the status item's own window. That single
    // substitution is the fix: the model that re-places the surface follows the positioning view's
    // window, and this one is a window nothing outside the app can move.
    guard let toggleStart = statusSource.range(of: "private func togglePopover(button: NSStatusBarButton, afterDismissal: Bool)"),
          let toggleEnd = statusSource.range(of: "\n    }\n",
                                             range: toggleStart.upperBound ..< statusSource.endIndex)
    else {
        check("the showing was found to read", false)
        exit(1)
    }
    let toggle = String(statusSource[toggleStart.upperBound ..< toggleEnd.lowerBound])
    check("the popover is shown against the decoy's view",
          toggle.contains("popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)"))
    check("…never against the status item's own window, which is the one the system moves",
          !toggle.contains("of: button"))
    check("…and the decoy is put where the item is before the popover is shown",
          precedes("decoyAnchorViewForShow(button: button)",
                   "popover.show(relativeTo: anchorView.bounds", in: toggle))
    check("…with the real anchor watched only so the decoy can follow it",
          toggle.contains("watchRealAnchor()"))

    // 12d. WHAT COMING FORWARD MAY COST, and the assertion here is the reverse of the one it
    //      replaces. Until 2026-08-15 this suite asserted `NSApp.activate(ignoringOtherApps: true)`
    //      as the first statement of the showing - the shape of the code, written down as if it
    //      were the contract - and that green light is what kept two reported symptoms in place for
    //      a day: activation fronts the app's KEY window, so a Settings window the user had left on
    //      another display came forward with the popover (measured off the window server's own
    //      ordering: it went from behind the terminal to in front of it on one press), and it can
    //      take the menu bar to that display with it, which is the anchor being read a moment later.
    //
    //      The contract is therefore about ORDER and about WHICH WINDOW: the anchor is read from the
    //      click before anything is activated, and the window activation is allowed to front is one
    //      of ours that nobody can see.
    check("the anchor is read before the app takes the foreground, never after",
          precedes("decoyAnchorViewForShow(button: button)", "takeForegroundForPopover()", in: toggle))
    check("…and the showing itself no longer activates anything unconditionally",
          !toggle.contains("NSApp.activate"))
    guard let frontStart = statusSource.range(of: "private func takeForegroundForPopover()"),
          let frontEnd = statusSource.range(of: "\n    }\n",
                                            range: frontStart.upperBound ..< statusSource.endIndex)
    else {
        check("the foreground step was found to read", false)
        exit(1)
    }
    let foreground = String(statusSource[frontStart.upperBound ..< frontEnd.lowerBound])
    //      THE CONDITION IS THE WHOLE FIX, and it is asserted as a condition rather than as an
    //      absence: activating is what makes the popover typeable, so a path that never activated
    //      would be a different bug (an account rename that swallows keystrokes). What may not
    //      happen is activating while a window of ours is on screen to be dragged forward with it.
    check("the popover comes forward only when no window of ours is on screen to come with it",
          precedes("guard !SettingsWindowController.shared.isWindowVisible",
                   "NSApp.activate(ignoringOtherApps: true)", in: foreground)
              && foreground.contains("!MainWindowController.shared.isWindowVisible else { return }"))
    check("…and it still activates in that case, because a popover that cannot be typed into is a bug too",
          foreground.contains("NSApp.activate(ignoringOtherApps: true)"))
    check("…asked of what is ON SCREEN, so a window the user minimized is not a reason to stand down",
          !foreground.contains("isWindowOpen"))
    check("…and this is the only place in the controller that takes the foreground at all",
          statusSource.components(separatedBy: "NSApp.activate").count == 2)

    // THE DECOY ITSELF: ours, invisible, and unable to eat a click meant for the item under it.
    guard let decoyStart = statusSource.range(of: "private func decoyAnchorViewForShow(button: NSStatusBarButton)"),
          let decoyEnd = statusSource.range(of: "\n    }\n",
                                            range: decoyStart.upperBound ..< statusSource.endIndex)
    else {
        check("the decoy was found to read", false)
        exit(1)
    }
    let decoy = String(statusSource[decoyStart.upperBound ..< decoyEnd.lowerBound])
    check("the decoy is invisible", decoy.contains("window.alphaValue = 0"))
    check("…and never takes a click meant for the item beneath it",
          decoy.contains("window.ignoresMouseEvents = true"))
    check("…sits at the status bar's own level, on every Space, like the item it stands in for",
          decoy.contains("CGWindowLevelForKey(.statusWindow)")
              && decoy.contains("collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]"))
    // `.fullScreenAuxiliary` is not decoration: without it the decoy cannot join a full-screen
    // Space, so a popover opened from the menu bar of a full-screen app has no anchor to be shown
    // against at all. The pinned panel has carried it for the same reason since it was written, and
    // the two are asserted together so the pair cannot drift apart.
    check("…and can join a full-screen Space, the way the pinned panel already does",
          code(of: "Tally/MenuBar/PinnedPanelController.swift")
              .contains("collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]"))
    // Built once and reused: a window per showing would be a new positioning view each time, and the
    // point of this one is that it is stable and ours.
    check("…built once and reused, then moved onto the item",
          decoy.contains("if decoyAnchor == nil") && decoy.contains("decoyAnchor?.setFrame(anchorRect"))
    check("…at the item's own rectangle in screen coordinates",
          statusSource.contains("window.convertToScreen(button.convert(button.bounds, to: nil))"))

    // FOLLOW OR FREEZE, and nothing else. Both answers are passive: following moves the decoy and
    // AppKit slides the popover natively; freezing moves nothing, so nothing moves the popover.
    // Keyed on the function, not on its access level: `private` is not part of any contract here,
    // and an anchor that includes it makes an unrelated change look like a broken contract.
    guard let feedStart = statusSource.range(of: "func feedDecoyAnchor()"),
          let feedEnd = statusSource.range(of: "\n    }\n",
                                           range: feedStart.upperBound ..< statusSource.endIndex)
    else {
        check("the feeding was found to read", false)
        exit(1)
    }
    let feed = String(statusSource[feedStart.upperBound ..< feedEnd.lowerBound])
    check("the decoy follows the real anchor only where the surface may go",
          precedes("guard anchorMayBeFollowed", "decoyAnchor?.setFrame(anchorRect", in: feed))
    check("…and freezing is a return, not a correction of anything",
          feed.contains("return") && !feed.contains("setFrameOrigin"))
    check("…with no write at all when the item has not actually moved",
          feed.contains("guard decoyAnchor?.frame != anchorRect else { return }"))
    guard let followStart = statusSource.range(of: "private var anchorMayBeFollowed: Bool"),
          let followEnd = statusSource.range(of: "\n    }\n",
                                             range: followStart.upperBound ..< statusSource.endIndex)
    else {
        check("the following rule was found to read", false)
        exit(1)
    }
    let follows = String(statusSource[followStart.upperBound ..< followEnd.lowerBound])
    check("the rule compares the anchor against the POPOVER's display, not the anchor's own",
          follows.contains("StatusAnchor.isOnScreen(buttonWindow: anchor, screen: screen)")
              && follows.contains("popoverScreenFrame()"))
    check("…so the derived screen the old question asked about is gone from it",
          !follows.contains("menuBarScreen"))
    check("…asked in exactly one place", statusSource.components(separatedBy: "StatusAnchor.isOnScreen").count == 2)

    // A RESIZE IS JUST A RESIZE AGAIN. It re-places the surface against the decoy, which is where the
    // surface belongs, so there is nothing to undo afterwards.
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
    check("…and a real one writes the size, then hands the anchor back",
          precedes("self.popover.contentSize = size", "self.fitShownPopoverToScreen()", in: apply))
    check("…moving nothing itself, which is what three rounds of this pass used to do",
          !apply.contains("setFrameOrigin") && !apply.contains("setContentSize"))
    guard let fitStart = statusSource.range(of: "private func fitShownPopoverToScreen()"),
          let fitEnd = statusSource.range(of: "\n    }\n",
                                          range: fitStart.upperBound ..< statusSource.endIndex)
    else {
        check("the re-placement was found to read", false)
        exit(1)
    }
    let fit = String(statusSource[fitStart.upperBound ..< fitEnd.lowerBound])
    check("the anchor handed back is the decoy's, unconditionally",
          fit.contains("popover.positioningRect = anchorView.bounds")
              && !fit.contains("anchorMayBeFollowed"))

    // THE TOGGLE. With the anchor no longer the item's own window, a click on the item is outside the
    // popover and dismisses it on the mouse-down; the action arrives on the mouse-up and would open it
    // straight back. The dismissal's own timestamp is what tells the two apart.
    check("the click that dismissed the popover does not reopen it",
          precedes("} else if afterDismissal {", "takeForegroundForPopover()", in: toggle))
    // SPENT, NOT TIMED OUT. A window judged only by elapsed time expires under a press that is
    // merely HELD, and the release then reopens the popover the press just shut (codex review of
    // ca32b61). What is recorded instead is what the dismissal SAW, and the next click spends it.
    check("…judged by what the dismissal saw, recorded at the close while the click is still in flight",
          statusSource.contains("lastDismissal = (Date(), onItem, NSEvent.pressedMouseButtons & 1 == 1)")
              && statusSource.contains("self?.noteDismissal()"))
    check("…and the pointer's position at that moment is part of it, so a click elsewhere leaves nothing",
          statusSource.contains(".contains(NSEvent.mouseLocation) ?? false"))
    check("…spent exactly once per click, before the kind of click is even decided",
          precedes("let dismissedByThisClick = consumeDismissalOfThisClick()",
                   "let isSecondary", in: statusSource)
              && statusSource.contains("lastDismissal = nil"))
    check("…with no elapsed-time judgement left in the controller at all",
          !statusSource.contains("lastPopoverClose"))
    check("…and the close is also where the decoy is put away",
          statusSource.contains("self?.retireDecoyAnchor()"))

    // THE DECISION ITSELF, which is the one thing here a machine can be held to: the case that
    // matters is a press HELD, and it cannot be exercised against a real popover (transient
    // dismissal ignores events posted into the process, probe v7 and its control), so it is pure.
    check("a press still held when the popover closed suppresses the open, however long it is held",
          TogglePress.suppressesOpen(pointerWasOnItem: true, buttonWasDown: true, elapsed: 2.0))
    check("…which is exactly what a timer got wrong: 2 seconds is long past any window",
          TogglePress.releaseWindow < 2.0)
    check("a click too short to still be held is caught by the window instead",
          TogglePress.suppressesOpen(pointerWasOnItem: true, buttonWasDown: false, elapsed: 0.05))
    check("…and a later, deliberate click on the item is not",
          !TogglePress.suppressesOpen(pointerWasOnItem: true, buttonWasDown: false, elapsed: 1.0))
    check("…with the window's own edge outside it, not on it",
          !TogglePress.suppressesOpen(pointerWasOnItem: true, buttonWasDown: false,
                                      elapsed: TogglePress.releaseWindow))
    // Dismissing by clicking somewhere else must leave nothing behind that a later click on the item
    // could spend, which is the half a pure timer could not express at all.
    check("a dismissal with the pointer somewhere else suppresses nothing",
          !TogglePress.suppressesOpen(pointerWasOnItem: false, buttonWasDown: true, elapsed: 0)
              && !TogglePress.suppressesOpen(pointerWasOnItem: false, buttonWasDown: false, elapsed: 0))

    // AND THE MACHINERY THAT LOST IS GONE, pinned so it cannot creep back. Each of these was a real
    // mechanism in this file within the last day, and each one existed to correct a placement after
    // AppKit had made it. The whole family is what the decoy replaces.
    for gone in ["heldPlacement", "lastLegitimateFrame", "readingScreenFrame", "StatusAnchor.heldOrigin",
                 "placementDidMove", "enforceHeldPlacement", "beginHoldingPlacement"] {
        check("the placement-correction machinery is gone: no `\(gone)`", !statusSource.contains(gone))
    }
    // The strongest form of the same claim: this file no longer moves the popover's window at all.
    // Its position has exactly one writer, which is AppKit, and the anchor's has exactly one, which
    // is this file.
    check("nothing here moves the popover's own window any more",
          !statusSource.contains("window.setFrameOrigin") && !statusSource.contains("popoverWindow?.setFrame"))
    check("…and the geometry that used to compute where to put it back is gone from the shared file",
          !code(of: "Tally/Core/StatusAnchor.swift").contains("func heldOrigin"))

    // The content still fits the display the SURFACE is on, not the one the anchor has wandered to.
    check("the content is fitted to the display the popover is standing on",
          statusSource.contains("hostScreen: { [weak self] in self?.contentHostScreen() }"))
    guard let hostStart = statusSource.range(of: "private func contentHostScreen() -> NSScreen?"),
          let hostEnd = statusSource.range(of: "\n    }\n",
                                           range: hostStart.upperBound ..< statusSource.endIndex)
    else {
        check("the content's host screen was found to read", false)
        exit(1)
    }
    let host = String(statusSource[hostStart.upperBound ..< hostEnd.lowerBound])
    check("…asked of the surface first, with the anchor's display only as the answer before it opens",
          precedes("popoverScreenFrame()", "menuBarScreen()", in: host))
    // Sub-point rounding is not a resize, for the same reason it was never a move: the tolerance is
    // stated once, in ResizeAnchor.
    check("…and the sameness it uses is the shared one, tolerance included",
          !ResizeAnchor.needsResize(from: CGSize(width: 560, height: 700),
                                    to: CGSize(width: 560, height: 700.4))
              && ResizeAnchor.needsResize(from: CGSize(width: 560, height: 700),
                                          to: CGSize(width: 834, height: 700)))
}
