import Foundation

/// Turns each Chrome-gap event the hook filed (TallyCLI/ChromeGapEvent.swift) into one notification.
/// Runs on the refresh cycle, installed app only, beside the other notifiers; events older than
/// `chromeGapEventMaxAge` are deleted unannounced by the drain.
@MainActor
final class ChromeGapNotifier {
    static let shared = ChromeGapNotifier()

    private init() {}

    func sweep(now: Date = Date()) {
        for event in drainChromeGapEvents(now: now) {
            let alert = Self.alert(for: event)
            Task { _ = await SystemAlert.post(title: alert.title, body: alert.body) }
        }
    }

    /// The words, kept apart from delivery so they are the part that can be read in isolation.
    /// Says what to check; never claims which accounts the extension is signed in to.
    static func alert(for event: ChromeGapEvent) -> (title: String, body: String) {
        let project = event.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? L("A session")
        let reachable = event.reachable ?? []
        let observed = reachable.isEmpty ? L("none") : reachable.joined(separator: ", ")
        return (String(format: L("Chrome not connected on %@"), event.label),
                String(format: L("%1$@: verify the extension is open and signed in to this account. Previously connected: %2$@."),
                       project, observed))
    }
}
