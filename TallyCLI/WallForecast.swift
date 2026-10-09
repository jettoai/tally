import Foundation

// WALL FORECAST: how many minutes an account has before a window it spends hits zero, from the
// burn the app has been recording (`~/.tally/history.jsonl`). B-1360: on 2026-10-07 an account's
// 5h window went from 10% to 0% in fourteen minutes with nine sessions on it; the turn-boundary
// move waited for 5%, which left about six minutes, and nine sessions walled mid-turn.

/// Minutes-to-wall at or under which the turn-boundary move starts early. Measured on that
/// drought: every walled session reached a turn end within twelve minutes of the forecast first
/// reading under twenty, and the app's history had an eleven-minute gap in its samples there.
let earlyMoveMinutes: Double = 20

/// How far back the slope looks.
let wallForecastLookback: TimeInterval = 15 * 60

/// The shortest stretch a slope is read over. History percents are whole numbers, so two samples a
/// minute apart turn one point of rounding into a point a minute, which reads 10% as ten minutes from
/// the wall; over five minutes the same rounding is a fifth of that. The app samples every two to
/// six minutes (p10 and p50 on this machine), so a real burn always spans this inside the lookback.
let wallForecastMinSpan: TimeInterval = 5 * 60

/// One reading of one (account, window): remaining percent at a moment.
struct BurnSample: Equatable { let at: Date; let remaining: Double }

/// Slope in percent per minute over the lookback, or nil when it cannot be read (fewer than two
/// samples, fewer than `minSpan` between them, or no fall). nil is "no forecast", which never moves anything.
func burnSlope(_ samples: [BurnSample], now: Date,
               lookback: TimeInterval = wallForecastLookback,
               minSpan: TimeInterval = wallForecastMinSpan) -> Double? {
    let inWindow = samples.filter { now.timeIntervalSince($0.at) <= lookback && $0.at <= now }
        .sorted { $0.at < $1.at }
    // A window that reset inside the lookback rose; only the readings since its last rise describe
    // this cycle, so a fresh window is forecast once it has burned `minSpan`, not once the old
    // cycle's readings age out of the lookback.
    let rise = inWindow.indices.last {
        $0 > 0 && inWindow[$0].remaining > inWindow[$0 - 1].remaining
    }
    let recent = rise.map { Array(inWindow[$0...]) } ?? inWindow
    guard let first = recent.first, let last = recent.last,
          last.at.timeIntervalSince(first.at) >= minSpan,
          first.remaining > last.remaining else { return nil }
    return (first.remaining - last.remaining) / (last.at.timeIntervalSince(first.at) / 60)
}

/// The account's minutes to its first wall across the windows `ratedWindows` counts, or nil.
/// `samples` is asked by the rated window's name (`AccountRoles` names, or the flagship's).
func minutesToWall(_ account: Snapshot.Account, primaryModel: String?,
                   reserves: AccountReserves = .none, now: Date,
                   samples: (_ window: String) -> [BurnSample]) -> Double? {
    ratedWindows(account, primaryModel: primaryModel, reserves: reserves, now: now)
        .compactMap { window -> Double? in
            guard let slope = burnSlope(samples(window.name), now: now) else { return nil }
            return max(effectiveRemaining(comfortWindow(window), now: now), 0) / slope
        }
        .min()
}

/// The history key for one rated window. The history names windows `session`, `weeklyAll` and
/// `weeklyModel`; `ratedWindows` names them `AccountRoles.sessionWindowName`, `weeklyWindowName`
/// and the flagship's own name, so anything else is the flagship. Account ids are the same form on
/// both sides (`claude:.claude3`), as `loadAdvisorReadings` already relies on.
func burnSampleKey(account: String, ratedWindow: String) -> String {
    let window: String
    switch ratedWindow {
    case AccountRoles.sessionWindowName: window = "session"
    case AccountRoles.weeklyWindowName: window = UsageAdvisor.weeklyAllWindow
    default: window = UsageAdvisor.weeklyModelWindow
    }
    return account + "\t" + window
}

/// The history tail, read once per call: the last `tailBytes` of the file, grouped by
/// `burnSampleKey`. Fail-open to empty, which reads as "no forecast". Timestamps are read with and
/// without fractional seconds, since `.iso8601` alone drops the row that carries them.
func loadBurnSamples(file: URL = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".tally/history.jsonl"),
                     tailBytes: Int = 512 * 1024) -> [String: [BurnSample]] {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    guard (try? handle.seek(toOffset: offset)) != nil,
          let data = try? handle.readToEnd() else { return [:] }
    var lines = data.split(separator: UInt8(ascii: "\n"))
    if offset > 0, !lines.isEmpty { lines.removeFirst() }  // the cut left half a line
    let whole = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var out: [String: [BurnSample]] = [:]
    for line in lines {
        guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let account = row["account"] as? String, let window = row["window"] as? String,
              let used = (row["used"] as? NSNumber)?.doubleValue, let ts = row["ts"] as? String,
              let at = whole.date(from: ts) ?? fractional.date(from: ts) else { continue }
        out[account + "\t" + window, default: []].append(BurnSample(at: at, remaining: 100 - used))
    }
    return out
}

/// The supervisor's copy of the history tail, re-read at most once a minute and only when a
/// forecast is actually asked for.
struct BurnSampleCache {
    private var samples: [String: [BurnSample]] = [:]
    private var readAt: Date?

    mutating func forecast(_ account: Snapshot.Account, primaryModel: String?,
                           reserves: AccountReserves, now: Date) -> Double? {
        if readAt.map({ now.timeIntervalSince($0) >= 60 || now < $0 }) ?? true {
            samples = loadBurnSamples()
            readAt = now
        }
        let loaded = samples
        return minutesToWall(account, primaryModel: primaryModel, reserves: reserves, now: now) {
            loaded[burnSampleKey(account: account.id, ratedWindow: $0)] ?? []
        }
    }
}
