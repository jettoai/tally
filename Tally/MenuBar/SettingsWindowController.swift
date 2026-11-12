import AppKit
import SwiftUI

/// Hosts the settings UI in a plain custom NSWindow (mirroring MainWindowController) instead of the
/// SwiftUI `Settings` scene. The scene's `showSettingsWindow:` action is unreliable for an LSUIElement
/// accessory app (and the selector name is OS-version-sensitive), which made the gear appear to hang.
///
/// Sizing: ONE FIXED SIZE ON EVERY PANE (`SettingsChrome.windowWidth` by `windowHeight`), written
/// by `applyFixedSize` and nothing else. The view reports no size; only the display can overrule the
/// height (a short screen caps it). The window used to follow the pane in front, which made it grow
/// and shrink under the click on every sidebar switch (Albert, 2026-08-23, 2026-10-10, 2026-11-12).
/// `sizingOptions = []` keeps this the ONLY size authority - two authorities recursed the layout
/// engine into a stack overflow once (see PinnedPanelController).
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private(set) var window: NSWindow?

    /// Restore-on-launch flag, mirroring MainWindowController: an update relaunch is quit +
    /// launch, and Settings is the LIKELIEST open window then (the update button lives in it).
    private nonisolated static let restoreKey = "restoreSettingsWindow"

    /// The ONE place that flag is written, and the one launch that does not write it.
    ///
    /// A CAPTURE LAUNCH MAY NOT LEAVE THE USER A WINDOW THEY DID NOT OPEN
    /// (`CaptureLaunch.mayRecordWindowState` carries the rule and what it is worth). This window is
    /// opened at launch by `-TallySettingsCapture` so a row in it can be photographed, and every
    /// write below would otherwise be that photograph editing the app: the summon records "open",
    /// the tear-down records it again, and the next ordinary launch puts Settings up on its own.
    /// Suppressed in BOTH directions rather than only the true one, because the false is a write
    /// too: a capture that opens and closes this window would otherwise erase a restore the user
    /// really had.
    ///
    /// Its neighbour needs no such guard: no flag in the family opens the dashboard, so the only
    /// thing a capture launch can record about it is the state it restored it from.
    private nonisolated static func recordRestore(_ open: Bool) {
        guard CaptureLaunch.launchMayRecordWindowState else { return }
        UserDefaults.standard.set(open, forKey: restoreKey)
    }

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
        Self.recordRestore(isWindowOpen)
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
            let hosting = NSHostingController(rootView: SettingsView(store: .shared, settings: .shared))
            hosting.sizingOptions = []   // manual sizing only - never a second authority
            let window = Self.makeWindow(hosting)
            window.title = String(localized: "Settings", bundle: AppLocale.bundle)
            // Dev flavour says so in the title bar strip, top right over the pane, visible from
            // every pane and not just About: the panel header's own tag, as a titlebar accessory.
            if BuildVariant.isDev || OverlayApp.menuBarEditionText != nil {
                let badge = NSHostingView(rootView: HStack(spacing: 6) {
                    if BuildVariant.isDev { TallyDevTagView() }
                    OverlayApp.titlebarEditionBadge
                }.padding(.trailing, 8))
                badge.frame.size = badge.fittingSize
                let accessory = NSTitlebarAccessoryViewController()
                accessory.view = badge
                accessory.layoutAttribute = .trailing
                window.addTitlebarAccessoryViewController(accessory)
            }
            // No title bar of its own (B-1355, System Settings' shape): the content runs to the top
            // edge, the sidebar colour carries up behind the traffic lights, and the pane names the
            // section, so the window title stays only for the Window menu and Cmd-Tab. The strip
            // stays draggable: it is still the titlebar, only transparent.
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            // The fixed size; the display may still cap the height (`applyFixedSize`, every show).
            window.setContentSize(NSSize(width: SettingsChrome.windowWidth, height: SettingsChrome.windowHeight))
            // Autosave carries the POSITION across launches, for the restore path that does not
            // re-derive one (a launch-time restore keeps where the user left the window); every
            // ordinary summon re-derives it below (pointer's screen), so a stale saved origin never
            // wins there. The size it saves along with it is never read as the truth: every show
            // rewrites it (`applyFixedSize`), so the name does not need to move on when sizing
            // changes.
            window.setFrameAutosaveName("TallySettingsWindow.v6")
            ActivationPolicy.track(window)
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                // Quit-time tear-down also closes the window; only a close while the app keeps
                // running is the user dismissing it (Sparkle-relaunch lesson, see AppDelegate).
                Task { @MainActor in
                    if !AppTermination.inProgress { Self.recordRestore(false) }
                }
            }
            self.window = window
        }
        // Summoned windows follow the user (`NSWindow.summonShouldFollowPointer` states the whole
        // rule): to the pointer's screen when it is not up, and also when it is up but sitting
        // unfocused on a display the user is not on - on several displays, leaving it there is the
        // gear reading as a dead button. A window that is key is one they are working in, and that
        // one is never moved.
        if !restoring, window?.summonShouldFollowPointer == true {
            // SIZED FOR THE DISPLAY IT IS GOING TO, BEFORE IT IS PLACED THERE. A window that kept a
            // tall display's height when it is summoned to a short one cannot be saved by a clamp
            // alone: the clamp saves the title bar while the buttons stay off the bottom of the
            // screen (found by review of 8cdafad). Sizing first is what lets the placement below be
            // made around the height the window will actually have.
            applyFixedSize(on: NSScreen.pointerScreen)
            window?.centerOnPointerScreen()
            window?.clampOnScreen()
        }
        // A restore keeps the saved position but not the saved size: the frame autosave brings back
        // whatever size the window last had (an older build's pane-fitted height, say), and nothing
        // else would correct it now that no content report does. The clamp is for a window that
        // grows past the foot of its display.
        if restoring {
            applyFixedSize(on: window?.screen)
            window?.clampOnScreen()
        }
        Self.recordRestore(true)
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
        // Nothing starts focused (same rule as `bringToFrontIfVisible`): AppKit hands the first
        // text field the focus as the window comes up, which put a caret in the Launch pane's
        // fallback-args field on every open. A turn later, after that hand-off has happened.
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
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

    /// THE ONE PLACE THIS WINDOW'S SIZE IS WRITTEN: the fixed width and height, the height capped to
    /// what `screen` has (`ResizeAnchor.fittedWindowHeight`, the one piece of arithmetic for that).
    ///
    /// The display is passed in rather than read off the window because a summon knows where the
    /// window is ABOUT to be, and sizing against the display it is leaving would answer with the
    /// height it already has. Holds the top edge, so a cap change moves only the bottom edge.
    ///
    /// Never animated: an animated height is a pane visibly unrolling (Albert, 2026-10-10).
    private func applyFixedSize(on screen: NSScreen?) {
        guard let window else { return }
        // The titlebar strip, measured: with a full-size content view the content view spans the
        // whole frame, and the layout rect is the part below the strip the view lays out in.
        let chrome = window.frame.height - window.contentLayoutRect.height
        let visible = (screen ?? window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = ResizeAnchor.fittedWindowHeight(reported: SettingsChrome.windowHeight - chrome,
                                                     chrome: chrome, visibleHeight: visible)
        let size = CGSize(width: SettingsChrome.windowWidth, height: height)
        guard ResizeAnchor.needsResize(from: window.frame.size, to: size) else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - height   // keep the title bar where the user sees it
        window.setFrame(frame, display: true)
    }
}

extension SettingsWindowController {
    /// A capture launch runs in the background, so its window is never key and every switch in it
    /// draws grey, which on a review shot reads as "all switched off". Debug captures get a window
    /// that reports itself key and main so the controls draw as they do in front of the user.
    fileprivate static func makeWindow(_ hosting: NSViewController) -> NSWindow {
        #if DEBUG
        if SettingsCaptureLaunch.isActive { return CaptureKeyWindow(contentViewController: hosting) }
        #endif
        return NSWindow(contentViewController: hosting)
    }
}

#if DEBUG
private final class CaptureKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    // Switches ask AppKit's own active-appearance queries rather than isKeyWindow; these are the
    // selectors NSWindow answers them with (listed from the runtime, macOS 27).
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasActiveControls() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }
}
#endif
