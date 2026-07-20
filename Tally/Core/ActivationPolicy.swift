import AppKit

/// Menu-bar app baseline is `.accessory` (no Dock icon). While a regular Tally window is on
/// screen (dashboard or Settings), the app promotes itself to `.regular` so it exists in the
/// Dock and Cmd-Tab, then retracts once the last one closes: findable while open, invisible
/// while not. The pinned panel and the menu bar popover are chrome, never promoted.
@MainActor
enum ActivationPolicy {
    static func promote() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// Recompute from actual window visibility. Deferred a runloop turn so a will-close
    /// notification observes the window already gone.
    static func refresh() {
        DispatchQueue.main.async {
            let visible = MainWindowController.shared.isWindowVisible
                || SettingsWindowController.shared.isWindowVisible
            let target: NSApplication.ActivationPolicy = visible ? .regular : .accessory
            if NSApp.activationPolicy() != target { NSApp.setActivationPolicy(target) }
        }
    }

    /// Watch a window so the Dock icon retracts when its traffic light closes it.
    static func track(_ window: NSWindow) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in Task { @MainActor in refresh() } }
    }
}
