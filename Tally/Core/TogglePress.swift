import Foundation

/// Whether the click now arriving at the status item is the one that just dismissed the popover.
///
/// The popover hangs off a decoy anchor of our own, which makes the status item OUTSIDE it: pressing
/// the item dismisses the transient popover on the mouse-DOWN, and the item's own action arrives on
/// the mouse-UP. Without this the action would open the popover straight back and the item could not
/// be clicked shut. While the anchor was the item's own window, NSPopover exempted clicks inside it
/// and none of this existed.
///
/// Pure, and in its own file, because the case that decides the shape cannot be exercised against a
/// real popover: transient dismissal ignores mouse events posted into the process (measured, probe
/// v7 and its control), so a held press can only be reasoned about here and confirmed on a machine.
enum TogglePress {
    /// The gap between a mouse-down and its own mouse-up, not the gap between two deliberate visits
    /// to the menu bar.
    static let releaseWindow: TimeInterval = 0.25

    /// - Parameters:
    ///   - pointerWasOnItem: whether the dismissal happened with the pointer over the status item.
    ///     Nothing else may consume a suppression, so dismissing the popover by clicking somewhere
    ///     else leaves nothing behind that could swallow a later, deliberate click on the item.
    ///   - buttonWasDown: whether the mouse button was still held when the dismissal was delivered,
    ///     i.e. the click that caused it had not finished yet. This is the half that answers a press
    ///     HELD for any length of time, which is what a timer alone got wrong: hold the item for a
    ///     second and the window expires, so the release opened the popover the press had just shut.
    ///   - elapsed: how long ago the dismissal was. It only decides anything when the button was
    ///     already up by the time the close was delivered, which is a click short enough to have
    ///     finished first.
    static func suppressesOpen(pointerWasOnItem: Bool, buttonWasDown: Bool,
                               elapsed: TimeInterval) -> Bool {
        guard pointerWasOnItem else { return false }
        return buttonWasDown || elapsed < releaseWindow
    }
}
