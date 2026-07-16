import AppKit
import SwiftUI

/// Hosts the settings UI in a plain custom NSWindow (mirroring MainWindowController) instead of the
/// SwiftUI `Settings` scene. The scene's `showSettingsWindow:` action is unreliable for an LSUIElement
/// accessory app (and the selector name is OS-version-sensitive), which made the gear appear to hang.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(store: .shared, settings: .shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "Settings", bundle: AppLocale.bundle)
            // Settings windows are conventionally fixed-size and not minimizable (macOS HIG).
            // No manual setContentSize: the hosting controller sizes the window to SettingsView's
            // fixed frame — a second (smaller) size authority here clipped the form's right/bottom.
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("TallySettingsWindow")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
