import AppKit

/// WHAT THE STATUS ITEM SUMMONS BESIDES ITS POPOVER: the secondary-click menu, and the pin
/// transformation that hands the usage view between the popover, the floating panel and the window.
///
/// Split out of `StatusItemController` on 2026-08-15, unchanged: that file had grown past this
/// repo's 500-line limit while the summoning path inside it was being rewritten, and these are the
/// commands the item offers rather than the placement machinery being changed.
extension StatusItemController {
    /// Toggle the pinned floating panel (called from the popover/panel footer's pin button).
    static func togglePin() {
        shared?.setPinned(!SettingsStore.shared.isUsagePanelPinned)
    }

    /// Retire the pinned panel, the other half of the transformation below - called by the dashboard
    /// window as it takes the stage.
    ///
    /// The two are one surface in two forms, and the panel floats above every normal window, so
    /// leaving it up while the dashboard opens stacks two IDENTICAL views with the floating one on
    /// top: every click on the covered part of the dashboard is silently eaten by the panel. It
    /// looks like a dead region rather than an overlap precisely because both surfaces render the
    /// same view, and which part is covered changes as the window resizes - switching the dashboard
    /// to Tokens shrinks it (top-anchored), pulling its footer up into the panel's band, so the
    /// whole footer stops responding while the header above the panel still works.
    ///
    /// Unpinning rather than merely hiding keeps the state honest: the window's footer button reads
    /// "Pin on top" again, which is exactly what it now does.
    static func unpin() {
        guard SettingsStore.shared.isUsagePanelPinned else { return }
        SettingsStore.shared.isUsagePanelPinned = false
        PinnedPanelController.shared.applyPinLevel()
        PinnedPanelController.shared.hide()
    }

    private func setPinned(_ pinned: Bool) {
        guard pinned else { return Self.unpin() }
        SettingsStore.shared.isUsagePanelPinned = true
        // Pinning is a transformation, not a copy: whichever surface the pin was clicked in
        // (popover or main window) hands its on-screen position AND the view it is showing to
        // the panel and closes, so the panel visibly takes over in place. Handing over only the
        // position would have made pinning the token history a way to leave it, which is why the
        // view goes over whole: the tab and the Cost page (`SurfacePage`).
        let fromPopover = popoverContentTopLeft()
        let source = fromPopover != nil ? popoverTab : MainWindowController.shared.surfaceTab
        let topLeft = fromPopover ?? MainWindowController.shared.contentTopLeft
        popover.performClose(nil)
        MainWindowController.shared.close()
        PinnedPanelController.shared.show(atTopLeft: topLeft, showing: source.page)
    }

    /// The screen-space top-left of the popover's content, so the panel can open exactly where the
    /// popover was (its own window frame includes the arrow, so measure the content view instead).
    /// Returns nil unless the popover is actually on screen: after `performClose` AppKit keeps the
    /// content view attached to an off-screen window, so a `view.window` check alone stays non-nil
    /// forever once the popover has been shown, and callers using this as "the pin came from the
    /// popover" would misread every later pin from the main window.
    private func popoverContentTopLeft() -> CGPoint? {
        guard popover.isShown else { return nil }
        guard let view = popover.contentViewController?.view, let window = popoverWindow else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        return CGPoint(x: onScreen.minX, y: onScreen.maxY)
    }

    func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let open = NSMenuItem(title: String(localized: "Open Tally", bundle: AppLocale.bundle),
                              action: #selector(openMainWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: String(localized: "Settings…", bundle: AppLocale.bundle),
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        // Always listed, dev builds included, so the entry can be seen and clicked there too;
        // what a click does depends on whether the updater is live (`checkForUpdates`).
        let check = NSMenuItem(title: String(localized: "Check for Updates…", bundle: AppLocale.bundle),
                               action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Tally", bundle: AppLocale.bundle),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// `-TallyStatusMenuCapture YES` (demo or dev builds only): pop the secondary-click menu at
    /// launch so it can be photographed without a synthesized click. `-TallyStatusMenuCapture alert`
    /// runs the Check for Updates item's own handler instead, for a shot of what a click shows.
    func showMenuForCaptureIfAsked() {
        let key = "TallyStatusMenuCapture"
        guard DemoUsage.isActive || BuildVariant.isDev, CaptureLaunch.carries(key),
              let button = statusItem?.button else { return }
        let clicksCheck = UserDefaults.standard.string(forKey: key)?.lowercased() == "alert"
        // Delayed: for the first moments of a launch the status item's button has no window on
        // screen, and then a strip not yet painted, so a menu popped early anchors to the wrong spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if clicksCheck { self.checkForUpdates() } else { self.showMenu(from: button) }
        }
    }

    /// A live updater checks for real, the same path as Settings' Check Now. A dormant one (a dev
    /// build has no feed) says so in a one-button alert rather than doing nothing; `CentredAlert`
    /// activates the app first, without which a menu-bar app's alert opens behind other apps.
    @objc private func checkForUpdates() {
        guard UpdateAvailability.shared.updaterActive else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Development builds don't check for updates.",
                                       bundle: AppLocale.bundle)
            alert.addButton(withTitle: String(localized: "OK", bundle: AppLocale.bundle))
            _ = CentredAlert.run(alert)
            return
        }
        UpdaterController.shared.checkForUpdates()
    }

    @objc private func openSettings() {
        StatusItemController.openSettingsWindow()
    }

    @objc private func openMainWindow() {
        MainWindowController.shared.show()
    }

    /// Opens the settings window (a reliable custom NSWindow, not the flaky `Settings` scene action).
    static func openSettingsWindow() {
        SettingsWindowController.shared.show()
    }
}
