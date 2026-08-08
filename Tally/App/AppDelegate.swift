import AppKit

/// Set at the first moment of app termination, before AppKit tears the windows down, so
/// quit-time willClose notifications can be told apart from the user actually closing a window.
@MainActor
enum AppTermination {
    private(set) static var inProgress = false
    static func begin() { inProgress = true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemController = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyPreviewAppearance()
        openPanelForCapture()
        // Notification delegate first: a response can arrive the instant the app is up (the user
        // clicked a banked-reset hint that launched it), and the action button only exists if its
        // category was registered before the alert landed.
        NotificationRouter.shared.install()
        // Menu-bar accessory app: install the status item, then start the refresh loop.
        statusItemController.install()
        // Updater before the window restores: a restored Settings window renders update rows,
        // and they must see a live updater (plus the observable mirror, for any later render).
        UpdaterController.shared.start()   // dormant unless the build carries a feed URL + ED key
        // Whatever was on screen at the last quit comes back: an update relaunch is just
        // quit + launch, and losing the window you were reading mid-update is disorienting.
        // (The pinned panel restores itself inside install(); the transient popover is always
        // closed by the time an update runs, so there is nothing of it to restore.)
        // Settings second so it lands on top when both were open: the update button lives
        // there, making it the window the user most likely had focused.
        MainWindowController.shared.restoreAtLaunchIfNeeded()
        // A state preview opens Settings its own way and stands IN FOR the restore rather than
        // following it. Following would not work: the restore activates, and the second preview
        // launch onwards would always find the restore flag set, because opening the window is
        // what sets it.
        if !openSettingsForLoginItemPreview() {
            SettingsWindowController.shared.restoreAtLaunchIfNeeded()
        }
        // Design-preview hook (demo/dev only): -TallyUpdateChip 0.15.0 renders the header's
        // update chip without a live feed (-TallyUpdateChipReady YES for the downloaded state),
        // so the nudge can be reviewed and screenshotted.
        if DemoUsage.isActive || BuildVariant.isDev,
           let fake = UserDefaults.standard.string(forKey: "TallyUpdateChip") {
            UpdateAvailability.shared.version = fake
            UpdateAvailability.shared.isDownloaded = UserDefaults.standard.bool(forKey: "TallyUpdateChipReady")
        }
        UsageStore.shared.start()
        // An agent skill installed by an older app version is silently brought up to date, so
        // the guidance ships with the app. Only files that are already installed and ours are
        // touched: never an install, never someone else's skills/tally.
        IntegrationsStore.shared.autoUpdateSkill()
        // And keep them there: the sync above runs once, while the file it writes into is the
        // user's and can be rewritten by anything (IntegrationsSelfHeal.swift).
        IntegrationsStore.shared.refreshSettingsWatcher()
        // Volatile launch flag (argument domain): post one sample low-tier notification so the
        // permission prompt and the alert's look can be verified without waiting for a real
        // tripwire. No state is persisted, so a normal launch is unaffected.
        if UserDefaults.standard.bool(forKey: "TallyDryNotifyTest") {
            DryPoolNotifier.shared.postSampleNotification()
        }
        // Same idea for the banked-reset hint (-TallyResetHintTest), which additionally carries an
        // action button: the one piece that cannot be checked from a card.
        if UserDefaults.standard.bool(forKey: "TallyResetHintTest") {
            ResetHintNotifier.shared.postSampleNotification()
        }
        // And for the login-expiry alert (-TallyLoginExpiryTest), whose "Renew login" button is the
        // one path into a renewal that no card is involved in.
        if UserDefaults.standard.bool(forKey: "TallyLoginExpiryTest") {
            LoginStatusStore.shared.postSampleNotification()
        }
    }

    /// Design-capture hook (demo/dev builds only, argument domain so nothing persists):
    /// `-TallyAppearance light` / `dark` pins THIS instance to one scheme, leaving every other app
    /// - and the user's own Tally - exactly as they were.
    ///
    /// It exists because both of the alternatives are worse. A scheme cannot be forced from
    /// outside: AppKit resolves `AppleInterfaceStyle` through CFPreferences, which never consults
    /// NSUserDefaults' argument domain, and writing it into the app's own domain does not move an
    /// app that follows the system either (both measured, 2026-08-04). What is left is flipping the
    /// SYSTEM setting, which repaints every window the user is looking at - the same "do not take
    /// the desktop away from them" rule that put the other capture flags here
    /// (~/.claude/docs/patterns/macos-app-verification.md). Same family as `-TallyDemoData`,
    /// `-TallyUpdateChip` and `-TallyTooltipPreview`.
    /// `-TallyPanelCapture YES`: open the pinned usage panel at launch, so the surface can be
    /// photographed without touching the desktop.
    ///
    /// It exists because a menu-bar popover has no non-synthetic way in: it opens by clicking the
    /// status item, and a synthesized click takes the pointer and the frontmost app away from
    /// whoever is using the machine - the rule the other capture flags here were all added under
    /// (~/.claude/docs/patterns/macos-app-verification.md). The pinned panel draws the same
    /// PopoverRootView in a real window, which `screencapture -o -l <windowID>` can take from the
    /// background.
    ///
    /// Gated on the demo data or a dev build, like `-TallyAppearance`: it must never be reachable in
    /// a release instance somebody is actually using, and it deliberately does NOT go through
    /// `setPinned`, which would write the pin into the shared defaults domain and change the real
    /// app's state.
    private func openPanelForCapture() {
        guard DemoUsage.isActive || BuildVariant.isDev,
              UserDefaults.standard.bool(forKey: "TallyPanelCapture") else { return }
        PinnedPanelController.shared.show(atTopLeft: CGPoint(x: 120, y: 160))
    }

    /// `-TallyLoginItemPreview <state>` (LoginItemPreview): put the window the previewed row lives
    /// in on screen, on that row's own pane, so the flag is the whole instruction rather than the
    /// first half of one. Reports whether it did, because a preview launch replaces the ordinary
    /// Settings restore instead of running after it (see the caller).
    ///
    /// The gate is inside `LoginItemPreview.fixture`, which is nil on every normal launch. Unlike
    /// the panel-capture hook above there is nothing to keep out of the shared defaults here: this
    /// goes through the ordinary `show()`, so the one thing it records is that Settings was open,
    /// which is the same note the window makes when somebody opens it by hand, in the dev build's
    /// own domain.
    ///
    /// Which pane it lands on is not decided here: `SettingsView` seeds its opening section from
    /// the same `settingsOpening`, so the flag and the pane cannot disagree.
    private func openSettingsForLoginItemPreview() -> Bool {
        guard LoginItemPreview.fixture != nil else { return false }
        // Passed rather than hardcoded false, so the value the assertions pin is the value that
        // reaches the window.
        SettingsWindowController.shared.show(
            activating: LoginItemPreview.settingsOpening.activates)
        return true
    }

    private func applyPreviewAppearance() {
        guard DemoUsage.isActive || BuildVariant.isDev,
              let raw = UserDefaults.standard.string(forKey: "TallyAppearance")?.lowercased()
        else { return }
        switch raw {
        case "light", "aqua": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break   // anything else leaves the app following the system, as it always does
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Snapshot restore state HERE, the first termination hook, while the windows are still
        // on screen. By applicationWillTerminate AppKit has already closed them - their
        // willClose fired and read as the user dismissing each window, which is exactly how a
        // Sparkle update relaunch lost every flag (verified via scripted quit, 2026-07-21).
        // The latch keeps the willClose observers quiet through the tear-down.
        AppTermination.begin()
        MainWindowController.shared.persistRestoreState()
        SettingsWindowController.shared.persistRestoreState()
        return .terminateNow
    }

    /// Escape hatch for a hidden status item: macOS silently hides menu bar icons that
    /// no longer fit (notch or a crowded bar), and this app has no Dock icon, so
    /// relaunching from Spotlight or Finder is the only door left. Surface the main
    /// window instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindowController.shared.show() }
        return true
    }
}
