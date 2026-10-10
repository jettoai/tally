import AppKit

/// WHICH LEVEL THE USAGE PANEL STANDS AT, and the pin setting is the whole answer (B-1056).
///
/// Pinned is the one state that floats above other apps' windows; unpinned is an ordinary window
/// level, so clicking another app covers the panel like any other window. There is no build or
/// launch-flag exception: a dev build, the release build and a `-TallyPanelCapture` launch all ask
/// this one function, so a panel that is merely shown (never pinned) does not float.
///
/// Only the level follows the pin. `hidesOnDeactivate` stays false either way, so an unpinned panel
/// is covered rather than vanishing, which is what an ordinary window does.
@MainActor
enum PanelPinLevel {
    static func level(pinned: Bool) -> NSWindow.Level { pinned ? .floating : .normal }

    static func apply(to window: NSWindow, pinned: Bool) {
        window.level = level(pinned: pinned)
    }
}
