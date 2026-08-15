import AppKit
import SwiftUI

/// Hosts the settings UI in a plain custom NSWindow (mirroring MainWindowController) instead of the
/// SwiftUI `Settings` scene. The scene's `showSettingsWindow:` action is unreliable for an LSUIElement
/// accessory app (and the selector name is OS-version-sensitive), which made the gear appear to hang.
///
/// Sizing: the view measures its own full content height (non-lazy layout, so the measurement is
/// the truth) and reports it here; the window follows, exactly content-fit. Same proven pattern as
/// the pinned panel (`onContentSize`): `sizingOptions = []` keeps this the ONLY size authority -
/// two authorities recursed the layout engine into a stack overflow once (see PinnedPanelController).
/// Fixed-size window (macOS HIG for settings): with an exact fit there is nothing to resize.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var lastAppliedHeight: CGFloat = 0

    /// Restore-on-launch flag, mirroring MainWindowController: an update relaunch is quit +
    /// launch, and Settings is the LIKELIEST open window then (the update button lives in it).
    private nonisolated static let restoreKey = "restoreSettingsWindow"

    var isWindowVisible: Bool { window?.isVisible == true }

    /// Reopen the window at launch if it was up when the app last quit (see `restoreKey`).
    ///
    /// `activating`: the launch's one answer about taking the foreground, same as the dashboard's
    /// restore takes (CaptureLaunch.mayTakeForeground).
    func restoreAtLaunchIfNeeded(activating: Bool = true) {
        if UserDefaults.standard.bool(forKey: Self.restoreKey) {
            show(restoring: true, activating: activating)
        }
    }

    /// Whether the window is OPEN, which is not the same question as whether it is on screen: a
    /// miniaturized window answers `isVisible == false` (measured 2026-08-15: false while minimized,
    /// true again on deminiaturize, and `isMiniaturized` is what tells it from a window that was
    /// really closed). Asked separately from `isWindowVisible` because the other readers of that one
    /// - the Dock presence, the updater's "is anything on screen to interrupt" - genuinely mean on
    /// screen, and a window in the Dock interrupts nobody.
    var isWindowOpen: Bool { isWindowVisible || window?.isMiniaturized == true }

    /// Called at termination: tear-down closes must not read as the user dismissing the
    /// window, so re-record what is actually on screen for the next launch to restore.
    ///
    /// A minimized window counts as open: an update relaunch is quit + launch, and a window the user
    /// parked in the Dock is one they still have. It comes back on screen rather than back in the
    /// Dock, which is the side to be wrong on - the other one loses it entirely.
    func persistRestoreState() {
        UserDefaults.standard.set(isWindowOpen, forKey: Self.restoreKey)
    }

    /// `restoring` = a launch-time restore: keep the autosaved frame instead of re-centering,
    /// so the window reappears where the user left it before the (update-driven) quit.
    ///
    /// `activating` = take the foreground, which every ordinary summon does because it is a click.
    /// The dev state preview passes false so that whether Tally comes forward is decided by how it
    /// was launched (`open` versus `open -g`) rather than overruled from in here.
    func show(restoring: Bool = false, activating: Bool = true) {
        StatusItemController.shared?.closePopover()
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                store: .shared, settings: .shared,
                onContentHeight: { [weak self] height in self?.applyContentHeight(height) }))
            hosting.sizingOptions = []   // manual sizing only - never a second authority
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "Settings", bundle: AppLocale.bundle)
            // Dev flavour says so in the title bar - visible from every pane, not just About.
            // Same chip as the panel header, as a titlebar accessory (titles can't carry style).
            if BuildVariant.isDev {
                let badge = NSHostingView(rootView: DevTitlebarBadge())
                badge.frame.size = badge.fittingSize
                let accessory = NSTitlebarAccessoryViewController()
                accessory.view = badge
                accessory.layoutAttribute = .trailing
                window.addTitlebarAccessoryViewController(accessory)
            }
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 500, height: 640))   // placeholder until the first report
            // Autosave keeps the size stable across launches; the position is re-derived on
            // every summon below (pointer's screen), so a stale saved origin never wins.
            window.setFrameAutosaveName("TallySettingsWindow.v5")
            ActivationPolicy.track(window)
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                // Quit-time tear-down also closes the window; only a close while the app keeps
                // running is the user dismissing it (Sparkle-relaunch lesson, see AppDelegate).
                Task { @MainActor in
                    if !AppTermination.inProgress {
                        UserDefaults.standard.set(false, forKey: Self.restoreKey)
                    }
                }
            }
            self.window = window
        }
        // Summoned windows follow the user (`NSWindow.summonShouldFollowPointer` states the whole
        // rule): to the pointer's screen when it is not up, and also when it is up but sitting
        // unfocused on a display the user is not on - on several displays, leaving it there is the
        // gear reading as a dead button. A window that is key is one they are working in, and that
        // one is never moved.
        if !restoring, window?.summonShouldFollowPointer == true { window?.centerOnPointerScreen() }
        UserDefaults.standard.set(true, forKey: Self.restoreKey)
        ActivationPolicy.promote()   // a visible Settings window earns a Dock / Cmd-Tab presence
        // The promotion above is unconditional on purpose: Cmd-Tab presence is how a window is
        // found again, and withholding it from a window nobody activated is the wrong half to
        // withhold. Only the foreground is the caller's call - and `orderFront` rather than
        // `makeKeyAndOrderFront` when it is not ours to take, so a background launch does not pull
        // first responder out of whatever the user is typing into.
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFront(nil)
        }
    }

    /// Bring the (already open) window along when another Tally window takes the stage - macOS
    /// only fronts the key window on activation, which buried Settings under other apps the
    /// moment Sparkle's update alert appeared out of it.
    func bringToFrontIfVisible() {
        if window?.isVisible == true { window?.orderFront(nil) }
        // Nothing should start focused: an auto-focused rename field opens the window with a loud
        // blue focus ring on a random account.
        window?.makeFirstResponder(nil)
    }

    /// Follow the view's reported content height (deferred a runloop turn so the window never
    /// resizes from inside the SwiftUI update that reported it - the pinned panel's lesson).
    /// Continuous but self-quieting: the ±1pt dead band stops echo, and equal heights no-op.
    private func applyContentHeight(_ height: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            guard height.isFinite, height > 1, abs(height - self.lastAppliedHeight) > 1 else { return }
            self.lastAppliedHeight = height
            let chrome = window.frame.height - (window.contentView?.frame.height ?? 0)
            // Reported height = the TALLEST pane (they lay out together for tab-switch
            // stability). Fit it whole - the workhorse pane must never need a scrollbar; short
            // panes trading some empty space for that is the right side of the tradeoff
            // (Albert's call, 2026-07-19). The screen bound stays as the only cap.
            let maxHeight = (((window.screen ?? NSScreen.main)?.visibleFrame.height) ?? 900) - 40
            let target = max(200, min(height + chrome, maxHeight))
            guard abs(target - window.frame.height) > 1 else { return }
            var frame = window.frame
            let top = frame.maxY
            frame.size.height = target
            frame.origin.y = top - target   // keep the title bar where the user sees it
            window.setFrame(frame, display: true)
        }
    }
}

/// The dev chip for the settings titlebar - same mark as the panel header's, so every surface
/// of a test instance carries the one recognizable tag.
private struct DevTitlebarBadge: View {
    var body: some View {
        Text(verbatim: "DEV")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(TallyColor.warning)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(Capsule().stroke(TallyColor.warning.opacity(0.6), lineWidth: 1))
            .padding(.trailing, 8)
    }
}
