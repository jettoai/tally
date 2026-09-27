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

    private let url: URL
    private let queue = DispatchQueue(label: "tally.usage-history", qos: .utility)
    /// Last written (used, resetAt) per "account|window" key - the change filter.
    private var lastWritten: [String: (used: Double, resetAt: Date?)] = [:]
    private var didPrune = false

    /// Incremental read cache: every sample decoded so far (file order), the byte offset just past
    /// the last newline consumed, and the file's identity. A refresh decodes only the bytes appended
    /// since; a different inode/device, a file shorter than the offset, or a byte before the offset
    /// that is no longer a newline (in-place rewrite) drops the cache and reloads the whole file.
    private var cached: [Sample] = []
    private var cachedOffset: UInt64 = 0
    private var cachedIdentity: [Int]?

    init(fileURL: URL = UsageHistory.fileURL) {
        url = fileURL
    }

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
    /// A trailing line without its newline is still being written and is left for the next call.
    func samples(since: Date, completion: @escaping @Sendable ([Sample]) -> Void) {
        queue.async { [self] in
            refreshCache()
            // Keep the cache bounded to retention (plus a day of slack, so a caller asking for
            // exactly `retentionDays` a moment earlier still gets every sample it asked for).
            let floor = Date().addingTimeInterval(-TimeInterval(Self.retentionDays + 1) * 86_400)
            cached.removeAll { $0.ts < floor }
            completion(cached.filter { $0.ts >= since })
        }
    }

    private func refreshCache() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            invalidateCache()
            return
        }
        let identity = [(attrs[.systemFileNumber] as? NSNumber)?.intValue ?? -1,
                        (attrs[.deviceIdentifier] as? NSNumber)?.intValue ?? -1]
        if identity != cachedIdentity || size < cachedOffset {
            invalidateCache()
            cachedIdentity = identity
        }
        guard size > cachedOffset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        // Re-read the newline that ended the last consumed line: if it is gone, the file was
        // rewritten in place and the cached samples no longer describe it.
        let start = cachedOffset > 0 ? cachedOffset - 1 : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              var data = try? handle.readToEnd() else { return }
        if cachedOffset > 0 {
            guard data.first == UInt8(ascii: "\n") else {
                invalidateCache()
                cachedIdentity = identity
                refreshCache()
                return
            }
            data = data.dropFirst()
        }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        for line in data[data.startIndex..<lastNewline].split(separator: UInt8(ascii: "\n")) {
            if let sample = try? Self.decoder.decode(Sample.self, from: Data(line)) {
                cached.append(sample)
            }
        }
        cachedOffset += UInt64(lastNewline - data.startIndex + 1)
    }

    private func invalidateCache() {
        cached = []
        cachedOffset = 0
        cachedIdentity = nil
    }

    private func append(_ lines: [Data]) {
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
        invalidateCache()
    }
}
