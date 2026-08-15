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

    /// A display as the summoning arithmetic needs it: the WHOLE rectangle, which is where the menu
    /// bar and the items in it live, and the part a window may occupy, which is where a surface may
    /// be put.
    ///
    /// Both, because they are not the same rectangle and each answers a different half of a summon.
    /// The status item says which display the user clicked on, and it sits IN the menu bar - outside
    /// `visibleFrame` on every machine whose bar is showing - so an arithmetic that looked for the
    /// anchor among visible frames would find no display at all and quietly decline to move anything.
    struct Display: Equatable {
        let frame: CGRect
        let visible: CGRect
    }

    /// WHERE A PINNED PANEL GOES WHEN IT IS SUMMONED FROM A DISPLAY IT IS NOT ON.
    ///
    /// The panel is a fixture the user placed, and until now that meant a click on the status item
    /// only raised it - on whichever display it was left on, which on a four-display machine is
    /// routinely one nobody is looking at (reported 2026-08-15: "the panel opens on another
    /// monitor"). A summon is the one moment the fixture rule has to give: the user is asking for it
    /// HERE, and z-order is not an answer to "where".
    ///
    /// What it keeps is the PLACE ON THE DISPLAY rather than the coordinates - the same corner, the
    /// same inset, scaled between displays of different sizes - because that is the part of "where
    /// the user put it" that survives the move. Dropping it under the item instead would throw away
    /// a position the user chose every time they glanced at it from another desk.
    ///
    /// Nil means MOVE NOTHING, and it is three different facts wearing one answer: no anchor to
    /// summon towards, an anchor on no display this machine has, or a panel already standing on the
    /// display the click came from. Nil rather than "the origin it already has" so the caller writes
    /// no frame at all: a summon that rewrote the origin on every click would walk the panel a
    /// rounding point at a time.
    static func summonTopLeft(panel: CGRect, towards anchor: CGRect?,
                              displays: [Display]) -> CGPoint? {
        guard let anchor, !anchor.isEmpty, !panel.isEmpty else { return nil }
        let anchorCentre = CGPoint(x: anchor.midX, y: anchor.midY)
        guard let target = displays.first(where: { $0.frame.contains(anchorCentre) })
        else { return nil }
        let source = displays.first { $0.frame.contains(CGPoint(x: panel.midX, y: panel.midY)) }
        guard source != target else { return nil }
        let wanted: CGPoint
        if let source, source.visible.width > 0, source.visible.height > 0 {
            wanted = CGPoint(
                x: target.visible.minX
                    + (panel.minX - source.visible.minX) * (target.visible.width / source.visible.width),
                y: target.visible.maxY
                    - (source.visible.maxY - panel.maxY) * (target.visible.height / source.visible.height))
        } else {
            // Standing on no display at all - a screen was unplugged out from under it - so there is
            // no place to keep. It is summoned to the item itself: centred under it, top edge as
            // high as a window may go.
            wanted = CGPoint(x: anchor.midX - panel.width / 2, y: target.visible.maxY)
        }
        return clampedTopLeft(wanted, size: panel.size, within: target.visible)
    }

    /// KEEPING A SURFACE ON ITS DISPLAY, as arithmetic on a top-left corner. The one statement of
    /// it: `NSWindow.clampOnScreen` is this function with a window's frame in it, and the summon
    /// above is this function with a proposed placement in it. Two copies would be free to disagree
    /// about which edge a surface too big for its display keeps, and this file's own history is a
    /// list of invariants that died of having two implementations.
    ///
    /// The clamp ORDER decides that edge, and it is the last clamp applied that wins: both keep the
    /// edge the surface is read FROM, which is the left one and the top one (the header is up there).
    static func clampedTopLeft(_ topLeft: CGPoint, size: CGSize, within visible: CGRect) -> CGPoint {
        let x = max(min(topLeft.x, visible.maxX - size.width), visible.minX)
        let bottom = min(max(topLeft.y - size.height, visible.minY), visible.maxY - size.height)
        return CGPoint(x: x, y: bottom + size.height)
    }

    // A popover's ORIGIN is deliberately not computed here any more. Three rounds of this file
    // corrected the surface's position after AppKit had placed it, and every one of them lost to a
    // resident model that placed it again; the arithmetic that put it back (`heldOrigin`, with its
    // held constants and its clamp) went with them when the popover was given an anchor nothing
    // outside the app can move. What is left is the two questions that decide whether the anchor may
    // be followed, which is all the app still asks about placement.
}
