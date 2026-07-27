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

    /// Whether the queued install may run right now.
    ///
    /// - Parameters:
    ///   - taskSurfaceOpen: a Tally window the user opened to do something is on screen (the
    ///     popover, Settings, the main window, a modal). A restart would take it away mid-task, so
    ///     this vetoes with no expiry.
    ///   - pinnedPanelOpen: the pinned usage panel is on screen. Vetoes only until
    ///     `pinnedPanelGrace` has passed (see above).
    ///   - secondsSinceUserInput: seconds since the last keyboard or mouse event, machine wide.
    ///   - waiting: how long the install has been queued.
    static func shouldInstall(taskSurfaceOpen: Bool, pinnedPanelOpen: Bool,
                              secondsSinceUserInput: TimeInterval,
                              waiting: TimeInterval) -> Bool {
        if taskSurfaceOpen { return false }
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
