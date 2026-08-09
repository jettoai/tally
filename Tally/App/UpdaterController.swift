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
        if automaticallyChecksForUpdates { startPolling() }
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
            if newValue { startPolling() } else { stopPolling() }
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
    /// The newest release the feed offered, or nil when this build is already it.
    private var newest: FeedRelease?
    /// The release Sparkle has downloaded and staged, once it has one.
    private var staged: FeedRelease?
    /// When the app first learned an update existed. `IdleInstall` measures the pinned-panel grace
    /// against it, and it survives the download that follows.
    private var knownSince: Date?
    private(set) var lastFeedCheck: Date?

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
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data else { return }
            let found = AppcastFeed.newest(from: data, runningSystem: system, above: installed)
            Task { @MainActor in UpdaterController.shared.absorbFeed(found) }
        }.resume()
    }

    private func absorbFeed(_ found: FeedRelease?) {
        lastFeedCheck = Date()
        newest = found
        refreshAvailability()
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

    /// Push what is known into the observable the header chip reads, and keep the idle timer
    /// running exactly while there is something for it to do.
    private func refreshAvailability() {
        let chip = UpdatePlan.chip(installedBuild: Self.installedBuild, staged: staged, newest: newest)
        UpdateAvailability.shared.version = chip?.display
        UpdateAvailability.shared.isDownloaded = chip?.ready ?? false
        guard chip != nil else {
            knownSince = nil
            idleTimer?.invalidate()
            idleTimer = nil
            return
        }
        if knownSince == nil { knownSince = Date() }
        if idleTimer == nil {
            idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idlePollInterval, repeats: true) { _ in
                Task { @MainActor in UpdaterController.shared.installIfIdle() }
            }
        }
        installIfIdle()
    }

    /// User-initiated check from Settings: promote to a regular app so Sparkle's window fronts.
    /// Whatever windows Sparkle opens (checking, update found, up to date, error) follow the
    /// pointer's screen: they aren't ours to create, so a fast poller (every 50ms, stopped when
    /// the session ends) places each new window once, quickly enough that the move from
    /// Sparkle's default spot is imperceptible. Fixed-delay sweeps raced the feed fetch: a
    /// window that appeared between sweeps sat at Sparkle's position long enough to visibly jump.
    func checkForUpdates() {
        // Holding Sparkle's install handler stalls its update cycle: `sessionInProgress` stays true
        // for as long as we hold it, and `SPUUpdater.checkForUpdates` bails out (with a log line and
        // nothing else) while it is. A click on the header's "↻ ready" chip or on Check Now means
        // "put the new version on", which is precisely what the held handler does, so run it rather
        // than a check that cannot go anywhere. (The chip's own press goes through `installNow`;
        // this is Check Now, and the CLI's `tally update`.)
        if pendingInstall != nil { runPendingInstall(); return }
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
    private var pendingInstall: InstallHandler?
    private var idleTimer: Timer?
    /// Somebody pressed the chip: the download that follows installs the moment it is ready,
    /// without waiting for the machine to go quiet. Cleared when the request is served.
    private var userRequestedInstall = false

    /// How often the idle conditions are re-tested. The install is in no hurry and the shortest
    /// window it can accept is `IdleInstall.idleBar` (five minutes), so a minute's granularity
    /// cannot miss one and costs nothing while it waits.
    private static let idlePollInterval: TimeInterval = 60

    /// The header chip's action: put the newest version this app knows about onto the machine.
    ///
    /// Distinct from Check Now, which is a question ("is there anything?") and is entitled to
    /// Sparkle's windows to answer it. This is an instruction, and its whole contract is that what
    /// lands is the version the chip was showing.
    func installNow() {
        switch UpdatePlan.step(installedBuild: Self.installedBuild, staged: staged, newest: newest) {
        case .nothing:
            checkForUpdates()   // the chip should not have been up; treat the press as a question
        case .installStaged, .installStaleStaged:
            // Run the payload if it is in hand; otherwise Check Now is the way to reach a staged
            // install a previous run left behind, and the flag makes it land without a second press.
            userRequestedInstall = true
            checkForUpdates()
        case .fetchNewest:
            // Without the standing consent to install unattended, the press earns the standard
            // dialog (release notes, an explicit Install) rather than a silent restart.
            guard automaticallyDownloadsUpdates else { checkForUpdates(); return }
            userRequestedInstall = true
            beginSilentInstall()
        }
    }

    /// Ask Sparkle for a fresh background check. It reads the feed at this moment, downloads
    /// whatever is newest in it and hands the install back through `willInstallUpdateOnQuit`. This
    /// is the only place a payload is ever staged, which is what keeps the staged payload and the
    /// newest known release the same thing.
    private func beginSilentInstall() {
        guard let updater = controller?.updater, !updater.sessionInProgress,
              updater.automaticallyDownloadsUpdates else { return }
        updater.checkForUpdatesInBackground()
    }

    /// Take the install over, then run it when the moment is right.
    private func holdInstall(_ handler: InstallHandler) {
        pendingInstall = handler
        if userRequestedInstall { runPendingInstall(); return }
        // The payload is on disk: the chip's green ↻ state, and (through the same call) the idle
        // timer and a first look at whether the moment is already here.
        refreshAvailability()
    }

    /// Do whatever the current knowledge says to do, if the moment allows it. The rules for the
    /// moment are in `IdleInstall` and the rules for the action are in `UpdatePlan`; this only
    /// reads the world for them.
    private func installIfIdle() {
        guard automaticallyDownloadsUpdates, let since = knownSince else { return }
        guard IdleInstall.shouldInstall(
            taskSurfaceOpen: Self.taskSurfaceOnScreen,
            pinnedPanelOpen: PinnedPanelController.shared.isVisible,
            secondsSinceUserInput: Self.secondsSinceUserInput(),
            waiting: Date().timeIntervalSince(since)) else { return }
        switch UpdatePlan.step(installedBuild: Self.installedBuild, staged: staged, newest: newest) {
        case .nothing:
            return
        case .installStaged, .installStaleStaged:
            runPendingInstall()
        case .fetchNewest:
            beginSilentInstall()
        }
    }

    /// Hand the update back to Sparkle to install and relaunch. Everything is torn down first: the
    /// app is about to be replaced, and a timer that outlived the handler would poll a state that
    /// no longer exists.
    private func runPendingInstall() {
        guard let handler = pendingInstall else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        feedTimer?.invalidate()
        feedTimer = nil
        pendingInstall = nil
        userRequestedInstall = false
        handler.run()
    }

    /// Windows the user opened to DO something: a restart takes them away mid-task (a half-scrolled
    /// Settings pane, a rename in progress, an alert waiting on an answer), so any of them means
    /// wait. The pinned panel is deliberately absent - it is meant to stay up forever, so counting
    /// it here would mean anyone who pins never gets an automatic install (`IdleInstall` gives it a
    /// grace period instead).
    private static var taskSurfaceOnScreen: Bool {
        NSApp.modalWindow != nil
            || StatusItemController.shared?.isPopoverShown == true
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
private struct InstallHandler: @unchecked Sendable {
    let run: () -> Void
}

extension UpdaterController: SPUUpdaterDelegate {
    /// What Sparkle just fetched is a fresher reading than the poller's, so it replaces it. The
    /// chip follows (the Docker-style nudge: an accent "↑ x.y.z" while an update is known).
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let release = Self.release(from: item)
        Task { @MainActor in
            self.newest = release
            self.refreshAvailability()
        }
    }

    /// Second chip state, the Ghostty semantic: the payload is already on disk, so a click means
    /// "restart into the new version", not "start a download". The chip goes green + ↻.
    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let release = Self.release(from: item)
        Task { @MainActor in
            self.staged = release
            self.refreshAvailability()
        }
    }

    /// Sparkle's own view of an appcast entry, in the shape the plan compares. An item whose
    /// `sparkle:version` will not read as an integer is not something this app's own ranking can
    /// place, so it is left out and Sparkle's comparator remains the only judge of it.
    nonisolated private static func release(from item: SUAppcastItem) -> FeedRelease? {
        guard let build = Int(item.versionString) else { return nil }
        return FeedRelease(build: build, display: item.displayVersionString,
                           minimumSystemVersion: item.minimumSystemVersion)
    }

    /// The whole point of the "install automatically" toggle: Sparkle has the update prepared and
    /// would otherwise sit on it until the app is quit, which for a menu-bar app is never. Answering
    /// true takes the install over (Sparkle stalls its cycle and hands us the trigger), and it then
    /// runs on the first quiet moment - see the idle self-install section above.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void)
        -> Bool {
        let handler = InstallHandler(run: immediateInstallHandler)
        let release = Self.release(from: item)
        Task { @MainActor in
            self.staged = release
            self.holdInstall(handler)
        }
        return true
    }

    /// Sparkle looked at the feed just now and found nothing, which outranks whatever the poller
    /// last saw. The staged payload, if there is one, is a fact on disk and stays.
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.newest = nil
            self.refreshAvailability()
        }
    }

    /// A silent install that fails has nothing to show for itself, and a press of the chip that
    /// visibly does nothing is worse than an error. So a failed request is re-run as a visible
    /// check, which is the same work with Sparkle's windows attached: the user gets told why.
    /// Only when the request is still outstanding - the flag is cleared the moment one is served,
    /// so the ordinary end of an update session does not come back through here.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Task { @MainActor in
            guard self.userRequestedInstall else { return }
            self.userRequestedInstall = false
            self.checkForUpdates()
        }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.newest = nil
            self.staged = nil
            UpdateAvailability.shared.clear()
        }
    }
}

/// Observable "an update is waiting" state, fed by the updater delegate above and rendered by
/// the panel header. Separate tiny class because UpdaterController is an NSObject delegate
/// (the @Observable macro and NSObject don't mix).
@MainActor
@Observable
final class UpdateAvailability {
    static let shared = UpdateAvailability()
    var version: String?
    /// True once Sparkle has the update downloaded (auto-download on): a click now finishes
    /// in one restart instead of walking the download dialog.
    var isDownloaded = false
    /// Observable mirror of UpdaterController.isActive, so views rendered before start() (a
    /// Settings window restored at launch) correct themselves once the updater comes up.
    var updaterActive = false

    func clear() {
        version = nil
        isDownloaded = false
    }
}
