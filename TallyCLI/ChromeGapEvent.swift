import Foundation

// THE CHROME-GAP EVENT, the one file both targets compile for it: the hook (ChromeReach.swift) writes
// one per supervised child whose Claude in Chrome call came back "not connected", and the app
// (ChromeGapNotifier.swift) turns each into one notification and deletes it. Separate processes
// speaking through a file, so the shape, the directory and the reader live here once.

/// Where the hook leaves an event for the app to announce.
let chromeGapEventDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/chrome-gap")

/// An event older than this is dropped unannounced: an app that was not running when the gap
/// happened should not replay it later as if it were news.
let chromeGapEventMaxAge: TimeInterval = 30 * 60

/// One "Chrome was not connected here" observation. Keyed JSON, additive fields only.
struct ChromeGapEvent: Codable, Equatable, Sendable {
    var account: String
    var label: String
    var cwd: String?
    /// Labels of the accounts the ledger has seen reach Chrome, at the moment of the gap.
    var reachable: [String]?
    var at: Date
}

/// Best effort and atomic; a lost event costs one notification, never the session.
func writeChromeGapEvent(_ event: ChromeGapEvent, supervisorPid: String, childPid: Int,
                         dir: URL = chromeGapEventDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(event) else { return }
    try? data.write(to: dir.appendingPathComponent("\(supervisorPid).\(childPid).json"),
                    options: .atomic)
}

/// Every event waiting in `dir` that is still fresh, oldest first. EVERY file read is deleted,
/// whether it decoded, decoded stale, or did not decode at all: each is announced at most once.
func drainChromeGapEvents(dir: URL = chromeGapEventDir, now: Date = Date()) -> [ChromeGapEvent] {
    let files = ((try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var events: [ChromeGapEvent] = []
    for file in files {
        let event = (try? Data(contentsOf: file)).flatMap {
            try? decoder.decode(ChromeGapEvent.self, from: $0)
        }
        try? FileManager.default.removeItem(at: file)
        if let event, now.timeIntervalSince(event.at) <= chromeGapEventMaxAge { events.append(event) }
    }
    return events.sorted { $0.at < $1.at }
}
