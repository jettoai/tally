import AppKit
import SwiftUI

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
    /// The state is read HERE, on the press, and the callers never disable themselves on it: nothing
    /// tells SwiftUI that ~/.tally/supervisor-state changed, so a rendered count goes stale the
    /// moment a session starts or ends. A control disabled by a stale zero reads as broken, and one
    /// enabled by a stale count would silently do nothing. So the button is always live and answers
    /// with what is true at the moment of the click: the confirmation when sessions will act on it,
    /// and the note below when they will not.
    @MainActor
    static func presentConfirm() {
        let readiness = currentReloadReadiness()
        guard case .ready(let live) = readiness else {
            // Nothing to confirm either way, but the two remaining states are not the same news:
            // one says the machine is idle, the other that sessions are running and need one
            // restart first.
            presentNotice(L("Reload running sessions"), readinessNote(readiness),
                          style: .informational)
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
            presentNotice(L("Could not request a reload"), error.localizedDescription,
                          style: .warning)
        }
    }

    /// What every surface says about a given state, so the alert, the footer tooltip, and the
    /// Settings row cannot disagree. Empty while sessions are registered and will act: there is
    /// nothing to warn about, and the caller supplies its own ordinary wording. Takes the state
    /// rather than reading it, so a caller that already has one does not pay for a second scan.
    @MainActor
    static func readinessNote(_ readiness: ReloadReadiness) -> String {
        switch readiness {
        case .ready: return ""
        case .nothingRunning: return L("No supervised sessions are running")
        case .legacyOnly(let count): return reloadLegacyNotice(count, localize: L)
        }
    }

    /// The tooltip for a control that triggers a reload: the ordinary two-clause explanation, or the
    /// state note when there is something the click will not be able to do.
    @MainActor
    static func tooltip() -> String {
        let note = readinessNote(currentReloadReadiness())
        guard note.isEmpty else { return note }
        return L("Reload running sessions") + " · " + L("Each restarts when it goes idle")
    }

    /// One button and a dismissal, in the same centred window the confirmation uses.
    @MainActor
    private static func presentNotice(_ title: String, _ body: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = style
        alert.addButton(withTitle: L("OK"))
        _ = runCentred(alert)
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
