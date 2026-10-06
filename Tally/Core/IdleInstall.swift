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
    /// the panel restores itself on the next launch, and `idleBar` still keeps the restart from
    /// landing while someone is at the machine (until `idleBarCap`).
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

    /// How long an update may wait on `idleBar` before the bar stops applying.
    ///
    /// Machine-wide input is a proxy for a person, and some machines never go quiet by it: an agent
    /// driving the desktop, or a VM forwarding input, posts events every few seconds around the
    /// clock, so an update downloaded there never installed at all (live report 2026-09-27, idle
    /// readings of 0 to 2 seconds for hours on end). What makes a restart costly is not this app:
    /// relaunching Tally only blinks the menu-bar strip, and the expensive handover (the supervisor
    /// restarting Claude sessions) has its own protection in the self-update hold, which waits for
    /// background work. So after a day the bar is dropped. Both graces have long expired by then,
    /// which leaves an open modal as the only thing that still holds the install off.
    static let idleBarCap: TimeInterval = 24 * 3600

    /// One window, in the only terms the question below needs. Built from AppKit at the call site,
    /// so the rule itself can be asked about a machine that is not there.
    struct WindowState {
        /// The window is running an application-modal session (`NSApp.modalWindow`).
        let isApplicationModal: Bool
        /// A sheet is attached to this window (`NSWindow.attachedSheet`), which is what SwiftUI's
        /// `.sheet` modifier puts up.
        let hasAttachedSheet: Bool
    }

    /// Whether something on screen is holding a thing the user has started and not finished. This
    /// is what feeds `shouldInstall`'s `modalOpen`, the one veto with no expiry.
    ///
    /// The question is about intent, not about mechanism. `NSApp.modalWindow` answers the mechanism
    /// question only, and it answers nil for a sheet attached to a window, which is exactly what
    /// SwiftUI's `.sheet` is. So "Add account" - a half-filled form with an OAuth round trip in the
    /// middle of it - never reached this veto at all. It was covered by `taskWindowOpen` instead,
    /// because the sheet hangs off Settings and an open window used to veto forever; once
    /// `taskWindowGrace` put an hour on that, the cover expired and the sheet could be restarted out
    /// from under the person filling it in.
    ///
    /// Popovers are deliberately not counted here, and that is a decision rather than an oversight.
    /// The test is whether the surface holds input the user has not committed: a popover dismisses
    /// itself on a click anywhere outside it and keeps nothing, so this app's three (View Options,
    /// the launch help, the account menu) stay on the `taskWindowOpen` side and are discounted after
    /// `taskWindowGrace` like any other window.
    static func decisionPending(windows: [WindowState]) -> Bool {
        windows.contains { $0.isApplicationModal || $0.hasAttachedSheet }
    }

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
    ///     Must reach `idleBar`, until `waiting` reaches `idleBarCap` (see above).
    ///   - waiting: how long this app has known about the update (`UpdateState.knownSince`), which
    ///     is the clock both grace periods and `idleBarCap` are measured on. It is deliberately not "how long the
    ///     window has been open": what the grace is there to bound is how long an update may be
    ///     held back, and a window opened after the update was already known has no claim to start
    ///     that clock again.
    ///   - sinceLastInstall: seconds since the last install this app ran, nil when it never ran
    ///     one. Below `autoInstallSpacing`, nothing is installed unattended.
    ///   - busySessions: supervised sessions not idle, nil when they cannot be read. Any, or none
    ///     readable, hold the install until `waiting` reaches `busySessionsCap`.
    static func shouldInstall(modalOpen: Bool, taskWindowOpen: Bool, pinnedPanelOpen: Bool,
                              secondsSinceUserInput: TimeInterval,
                              waiting: TimeInterval, sinceLastInstall: TimeInterval? = nil,
                              busySessions: Int? = 0) -> Bool {
        if let since = sinceLastInstall, since < autoInstallSpacing { return false }
        if (busySessions ?? 1) > 0, waiting < busySessionsCap { return false }
        if modalOpen { return false }
        if taskWindowOpen, waiting < taskWindowGrace { return false }
        if pinnedPanelOpen, waiting < pinnedPanelGrace { return false }
        // The human-presence bar holds for a day, then gives way (see `idleBarCap`).
        return secondsSinceUserInput >= idleBar || waiting >= idleBarCap
    }

    /// The fewest seconds between two installs nobody asked for (B-5730: about six a day, each
    /// restarting every supervised session). A person's own check never comes through here: the
    /// reducer installs a requested update without asking `shouldInstall` (UpdateState.swift).
    static let autoInstallSpacing: TimeInterval = 24 * 3600

    /// How long busy or unreadable sessions may hold an install off. Past it the install goes ahead,
    /// so a session that never reports (an old supervisor, a stuck dialog) cannot freeze updates.
    static let busySessionsCap: TimeInterval = 72 * 3600

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
