import Foundation

/// When an already downloaded update is allowed to install itself.
///
/// Sparkle's "automatically download" consent only downloads and PREPARES the update; the install
/// is queued for app termination. `SPUUpdaterDelegate.h` is explicit about it ("In either case
/// Sparkle will always attempt to install the update when the app terminates"), and there is no
/// Info.plist key or updater property that moves the moment. Tally is a menu-bar accessory nobody
/// quits, so that moment never arrived: Sparkle waited out `SUScheduledImpatientCheckInterval` and
/// fell back to asking "install and relaunch now?", which is the one thing the setting promised it
/// would stop doing (live report, 2026-07-27).
///
/// Taking over the install (returning true from `updater(_:willInstallUpdateOnQuit:...)`) hands the
/// app the job of picking the moment. These are the rules for picking it. Pure and Foundation-only
/// so the assertion harness compiles this file alone.
enum IdleInstall {
    /// How still the keyboard and mouse must have been before an install may run. Installing
    /// restarts the app, so the menu-bar strip (and a pinned panel) blink out and come back. Five
    /// minutes is the bar for "nobody is at the machine": long enough that a pause mid-sentence or
    /// a detour into another window never qualifies, short enough that stepping away for a coffee
    /// does.
    static let idleBar: TimeInterval = 300

    /// How long a pinned panel may hold the install off before it stops counting as a reason to
    /// wait. The panel exists to sit on screen indefinitely, so treating it like a window the user
    /// just opened would mean anyone who pins never updates at all. After this it is discounted:
    /// the panel restores itself on the next launch, and `idleBar` still guarantees nobody is
    /// watching the moment it happens.
    static let pinnedPanelGrace: TimeInterval = 6 * 3600

    /// How long an ordinary Tally window (the popover, Settings, the main window) may hold the
    /// install off before it stops counting as a reason to wait.
    ///
    /// An open window used to veto forever, on the reading that a window on screen means a task in
    /// progress. It does not: people leave the main window parked on a second display for days, and
    /// two releases in a row (0.76.6 and 0.77.0) never installed themselves for exactly that reason,
    /// the second one with the window untouched on a display the user was not even looking at (live
    /// reports, 2026-09-21 and 2026-09-22). A window that has been open across a whole hour of an
    /// update waiting is furniture, not a task.
    ///
    /// One hour rather than `pinnedPanelGrace`'s six: a pinned panel is BUILT to sit there forever,
    /// so discounting it early would be overruling what it is for, whereas these three are ordinary
    /// windows and an hour is already far longer than any real interaction with them. Shorter than
    /// an hour is not worth reaching for either, because nothing is lost by waiting: the install
    /// still needs `idleBar` on top, and all three surfaces come back by themselves after the
    /// restart (the popover is one click on the strip, Settings and the main window reopen the same
    /// way they were opened).
    static let taskWindowGrace: TimeInterval = 3600

    /// Whether the queued install may run right now.
    ///
    /// - Parameters:
    ///   - modalOpen: a modal is up, so a decision is sitting in front of the user. Restarting
    ///     would answer it for them, so this vetoes with no expiry.
    ///   - taskWindowOpen: an ordinary Tally window the user opened is on screen (the popover,
    ///     Settings, the main window). Vetoes only until `taskWindowGrace` has passed (see above).
    ///   - pinnedPanelOpen: the pinned usage panel is on screen. Vetoes only until
    ///     `pinnedPanelGrace` has passed (see above).
    ///   - secondsSinceUserInput: seconds since the last keyboard or mouse event, machine wide.
    ///   - waiting: how long this app has known about the update (`UpdateState.knownSince`), which
    ///     is the clock both grace periods are measured on. It is deliberately not "how long the
    ///     window has been open": what the grace is there to bound is how long an update may be
    ///     held back, and a window opened after the update was already known has no claim to start
    ///     that clock again.
    static func shouldInstall(modalOpen: Bool, taskWindowOpen: Bool, pinnedPanelOpen: Bool,
                              secondsSinceUserInput: TimeInterval,
                              waiting: TimeInterval) -> Bool {
        if modalOpen { return false }
        if taskWindowOpen, waiting < taskWindowGrace { return false }
        if pinnedPanelOpen, waiting < pinnedPanelGrace { return false }
        // The human-presence bar is never waived: no amount of waiting makes it acceptable to
        // restart the app out from under someone who is typing.
        return secondsSinceUserInput >= idleBar
    }

    /// Whether Sparkle's standard alert should present a SCHEDULED update.
    ///
    /// With automatic installs on, the app owns the moment (`shouldInstall` above) and the panel
    /// header's update chip is the reminder, so the alert would be asking a question the user has
    /// already answered in Settings. With them off, nothing else would ever raise the subject, so
    /// the standard alert stays exactly as it was.
    ///
    /// User-initiated checks never reach here: Sparkle routes them past the delegate entirely
    /// (`SPUStandardUserDriverDelegate.h`, "This method is not called for user-initiated update
    /// checks"), which is why there is no `userInitiated` input to weigh.
    static func standardAlertShouldShowScheduledUpdate(automaticInstallsEnabled: Bool) -> Bool {
        !automaticInstallsEnabled
    }
}
