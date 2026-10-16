import Foundation

/// The last good reading of every account, kept across launches so the first frame after a
/// restart ("Update and relaunch") is the account list the user just had, not an empty pool that
/// fills one account at a time as the probes land (B-2027).
///
/// A whitelist, not a dump: only what the card already shows (percentages, reset instants, the
/// account's id, label and plan) plus the config home path used to drop a removed account at
/// seed time. Never the email, never an error string, never any token or grant.
struct LastGoodCache: Codable, Equatable {
    static let currentVersion = 1
    /// A row older than this is not shown as if it were current.
    static let maxAge: TimeInterval = 86_400

    var version: Int
    var savedAt: Date
    var rows: [Row]

    struct Row: Codable, Equatable {
        var id: String
        var providerID: String
        var accountLabel: String
        var planName: String?
        /// Config home, only to notice at seed time that the account was removed.
        var home: String
        var refreshedAt: Date
        var metrics: [UsageMetric]
    }

    /// Only accounts with a known home are kept, sorted by id so identical state encodes to
    /// identical rows. Dates use the default (Double) strategy: `.iso8601` would drop sub-seconds.
    static func rows(_ lastGood: [String: AccountUsage], homes: [String: String]) -> [Row] {
        lastGood.values.compactMap { usage in
            homes[usage.id].map {
                Row(id: usage.id, providerID: usage.providerID, accountLabel: usage.accountLabel,
                    planName: usage.planName, home: $0, refreshedAt: usage.refreshedAt,
                    metrics: usage.metrics)
            }
        }
        .sorted { $0.id < $1.id }
    }

    static func encode(rows: [Row], savedAt: Date) -> Data? {
        try? JSONEncoder().encode(LastGoodCache(version: currentVersion, savedAt: savedAt, rows: rows))
    }

    /// nil for no data, damaged data, or a schema this build does not know.
    static func decode(_ data: Data?) -> LastGoodCache? {
        guard let data, let cache = try? JSONDecoder().decode(LastGoodCache.self, from: data),
              cache.version == currentVersion else { return nil }
        return cache
    }

    struct Seed {
        /// Rows to show on the first frame, in the order a refresh commit sorts them.
        var rows: [AccountUsage] = []
        /// Every surviving reading, shown or not, so re-enabling an account has numbers at once.
        var lastGood: [String: AccountUsage] = [:]
        var homes: [String: String] = [:]
    }

    /// What survives a restart: rows younger than `maxAge`, whose home still exists, restored to
    /// the shape the in-memory last-good has (no error, not stale).
    static func seed(_ cache: LastGoodCache?, now: Date, homeExists: (String) -> Bool,
                     isShown: (_ providerID: String, _ id: String) -> Bool) -> Seed {
        var seed = Seed()
        for row in cache?.rows ?? []
        where now.timeIntervalSince(row.refreshedAt) <= maxAge && homeExists(row.home) {
            let usage = AccountUsage(id: row.id, providerID: row.providerID,
                                     accountLabel: row.accountLabel, planName: row.planName,
                                     accountEmail: nil, metrics: row.metrics,
                                     refreshedAt: row.refreshedAt, error: nil)
            seed.lastGood[row.id] = usage
            seed.homes[row.id] = row.home
            if isShown(row.providerID, row.id) { seed.rows.append(usage) }
        }
        seed.rows.sort { ($0.providerID, $0.accountLabel) < ($1.providerID, $1.accountLabel) }
        return seed
    }
}
