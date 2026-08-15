import CoreGraphics
import Foundation

// SUMMONING: where a surface goes when the user asks for it from a display it is not on.
//
// Three reported symptoms share one shape (2026-08-15, a four-display machine): the pinned panel is
// raised on whichever display it was left on, an open Settings window is raised on whichever display
// it was opened on, and a panel left on a display that went away is raised where that display used
// to be. All three are answers to "which window" given to a question that asked "where".
//
// The arithmetic is here because it is arithmetic - rectangles and displays, no AppKit - and the
// wiring is read off the source for the same reason the rest of this suite does: windows cannot be
// driven from a command-line harness. The harness itself (check, near, code) is main.swift's.
/// Order in a source file, for the assertions that are about a sequence rather than a presence.
/// (The popover section has its own copy nested in its function; this one is the file-scope twin,
/// and both mean the same thing: `first` appears, `second` appears, and not the other way round.)
private func precedes(_ first: String, _ second: String, in body: String) -> Bool {
    guard let a = body.range(of: first), let b = body.range(of: second) else { return false }
    return a.upperBound <= b.lowerBound
}

func checkPanelSummon() {
    // A machine with a menu bar showing, so the two rectangles of a display are genuinely different.
    let bar: CGFloat = 24
    let main = StatusAnchor.Display(frame: CGRect(x: 0, y: 0, width: 2048, height: 1152),
                                    visible: CGRect(x: 0, y: 0, width: 2048, height: 1152 - bar))
    let big = StatusAnchor.Display(frame: CGRect(x: 2048, y: 1152, width: 2560, height: 1440),
                                   visible: CGRect(x: 2048, y: 1152, width: 2560, height: 1440 - bar))
    let displays = [main, big]
    // The status item lives IN the menu bar, which is the strip a window may not occupy. Stated
    // first because it is the trap the whole signature exists for: an arithmetic handed only the
    // visible frames would find no display under the anchor and decline to move anything, on every
    // machine whose bar is showing - and silently, since "no display" and "already there" are both
    // "do nothing".
    let item = CGRect(x: 4000, y: big.frame.maxY - bar, width: 44, height: bar)
    let itemCentre = CGPoint(x: item.midX, y: item.midY)
    check("the status item is inside its display's frame but outside the part a window may use",
          big.frame.contains(itemCentre) && !big.visible.contains(itemCentre))

    // 1. THE REPORTED CASE. The panel is on the main display, the click came from the big one.
    let panel = CGRect(x: 100, y: 800, width: 406, height: 257)
    guard let moved = StatusAnchor.summonTopLeft(panel: panel, towards: item, displays: displays)
    else {
        check("a panel summoned from another display moves", false)
        return
    }
    let landed = CGRect(x: moved.x, y: moved.y - panel.height, width: panel.width, height: panel.height)
    check("a panel summoned from another display lands wholly on that display",
          big.visible.contains(landed))
    // What it keeps is the PLACE, not the coordinates: same corner, same inset, scaled between two
    // displays of different sizes. Dropping it under the item instead would throw away a position
    // the user chose, every time they glanced at it from another desk.
    check("…keeping where on the display the user had put it, scaled to the new one",
          near(landed.minX - big.visible.minX,
               (panel.minX - main.visible.minX) * (big.visible.width / main.visible.width))
              && near(big.visible.maxY - landed.maxY,
                      (main.visible.maxY - panel.maxY) * (big.visible.height / main.visible.height)))

    // 2. AND IT SETTLES. A summon that produced an answer every time would write a frame on every
    //    click, which is how a surface walks a rounding point per press; the second ask has to be
    //    nothing at all.
    check("a panel already on the display the click came from is not moved",
          StatusAnchor.summonTopLeft(panel: landed, towards: item, displays: displays) == nil)
    check("…which makes the summon idempotent, not merely correct once",
          StatusAnchor.summonTopLeft(panel: CGRect(x: 2500, y: 1400, width: 406, height: 257),
                                     towards: item, displays: displays) == nil)

    // 3. NOTHING TO SUMMON TOWARDS is a move of nothing, three ways. An item with no window yet, an
    //    item on a display this machine does not have (the list is read fresh, the anchor may not
    //    be), and a panel that has no size because it was never built.
    check("no anchor at all moves nothing",
          StatusAnchor.summonTopLeft(panel: panel, towards: nil, displays: displays) == nil)
    check("…an anchor on no display in the list moves nothing",
          StatusAnchor.summonTopLeft(panel: panel, towards: CGRect(x: 9000, y: 9000, width: 44, height: 24),
                                     displays: displays) == nil)
    check("…and an empty rectangle is not an anchor, nor a panel",
          StatusAnchor.summonTopLeft(panel: panel, towards: .zero, displays: displays) == nil
              && StatusAnchor.summonTopLeft(panel: .zero, towards: item, displays: displays) == nil)
    check("…nor is a machine with no displays a machine to be summoned on",
          StatusAnchor.summonTopLeft(panel: panel, towards: item, displays: []) == nil)

    // 4. A PANEL TOO BIG FOR THE DISPLAY IT IS SUMMONED TO keeps the two edges it is read from, the
    //    top and the left, and lets the overflow hang below - the same standoff `clampOnScreen`
    //    settles the same way, which is what stops the two from fighting after the move.
    let huge = CGRect(x: 40, y: 40, width: 3000, height: 2000)
    guard let hugeTopLeft = StatusAnchor.summonTopLeft(panel: huge, towards: item, displays: displays)
    else {
        check("a panel larger than its target display is still summoned", false)
        return
    }
    check("a panel too big for the display keeps its top left corner on it",
          near(hugeTopLeft.x, big.visible.minX) && near(hugeTopLeft.y, big.visible.maxY))
    // And that is ONE rule rather than two. Keeping a surface on its display is arithmetic the
    // summon needs and every content-driven resize needs, and two copies of it would be free to
    // disagree about exactly this case - which edge an oversized surface keeps - in a way nothing
    // would notice until a footer was unreachable.
    check("the window clamp is the same arithmetic, not a second copy of it",
          code(of: "Tally/Core/WindowPlacement.swift").contains("StatusAnchor.clampedTopLeft(")
              && !code(of: "Tally/Core/WindowPlacement.swift").contains("origin.x = max(min("))

    // 5. A PANEL STANDING ON NO DISPLAY AT ALL - the screen was unplugged out from under it - has no
    //    place to keep, so it is summoned to the item: centred under it, as high as a window may go.
    //    This is the case `bringToFront` used to answer by raising a window nobody could see.
    let stranded = CGRect(x: 7000, y: 7000, width: 406, height: 257)
    guard let rescued = StatusAnchor.summonTopLeft(panel: stranded, towards: item, displays: displays)
    else {
        check("a panel on a display that no longer exists is summoned back", false)
        return
    }
    check("a panel on a display that no longer exists comes to the item itself",
          near(rescued.y, big.visible.maxY)
              && near(rescued.x + stranded.width / 2, item.midX))
    check("…and lands wholly on the display, like every other answer here",
          big.visible.contains(CGRect(x: rescued.x, y: rescued.y - stranded.height,
                                      width: stranded.width, height: stranded.height)))
    // Same case at the very edge of the display: centring under an item near the right edge would
    // hang the panel off it, so the clamp is part of the answer rather than a step the caller adds.
    let edgeItem = CGRect(x: big.frame.maxX - 30, y: big.frame.maxY - bar, width: 24, height: bar)
    guard let atEdge = StatusAnchor.summonTopLeft(panel: stranded, towards: edgeItem, displays: displays)
    else {
        check("an item at the edge of its display still summons the panel", false)
        return
    }
    check("an item at the very edge does not hang the panel off the display",
          near(atEdge.x, big.visible.maxX - stranded.width))

    // MARK: - and the surfaces are wired to ask

    // 6. THE PINNED PANEL. Three faults lived on the old one-line `bringToFront`: it raised the panel
    //    without moving it, it did nothing at all when there was no panel (an optional chain, so a
    //    click on the item was a silent no-op), and it never put a panel back on screen the way
    //    `show` does. One path answers all three, and it writes an ORIGIN - the size of this surface
    //    has exactly one authority and it is not this file (`SurfaceSizer`).
    let panelSource = code(of: "Tally/MenuBar/PinnedPanelController.swift")
    guard let summonStart = panelSource.range(of: "func summon(onScreenOf anchor: CGRect?)"),
          let summonEnd = panelSource.range(of: "\n    }\n",
                                            range: summonStart.upperBound ..< panelSource.endIndex)
    else {
        check("the panel's summon was found to read", false)
        return
    }
    let summon = String(panelSource[summonStart.upperBound ..< summonEnd.lowerBound])
    check("the pinned panel is summoned to the display the click came from",
          summon.contains("StatusAnchor.summonTopLeft(panel: panel.frame, towards: anchor,")
              && summon.contains("panel.setFrameTopLeftPoint(topLeft)"))
    check("…is shown rather than silently doing nothing when there is no panel yet",
          summon.contains("guard let panel else { return show(atTopLeft: nil) }"))
    check("…and is put back on a screen it can be seen on, which raising alone never did",
          summon.contains("panel.clampOnScreen()") && summon.contains("panel.makeKeyAndOrderFront(nil)"))
    check("…writing an origin and never a size",
          !summon.contains("setContentSize") && !summon.contains("frame.size"))
    check("the raise-and-nothing-else it replaces is gone",
          !panelSource.contains("func bringToFront"))
    // The status item is what says WHICH display, so its own rectangle is what goes in - the same
    // rectangle the decoy is put at, read the same way.
    // The controller's three files as one (`statusControllerFiles`, main.swift): the two claims
    // below are about the controller, and one of them is a COUNT - the shape most quietly defeated
    // by moving a statement into a sibling file.
    check("the item hands its own rectangle to that summon",
          statusControllerSource.contains(
              "PinnedPanelController.shared.summon(onScreenOf: anchorScreenRect(button: button))"))

    // 7. THE DISPLAYS THEMSELVES CHANGING. Putting a surface back used to be reachable only through
    //    a resize, which made it conditional on the content's height cap coming out different - and
    //    two displays of the same height report the same cap, so a panel left on the one that went
    //    away stayed there. The event that says the displays changed is what the clamp belongs on.
    let sizerSource = code(of: "Tally/MenuBar/SurfaceSizer.swift")
    guard let screensStart = sizerSource.range(
            of: "forName: NSApplication.didChangeScreenParametersNotification"),
          let screensEnd = sizerSource.range(of: "\n        }\n",
                                             range: screensStart.upperBound ..< sizerSource.endIndex)
    else {
        check("the screen-topology observer was found to read", false)
        return
    }
    let onScreens = String(sizerSource[screensStart.upperBound ..< screensEnd.lowerBound])
    check("a display appearing or going away puts the surface back on screen by itself",
          onScreens.contains("window.clampOnScreen()"))
    check("…and re-reads the edges the next resize anchors against, like every other write here",
          onScreens.contains("anchorEdges = ") && onScreens.contains("resizeEdges"))

    // 8. THE ANCHOR'S OWN SHAPE. The status item's width changes under this app's own hand - the
    //    waiting dot appears, a percentage goes from two digits to three - and watching only moves
    //    was the assumption that one event always brings the other.
    check("the popover's anchor is followed through resizes as well as moves",
          statusControllerSource.contains(
              "for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification]"))
    // EXACTLY TWO occurrences anywhere in the controller: the declaration, and the one call site
    // inside that loop. Counted rather than merely bounded, because a bound with slack in it is a
    // bound a second feeder can be added under - which is precisely the drift this asserts against.
    check("…through the one handler and the one call site, so the two cannot drift apart",
          statusControllerSource.components(separatedBy: "feedDecoyAnchor()").count - 1 == 2)

    // 9. AND THE SAME QUESTION FOR THE WINDOWS. A summoned window follows the user; the rule used to
    //    apply only to windows that were not up yet, which on one display is right and on several is
    //    a gear that reads as a dead button. The window being worked in is still never moved.
    let placement = code(of: "Tally/Core/WindowPlacement.swift")
    guard let ruleStart = placement.range(of: "var summonShouldFollowPointer: Bool"),
          let ruleEnd = placement.range(of: "\n    }\n",
                                        range: ruleStart.upperBound ..< placement.endIndex)
    else {
        check("the summon rule was found to read", false)
        return
    }
    let rule = String(placement[ruleStart.upperBound ..< ruleEnd.lowerBound])
    check("a window that is not up opens where the user is",
          rule.contains("guard isVisible else { return true }"))
    check("…a window the user is working in is never moved out from under them",
          rule.contains("guard !isKeyWindow else { return false }"))
    check("…and one that is up, unfocused and on another display is summoned to this one",
          rule.contains("StatusAnchor.screenFrame(containing: frame,")
              && rule.contains("return standing != pointer.frame"))
    for (name, path) in [("settings window", "Tally/MenuBar/SettingsWindowController.swift"),
                         ("dashboard window", "Tally/MenuBar/MainWindowController.swift")] {
        let source = code(of: path)
        check("the \(name) asks that one rule rather than restating it",
              source.contains("summonShouldFollowPointer == true")
                  && !source.contains("window?.isVisible != true, !restoring"))
    }

    // 9b. AND A SUMMONED WINDOW HAS TO BE THE HEIGHT THE NEW DISPLAY ALLOWS, which is the half the
    //     first round of this fix missed (found by review of 8cdafad). The settings window fits its
    //     tallest pane whole and lets only the display overrule it, and that answer is a different
    //     number on a different display - while the CONTENT is the same, so the report that would
    //     recompute it never arrives. Moving such a window without re-fitting leaves it at the tall
    //     display's height on a short one, where a clamp can only save the title bar: everything
    //     below the screen's bottom edge, the buttons included, stays unreachable.
    //
    //     Enumerated on the arithmetic, which is why it is arithmetic: fits / capped / floored /
    //     unchanged are the whole set of things a display can do to a reported height.
    let chrome: CGFloat = 28
    let reported: CGFloat = 1200
    let tallVisible: CGFloat = 1400
    let shortVisible: CGFloat = 900
    let onTall = ResizeAnchor.fittedWindowHeight(reported: reported, chrome: chrome,
                                                 visibleHeight: tallVisible)
    let onShort = ResizeAnchor.fittedWindowHeight(reported: reported, chrome: chrome,
                                                  visibleHeight: shortVisible)
    check("a pane that fits its display is fitted whole, cap or no cap",
          near(onTall, reported + chrome) && onTall < tallVisible)
    check("…and the same pane summoned to a shorter display is capped to what that one has",
          near(onShort, shortVisible - ResizeAnchor.screenMargin) && onShort < onTall)
    // Stated a second time WITHOUT reference to the margin, because the line above moves with it: an
    // assertion whose both sides are the constant being changed cannot notice the constant changing,
    // and "a window shorter than its display, with room left" is the property that actually matters.
    check("…strictly shorter than the display, not merely equal to it",
          onShort < shortVisible && onShort > shortVisible / 2)
    check("…which is the whole point: the height it was is taller than the display it went to",
          onTall > shortVisible)
    check("a display too short even for the margin still leaves a window worth having",
          near(ResizeAnchor.fittedWindowHeight(reported: 40, chrome: chrome, visibleHeight: 300),
               ResizeAnchor.minimumWindowHeight))
    check("…and a summon between displays of the same height recomputes to the height it already has",
          near(ResizeAnchor.fittedWindowHeight(reported: reported, chrome: chrome,
                                               visibleHeight: tallVisible), onTall))
    // The two halves have to MEET: a capped height is only useful if the placement then puts the
    // whole window inside the display. Asserted through the same clamp the windows use, so this is
    // the real composition rather than two facts side by side.
    let shortScreen = CGRect(x: 0, y: 0, width: 1600, height: shortVisible)
    let summoned = CGSize(width: 651, height: onShort)
    let placed = StatusAnchor.clampedTopLeft(CGPoint(x: 300, y: shortScreen.maxY + 200),
                                             size: summoned, within: shortScreen)
    check("a window fitted then clamped ends up wholly inside the display it was summoned to",
          shortScreen.contains(CGRect(x: placed.x, y: placed.y - summoned.height,
                                      width: summoned.width, height: summoned.height)))
    // …and the same composition with the UNFITTED height is what the bug looked like: the clamp
    // holds the top edge, so the bottom of the window is off the display and stays there.
    let unfitted = CGSize(width: 651, height: onTall)
    let stuck = StatusAnchor.clampedTopLeft(CGPoint(x: 300, y: shortScreen.maxY + 200),
                                            size: unfitted, within: shortScreen)
    check("…while the unfitted height clamps to a window whose bottom is off the screen (the bug, stated)",
          !shortScreen.contains(CGRect(x: stuck.x, y: stuck.y - unfitted.height,
                                       width: unfitted.width, height: unfitted.height))
              && near(stuck.y, shortScreen.maxY))

    let settingsSource = code(of: "Tally/MenuBar/SettingsWindowController.swift")
    check("the settings window fits its height to the display it is going to, before it is placed there",
          precedes("fitHeight(on: NSScreen.pointerScreen)", "window?.centerOnPointerScreen()",
                   in: settingsSource)
              && precedes("window?.centerOnPointerScreen()", "window?.clampOnScreen()",
                          in: settingsSource))
    check("…keeping the reported height rather than only the applied one, since no new report is coming",
          settingsSource.contains("private var reportedHeight: CGFloat = 0")
              && settingsSource.contains("reportedHeight = height"))
    check("…through the one function that writes this window's height, not a second frame write",
          settingsSource.components(separatedBy: "window.setFrame(frame, display: true)").count == 2
              && settingsSource.contains("private func fitHeight(on screen: NSScreen?)"))
    check("…and the cap itself is the shared arithmetic rather than numbers inline here",
          settingsSource.contains("ResizeAnchor.fittedWindowHeight(reported: reportedHeight,")
              && !settingsSource.contains("- 40") && !settingsSource.contains("max(200,"))
    // Same-screen summons must not resize either, and the guard that decides that is a comparison
    // against the height the window already has: without it, every summon writes a frame.
    check("…with no write at all when the fitted height is the height it already is",
          settingsSource.contains("guard abs(target - window.frame.height) > 1 else { return }"))

    // 9c. THE DASHBOARD DOES NOT NEED ANY OF THAT, and the reason is a mechanism rather than luck:
    //     its cap does not live in its controller at all. The content reads the cap off its own host
    //     screen and re-reads it on every window move (`PopoverRootView.refreshScreenCap`), so the
    //     move a summon makes is itself what recomputes the height, and the shared sizing contract
    //     applies the new report. Asserted here because it is the reason the fix above is only in
    //     one of the two controllers: if that observer goes, this exemption goes with it silently.
    let rootSource = code(of: "Tally/Views/PopoverRootView.swift")
    check("the dashboard's cap is re-read whenever its window moves, which is what a summon does",
          rootSource.contains("publisher(for: NSWindow.didMoveNotification)")
              && rootSource.contains("refreshScreenCap()"))
    check("…off the display the surface is on, so a move to a shorter one answers differently",
          rootSource.contains("ScreenFitStack.maxHeight(on: hostScreen(), topEdge: hostTopEdge())"))
    check("…and the dashboard's summon still clamps, since holding a top edge is not staying on screen",
          precedes("window?.centerOnPointerScreen()", "window?.clampOnScreen()",
                   in: code(of: "Tally/MenuBar/MainWindowController.swift")))

    // 10. A MINIMIZED WINDOW IS STILL OPEN. `isVisible` answers false for one (measured 2026-08-15:
    //     false while minimized, true again on deminiaturize), so the flag an update relaunch reads
    //     was recording a window parked in the Dock as one the user had closed.
    for (name, path) in [("settings window", "Tally/MenuBar/SettingsWindowController.swift"),
                         ("dashboard window", "Tally/MenuBar/MainWindowController.swift")] {
        let source = code(of: path)
        check("the \(name) restores a window the user had minimized, not just a visible one",
              source.contains("var isWindowOpen: Bool { isWindowVisible || window?.isMiniaturized == true }")
                  && source.contains("UserDefaults.standard.set(isWindowOpen, forKey: Self.restoreKey)"))
    }
}
