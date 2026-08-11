import CoreGraphics

/// Whether the status item is somewhere a popover can be anchored to right now.
///
/// The menu bar is not always on screen. With "Automatically hide and show the menu bar" on and the
/// bar hidden, the status item's window is still there but it sits in the strip ABOVE its display,
/// off screen (the same fact `StatusItemController.menuBarScreen` exists to work around). Anything
/// that asks AppKit to place a surface against that anchor is asking it to place it off screen, and
/// AppKit answers by putting the popover in the top-left corner of the display with its arrow
/// pointing back at the corner it came from - which is what the user sees.
///
/// Pure geometry in its own file so a test can compile it without AppKit (tests/windowanchor), and
/// because the question is about a rectangle and a display, not about a window.
enum StatusAnchor {
    /// True when the status button's window is really on `screen` - measured at its centre, so a
    /// point of rounding at the top edge cannot read as hidden while a bar mid-reveal (half in the
    /// strip, half on the display) reads as whichever half it is mostly in.
    ///
    /// `screen` is the display the bar itself is on (`menuBarScreen`), never the one the window
    /// frame happens to land in: with a second display stacked above this one, the hidden strip is
    /// inside THAT display, and asking "is this frame on some screen" would answer yes for the one
    /// case this exists to catch.
    /// A window with no size at all has no centre worth asking about (an item that never installed),
    /// and an empty screen answers no on its own - `CGRect.contains` holds nothing.
    static func isOnScreen(buttonWindow: CGRect, screen: CGRect) -> Bool {
        guard !buttonWindow.isEmpty else { return false }
        return screen.contains(CGPoint(x: buttonWindow.midX, y: buttonWindow.midY))
    }
}
