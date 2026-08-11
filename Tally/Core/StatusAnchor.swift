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

    /// Where a popover has to be put back to when its content changed size against an anchor nobody
    /// can see: the top edge and the horizontal centre it already had, at its new `size`.
    ///
    /// Declining to hand the anchor back is not enough on its own, because HANDING NSPOPOVER A
    /// CONTENT SIZE IS ITSELF A PLACEMENT: it re-derives the anchor from the positioning view's
    /// window on every write, and while the bar is hidden that window is in the strip. Measured
    /// (2026-08-12): with a display stacked above, the surface was thrown 350pt up onto that
    /// display; with nothing above the strip it landed at the host display's top-left corner with
    /// its arrow pointing at the corner, which is the report this answers.
    ///
    /// The top edge, because the popover hangs off the bar and grows downward - the same rule a
    /// visible anchor would have given it. The centre, because that is where the arrow is: a popover
    /// is centred on the item it points at, so a surface that widens has to widen about that point
    /// rather than off one of its own edges.
    ///
    /// `screen` is the bar's own display and the horizontal clamp is measured against it, NOT
    /// against whichever display the widened surface now mostly covers: an item near the right of
    /// the bar puts more than half of a wide popover onto the display next door, and a clamp that
    /// asked the window where it was would answer "that one" and tidily park it there. Too wide to
    /// fit keeps the left edge, which is the edge the content is read from (`clampOnScreen`).
    ///
    /// Nothing clamps the vertical: a surface taller than the display is pinned to the top and keeps
    /// its overflow below, which is the rule the whole app sizes to (`ScreenFitStack`), and a bottom
    /// clamp here would be a second answer to the question the held top edge just answered.
    static func heldOrigin(previous: CGRect, size: CGSize, within screen: CGRect) -> CGPoint {
        let centred = previous.midX - size.width / 2
        let rightmost = max(screen.maxX - size.width, screen.minX)
        return CGPoint(x: min(max(centred, screen.minX), rightmost), y: previous.maxY - size.height)
    }
}
