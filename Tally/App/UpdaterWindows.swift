import AppKit
import Sparkle

/// Where Sparkle's own windows go, and who is allowed to open one. Split out of
/// `UpdaterController` because it is a separate concern from deciding what to install: this file
/// only ever runs once a window is on its way to the screen.
extension UpdaterController {
    /// Windows already placed once. Sparkle RESIZES its window as the flow advances (checking →
    /// found → downloading); re-centring it on every sweep made it visibly hop up and down, so
    /// each window is placed exactly once and then left alone.
    static var placedWindows = Set<Int>()

    /// Find Sparkle's update window (its classes are the only SU*/SPU* windows in the process)
    /// and centre it on the screen containing the pointer. No-op when nothing matches.
    static func centerSparkleWindowOnPointerScreen() {
        centerOnPointerScreen(NSApp.windows.filter {
            let className = String(describing: type(of: $0))
            return $0.isVisible && (className.hasPrefix("SU") || className.hasPrefix("SPU"))
        })
    }

    /// See NSWindow.centerOnPointerScreen (Core/WindowPlacement.swift) - the shared house rule.
    /// Once per window (see `placedWindows`).
    static func centerOnPointerScreen(_ windows: [NSWindow]) {
        for window in windows where !placedWindows.contains(window.windowNumber) {
            placedWindows.insert(window.windowNumber)
            window.centerOnPointerScreen()
        }
    }
}

extension UpdaterController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Whether Sparkle's own alert gets to present a scheduled update. Sparkle asks this only for
    /// scheduled checks - a user-initiated check is never routed through here, so Check Now always
    /// gets the standard UI. The answer is `IdleInstall`'s to give.
    ///
    /// Nothing reaches it as the app is configured today: Sparkle's scheduler is off and the only
    /// background check Tally starts is the one that installs, which always has the standing
    /// consent that makes this answer false anyway. It stays because the day any of that changes,
    /// the right answer is still this one.
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
}
