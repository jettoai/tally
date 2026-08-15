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
    ///
    /// THE ACTIVATION STAYS UNCONDITIONAL HERE, and that is a difference from the popover's summon
    /// rather than an oversight (both were looked at on 2026-08-15). The popover asks a question the
    /// user can answer by looking, so it must not disturb anything to be read; an alert is a question
    /// that BLOCKS - a modal run loop is already started - and it may be raised by a path with
    /// nothing of ours on screen at all, so an app that failed to come forward would be an app
    /// waiting on an answer to a question nobody was shown. The known cost is the popover's symptom
    /// in miniature: while another Tally window is open it is the key one, so it comes forward with
    /// the alert. It is momentary and the user asked for the alert, which is why it is priced
    /// differently from a glance at the menu bar.
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
