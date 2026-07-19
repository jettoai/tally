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

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                store: .shared, settings: .shared,
                onContentHeight: { [weak self] height in self?.applyContentHeight(height) }))
            hosting.sizingOptions = []   // manual sizing only - never a second authority
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "Settings", bundle: AppLocale.bundle)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 500, height: 640))   // placeholder until the first report
            // Autosave keeps the size stable across launches; the position is re-derived on
            // every summon below (pointer's screen), so a stale saved origin never wins.
            window.setFrameAutosaveName("TallySettingsWindow.v5")
            self.window = window
        }
        // Summoned windows follow the user: place on the pointer's screen whenever the window
        // isn't already up (an open window stays put - yanking it mid-use would be worse).
        if window?.isVisible != true { window?.centerOnPointerScreen() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
