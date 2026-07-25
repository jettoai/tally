import SwiftUI
import AppKit

/// The one confirm-and-write behind every in-app "reload running sessions" control (the Settings
/// row and the panel footer button). Both surfaces are the same act, so they share this rather than
/// each carrying their own alert: one sentence to translate, one place a change lands.
///
/// The write itself is `writeReloadRequest` from ReloadRequest.swift, compiled into both targets,
/// so the button and `tally reload` stamp the identical file.
enum ReloadAction {
    /// Ask first, then stamp the request. Confirmed on purpose: a button sits one stray click away
    /// from restarting every session on the machine, while typing `tally reload` IS the intent.
    ///
    /// The count is read HERE, on the press, and the callers never disable themselves on it: nothing
    /// tells SwiftUI that ~/.tally/supervisor-state changed, so a rendered count goes stale the
    /// moment a session starts or ends. A control disabled by a stale zero reads as broken, and one
    /// enabled by a stale count would silently do nothing. So the button is always live and answers
    /// with what is true at the moment of the click: the confirmation when there are sessions, and
    /// a plain "none are running" when there are not.
    @MainActor
    static func presentConfirm() {
        let live = liveSupervisorCount()
        guard live > 0 else {
            let none = NSAlert()
            none.messageText = L("Reload running sessions")
            none.informativeText = L("No supervised sessions are running")
            none.alertStyle = .informational
            none.addButton(withTitle: L("OK"))
            _ = runCentred(none)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Reload running sessions")
        alert.informativeText = String(format: L(live == 1
            ? "Reload %d running session? Each restarts when it goes idle; conversations continue."
            : "Reload %d running sessions? Each restarts when it goes idle; conversations continue."),
            live)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Reload"))
        alert.addButton(withTitle: L("Cancel"))
        guard runCentred(alert) == .alertFirstButtonReturn else { return }
        do {
            try writeReloadRequest()
        } catch {
            // A request that never landed must never pass for a quiet success.
            let failure = NSAlert()
            failure.messageText = L("Could not request a reload")
            failure.informativeText = error.localizedDescription
            failure.alertStyle = .warning
            failure.addButton(withTitle: L("OK"))
            _ = runCentred(failure)
        }
    }

    /// An AppKit alert in its OWN window, like the card's redeem confirmation: SwiftUI's `.alert`
    /// inside the borderless pinned panel forces the host window opaque while it shows, squaring
    /// its rounded corners. Centred on the window the user actually clicked in, falling back to the
    /// screen under the pointer, never on some other monitor's main screen.
    @MainActor
    private static func runCentred(_ alert: NSAlert) -> NSApplication.ModalResponse {
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
            // runModal re-centres the alert window as it shows, clobbering the origin above.
            // Re-assert it from inside the modal run loop, right after the show.
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
}
