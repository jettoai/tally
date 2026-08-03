import AppKit

extension NSWindow {
    /// Centre on the screen containing the pointer - the house rule for every SUMMONED window
    /// (settings, the main window, dialogs, update alerts): they follow the user, never the
    /// main display or wherever they last were. Persistent fixtures (the pinned panel) keep
    /// their user-placed position instead, and anchored popovers follow their anchor.
    @MainActor func centerOnPointerScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Standard dialog position (AppKit's center()): above the geometric middle, one third of
        // the leftover space above and two thirds below. Matching the system rule means a window
        // WE move lands where an unmoved system/Sparkle window would already be, so consecutive
        // dialogs (checking, then the result alert) don't visibly jump between two heights.
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                               y: visible.minY + (visible.height - frame.height) * 2 / 3))
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
