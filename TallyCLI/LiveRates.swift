import Foundation

// What Claude Code itself reports about an account's two main windows, captured on every status
// line render and read by the app's poller (ProbeCadence.swift). Status-line JSON as of CC 2.1.283:
// `rate_limits.five_hour` / `rate_limits.seven_day`, each `{ used_percentage, resets_at }`
// (resets_at in unix seconds), present only after the session's first API response. There is no
// model-scoped (flagship) window in it, so the `/usage` probe still owns that one.
//
// Only percentages, reset times, timestamps and the account id are stored: nothing here is a
// credential. Both targets compile this file: the status line writes it, the app reads it.

let liveRatesDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/live-rates", isDirectory: true)

struct LiveRateWindow: Codable, Equatable, Sendable {
    var usedPercent: Double
    var resetsAt: Date
}

struct LiveRateFact: Codable, Equatable, Sendable {
    /// "claude:<home directory name>", the id UsageStore rows carry.
    var accountID: String
    /// The last render that carried rate limits for this account, from any of its sessions.
    var observedAt: Date
    /// When the stored numbers last moved. A render of an idle session repeats the headers of its
    /// last API response, so this, not `observedAt`, is how recent the numbers are.
    var changedAt: Date
    var fiveHour: LiveRateWindow?
    var sevenDay: LiveRateWindow?
    /// The last render whose session was running this account's flagship model.
    var flagshipAt: Date?
}

typealias LiveRateWindows = (fiveHour: LiveRateWindow?, sevenDay: LiveRateWindow?)

func parseLiveRateWindows(_ json: [String: Any]?) -> LiveRateWindows? {
    guard let limits = json?["rate_limits"] as? [String: Any] else { return nil }
    func window(_ key: String) -> LiveRateWindow? {
        guard let entry = limits[key] as? [String: Any],
              let used = (entry["used_percentage"] as? NSNumber)?.doubleValue,
              let resets = (entry["resets_at"] as? NSNumber)?.doubleValue else { return nil }
        return LiveRateWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
    }
    let (five, seven) = (window("five_hour"), window("seven_day"))
    return five == nil && seven == nil ? nil : (five, seven)
}

/// Whether a session runs the account's flagship model: the flagship window's name, lower-cased,
/// is a prefix of the session model's name ("fable" of "Fable 5.1"). An empty window name matches
/// nothing, because `hasPrefix("")` is true of every string. The status line's flagship meter and
/// the live-rate fact both ask this, so it is written once.
func sessionRunsFlagship(windowName: String?, sessionModel: String?) -> Bool {
    guard let name = windowName?.lowercased(), !name.isEmpty,
          let model = sessionModel?.lowercased() else { return false }
    return model.hasPrefix(name)
}

/// Several sessions of one account write the same file, and an idle one re-rendering repeats older
/// headers. Within one period usage only rises, so the same reset keeps the higher number; a later
/// reset is a new period and wins outright.
func mergeLiveRateWindow(_ old: LiveRateWindow?, _ new: LiveRateWindow?) -> LiveRateWindow? {
    guard let old else { return new }
    guard let new else { return old }
    if new.resetsAt != old.resetsAt { return new.resetsAt > old.resetsAt ? new : old }
    return new.usedPercent >= old.usedPercent ? new : old
}

func mergeLiveRateFact(previous: LiveRateFact?, accountID: String, windows: LiveRateWindows,
                       onFlagship: Bool, now: Date) -> LiveRateFact {
    let five = mergeLiveRateWindow(previous?.fiveHour, windows.fiveHour)
    let seven = mergeLiveRateWindow(previous?.sevenDay, windows.sevenDay)
    let moved = previous == nil || five != previous?.fiveHour || seven != previous?.sevenDay
    return LiveRateFact(accountID: accountID, observedAt: now,
                        changedAt: moved ? now : (previous?.changedAt ?? now),
                        fiveHour: five, sevenDay: seven,
                        flagshipAt: onFlagship ? now : previous?.flagshipAt)
}

func liveRateFile(accountID: String, dir: URL = liveRatesDir) -> URL {
    let safe = accountID.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
    return dir.appendingPathComponent(String(safe) + ".json")
}

func readLiveRateFact(accountID: String, dir: URL = liveRatesDir) -> LiveRateFact? {
    guard let data = try? Data(contentsOf: liveRateFile(accountID: accountID, dir: dir)),
          let fact = try? JSONDecoder().decode(LiveRateFact.self, from: data),
          fact.accountID == accountID else { return nil }
    return fact
}

/// Best effort and silent: a status line must render whatever happens here. Writes only when the
/// numbers moved, the flagship stamp moved, or the last write is 20 seconds old or more, because a
/// busy session renders several times a second.
func recordLiveRateFact(_ fact: LiveRateFact, previous: LiveRateFact?, dir: URL = liveRatesDir) {
    if let previous, previous.changedAt == fact.changedAt, previous.flagshipAt == fact.flagshipAt,
       fact.observedAt.timeIntervalSince(previous.observedAt) < 20 { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(fact) else { return }
    try? data.write(to: liveRateFile(accountID: fact.accountID, dir: dir), options: .atomic)
}
