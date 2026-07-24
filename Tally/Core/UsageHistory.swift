import Foundation

/// Append-only usage history (`~/.tally/history.jsonl`): the raw material for burn-rate
/// forecasting ("at my pace, does the fleet last until the resets refill?"). One JSON line per
/// (account, window) sample, written only when the value actually moved, so idle hours cost
/// nothing. Pruned to a rolling retention window once per app run.
///
/// Queue-confined: all mutable state and file I/O live on one serial utility queue, so recording
/// never blocks the main-actor refresh path.
final class UsageHistory: @unchecked Sendable {
    static let shared = UsageHistory()

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tally/history.jsonl")
    static let retentionDays = 28   // four weeks: the usage advisor's weekly-demand trend needs it

    /// One recorded observation. `used` is the percent used at `ts`; `resetAt` segments the series
    /// (a window whose resetAt changed has rolled over, so deltas across it are not consumption).
    struct Sample: Codable, Sendable {
        var ts: Date
        var account: String
        var provider: String
        var window: String       // MetricKind rawValue
        var model: String?
        var used: Double
        var resetAt: Date?
    }

    private let queue = DispatchQueue(label: "tally.usage-history", qos: .utility)
    /// Last written (used, resetAt) per "account|window" key - the change filter.
    private var lastWritten: [String: (used: Double, resetAt: Date?)] = [:]
    private var didPrune = false

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Record one refresh round. Only fresh fetches count: stale carried-forward numbers would
    /// write flat lines that dilute the burn-rate estimate. Demo fixtures never reach here
    /// (the demo refresh path returns before recording, same as the snapshot write).
    func record(_ accounts: [AccountUsage], at now: Date = Date()) {
        let fresh = accounts.filter { $0.error == nil && !$0.isStale }
        guard !fresh.isEmpty else { return }
        queue.async { [self] in
            if !didPrune {
                didPrune = true
                prune(now: now)
            }
            var lines: [Data] = []
            for account in fresh {
                for metric in account.metrics {
                    let key = "\(account.id)|\(metric.id)"
                    let last = lastWritten[key]
                    guard last == nil || last!.used != metric.usedPercent
                        || last!.resetAt != metric.resetsAt else { continue }
                    lastWritten[key] = (metric.usedPercent, metric.resetsAt)
                    let sample = Sample(ts: now, account: account.id, provider: account.providerID,
                                        window: metric.kind.rawValue, model: metric.modelName,
                                        used: metric.usedPercent, resetAt: metric.resetsAt)
                    if let data = try? Self.encoder.encode(sample) { lines.append(data) }
                }
            }
            guard !lines.isEmpty else { return }
            append(lines)
        }
    }

    /// Read every sample at or after `since` (line-by-line tolerant decode), delivered on the
    /// history queue - callers hop back to their own actor.
    func samples(since: Date, completion: @escaping @Sendable ([Sample]) -> Void) {
        queue.async {
            var out: [Sample] = []
            if let data = try? Data(contentsOf: Self.fileURL) {
                for line in data.split(separator: UInt8(ascii: "\n")) {
                    guard let sample = try? Self.decoder.decode(Sample.self, from: Data(line)),
                          sample.ts >= since else { continue }
                    out.append(sample)
                }
            }
            completion(out)
        }
    }

    private func append(_ lines: [Data]) {
        let url = Self.fileURL
        let payload = lines.map { $0 + Data("\n".utf8) }.reduce(Data(), +)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? payload.write(to: url)
        }
    }

    /// Drop samples older than the retention window. Line-by-line decode so one corrupt line
    /// (partial write, manual edit) costs only itself, not the whole file.
    private func prune(now: Date) {
        let url = Self.fileURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.retentionDays) * 86_400)
        let kept = data.split(separator: UInt8(ascii: "\n")).filter { line in
            guard let sample = try? Self.decoder.decode(Sample.self, from: Data(line)) else {
                return false
            }
            return sample.ts >= cutoff
        }
        let rewritten = kept.map { Data($0) + Data("\n".utf8) }.reduce(Data(), +)
        guard rewritten.count != data.count else { return }
        try? rewritten.write(to: url, options: .atomic)
    }
}
