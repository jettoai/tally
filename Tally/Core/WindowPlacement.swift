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
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                               y: visible.midY - frame.height / 2))
    }
}
