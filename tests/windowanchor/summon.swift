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
    // AND NOTHING ELSE, which is what the one-anchor rule bought: this used to have to write down
    // the edges the next resize would put back, because a second corner needed a remembered shape to
    // hold. `sizeNow` reads the edge it holds off the window in the statement that resizes it, so
    // there is nothing here for a stale copy of it to be.
    check("…and remembers nothing, because the anchor is read where it is used",
          !onScreens.contains("anchorEdges"))

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
    //     first round of this fix missed (found by review of 8cdafad). The settings window is one
    //     fixed size and lets only the display overrule its height, and that answer is a different
    //     number on a different display - while the content is the same. Moving such a window
    //     without re-sizing leaves it at the tall display's height on a short one, where a clamp can
    //     only save the title bar: everything below the screen's bottom edge, the buttons included,
    //     stays unreachable.
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
          near(ResizeAnchor.fittedWindowHeight(reported: 40, chrome: chrome, visibleHeight: 200),
               ResizeAnchor.minimumWindowHeight))
    // THE FLOOR UNDER THE CONTENT, which is the case the shortest pane produces: About measures a
    // hair over its sidebar, and fitted to that alone the window came out a 200pt sliver. Stated
    // as the content height (the title bar is not content), because that is what the number means.
    let floored = ResizeAnchor.fittedWindowHeight(reported: 200, chrome: chrome,
                                                  visibleHeight: tallVisible)
    check("a pane shorter than the floor is given the floor, in content",
          near(floored - chrome, ResizeAnchor.minimumContentHeight))
    check("…and a pane taller than it is left alone",
          near(ResizeAnchor.fittedWindowHeight(reported: ResizeAnchor.minimumContentHeight + 100,
                                               chrome: chrome, visibleHeight: tallVisible) - chrome,
               ResizeAnchor.minimumContentHeight + 100))
    // Floor first, cap second, and the cap wins: a floor honoured past the screen edge would put
    // the window's own bottom rows out of reach, which is what the cap is for.
    check("…and a display too short for the floor caps below it rather than overhanging",
          near(ResizeAnchor.fittedWindowHeight(reported: 40, chrome: chrome, visibleHeight: 300),
               300 - ResizeAnchor.screenMargin))
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
    check("the settings window sizes itself for the display it is going to, before it is placed there",
          precedes("applyFixedSize(on: NSScreen.pointerScreen)", "window?.centerOnPointerScreen()",
                   in: settingsSource)
              && precedes("window?.centerOnPointerScreen()", "window?.clampOnScreen()",
                          in: settingsSource))
    // THE SIZE COMES FROM THE CHROME CONSTANTS AND NOTHING ELSE. A view that reports a height, or a
    // controller that keeps one, is a second size authority and the pane-fitted window is back.
    check("…from the fixed window constants, with no height reported by the view",
          settingsSource.contains("SettingsChrome.windowHeight - chrome")
              && settingsSource.contains("SettingsChrome.windowWidth")
              && !settingsSource.contains("reportedHeight")
              && !settingsSource.contains("onContentHeight")
              && !settingsSource.contains("onPaneSwitch")
              && !settingsSource.contains("applyContentHeight")
              && !settingsSource.contains("applyPaneSwitch"))
    check("…through the one function that writes this window's frame, not a second frame write",
          settingsSource.components(separatedBy: "setFrame(").count == 2
              && settingsSource.contains("private func applyFixedSize(on screen: NSScreen?) {")
              && settingsSource.components(separatedBy: "setContentSize(").count == 2
              && settingsSource.contains(
                  "setContentSize(NSSize(width: SettingsChrome.windowWidth, height: SettingsChrome.windowHeight))"))
    check("…and the cap itself is the shared arithmetic rather than numbers inline here",
          settingsSource.contains("ResizeAnchor.fittedWindowHeight(reported: SettingsChrome.windowHeight - chrome,")
              && !settingsSource.contains("- 40") && !settingsSource.contains("max(200,"))
    // Same-screen summons must not rewrite the frame either: the guard is a comparison against the
    // size the window already has, and without it every summon writes one.
    check("…with no write at all when the size is the size it already is",
          settingsSource.contains(
              "guard ResizeAnchor.needsResize(from: window.frame.size, to: size) else { return }"))
    // A RESTORE KEEPS THE SAVED POSITION BUT NOT THE SAVED SIZE. The frame autosave brings back the
    // size the window last had, and with no content report any more nothing else would correct an
    // older build's pane-fitted height.
    check("…including a launch-time restore, which has no summon to size it",
          settingsSource.contains("if restoring {\n            applyFixedSize(on: window?.screen)")
              && settingsSource.components(separatedBy: "applyFixedSize(on:").count >= 3)

    // 9bb. AND THE SCROLL LENGTH IS THE PANE IN FRONT, not the tallest of the five. The window is
    //      one fixed size, so what a pane's own height decides is how far the column scrolls: all
    //      five laid out together would scroll About through as much blank page as Integrations is
    //      tall. Asserted on both sides - the shape that gives a height to one pane, and the absence
    //      of the shape that laid out all of them - because the old one is invisible once it works:
    //      a ZStack of five panes still SHOWS the right pane, it only scrolls the wrong length.
    let settingsView = code(of: "Tally/Views/SettingsView.swift")
    check("the settings view gives a height to the selected pane and none to the rest",
          settingsView.contains(".frame(height: section == item ? nil : 0, alignment: .top)")
              && settingsView.contains(".clipped()"))
    // COLLAPSED, NOT REMOVED. Building only the selected pane measures just as well and destroys
    // every pane the user leaves - and a pane here can be holding work (see the implication below).
    check("…keeping the other four alive behind it, seen by nothing",
          settingsView.contains("ZStack(alignment: .top)")
              && settingsView.contains(".opacity(section == item ? 1 : 0)")
              && settingsView.contains(".allowsHitTesting(section == item)")
              && settingsView.contains(".accessibilityHidden(section != item)")
              && !settingsView.contains(
                  "private var pane: some View {\n        paneContent(section)\n    }"))
    // AND THE REASON, AS AN IMPLICATION rather than a fact, so that doing the other right thing
    // later (lifting the staged pair out of the row) does not fail this suite for being right:
    // WHILE the launch defaults are staged in view state, the view holding them may not be one the
    // window throws away. A model picked, a glance at another pane and a click back would put the
    // committed model on screen with nothing said (found by review of 5e9e03d).
    let launchRows = code(of: "Tally/Views/SettingsLaunchRows.swift")
    let stagedIsViewState = launchRows.contains("@State private var stagedModel: String?")
        && launchRows.contains("@State private var stagedEffort: String?")
    check("staged, unapplied launch defaults are not thrown away by a visit to another pane",
          !stagedIsViewState || settingsView.contains("paneContent(item)"))
    // THE VIEW REPORTS NO SIZE, so there is nothing for the window to follow. A probe, a measured
    // height or a callback in the view is the pane-fitted window coming back through the front door.
    check("the settings view reports no height to the window",
          !settingsView.contains("onContentHeight")
              && !settingsView.contains("onPaneSwitch")
              && !settingsView.contains("paneHeights")
              && !settingsView.contains("heightProbe")
              && !settingsView.contains("GeometryReader"))
    // The sidebar's footer (a private build's account chip) is pushed to the foot of the window by
    // the spacer, not measured. Adjacency rather than order, because `Spacer(minLength: 0)` is
    // written twice in this file with two meanings - the one inside a sidebar ROW pushes its label
    // left, and the one being asserted here fills the column.
    check("…and the sidebar's footer is pushed to the foot of the window by a spacer, not measured",
          settingsView.contains("Spacer(minLength: 0)\n            overlaySidebarFooter"))

    // 9bc. THE CHANGE IS NEVER ANIMATED (Albert, 2026-10-10: the growing window read as the pane
    //      "unrolling" under the click). Asserted as an absence of every way AppKit animates a
    //      frame, since an animation needs no flag of ours to come back: one `animator()` is enough.
    check("the settings window's height is written instantly, never through an animation",
          !settingsSource.contains("animator()")
              && !settingsSource.contains("NSAnimationContext")
              && !settingsSource.contains("animate:")
              && settingsSource.contains("window.setFrame(frame, display: true)"))
    check("…and the resize holds the top edge, so the sidebar row under the cursor does not move",
          settingsSource.contains("frame.origin.y = top - height"))
    // The autosave name stays v6: the size it saves is rewritten on every show (above), so an old
    // saved size cannot win, and a new name would only throw away every user's saved position.
    check("…and the autosave name is v6, not v5 (whose saved heights were the tallest pane's)",
          settingsSource.contains("TallySettingsWindow.v6")
              && !settingsSource.contains("TallySettingsWindow.v5"))

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
    //     The write itself is named per controller rather than matched as one literal: the settings
    //     window's goes through a guard of its own now (a capture launch may not record a window the
    //     user did not open, `CaptureLaunch.mayRecordWindowState`), and what this check is about is
    //     the VALUE that reaches the flag, which is `isWindowOpen` on both sides of that change.
    for (name, path, write) in
        [("settings window", "Tally/MenuBar/SettingsWindowController.swift",
          "Self.recordRestore(isWindowOpen)"),
         ("dashboard window", "Tally/MenuBar/MainWindowController.swift",
          "UserDefaults.standard.set(isWindowOpen, forKey: Self.restoreKey)")] {
        let source = code(of: path)
        check("the \(name) restores a window the user had minimized, not just a visible one",
              source.contains("var isWindowOpen: Bool { isWindowVisible || window?.isMiniaturized == true }")
                  && source.contains(write))
    }
}

// A PANE SWITCH NEVER CHANGES THE WINDOW (Albert, 2026-09-28: the window "unrolled" under a pane
// that was already there; 2026-10-10: and not by animating between them either; 2026-11-12: it
// still grew and shrank on every sidebar click). The window is one size on every pane, and a switch
// only changes the pane and scrolls it to its top.
func checkPaneSwitchOrder() {
    // The fixed content height is the only thing the window asks the display about: 700 in total on
    // a display with room, and the display's cap on one without.
    check("the fixed height is the window's height on a tall display and the display's cap on a short one",
          near(ResizeAnchor.fittedWindowHeight(reported: 700 - 28, chrome: 28, visibleHeight: 1400), 700)
              && near(ResizeAnchor.fittedWindowHeight(reported: 700 - 28, chrome: 28, visibleHeight: 700),
                      700 - ResizeAnchor.screenMargin))
    let chromeSource = code(of: "Tally/Views/SettingsChrome.swift")
    check("…and that height and the width come from one place, the chrome constants",
          chromeSource.contains("static let windowHeight: CGFloat = 700")
              && chromeSource.contains("static var windowWidth: CGFloat { sidebarWidth + contentWidth }")
              && !chromeSource.contains("maxWindowHeight"))

    // Every way a pane changes goes through the one function.
    let view = code(of: "Tally/Views/SettingsView.swift")
    let assignments = view.split(separator: "\n").filter {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("section = ")
    }
    check("the pane in front is assigned in exactly one place, select (\(assignments.count))",
          assignments.count == 1)
    check("…and the sidebar and the Launch pane's link both go through it",
          view.contains("Button {\n                    select(item)\n                }")
              && view.contains("select(.integrations)"))
    check("…which changes the pane and scrolls it to the top, with nothing waiting on it",
          view.contains("        section = item\n        scrollTarget = Self.paneTopAnchor")
              && view.contains("Color.clear.frame(height: 0).id(Self.paneTopAnchor)")
              && !view.contains("pendingSection"))
    // The Launch link scrolls to a group of the pane it lands on, after the switch has asked for the
    // top; the scroll request is consumed on its last value, so the link still wins.
    check("…and the Launch pane's link asks for its group after the switch asked for the top",
          precedes("select(.integrations)", "scrollTarget = Self.sharedHarnessAnchor", in: view))
    let controller = code(of: "Tally/MenuBar/SettingsWindowController.swift")
    check("…and the window is not asked to do anything about it",
          !controller.contains("applyPaneSwitch")
              && !view.contains("onPaneSwitch")
              && controller.contains("hosting.sizingOptions = []"))
    check("…the view handed to the window carries only its two stores",
          controller.contains("NSHostingController(rootView: SettingsView(store: .shared, settings: .shared))"))
}
