import CoreGraphics

/// WHERE THE VIEW-OPTIONS CARD STANDS, AND WHAT PUTS IT AWAY.
///
/// The card is a window of its own rather than a popover attached to the footer button, and the
/// reason is the one thing a popover cannot do: STAY STILL. Every control on the card resizes the
/// surface behind it, the surface holds its top left through that resize (`ResizeAnchor`), so the
/// footer - and an attached popover with it - travels by the whole height change on every click.
/// The surface used to move instead, holding its bottom right while the pointer was on the card and
/// jumping back when the card closed; both of those were the panel moving, which is what was
/// actually reported. So the card is placed ONCE, from where the button was when it opened, and
/// nothing moves it afterwards: the controls stay under the pointer because they are not attached to
/// anything that moves.
///
/// Both decisions live here as arithmetic rather than inside the window controller, for the reason
/// this repo keeps re-learning: a rule written inside an AppKit callback is a rule no test can
/// reach, and "where is it put" and "what dismisses it" are exactly the two halves that were wrong
/// last time (`tests/windowanchor`).
enum ViewOptionsCardPlacement {
    /// The breath between the card and the button that opened it. Small: they are one control in two
    /// pieces, and a gap wide enough to read as separation would leave the card floating.
    static let gap: CGFloat = 6

    /// Where a card of `size` goes, for a toggle button occupying `anchor` on a display whose usable
    /// area is `visible` (all in AppKit screen space, y up).
    ///
    /// Above the button and centred on it, which is where the popover this replaces sat, so nothing
    /// about the gesture changed for the person using it. Two bounds on that: a card with no room
    /// above stands UNDER the button instead (the surface can be dragged to the top of a display),
    /// and either way it is kept inside the visible area - a card is worthless off screen, and being
    /// its own window means nothing else will put it back.
    static func frame(size: CGSize, anchor: CGRect, visible: CGRect) -> CGRect {
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        if origin.y + size.height > visible.maxY { origin.y = anchor.minY - gap - size.height }
        origin.x = clamp(origin.x, low: visible.minX, high: visible.maxX - size.width)
        origin.y = clamp(origin.y, low: visible.minY, high: visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    /// Whether a press at `point` puts the card away.
    ///
    /// EVERYTHING BUT THE CARD DOES, and the drag regions are the case that has to be said out loud:
    /// pressing the panel's wordmark to carry it is a press beside the card, so the card goes at once
    /// and the carry starts from the same press - the surface neither waits for a second click nor
    /// moves a point on the way (Albert's call, 2026-08-18).
    ///
    /// The button that opened it is the one exemption, and it is not a courtesy: that button is a
    /// TOGGLE, so a press dismissing the card on the way down would leave its own action to re-open
    /// the card on the way up, and the card could never be closed by the control that opens it.
    ///
    /// `toggle` is read LIVE at the press, not remembered from the opening: the surface behind the
    /// card resizes while the card is up, which moves the footer the button sits in. The card's own
    /// rectangle is the opposite - decided once, when it opened - and that asymmetry is the design.
    static func dismisses(press: CGPoint, card: CGRect, toggle: CGRect?) -> Bool {
        if card.contains(press) { return false }
        if let toggle, toggle.contains(press) { return false }
        return true
    }

    /// Bounded even when the room is smaller than the thing being put in it: the low edge wins, so a
    /// card taller than the display hangs off the bottom rather than being pushed off the top, where
    /// the button that dismisses it would be out of reach.
    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}
