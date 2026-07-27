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

    func start() {
        let info = Bundle.main.infoDictionary
        guard let feed = info?["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info?["SUPublicEDKey"] as? String, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        UpdateAvailability.shared.updaterActive = true
        // Check hourly, Sparkle's minimum (default is daily): the release cadence here ships
        // multiple versions a day, and the header chip only appears once a check has run.
        controller?.updater.updateCheckInterval = 3_600
        // `tally update` posts this from the CLI. Registered only when the updater is live,
        // so dev builds (no feed) ignore the broadcast.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(externalCheckRequested),
            name: Self.externalCheckNotification, object: nil)
    }

    static let externalCheckNotification = Notification.Name("ai.jetto.tally.checkForUpdates")

    @objc nonisolated private func externalCheckRequested() {
        Task { @MainActor in self.checkForUpdates() }
    }

    /// Sparkle's own persisted preference, surfaced as a Settings toggle.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Sparkle's second, separate consent: download and PREPARE an update in the background as soon
    /// as one is found (the checkbox in the update dialog), surfaced as a Settings toggle so it
    /// isn't reachable only through a dialog that stops appearing once you enable it.
    ///
    /// It does not decide WHEN the prepared update is installed: Sparkle queues that for app
    /// termination, and this app takes the moment over instead (see the idle self-install below).
    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

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
        // than a check that cannot go anywhere.
        if pendingInstall != nil { runPendingInstall(); return }
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

    private var sweepTimer: Timer?

    /// Windows already placed once. Sparkle RESIZES its window as the flow advances (checking →
    /// found → downloading); re-centring it on every sweep made it visibly hop up and down, so
    /// each window is placed exactly once and then left alone.
    private static var placedWindows = Set<Int>()

    // MARK: - Idle self-install

    /// Sparkle's "install this on quit" handler, held while we wait for a moment to run it, paired
    /// with when the holding started (the clock `IdleInstall.pinnedPanelGrace` is measured against).
    private var pendingInstall: (handler: InstallHandler, since: Date)?
    private var idleTimer: Timer?

    /// How often the idle conditions are re-tested. The install is in no hurry and the shortest
    /// window it can accept is `IdleInstall.idleBar` (five minutes), so a minute's granularity
    /// cannot miss one and costs nothing while it waits.
    private static let idlePollInterval: TimeInterval = 60

    /// Take the install over, then wait for a quiet moment. Idempotent: Sparkle may hand the
    /// handler over again (it re-offers it when a termination request is cancelled), and the
    /// waiting clock must survive that or the pinned-panel grace would restart each time.
    private func holdInstall(_ handler: InstallHandler) {
        pendingInstall = (handler, pendingInstall?.since ?? Date())
        // The payload is on disk and one click from running, which is exactly what the chip's
        // green ↻ state means. didDownloadUpdate has normally said so already; this covers the
        // resumed-download path, where it hasn't.
        UpdateAvailability.shared.isDownloaded = true
        if idleTimer == nil {
            idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idlePollInterval, repeats: true) { _ in
                Task { @MainActor in UpdaterController.shared.installIfIdle() }
            }
        }
        installIfIdle()   // the moment may already be here
    }

    /// Run the held install if the conditions say so. The rules themselves are in `IdleInstall`;
    /// this only reads the world for them.
    private func installIfIdle() {
        guard let pending = pendingInstall else { return }
        guard IdleInstall.shouldInstall(
            taskSurfaceOpen: Self.taskSurfaceOnScreen,
            pinnedPanelOpen: PinnedPanelController.shared.isVisible,
            secondsSinceUserInput: Self.secondsSinceUserInput(),
            waiting: Date().timeIntervalSince(pending.since)) else { return }
        runPendingInstall()
    }

    /// Hand the update back to Sparkle to install and relaunch. Everything is torn down first: the
    /// app is about to be replaced, and a timer that outlived the handler would poll a state that
    /// no longer exists.
    private func runPendingInstall() {
        guard let pending = pendingInstall else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        pendingInstall = nil
        pending.handler.run()
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

extension UpdaterController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Whether Sparkle's own alert gets to present a scheduled update. Sparkle asks this only for
    /// scheduled checks - a user-initiated check is never routed through here, so Check Now always
    /// gets the standard UI. The answer is `IdleInstall`'s to give.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Every SPUUserDriver method is documented as main-thread (SPUUserDriver.h), and this
        // delegate is called from inside one of them.
        MainActor.assumeIsolated {
            IdleInstall.standardAlertShouldShowScheduledUpdate(
                automaticInstallsEnabled: automaticallyDownloadsUpdates)
        }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState) {
        // Sparkle calls this either way. When it is NOT showing the update (we answered false
        // above) there is no window to place and the header chip is the whole reminder, so the
        // placement below would be chasing a window that never appears.
        guard handleShowingUpdate else { return }
        // Sparkle centres its window on the MAIN display; the user may be working on another.
        // Move it to the screen the pointer is on (the same rule the redeem alert follows) -
        // a beat after Sparkle has actually put it on screen.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            Self.centerSparkleWindowOnPointerScreen()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        // Update UI done - retract to whatever the visible windows dictate (accessory when none),
        // and hand focus back to the Tally window the check came from. Without this, macOS
        // treats the closing Sparkle window as "app done" and activates some other app (the
        // check ended with the user staring at a random Finder window).
        Task { @MainActor in
            self.sweepTimer?.invalidate()
            ActivationPolicy.refresh()
            if SettingsWindowController.shared.isWindowVisible
                || MainWindowController.shared.isWindowVisible {
                NSApp.activate(ignoringOtherApps: true)
                SettingsWindowController.shared.bringToFrontIfVisible()
            }
        }
    }

    /// Find Sparkle's update window (its classes are the only SU*/SPU* windows in the process)
    /// and centre it on the screen containing the pointer. No-op when nothing matches.
    @MainActor private static func centerSparkleWindowOnPointerScreen() {
        centerOnPointerScreen(NSApp.windows.filter {
            let className = String(describing: type(of: $0))
            return $0.isVisible && (className.hasPrefix("SU") || className.hasPrefix("SPU"))
        })
    }

    /// See NSWindow.centerOnPointerScreen (Core/WindowPlacement.swift) - the shared house rule.
    /// Once per window (see `placedWindows`).
    @MainActor private static func centerOnPointerScreen(_ windows: [NSWindow]) {
        for window in windows where !placedWindows.contains(window.windowNumber) {
            placedWindows.insert(window.windowNumber)
            window.centerOnPointerScreen()
        }
    }
}

extension UpdaterController: SPUUpdaterDelegate {
    /// The Docker-style in-app nudge: the panel header shows an accent "↑ x.y.z" chip while an
    /// update is known to be available; clicking it re-enters the standard install flow.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            // A newer version invalidates a prior "downloaded" flag: didDownloadUpdate has not
            // fired for this payload yet, so the chip must fall back to the detected (accent ↑)
            // state instead of falsely promising a one-click restart. Guarded on the version so a
            // re-check of the same, already-downloaded update keeps its green ↻.
            if UpdateAvailability.shared.version != version {
                UpdateAvailability.shared.isDownloaded = false
            }
            UpdateAvailability.shared.version = version
        }
    }

    /// Second chip state, the Ghostty semantic: the payload is already on disk, so a click means
    /// "restart into the new version", not "start a download". The chip goes green + ↻.
    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Task { @MainActor in UpdateAvailability.shared.isDownloaded = true }
    }

    /// The whole point of the "install automatically" toggle: Sparkle has the update prepared and
    /// would otherwise sit on it until the app is quit, which for a menu-bar app is never. Answering
    /// true takes the install over (Sparkle stalls its cycle and hands us the trigger), and it then
    /// runs on the first quiet moment - see the idle self-install section above.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void)
        -> Bool {
        let handler = InstallHandler(run: immediateInstallHandler)
        Task { @MainActor in self.holdInstall(handler) }
        return true
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in UpdateAvailability.shared.clear() }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Task { @MainActor in UpdateAvailability.shared.clear() }
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
