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

    /// WHICH DISPLAY THE CARD IS PLACED ON: the one the button it stands on is on, answered by
    /// asking which display holds the button's centre.
    ///
    /// Deliberately not the host window's own `screen`, which answers with the display holding the
    /// LARGEST part of that window: a surface straddling two displays with its footer on the
    /// right-hand one would then be measured against the left-hand display's visible area, and the
    /// card clamped hundreds of points from the button it belongs to. The repo asks anchors this
    /// question the same way everywhere it matters (`StatusItemController.menuBarScreen`,
    /// `StatusAnchor.summonTopLeft`), each time for its own version of this reason.
    ///
    /// Nil means NO DISPLAY HOLDS IT - a button on a screen that was just unplugged - which is the
    /// caller's cue to fall back rather than to place the card against nothing.
    static func display(for anchor: CGRect, in displays: [CGRect]) -> Int? {
        let centre = CGPoint(x: anchor.midX, y: anchor.midY)
        return displays.firstIndex { $0.contains(centre) }
    }

    /// Whether another window of this app coming forward takes the card away.
    ///
    /// A PRESS IS NOT THE ONLY WAY A WINDOW ARRIVES, which is what the press monitors could not see:
    /// Command-, opens Settings from the keyboard, and Sparkle posts its update alert on a timer.
    /// Either one draws over the surface the card belongs to while the card, sitting one level above
    /// that surface, floats on top of the window that just took over - and the keystroke that would
    /// dismiss it is swallowed by the card's own Escape monitor. So a window becoming key is asked
    /// the same question a press is.
    ///
    /// The card and the surface it belongs to are the two exemptions: the card takes key when it
    /// opens, and the surface takes it back for its own reasons (a press on it is already answered
    /// by `dismisses(press:card:toggle:)`, toggle exemption included).
    static func dismisses(windowNumber: Int, card: Int, host: Int) -> Bool {
        windowNumber != card && windowNumber != host
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
