import AppKit
import CoreGraphics
import Sparkle

/// Owns the Sparkle updater. Dormant unless the build carries BOTH a feed URL and an EdDSA public
/// key (release builds only - Debug substitutes an empty SUFeedURL), so dev builds never poll a
/// feed and the Settings row hides itself.
///
/// Dockless (LSUIElement) apps need two extra dances:
/// Sparkle's update window opens behind other apps unless the activation policy is temporarily
/// promoted to `.regular`, and scheduled checks should use gentle reminders instead of stealing
/// focus.
@MainActor
final class UpdaterController: NSObject {
    static let shared = UpdaterController()

    private var controller: SPUStandardUpdaterController?

    /// False in dev builds / until the ship pipeline bakes the key - callers hide their UI.
    /// UI reads go through UpdateAvailability.updaterActive instead: this is not observable, and
    /// a Settings window restored at launch renders before start() runs - the "no update feed"
    /// branch it picked then stuck for the whole run (seen on every post-update relaunch).
    var isActive: Bool { controller != nil }

    /// Sparkle's key for "check on a schedule". Written directly, before the updater is built, so
    /// the scheduler never gets a turn (see `start`).
    private static let sparkleChecksKey = "SUEnableAutomaticChecks"
    /// Tally's own copy of the same question, because Sparkle's copy now permanently answers no.
    private static let checksKey = "TallyChecksForUpdatesAutomatically"

    func start() {
        let info = Bundle.main.infoDictionary
        guard let feed = info?["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info?["SUPublicEDKey"] as? String, !key.isEmpty else { return }
        // Sparkle stops polling here, and Tally polls instead (see `pollFeed`). Sparkle's update
        // session does not end when a check ends: a session that has found an update stays open
        // until the update is installed or a dialog is answered, every further check is refused
        // while it is open, and the next check is only ever scheduled from the completion handler
        // that the open session never reaches. So Sparkle's scheduler stops for good at the first
        // release it finds, which on this project's cadence is stale within the hour: it is what
        // put 0.40.0 on a machine half an hour after 0.41.0 shipped, from a chip that still read
        // 0.40.0 because nothing had been able to look since. Sparkle is kept for what it is
        // uniquely good at (fetch, verify, install, relaunch) and is asked to do it on demand.
        //
        // The write happens BEFORE the updater is constructed because `startingUpdater: true`
        // schedules the first cycle as it comes up; a setter called afterwards would be racing it.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.checksKey) == nil {
            defaults.set(defaults.object(forKey: Self.sparkleChecksKey) as? Bool ?? true,
                         forKey: Self.checksKey)
        }
        defaults.set(false, forKey: Self.sparkleChecksKey)
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        UpdateAvailability.shared.updaterActive = true
        // `tally update` posts this from the CLI. Registered only when the updater is live,
        // so dev builds (no feed) ignore the broadcast.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(externalCheckRequested),
            name: Self.externalCheckNotification, object: nil)
        // A timer that slept through a lid being shut can be hours late, and the whole point of
        // this poller is that it is the only thing watching.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        apply(.watchingChanged(automaticallyChecksForUpdates))
    }

    static let externalCheckNotification = Notification.Name("ai.jetto.tally.checkForUpdates")

    @objc nonisolated private func externalCheckRequested() {
        Task { @MainActor in self.checkForUpdates() }
    }

    @objc nonisolated private func systemDidWake() {
        Task { @MainActor in
            guard self.feedTimer != nil else { return }   // polling is on exactly while it exists
            self.pollFeed()
        }
    }

    /// Whether Tally watches the feed, surfaced as a Settings toggle. Tally's own preference now:
    /// Sparkle's is held at false for the life of the app (see `start`), so reading it back would
    /// answer for the scheduler rather than for the user.
    var automaticallyChecksForUpdates: Bool {
        get { UserDefaults.standard.object(forKey: Self.checksKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.checksKey)
            // Through the reducer, not straight to the timer: turning this off has to take the
            // unattended install down with it, and that rule lives in one place.
            apply(.watchingChanged(newValue))
        }
    }

    /// Sparkle's second, separate consent: install without asking. Kept in Sparkle's own preference
    /// so the answer survives across versions, and readable/writable while scheduled checks are off
    /// only because `SUAllowsAutomaticUpdates` is set in Info.plist (without it Sparkle ties this
    /// switch to the scheduler's, and the scheduler is now permanently off).
    ///
    /// What it now means: when the moment is right (`IdleInstall`), Tally asks Sparkle for a fresh
    /// background check, which fetches the feed, downloads whatever is newest AT THAT MOMENT and
    /// hands the install over. Nothing is downloaded ahead of time, because a payload Sparkle has
    /// staged cannot afterwards be swapped for a newer one: there is no public API that discards a
    /// staged update, and the staged installer runs on quit regardless. Staging late is what makes
    /// "what gets installed is the newest we know of" true rather than aspirational.
    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// The later of the two clocks: Tally's poll is the one that runs on a schedule, Sparkle's
    /// advances when an actual update session runs. Settings shows this under the checks switch.
    var lastUpdateCheckDate: Date? {
        [lastFeedCheck, controller?.updater.lastUpdateCheckDate].compactMap { $0 }.max()
    }

    // MARK: - Watching the feed

    /// How often the appcast is read. Fifteen minutes against a cadence of several releases a day,
    /// on a document of a few kilobytes: the check costs less than one refresh of the usage panel.
    private static let feedPollInterval: TimeInterval = 15 * 60

    private var feedTimer: Timer?
    private(set) var lastFeedCheck: Date?

    /// Everything known about updates, and the only thing that changes it. See UpdateState.swift
    /// for why the transitions are a function rather than a habit spread across the callbacks.
    private var state = UpdateState(installedBuild: UpdaterController.installedBuild)

    /// Move the state and carry out what it asks for. Every Sparkle callback, every timer and
    /// every switch in Settings comes through here, which is the point: there is one place where
    /// a transition is written down.
    ///
    /// Not private: the Sparkle delegate that raises most of these events lives in
    /// UpdaterDelegate.swift.
    func apply(_ event: UpdateEvent) {
        state.installsAutomatically = automaticallyDownloadsUpdates
        let actions = UpdateReducer.reduce(&state, event, now: Date())
        // Written only on a real change: this is an @Observable the panel header reads, and every
        // assignment invalidates the view whether or not the value moved.
        let chip = state.chip
        if UpdateAvailability.shared.version != chip?.display {
            UpdateAvailability.shared.version = chip?.display
        }
        if UpdateAvailability.shared.isDownloaded != (chip?.ready ?? false) {
            UpdateAvailability.shared.isDownloaded = chip?.ready ?? false
        }
        if UpdateAvailability.shared.busy != state.busy {
            UpdateAvailability.shared.busy = state.busy
        }
        // The idle timer runs exactly while there is an offer whose moment could arrive.
        if state.knownSince == nil {
            idleTimer?.invalidate()
            idleTimer = nil
        } else if idleTimer == nil {
            idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idlePollInterval, repeats: true) { _ in
                Task { @MainActor in UpdaterController.shared.installIfIdle() }
            }
        }
        for action in actions { perform(action) }
    }

    private func perform(_ action: UpdateAction) {
        switch action {
        case .startWatching: startPolling()
        case .stopWatching: stopPolling()
        case .runHeldInstall: runHeldInstall()
        case .beginSilentInstall: beginSilentInstall()
        case .visibleCheck: visibleCheck()
        case .teardownForRelaunch: teardownForRelaunch()
        case .discardHeldInstall: pendingInstall = nil
        }
    }

    private func startPolling() {
        guard controller != nil else { return }
        // A pinned preview chip (-TallyUpdateChip, for screenshots) is the one state a real reading
        // must not overwrite: the poll would land a second after AppDelegate set it and the shot
        // would be of whatever the feed actually says.
        guard UserDefaults.standard.string(forKey: "TallyUpdateChip") == nil else { return }
        if feedTimer == nil {
            feedTimer = Timer.scheduledTimer(withTimeInterval: Self.feedPollInterval, repeats: true) { _ in
                Task { @MainActor in UpdaterController.shared.pollFeed() }
            }
        }
        pollFeed()
    }

    private func stopPolling() {
        feedTimer?.invalidate()
        feedTimer = nil
    }

    /// Read the appcast. Failures are silent on purpose: the network being down is not news, and
    /// the next tick is fifteen minutes away.
    ///
    /// The checks preference is the callers' to weigh, not this method's: the timer only exists
    /// while the preference is on, and a press of Check Now is a reading somebody asked for.
    private func pollFeed() {
        guard let url = Self.feedURL else { return }
        // The local cache is bypassed because a five-kilobyte document read four times an hour is
        // not worth a stale answer. The CDN in front of it has its own mind (a release can take
        // minutes to appear there), which is the one staleness this app cannot do anything about.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        let system = Self.runningSystem
        let installed = Self.installedBuild
        URLSession.shared.dataTask(with: request) { data, response, error in
            // A reading only counts when all three succeeded. GitHub serves a body with its 404s
            // and its 5xx pages, and an appcast parser handed an HTML error page reports "no
            // items" as confidently as it reports an empty feed, so a failure that is allowed
            // through here erases a known update and stops the idle install.
            guard error == nil,
                  let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code),
                  let data, let feed = AppcastFeed.parse(data, runningSystem: system) else {
                Task { @MainActor in UpdaterController.shared.apply(.feedReadFailed) }
                return
            }
            let found = feed.first { $0.build > installed }
            Task { @MainActor in UpdaterController.shared.absorbFeed(found) }
        }.resume()
    }

    private func absorbFeed(_ found: FeedRelease?) {
        lastFeedCheck = Date()
        apply(.feedRead(newest: found, skippedBuild: Self.skippedBuild))
    }

    /// The version the user pressed "Skip This Version" on, as Sparkle recorded it
    /// (`SUSkippedVersion`, holding the appcast item's `sparkle:version`; see SPUSkippedUpdate.m).
    /// Sparkle's other skip key is for major upgrades, which are declared by
    /// `sparkle:minimumAutoupdateVersion` and which this project's appcast never emits.
    private static var skippedBuild: Int? {
        (UserDefaults.standard.string(forKey: "SUSkippedVersion")).flatMap { Int($0) }
    }

    /// This bundle's CFBundleVersion. An unreadable one answers `Int.max` so that nothing in the
    /// feed can look newer: a chip offering a downgrade would be worse than no chip at all, and
    /// Sparkle's own comparison (which does not go through here) still works either way.
    private static let installedBuild: Int = {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap { Int($0) } ?? .max
    }()

    private static let feedURL: URL? = {
        (Bundle.main.infoDictionary?["SUFeedURL"] as? String).flatMap { URL(string: $0) }
    }()

    private static let runningSystem: [Int] = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return [version.majorVersion, version.minorVersion, version.patchVersion]
    }()

    /// User-initiated check from Settings: promote to a regular app so Sparkle's window fronts.
    /// Whatever windows Sparkle opens (checking, update found, up to date, error) follow the
    /// pointer's screen: they aren't ours to create, so a fast poller (every 50ms, stopped when
    /// the session ends) places each new window once, quickly enough that the move from
    /// Sparkle's default spot is imperceptible. Fixed-delay sweeps raced the feed fetch: a
    /// window that appeared between sweeps sat at Sparkle's position long enough to visibly jump.
    func checkForUpdates() { apply(.checkPressed) }

    /// The visible half: promote to a regular app so Sparkle's window fronts, then ask.
    private func visibleCheck() {
        // Holding Sparkle's install handler stalls its update cycle: `sessionInProgress` stays true
        // for as long as we hold it, and `SPUUpdater.checkForUpdates` bails out (with a log line and
        // nothing else) while it is. The reducer only ever asks for this action when no handler is
        // held, so the check can actually go somewhere.
        pollFeed()   // the chip and this window should not be able to disagree about the version
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // The window this check was clicked in comes along - only the key window fronts on
        // activation, and Settings vanishing under other apps read as "the app lost my click".
        SettingsWindowController.shared.bringToFrontIfVisible()
        let before = Set(NSApp.windows.map(\.windowNumber))
        controller?.checkForUpdates(nil)
        sweepTimer?.invalidate()
        let deadline = Date().addingTimeInterval(60)   // safety stop if the session never ends
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                Self.centerOnPointerScreen(NSApp.windows.filter {
                    $0.isVisible && !before.contains($0.windowNumber)
                })
                if Date() > deadline { UpdaterController.shared.sweepTimer?.invalidate() }
            }
        }
    }

    /// Not private: the Sparkle-window placement that stops it lives in UpdaterWindows.swift.
    var sweepTimer: Timer?

    // MARK: - Idle self-install

    /// Sparkle's "install this on quit" handler, held from the moment the download it belongs to
    /// finishes preparing until the moment it is run.
    /// Not private: the callback that hands it over lives in UpdaterDelegate.swift.
    var pendingInstall: InstallHandler?
    private var idleTimer: Timer?

    /// How often the idle conditions are re-tested. The install is in no hurry and the shortest
    /// window it can accept is `IdleInstall.idleBar` (five minutes), so a minute's granularity
    /// cannot miss one and costs nothing while it waits.
    private static let idlePollInterval: TimeInterval = 60

    /// The header chip's action: put the newest version this app knows about onto the machine.
    /// Same event as Check Now, because the difference between "install this" and "is there
    /// anything?" is a fact about the state, not about which control was pressed, and keeping it
    /// in one place is what stops the two from drifting.
    func installNow() { apply(.chipPressed) }

    /// Ask Sparkle for a fresh background check. It reads the feed at this moment, downloads
    /// whatever is newest in it and hands the install back through `willInstallUpdateOnQuit`. This
    /// is the only place a payload is ever staged, which is what keeps the staged payload and the
    /// newest known release the same thing.
    private func beginSilentInstall() {
        guard let updater = controller?.updater, !updater.sessionInProgress,
              updater.automaticallyDownloadsUpdates else {
            // Nothing was started, and the chip is at this instant showing that something was.
            // Returning quietly here is how it would spin for the rest of the run, over a press
            // that never went anywhere.
            apply(.silentInstallCouldNotStart)
            return
        }
        updater.checkForUpdatesInBackground()
    }

    /// Read the world for `IdleInstall` and hand its verdict over. Which action that verdict earns
    /// is the reducer's to say.
    /// Not private: the install handler arriving is one of the moments worth asking at, and that
    /// callback lives in UpdaterDelegate.swift.
    func installIfIdle() {
        let idle = state.knownSince.map {
            IdleInstall.shouldInstall(
                modalOpen: Self.decisionPending,
                taskWindowOpen: Self.taskWindowOnScreen,
                pinnedPanelOpen: PinnedPanelController.shared.isVisible,
                secondsSinceUserInput: Self.secondsSinceUserInput(),
                waiting: Date().timeIntervalSince($0))
        } ?? false
        apply(.momentArrived(idle: idle))
    }

    /// Hand the update back to Sparkle. Nothing is torn down here: `handler.run()` is a request,
    /// not a departure, and it can fail (an authorisation the user cancels, a disk that is full, a
    /// replacement that does not take) with this app still running afterwards. Standing the timers
    /// down at this point is how the app would stop watching for updates for the rest of its life,
    /// which is the exact disease this whole change was written to cure, one door along. The
    /// teardown waits for `updaterWillRelaunchApplication`, which only fires when it is really
    /// going; a failure arrives at `didAbortWithError` instead and puts everything back.
    private func runHeldInstall() {
        guard let handler = pendingInstall else { return }
        pendingInstall = nil
        handler.run()
    }

    /// The app really is being replaced. Now the machinery can go.
    private func teardownForRelaunch() {
        idleTimer?.invalidate()
        idleTimer = nil
        stopPolling()
        pendingInstall = nil
    }

    /// Surfaces holding something the user has started and not finished, which is the veto with no
    /// expiry. `IdleInstall.decisionPending` is where the rule (and why a sheet is one of these and
    /// a popover is not) is written down; this reads the windows for it, so the rule itself stays
    /// answerable without a window server.
    private static var decisionPending: Bool {
        let modal = NSApp.modalWindow
        var windows = NSApp.windows.map {
            IdleInstall.WindowState(isApplicationModal: $0 === modal,
                                    hasAttachedSheet: $0.attachedSheet != nil)
        }
        // A modal session belonging to a window that is not in `NSApp.windows` would otherwise lose
        // its veto, and losing a veto is the one direction this must never fail in.
        windows.append(IdleInstall.WindowState(isApplicationModal: modal != nil,
                                               hasAttachedSheet: false))
        return IdleInstall.decisionPending(windows: windows)
    }

    /// Windows the user opened to DO something: a restart takes them away mid-task (a half-scrolled
    /// Settings pane, a rename in progress), so any of them means wait, for as long as
    /// `IdleInstall.taskWindowGrace`. Anything holding an unfinished decision or entry is
    /// deliberately absent and asked for separately, just above: those veto with no expiry. The pinned panel is absent for the opposite reason - it is meant to
    /// stay up forever, so it has a grace of its own (`IdleInstall.pinnedPanelGrace`).
    private static var taskWindowOnScreen: Bool {
        StatusItemController.shared?.isPopoverShown == true
            || SettingsWindowController.shared.isWindowVisible
            || MainWindowController.shared.isWindowVisible
    }

    /// Seconds since the last keyboard or mouse event anywhere on the system. `~0` is
    /// `kCGAnyInputEventType` from CGEventTypes.h (any HID event at all); it needs no accessibility
    /// permission and no process list. A value that cannot be read answers zero, i.e. "someone just
    /// typed", so a failure here can only ever postpone an install.
    private static func secondsSinceUserInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }
}

/// Carries Sparkle's install block from the delegate callback to the main actor. Objective-C blocks
/// do not import as `Sendable`, and this one is safe to send: Sparkle's own implementation of it
/// (`SPUAutomaticUpdateDriver.m`) dispatches to the main queue before touching anything.
struct InstallHandler: @unchecked Sendable {
    let run: () -> Void
}
