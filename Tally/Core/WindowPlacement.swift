import AppKit

extension NSScreen {
    /// Every display in the shape the summoning arithmetic takes them (`StatusAnchor.Display`): the
    /// whole rectangle and the part a window may occupy, read together so the two cannot be paired
    /// up wrong by a caller reading them from two different scans.
    /// The display the pointer is on, which is where a summoned surface goes. One statement of it:
    /// the placement below reads it, and so does anything that has to know a summon's destination
    /// BEFORE the surface is moved there (the settings window's height cap).
    @MainActor static var pointerScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    @MainActor static var displays: [StatusAnchor.Display] {
        NSScreen.screens.map { StatusAnchor.Display(frame: $0.frame, visible: $0.visibleFrame) }
    }
}

extension NSWindow {
    /// Centre on the screen containing the pointer - the house rule for every SUMMONED window
    /// (settings, the main window, dialogs, update alerts): they follow the user, never the
    /// main display or wherever they last were. Persistent fixtures (the pinned panel) keep
    /// their user-placed position instead, and anchored popovers follow their anchor.
    @MainActor func centerOnPointerScreen() {
        guard let screen = NSScreen.pointerScreen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Standard dialog position (AppKit's center()): above the geometric middle, one third of
        // the leftover space above and two thirds below. Matching the system rule means a window
        // WE move lands where an unmoved system/Sparkle window would already be, so consecutive
        // dialogs (checking, then the result alert) don't visibly jump between two heights.
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                               y: visible.minY + (visible.height - frame.height) * 2 / 3))
    }

    /// WHETHER A SUMMON MAY MOVE THIS WINDOW TO THE DISPLAY THE USER IS ON.
    ///
    /// The house rule above is "summoned windows follow the user", and it used to be applied only to
    /// windows that were not up yet: an open one stayed put, because yanking a window somebody is
    /// working in would be worse. That reasoning is a single-display reasoning. On several displays
    /// the same rule makes the gear read as a dead button - the window IS open, on a display behind
    /// the user's head, and the display they clicked on does nothing at all (2026-08-15).
    ///
    /// So the question is asked in three parts, and only the last one is new: a window that is not up
    /// opens where the user is; a window that is KEY is the one they are working in and is never
    /// moved; and a window that is up, unfocused, and on another display is summoned to this one.
    @MainActor var summonShouldFollowPointer: Bool {
        guard isVisible else { return true }
        guard !isKeyWindow else { return false }
        guard let pointer = NSScreen.pointerScreen else { return false }
        // By the window's centre, the same rule everything else here uses to say which display a
        // surface is standing on (`StatusAnchor.screenFrame`), so a window straddling a boundary is
        // not summoned back and forth by which half the pointer is over.
        let standing = StatusAnchor.screenFrame(containing: frame,
                                                among: NSScreen.screens.map(\.frame))
        return standing != pointer.frame
    }

    /// Nudge the window back onto a visible screen, origin only - the size belongs to the content
    /// (see the pinned panel's two-size-authorities crash). Runs after every content-driven resize,
    /// not just when a surface opens: these windows keep their TOP edge as they grow, so a fleet
    /// that gets taller pushes its own footer past the bottom of the display, and the footer is the
    /// way back out of it. It also catches the display that went away under a panel left on it.
    ///
    /// A surface can only be moved wholly back on when it fits, which is what `ScreenFitStack`
    /// guarantees; a taller one is pinned to the top of the screen and keeps its overflow below.
    @MainActor func clampOnScreen() {
        // The window's OWN screen, the same one the content sized itself for (`hostScreen`), so a
        // surface straddling two displays is not capped for one and clamped onto the other. Nil
        // only once it is off screen entirely, which is exactly when the scan is worth its cost.
        let screen = self.screen ?? NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        // The arithmetic is `StatusAnchor.clampedTopLeft` and lives there, because the summon that
        // moves a panel to another display has to keep a surface on a screen the same way this does
        // - which edge a surface too big for its display keeps is one rule, not two.
        let topLeft = StatusAnchor.clampedTopLeft(CGPoint(x: frame.minX, y: frame.maxY),
                                                  size: frame.size, within: visible)
        let origin = CGPoint(x: topLeft.x, y: topLeft.y - frame.height)
        if origin != frame.origin { setFrameOrigin(origin) }
    }

    /// Screen-space top-left of the window's CONTENT, i.e. what the user sees the view start at.
    /// Titlebars and borders differ between the surfaces that hand this view to each other (the
    /// popover, the borderless panel, the titled window), so the content rect is the only anchor
    /// they can all agree on - a frame-to-frame hand-off would slide the view by the chrome.
    @MainActor var contentTopLeft: CGPoint {
        let onScreen = convertToScreen(contentLayoutRect)
        return CGPoint(x: onScreen.minX, y: onScreen.maxY)
    }

    /// Move the window so its content top-left lands on `topLeft` - the exact inverse of
    /// `contentTopLeft`, which is what makes a hand-off between two surfaces land in place. Moving
    /// by the delta rather than computing the chrome keeps it correct for any style mask.
    @MainActor func setContentTopLeft(_ topLeft: CGPoint) {
        let current = contentTopLeft
        setFrameOrigin(NSPoint(x: frame.origin.x + (topLeft.x - current.x),
                               y: frame.origin.y + (topLeft.y - current.y)))
    }
}
