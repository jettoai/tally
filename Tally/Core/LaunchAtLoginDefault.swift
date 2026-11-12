import Foundation

/// The invited registration: the welcome window offers "Open Tally when you log in" on its two
/// finishing pages (ticked by default), and the button the user presses to leave is what registers
/// it, or not. Nothing registers at launch, and closing the window registers nothing. From then on
/// the switch in Settings owns it.
///
/// WHY THIS STILL STORES ONE BIT, in a feature whose whole rule is that state gets read and never
/// stored. The test is not "is it about login items", it is "can anything outside this app change
/// it without telling us". The login item's status can: System Settings revokes it and nothing
/// notifies the app, so reading it is the only way to be right. Whether this Mac has ever run
/// Tally cannot: nothing outside the app knows it happened, so there is nothing to re-read. That
/// bit decides one thing only, whether the welcome window is a first run's (`hasLaunchedBefore`).
///
/// Registering at launch used to be this file's job, and it was uninvited: the user had agreed to
/// nothing and macOS announced a "Login Item Added". The record of having done it doubled as the
/// first-run check, so `appliedKey` is still READ (an upgrade is not a first run) and never written.
enum LaunchAtLoginDefault {
    /// Written by every launch that may write (`recordsLaunch`): this Mac has run Tally. Per user,
    /// per bundle id, so the dev flavour cannot spend the release app's first run.
    static let ranBeforeKey = "tallyHasLaunched"

    /// The retired launch-time registration's record. Never written any more; installs that wrote
    /// it have run Tally before, and must not be welcomed again by an update.
    static let appliedKey = "launchAtLoginDefaultApplied"

    /// Whether this Mac has run Tally before, from the two keys that can say so.
    static func hasLaunchedBefore(ranBefore: Bool, legacyApplied: Bool) -> Bool { ranBefore || legacyApplied }

    /// Whether this launch may record that it happened. A launch that must not touch the machine
    /// has not been "the first run" of anything: the copy running from a mounted disk image shares
    /// its bundle id, and therefore its preferences, with the app the user is about to drag into
    /// place, and claiming the run would rob that app of its welcome.
    static func recordsLaunch(isUnshipped: Bool, isDemo: Bool) -> Bool { !isUnshipped && !isDemo }

    enum Plan: Equatable {
        /// Register the login item.
        case register

        /// Do nothing.
        case skip
    }

    /// What pressing a finishing button should do about the login item.
    ///
    /// `wanted` is the checkbox. `isUnshipped` is the same gate the Settings row's write path uses,
    /// for the same reason and with no exception: `SMAppService.mainApp` registers the bundle that
    /// is RUNNING, so a dev build, a build tree, or a copy launched out of a disk image would take
    /// the installed app's login item over and aim the next login at a directory that is about to
    /// stop existing. The box is still drawn there (the page is what is being reviewed); it just
    /// registers nothing.
    ///
    /// `isDemo` is here so that no launch capable of showing fixtures ever changes the machine,
    /// which is the standing rule for demo mode (it runs no provider CLI and writes no snapshot).
    static func plan(wanted: Bool, isUnshipped: Bool, isDemo: Bool) -> Plan {
        guard wanted, !isUnshipped, !isDemo else { return .skip }
        return .register
    }

    /// Carry out a plan, with the effect passed in so the sequence can be exercised without a
    /// login item anywhere near it. Returns what the attempt threw, for the Settings row to show.
    ///
    /// The error is caught and reported rather than swallowed or raised: the window is already
    /// closing when this runs, so throwing has nobody to tell, and a modal on the way out would be
    /// shouting at a user who has moved on. The row is where this belongs, and it already knows how
    /// to show a failed attempt and when to stop showing it.
    @discardableResult
    static func apply(_ plan: Plan, register: () throws -> Void) -> LaunchAtLoginFailure? {
        guard plan == .register else { return nil }
        do {
            try register()
            return nil
        } catch {
            return LaunchAtLoginFailure(wanted: true, message: error.localizedDescription)
        }
    }
}

/// What the one attempt threw, held until somebody has been told, and not one reader longer.
///
/// A one-shot rather than a value that is merely never written to disk. "Only this launch" was the
/// wrong boundary: a static lives as long as the PROCESS, while the view that reads it is rebuilt
/// whenever anything rebuilds the Settings tree, and switching the app's language rebuilds all of
/// it (SettingsView keys itself on the language for exactly that effect). Read a second time, a
/// failed startup registration reappears beside a switch the user has since turned off ON PURPOSE,
/// and `surviving` correctly keeps it there, because the state really does contradict what that
/// old attempt asked for. The user is then shown their own deliberate choice as a failure.
///
/// Which is the same fault this whole feature keeps being about: something out of date telling the
/// user about now. The fix has to be that reading it consumes it, not that it is not persisted.
struct LaunchAtLoginAttemptReport {
    private var failure: LaunchAtLoginFailure?

    init(_ failure: LaunchAtLoginFailure?) { self.failure = failure }

    /// Hand the failure over, once. Every later ask gets nil, because by then it has been said.
    mutating func take() -> LaunchAtLoginFailure? {
        defer { failure = nil }
        return failure
    }

    /// Whether a row in this situation may take the report.
    ///
    /// `visible` is here because being BUILT is not being seen. The Settings window lays every pane
    /// out at once in a single stack, the unselected ones merely transparent, so a row on a pane
    /// the user has never opened runs its lifecycle hooks exactly like the one they are looking at.
    /// Taking on `onAppear` therefore had the Accounts pane's neighbour swallow the report the
    /// moment the window opened, and the failure was gone before anyone could have read it: the
    /// same lie as the replay, told from the other side.
    ///
    /// The general rule this came from, worth more than the fix: a lifecycle event may drive
    /// IDEMPOTENT work, never destructive work. `refresh()` re-reading a status on a hidden pane
    /// costs a query and is right either way; `take()` on a hidden pane spends something that
    /// cannot be got back. Anything destructive has to hang off a condition that is true only when
    /// the thing is actually true, which is what `visible` is: a value, not an event.
    static func collectible(visible: Bool, previewing: Bool) -> Bool { visible && !previewing }
}

@MainActor
extension LaunchAtLoginDefault {
    /// The latest registration's report. Private so there is exactly one way to read it, and that
    /// way empties it: a `private(set)` property would let a second reader take the same copy
    /// again, which is the defect this replaced.
    private static var report = LaunchAtLoginAttemptReport(nil)

    /// The failure from the welcome window's registration, for whoever asks first. Nil afterwards.
    static func takeAttemptFailure() -> LaunchAtLoginFailure? { report.take() }

    /// Whether this Mac has run Tally before. Read BEFORE `recordLaunch()` marks this launch.
    static func hasLaunchedBefore() -> Bool {
        hasLaunchedBefore(ranBefore: UserDefaults.standard.bool(forKey: ranBeforeKey),
                          legacyApplied: UserDefaults.standard.bool(forKey: appliedKey))
    }

    /// Mark this launch as having happened, unless it must not touch the machine.
    static func recordLaunch() {
        guard recordsLaunch(isUnshipped: BuildVariant.isUnshipped, isDemo: DemoUsage.isActive) else { return }
        UserDefaults.standard.set(true, forKey: ranBeforeKey)
    }

    /// The welcome window's finishing button: register when the box is ticked. The failure, if any,
    /// waits for the Settings row to collect it once.
    static func registerFromWelcome(wanted: Bool) {
        report = LaunchAtLoginAttemptReport(apply(
            plan(wanted: wanted, isUnshipped: BuildVariant.isUnshipped, isDemo: DemoUsage.isActive),
            register: { try LaunchAtLoginService.setRegistered(true) }))
    }
}
