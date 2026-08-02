import Foundation

/// Scans the local Claude and Codex transcripts and keeps a per-file cache so only what changed is
/// ever read twice (`~/.tally/token-stats.json`).
///
/// The corpus is large - several gigabytes across thousands of files on a machine that has been
/// running agents for months - so the shape of this is dictated by one rule: a file whose identity
/// (size + modification time) is unchanged is never opened again. The first scan pays for the
/// whole history once; every later one reads only the sessions written since.
///
/// Queue-confined like `UsageHistory`: all state and file I/O live on one serial utility queue, so
/// the main actor never waits on a scan and two scans can never interleave.
final class TokenStatsEngine: @unchecked Sendable {
    static let shared = TokenStatsEngine()

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tally/token-stats.json")

    /// One scanned file: its identity, and what it contributed.
    struct Entry: Codable, Sendable {
        var provider: String
        var size: Int64
        var modified: Double
        var buckets: [TokenBucket]
    }

    struct Cache: Codable, Sendable {
        /// Bumped whenever the parsing rules change in a way that makes existing entries wrong
        /// (a new token column, a different attribution rule). A mismatch discards the cache and
        /// rescans, which is slow exactly once.
        var version: Int
        /// The time zone the day numbers were computed in. Entries are stamped with the LOCAL day
        /// a record falls on, so a machine that has moved zones (a flight, a DST-less zone change)
        /// would otherwise keep old entries cut on the old midnight and new ones on the new one,
        /// and no total would be wrong in a way anyone could see. Rescanning the whole corpus is
        /// the cheap answer to a rare event.
        var zone: String
        var files: [String: Entry]

        /// 2: projects are attributed by allow-list (`TokenProjectMap`) rather than by raw cwd, so
        /// every key written by version 1 names a directory that is no longer a row.
        /// 3: a turn's usage is counted at its highest restated value rather than its first.
        static let currentVersion = 3

        /// A cache stamped for the rules and the zone in force right now.
        static func current(files: [String: Entry] = [:]) -> Cache {
            Cache(version: currentVersion, zone: TimeZone.current.identifier, files: files)
        }

        var isCurrent: Bool { version == Self.currentVersion && zone == TimeZone.current.identifier }
    }

    private let queue = DispatchQueue(label: "tally.token-stats", qos: .utility)
    private var cache: Cache?

    /// Bring the cache up to date and hand back the merged totals. Called on every visit to the
    /// Tokens tab; the queue serializes overlapping calls, and a caller that arrives while a scan
    /// is running simply gets its result after that one finishes.
    func scan(completion: @escaping @Sendable ([TokenSample]) -> Void) {
        queue.async { [self] in
            var loaded = cache ?? Self.read()
            if !loaded.isCurrent { loaded = .current() }

            // The allow-list of projects is read from disk once per scan, not once per file.
            let projects = TokenProjectMap.current()
            var next: [String: Entry] = [:]
            var changed = false
            for file in TokenStatsSources.all() {
                if let known = loaded.files[file.path], known.size == file.size,
                   abs(known.modified - file.modified) < 0.001 {
                    next[file.path] = known
                    continue
                }
                changed = true
                let buckets = TokenStatsParser.buckets(of: URL(fileURLWithPath: file.path),
                                                       provider: file.provider, projects: projects)
                next[file.path] = Entry(provider: file.provider, size: file.size,
                                        modified: file.modified, buckets: buckets)
            }

            // Assigning rather than merging drops files that were deleted since the last scan, so
            // a removed transcript stops counting instead of being pinned in the cache forever.
            let updated = Cache.current(files: next)
            cache = updated
            if changed || loaded.files.count != next.count { Self.write(updated) }
            completion(Self.merge(next))
        }
    }

    /// Collapse every file's buckets into one cell per (day, project, provider).
    private static func merge(_ files: [String: Entry]) -> [TokenSample] {
        struct Key: Hashable {
            let day: Int
            let project: String
            let provider: String
        }
        var cells: [Key: TokenTotals] = [:]
        for entry in files.values {
            for bucket in entry.buckets {
                cells[Key(day: bucket.day, project: bucket.project, provider: entry.provider),
                      default: TokenTotals()] += bucket.totals
            }
        }
        return cells.map {
            TokenSample(day: $0.key.day, project: $0.key.project, providerID: $0.key.provider,
                        totals: $0.value)
        }
    }

    private static func read() -> Cache {
        guard let data = try? Data(contentsOf: fileURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else {
            return .current()
        }
        return cache
    }

    private static func write(_ cache: Cache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
