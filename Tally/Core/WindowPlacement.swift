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
}
