import Foundation

/// The one uninvited registration: a Tally nobody has configured starts at login, and after that
/// the switch belongs to the user.
///
/// WHY THIS IS ALLOWED TO REMEMBER SOMETHING, in a feature whose whole rule is that state gets
/// read and never stored. The test is not "is it about login items", it is "can anything outside
/// this app change it without telling us". The login item's status can: System Settings revokes it
/// and nothing notifies the app, so reading it is the only way to be right. Whether Tally has ever
/// made its one attempt cannot: nothing outside the app knows it happened, so there is nothing to
/// re-read and no way for a stored answer to go stale. Same category as the `wanted` kept beside a
/// failure, and for the same reason.
///
/// It is also not recoverable by reading, which is the stronger half of the argument. "Never asked"
/// and "asked, and the user said no" both look like `notRegistered` from the outside. An
/// implementation that registered whenever it found `notRegistered` would turn the switch off for
/// the user and back on at the next launch, forever: the distinction that stops that does not exist
/// in the world, so it has to be written down or it does not exist at all.
enum LaunchAtLoginDefault {
    /// The one bit this feature stores. Per user, per bundle id, so the dev flavour cannot spend
    /// the release app's attempt.
    static let appliedKey = "launchAtLoginDefaultApplied"

    enum Plan: Equatable {
        /// Make the attempt, then record it as made WHATEVER it returns.
        ///
        /// Recording a failure as done is the deliberate half. The record means "the one uninvited
        /// action has been spent", not "it worked", and a failed attempt spent it just the same.
        /// The failures that actually happen are persistent ones (consent already withheld, a code
        /// signature macOS refuses), so retrying at every launch would either achieve nothing or,
        /// in the denial case, have the app quietly arguing with a user who has already said no.
        /// A genuinely transient failure loses its retry; that is the price, and it is smaller than
        /// the alternative because the switch is right there and the row says what is wrong.
        case attemptThenRecord

        /// Do nothing and record nothing.
        ///
        /// Recording nothing matters as much as doing nothing. A launch that must not touch the
        /// machine has not spent the attempt, and claiming it did would rob the eventual proper
        /// install of the default: the copy running from a mounted disk image shares its bundle id,
        /// and therefore its preferences, with the app the user is about to drag into place.
        case skip
    }

    /// What a launch should do about the default.
    ///
    /// `isUnshipped` is the same gate the Settings row's write path uses, for the same reason and
    /// with no exception: `SMAppService.mainApp` registers the bundle that is RUNNING, so a dev
    /// build, a build tree, or a copy launched out of a disk image would take the installed app's
    /// login item over and aim the next login at a directory that is about to stop existing.
    ///
    /// `isDemo` is here so that no launch capable of showing fixtures ever changes the machine,
    /// which is the standing rule for demo mode (it runs no provider CLI and writes no snapshot)
    /// and makes the state preview's isolation total rather than nearly total.
    static func plan(alreadyApplied: Bool, isUnshipped: Bool, isDemo: Bool) -> Plan {
        guard !alreadyApplied, !isUnshipped, !isDemo else { return .skip }
        return .attemptThenRecord
    }

    /// Carry out a plan, with both effects passed in so the sequence can be exercised without a
    /// login item anywhere near it. Returns what the attempt threw, for the Settings row to show.
    ///
    /// The error is caught and reported rather than swallowed or raised: there is no user watching
    /// a launch, so throwing has nobody to tell, and a modal at startup would be shouting about
    /// something nobody asked for. The row is where this belongs, and it already knows how to show
    /// a failed attempt and when to stop showing it.
    @discardableResult
    static func apply(_ plan: Plan, register: () throws -> Void,
                      markApplied: () -> Void) -> LaunchAtLoginFailure? {
        guard plan == .attemptThenRecord else { return nil }
        var thrown: Error?
        do {
            try register()
        } catch {
            thrown = error
        }
        markApplied()
        return thrown.map { LaunchAtLoginFailure(wanted: true, message: $0.localizedDescription) }
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
    /// This launch's report. Private so there is exactly one way to read it, and that way empties
    /// it: a `private(set)` property would let a second reader take the same copy again, which is
    /// the defect this replaced.
    private static var report = LaunchAtLoginAttemptReport(nil)

    /// The failure from this launch's one attempt, for whoever asks first. Nil afterwards.
    static func takeAttemptFailure() -> LaunchAtLoginFailure? { report.take() }

    /// Run at launch, once per machine per install.
    static func applyIfNeeded() {
        report = LaunchAtLoginAttemptReport(apply(
            plan(alreadyApplied: UserDefaults.standard.bool(forKey: appliedKey),
                 isUnshipped: BuildVariant.isUnshipped, isDemo: DemoUsage.isActive),
            register: { try LaunchAtLoginService.setRegistered(true) },
            markApplied: { UserDefaults.standard.set(true, forKey: appliedKey) }))
    }
}
