import AppKit

/// Writes down every moment keyboard focus may have changed hands, for the supervisors
/// (TallyCLI/FocusEvents.swift says why they need it). Two sources, because a terminal loses key in
/// two ways the app can see: another app coming to the front, and one of Tally's own windows or
/// panels taking key while the terminal's app stays frontmost (the popover and the pick panel open
/// without activating the app, so no workspace notification fires for them).
@MainActor
final class FocusEventRecorder {
    static let shared = FocusEventRecorder()
    /// A switch fires a deactivate and an activate together, and a Tally window taking key fires its
    /// own pair; one line per switch is enough for a 1s window.
    static let dedupe: TimeInterval = 0.2
    private var tokens: [NSObjectProtocol] = []
    private var last: Date?

    func install() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { FocusEventRecorder.shared.record() }
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil,
                                                                 queue: .main) { _ in
                MainActor.assumeIsolated { FocusEventRecorder.shared.record() }
            })
        }
    }

    /// The time is taken before anything else so the file write cannot age it.
    func record(now: Date = Date()) {
        if let last, now.timeIntervalSince(last) < Self.dedupe { return }
        last = now
        try? appendFocusEvent(now)
    }
}
