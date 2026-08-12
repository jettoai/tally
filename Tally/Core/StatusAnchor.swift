import CoreGraphics

/// Whether the status item is somewhere a popover can be anchored to right now.
///
/// The anchor does not stay put. With "Automatically hide and show the menu bar" on, the status
/// item's window sits in the strip ABOVE its display while the bar is hidden; and on a machine with
/// several displays the system PARKS that window on another display entirely when the bar it was
/// summoned on goes away (measured 2026-08-12: the window moved from the display the user had just
/// clicked on to the main display's bar strip, 110ms after the popover opened, with nothing in this
/// app touching it). Anything that asks AppKit to place a surface against that anchor is asking it
/// to place the surface where the anchor is NOW - off screen in the first case, on another display
/// in the second - which is the jump the user sees.
///
/// Pure geometry in its own file so a test can compile it without AppKit (tests/windowanchor), and
/// because the question is about rectangles and displays, not about windows.
enum StatusAnchor {
    /// True when the status button's window is really on `screen` - measured at its centre, so a
    /// point of rounding at the top edge cannot read as hidden while a bar mid-reveal (half in the
    /// strip, half on the display) reads as whichever half it is mostly in.
    ///
    /// `screen` is the display THE POPOVER IS STANDING ON, and the caller has to keep it that way.
    /// Asking against the display the anchor itself is on is self-referential and can only ever
    /// answer false for an anchor that has fallen off every display: the question "is the anchor on
    /// the anchor's own screen" answered true for a window the system had parked on a different
    /// display, which is exactly the case it was written to catch (2026-08-12, two guards blind for
    /// the same reason). Two independent facts have to meet here: where the anchor is, and where the
    /// surface the user is reading is.
    /// A window with no size at all has no centre worth asking about (an item that never installed),
    /// and an empty screen answers no on its own - `CGRect.contains` holds nothing.
    static func isOnScreen(buttonWindow: CGRect, screen: CGRect) -> Bool {
        guard !buttonWindow.isEmpty else { return false }
        return screen.contains(CGPoint(x: buttonWindow.midX, y: buttonWindow.midY))
    }

    /// The display `surface` is standing on, by the same centre rule: a surface straddling two
    /// displays belongs to the one holding its middle, and one standing on none (a window in the
    /// strip above the desktop, or a display that has been unplugged out from under it) belongs to
    /// nothing and says so.
    ///
    /// Takes the screen frames rather than reading `NSWindow.screen` on purpose. That property is
    /// answered by AppKit AFTER whatever just moved the window, which is the trap the shared
    /// `clampOnScreen` sits in: a surface pushed over a display boundary is tidied onto the display
    /// it was pushed onto, not the one it belongs to.
    static func screenFrame(containing surface: CGRect, among screens: [CGRect]) -> CGRect? {
        guard !surface.isEmpty else { return nil }
        let centre = CGPoint(x: surface.midX, y: surface.midY)
        return screens.first { $0.contains(centre) }
    }

    // A popover's ORIGIN is deliberately not computed here any more. Three rounds of this file
    // corrected the surface's position after AppKit had placed it, and every one of them lost to a
    // resident model that placed it again; the arithmetic that put it back (`heldOrigin`, with its
    // held constants and its clamp) went with them when the popover was given an anchor nothing
    // outside the app can move. What is left is the two questions that decide whether the anchor may
    // be followed, which is all the app still asks about placement.
}
