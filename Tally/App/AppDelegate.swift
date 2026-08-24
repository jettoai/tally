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
        // The session footprints, which sample slowly for the life of the process rather than only
        // while their page is up: the cards draw a trend line, and a history that began when the
        // panel opened would be blank at the moment somebody opened it to ask what has been going
        // on (`ProcessFootprintStore`). After the status item, because the roster it reads its
        // sessions from is installed there.
        ProcessFootprintStore.shared.install()
        // Updater before the window restores: a restored Settings window renders update rows,
        // and they must see a live updater (plus the observable mirror, for any later render).
        UpdaterController.shared.start()   // dormant unless the build carries a feed URL + ED key
        // Whatever was on screen at the last quit comes back: an update relaunch is just
        // quit + launch, and losing the window you were reading mid-update is disorienting.
        // (The pinned panel restores itself inside install(); the transient popover is always
        // closed by the time an update runs, so there is nothing of it to restore.)
        // Settings second so it lands on top when both were open: the update button lives
        // there, making it the window the user most likely had focused.
        // The one uninvited registration: an unconfigured Tally starts at login, once per install,
        // and the switch in Settings owns it from then on (LaunchAtLoginDefault). It is here, at
        // every launch rather than behind a first-run check of its own, because the record of
        // having done it IS the first-run check, and the only honest one: nothing else can tell a
        // machine that has never been asked from one whose user said no.
        //
        // BEFORE the window restores below, and that ordering is load-bearing: if this attempt
        // fails it leaves a report for the Settings row to collect ONCE, and a restored Settings
        // window builds that row on its way up. Published later, the row would ask before there
        // was anything to ask for and the failure would never be seen on the launch it happened.
        LaunchAtLoginDefault.applyIfNeeded()
        // One answer for the whole launch, read once and given to every path below that puts a
        // window up without anybody having clicked anything. Read here rather than inside each
        // controller so the set of those paths is a list somebody can look at, and asked of the
        // whole capture family rather than of any one flag: every launch that exists to be looked
        // at wants the same thing from these paths, not just the login-item state preview.
        let mayTakeForeground = CaptureLaunch.launchMayTakeForeground
        MainWindowController.shared.restoreAtLaunchIfNeeded(activating: mayTakeForeground)
        // A state preview opens Settings its own way and stands IN FOR the restore rather than
        // following it. Following would not work: the restore activates, and the second preview
        // launch onwards would always find the restore flag set, because opening the window is
        // what sets it.
        // A capture launch stands in for the restore on the same terms, and is asked second because
        // the preview is the more specific instruction: it names a row, this one names at most a
        // pane.
        if !openSettingsForLoginItemPreview(), !openSettingsForCapture() {
            SettingsWindowController.shared.restoreAtLaunchIfNeeded(activating: mayTakeForeground)
        }
        // Design-preview hook (demo/dev only): -TallyUpdateChip 0.15.0 renders the header's
        // update chip without a live feed (-TallyUpdateChipReady YES for the downloaded state,
        // -TallyUpdateChipBusy updating|restarting for the two working faces), so the nudge can be
        // reviewed and screenshotted.
        if DemoUsage.isActive || BuildVariant.isDev,
           let fake = UserDefaults.standard.string(forKey: "TallyUpdateChip") {
            UpdateAvailability.shared.version = fake
            UpdateAvailability.shared.isDownloaded = UserDefaults.standard.bool(forKey: "TallyUpdateChipReady")
            // The working chip has no other way onto a screenshot: behind a live feed it lasts as
            // long as a download does, and the second of the two ends with the app being replaced.
            // Named for what the chip SAYS rather than for the state machine's steps, because that
            // is what is being reviewed - `.downloading` stands in for all three of the steps that
            // read "Updating…". An absent or unrecognised value leaves the chip as it was.
            switch UserDefaults.standard.string(forKey: "TallyUpdateChipBusy")?.lowercased() {
            case "updating": UpdateAvailability.shared.busy = .downloading
            case "restarting": UpdateAvailability.shared.busy = .restarting
            default: break
            }
        }
        // THE FIRST USAGE READING WAITS FOR THE KEYCHAIN REPAIR, and that ordering is the whole of
        // why these two lines share a task. A refresh runs the `claude` CLI, which reads its
        // credentials through `/usr/bin/security`, so on a machine Tally 0.64.0 damaged the app's
        // own first reading is one of the things that raises the "security" panel the repair exists
        // to remove - and started beside the repair it would race the rewrite as well
        // (KeychainRepairLaunch.swift; codex review, 2026-08-23).
        //
        // NOTHING ELSE WAITS. The repair suspends rather than blocking, so everything below is on
        // screen while it is in flight, and on a build that may not touch shared state it returns
        // without doing anything at all.
        Task {
            await KeychainRepairLaunch.run()
            UsageStore.shared.start()
            // The morning schedule's two punctuality nudges (a wall-clock timer and the wake
            // notification), inside the same task and after the reading for the same reason the
            // reading is here at all. Both nudges do nothing but ask for a refresh, and a refresh
            // runs the `claude` CLI against the credentials the repair is rewriting: an app opened
            // at 06:59:40 arms a timer that fires twenty seconds later, which is inside the time an
            // ACL dialog can hold the repair open. Started behind it, the morning's first reading
            // is the repaired one. Nothing is sent until the one-time notice has been read
            // (EarlyStartStore.swift).
            //
            // This call ORDERS ONE ENTRANCE. Acknowledging the notice or moving the Settings
            // switch during those same seconds arms the schedule without coming through here, so
            // the store gates those on a readiness flag that this line is what opens.
            EarlyStartStore.shared.start()
        }
        // The native picker behind `/tally`: listen for the CLI's
        // knock for the life of the process, the way the update check's observer does. Not
        // listening is not an error anywhere - the CLI waits a second and a half for a claim
        // and then draws the form Claude Code has always drawn (PickPanelController.swift).
        PickPanelController.shared.install()
        PickPanelController.previewIfRequested()
        // An agent skill installed by an older app version is silently brought up to date, so
        // the guidance ships with the app. Only files that are already installed and ours are
        // touched: never an install, never someone else's skill of the same name.
        IntegrationsStore.shared.autoUpdateSkill()
        // And the same for the PATH shims, which is the more urgent half of the same idea: the
        // script stands in front of every `claude` and `codex` typed on this machine, so a defect
        // in one may not wait for somebody to notice a Reinstall button (IntegrationsShim.swift).
        IntegrationsStore.shared.autoUpdateShims()
        // Same upkeep for the tab completion installed beside the command: an app that updated
        // itself carries a new CLI, and the script asks that binary its questions, so a stale copy
        // of it would offer words the new one refuses (IntegrationsCompletion.swift).
        Task { await IntegrationsStore.shared.autoUpdateCompletion() }
        // And keep them there: the sync above runs once, while the file it writes into is the
        // user's and can be rewritten by anything (IntegrationsSelfHeal.swift).
        IntegrationsStore.shared.refreshSettingsWatcher()
        // The upkeep the two above cannot do, because it is not about an install going stale: a hook
        // this version ADDED to a settings.json the user has already let Tally manage. Opt-in is
        // right for the first press and invisible for every one after it, so the new row follows the
        // presses already made and says so once (IntegrationsAutoFollow.swift).
        IntegrationsStore.shared.followNewIntegrations()
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
        // …and the last mile of the capture family: `-TallyWindowSnapshot <dir>` photographs
        // whatever the flags above put on screen and quits (WindowSnapshot.swift says why the app
        // takes its own picture rather than leaving it to `screencapture`). Last, because what it
        // captures is the state everything before it has finished setting up.
        WindowSnapshot.captureIfRequested()
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
    /// Which page that panel opens on is the other half of the same command, and it is not decided
    /// here: `-TallyTab <usage|tokens|sessions>` seeds the surface's own selection
    /// (`SurfaceTabLaunch`), so a capture of the session board needs no click either. Seeded rather
    /// than switched afterwards, because a tab switched after the panel is up crossfades, and a
    /// capture racing that animation photographs whichever frame it caught.
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
        // The same launch-wide answer the restores above got, so all three paths that can put a
        // window up at startup are driven by one value read in one place.
        SettingsWindowController.shared.show(activating: CaptureLaunch.launchMayTakeForeground)
        return true
    }

    /// `-TallySettingsCapture YES` (or a pane name): open the Settings window at launch, so a row in
    /// it can be photographed without touching the desktop.
    ///
    /// It exists for the reason `-TallyPanelCapture` does, one window over: the only way into
    /// Settings is the menu bar, and driving a menu means synthesizing clicks that take the pointer
    /// and the frontmost app away from whoever is using the machine
    /// (~/.claude/docs/patterns/macos-app-verification.md). A real window is what
    /// `screencapture -o -l <windowID>` can take from the background, and every review of an
    /// Integrations row is that same act.
    ///
    /// Which pane it lands on is not decided here: `SettingsView` seeds its opening section from
    /// `SettingsCaptureLaunch`, so the flag and the pane cannot disagree.
    ///
    /// Reports whether it did, because this replaces the ordinary Settings restore rather than
    /// running after it, exactly as the state preview above does and for the same reason: opening
    /// the window is what sets the note the restore reads, so a second capture launch would find it
    /// set and be restored on top of itself.
    ///
    /// Gated on the demo data or a dev build, like every other flag in this family: it must never be
    /// reachable in a release instance somebody is actually using. There is nothing to keep out of
    /// the shared defaults, for the reason the preview states: this goes through the ordinary
    /// `show()`, whose one record is that Settings was open, in that build's own domain.
    private func openSettingsForCapture() -> Bool {
        guard SettingsCaptureLaunch.isActive else { return false }
        // The same launch-wide answer every other unprompted window got, read in one place.
        SettingsWindowController.shared.show(activating: CaptureLaunch.launchMayTakeForeground)
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
