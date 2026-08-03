import AppKit

/// The one way Tally asks a modal question, shared by every surface that has to ask one.
///
/// An AppKit alert in its OWN window rather than SwiftUI's `.alert`: presenting one inside the
/// borderless pinned panel forces the host window opaque for the duration, turning the transparent
/// rounded corners square (2026-07-19). NSAlert leaves the panel untouched.
@MainActor
enum CentredAlert {
    /// Run an alert centred on the window the user actually clicked in (panel or popover), falling
    /// back to the screen under the pointer, never on some other monitor's main screen. The
    /// activation also covers the notification paths, where the app may have nothing on screen.
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        alert.layout()
        let mouse = NSEvent.mouseLocation
        let anchor = NSApp.windows.first { $0.isVisible && $0.frame.contains(mouse) }?.frame
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?.visibleFrame
        if let anchor {
            let window = alert.window
            let size = window.frame.size
            let origin = NSPoint(x: anchor.midX - size.width / 2,
                                 y: anchor.midY - size.height / 2)
            window.setFrameOrigin(origin)
            // runModal re-centres the alert window as it shows, clobbering the origin above
            // (live multi-monitor incident 2026-07-20). Re-assert it from inside the modal
            // run loop, right after the show.
            RunLoop.main.perform(inModes: [.modalPanel]) {
                // A RunLoop.main callout always executes on the main thread; the closure just
                // isn't annotated, so tell the compiler rather than hop actors.
                MainActor.assumeIsolated {
                    window.setFrameOrigin(origin)
                }
            }
        }
        return alert.runModal()
    }

    /// A destructive yes/no. True means the user chose to go ahead.
    static func confirm(title: String, body: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel"))
        return run(alert) == .alertFirstButtonReturn
    }

    /// One button and a dismissal, in the same centred window.
    static func notice(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        _ = run(alert)
    }
}
