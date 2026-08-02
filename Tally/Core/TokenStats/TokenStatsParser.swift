import Foundation

/// Reads one transcript file into per (day, project) token buckets.
///
/// Both readers memory-map the file and walk it line by line, and both start each line with a
/// substring test that rejects the ~95% of lines carrying no token counts before any structural
/// parsing happens. Malformed lines are skipped in silence: a transcript is an append-only log
/// that can be truncated mid-write by a crash, and one bad tail line must not lose the file.
///
/// Nothing here ever reads a transcript's prose. Only the numeric fields, the working directory
/// and the timestamp are converted; every other value is stepped over as raw bytes.
enum TokenStatsParser {
    static func buckets(of url: URL, provider: String, projects: TokenProjectMap) -> [TokenBucket] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return data.withUnsafeBytes { raw -> [TokenBucket] in
            guard raw.count > 0 else { return [] }
            var accumulator = BucketAccumulator()
            switch provider {
            case ClaudeAccounts.providerID: readClaude(raw, projects, into: &accumulator)
            case CodexAccounts.providerID: readCodex(raw, projects, into: &accumulator)
            default: break
            }
            return accumulator.buckets()
        }
    }

    // MARK: Claude Code transcripts

    /// `~/.claude*/projects/<munged-cwd>/**/*.jsonl`: one JSON object per line, token counts on
    /// `message.usage` of assistant lines, with `cwd` and `timestamp` at the top level.
    ///
    /// One assistant turn is written as several lines (one per content block: text, thinking, each
    /// tool call), all sharing one `message.id`, and each line repeats the turn's usage AS OF that
    /// line rather than its final figure. So the lines can neither be summed (that multiplies the
    /// real usage by about two) nor deduplicated down to the first one (on this machine's corpus
    /// that dropped 44.4M of 134M output tokens: 33,523 turns restated their count, and the first
    /// line of a streamed turn typically shows single-digit output). A turn is therefore counted
    /// as the highest value each column reached, credited one increment at a time.
    ///
    /// Deliberately per file, not global: resuming or forking a conversation copies earlier turns
    /// into the new transcript, so a few ids do appear in two files. Catching those would mean
    /// carrying every message id across the whole corpus in the cache, which costs orders of
    /// magnitude more than the error it removes - measured at 406 of 129,164 ids, 0.3% of all
    /// tokens on a machine with a year of history.
    private static func readClaude(_ raw: UnsafeRawBufferPointer, _ map: TokenProjectMap,
                                   into out: inout BucketAccumulator) {
        let scan = JSONScan(bytes: raw)
        var stamper = LocalDayStamper()
        var counted: [UInt64: TokenTotals] = [:]
        var projects = ProjectKeyMemo(map)

        forEachLine(raw) { line in
            guard contains(raw, line, "\"usage\"") else { return }

            var cwd: Range<Int>?
            var timestamp: Range<Int>?
            var message: Range<Int>?
            scan.forEachMember(in: line) { key, value in
                if scan.key(key, is: "cwd") { cwd = value }
                else if scan.key(key, is: "timestamp") { timestamp = value }
                else if scan.key(key, is: "message") { message = value }
            }
            guard let message, let timestamp, let day = stamper.day(fromISO: scan, timestamp) else { return }

            var usage: Range<Int>?
            var messageID: Range<Int>?
            scan.forEachMember(in: message) { key, value in
                if scan.key(key, is: "usage") { usage = value }
                else if scan.key(key, is: "id") { messageID = value }
            }
            guard let usage else { return }

            var totals = TokenTotals()
            scan.forEachMember(in: usage) { key, value in
                if scan.key(key, is: "input_tokens") { totals.input = scan.int64(value) ?? 0 }
                else if scan.key(key, is: "cache_creation_input_tokens") { totals.cacheWrite = scan.int64(value) ?? 0 }
                else if scan.key(key, is: "cache_read_input_tokens") { totals.cacheRead = scan.int64(value) ?? 0 }
                else if scan.key(key, is: "output_tokens") { totals.output = scan.int64(value) ?? 0 }
            }
            guard !totals.isEmpty else { return }

            // No id (older transcripts) means no way to tell a restatement from a real turn;
            // counting it whole is the safer error, since holding it back would lose the turn.
            if let messageID {
                let added = counted[fingerprint(raw, messageID), default: TokenTotals()].raise(to: totals)
                guard !added.isEmpty else { return }
                totals = added
            }
            out.add(totals, day: day, project: projects.key(scan, cwd))
        }
    }

    // MARK: Codex rollouts

    /// `~/.codex*/sessions/YYYY/MM/DD/rollout-*.jsonl`: the working directory is on the
    /// `session_meta` line, and each `token_count` event carries `total_token_usage`, which is
    /// CUMULATIVE for the session rather than per turn. Consecutive differences are taken so the
    /// tokens land on the day they were actually spent (a session running past midnight splits
    /// correctly), and a total that moved backwards is read as a fresh counter rather than a
    /// negative spend.
    ///
    /// Codex counts cached tokens INSIDE `input_tokens` and reasoning INSIDE `output_tokens`,
    /// while Claude reports cache reads separately. The cached part is subtracted out here so the
    /// two providers' columns mean the same thing.
    private static func readCodex(_ raw: UnsafeRawBufferPointer, _ map: TokenProjectMap,
                                  into out: inout BucketAccumulator) {
        let scan = JSONScan(bytes: raw)
        var stamper = LocalDayStamper()
        var projects = ProjectKeyMemo(map)
        var project = TokenProject.otherKey
        var previous: CodexCounters?

        forEachLine(raw) { line in
            guard contains(raw, line, "token_count") || contains(raw, line, "\"cwd\"") else { return }

            var type: Range<Int>?
            var timestamp: Range<Int>?
            var payload: Range<Int>?
            scan.forEachMember(in: line) { key, value in
                if scan.key(key, is: "type") { type = value }
                else if scan.key(key, is: "timestamp") { timestamp = value }
                else if scan.key(key, is: "payload") { payload = value }
            }
            guard let payload else { return }

            if let type, matches(raw, type, "\"session_meta\"") {
                project = projects.key(scan, scan.member("cwd", in: payload))
                return
            }

            var payloadType: Range<Int>?
            var info: Range<Int>?
            scan.forEachMember(in: payload) { key, value in
                if scan.key(key, is: "type") { payloadType = value }
                else if scan.key(key, is: "info") { info = value }
            }
            guard let payloadType, matches(raw, payloadType, "\"token_count\""),
                  let info, let usage = scan.member("total_token_usage", in: info),
                  let timestamp, let day = stamper.day(fromISO: scan, timestamp) else { return }

            var current = CodexCounters()
            scan.forEachMember(in: usage) { key, value in
                if scan.key(key, is: "input_tokens") { current.input = scan.int64(value) ?? 0 }
                else if scan.key(key, is: "cached_input_tokens") { current.cached = scan.int64(value) ?? 0 }
                else if scan.key(key, is: "cache_write_input_tokens") { current.cacheWrite = scan.int64(value) ?? 0 }
                else if scan.key(key, is: "output_tokens") { current.output = scan.int64(value) ?? 0 }
            }
            let delta = current.delta(since: previous)
            previous = current
            guard !delta.isEmpty else { return }
            out.add(delta, day: day, project: project)
        }
    }

    private struct CodexCounters {
        var input: Int64 = 0        // includes the cached part
        var cached: Int64 = 0
        var cacheWrite: Int64 = 0
        var output: Int64 = 0       // includes reasoning

        /// This event's spend, normalized onto Tally's four columns.
        func delta(since previous: CodexCounters?) -> TokenTotals {
            guard let previous, input >= previous.input, cached >= previous.cached,
                  cacheWrite >= previous.cacheWrite, output >= previous.output else {
                return TokenTotals(input: max(0, input - cached), cacheWrite: cacheWrite,
                                   cacheRead: cached, output: output)
            }
            let fresh = (input - previous.input) - (cached - previous.cached)
            return TokenTotals(input: max(0, fresh), cacheWrite: cacheWrite - previous.cacheWrite,
                               cacheRead: cached - previous.cached, output: output - previous.output)
        }
    }

    // MARK: Byte helpers

    /// Splits the buffer on newlines without copying.
    private static func forEachLine(_ raw: UnsafeRawBufferPointer, _ body: (Range<Int>) -> Void) {
        guard let base = raw.baseAddress else { return }
        var start = 0
        while start < raw.count {
            let remaining = raw.count - start
            let newline = memchr(base + start, 0x0A, remaining)
            let end = newline.map { UnsafeRawPointer($0) - base } ?? raw.count
            if end > start { body(start ..< end) }
            start = end + 1
        }
    }

    private static func contains(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ needle: StaticString) -> Bool {
        guard let base = raw.baseAddress, range.count >= needle.utf8CodeUnitCount else { return false }
        return memmem(base + range.lowerBound, range.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    /// Exact match of a value's raw bytes against a literal (quotes included), so a string value
    /// can be tested without allocating it.
    private static func matches(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ literal: StaticString) -> Bool {
        guard range.count == literal.utf8CodeUnitCount, let base = raw.baseAddress else { return false }
        return memcmp(base + range.lowerBound, literal.utf8Start, range.count) == 0
    }

    /// 64-bit FNV-1a over a value's bytes - the dedupe key for `message.id`. Hashing the bytes in
    /// place avoids building a String for every one of the millions of usage records; at a few
    /// thousand ids per file a collision is far less likely than a disk error.
    private static func fingerprint(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in range {
            hash ^= UInt64(raw[i])
            hash &*= 0x1000_0000_01b3
        }
        return hash
    }
}

/// Remembers the last working directory seen so a file whose lines all share one `cwd` (the normal
/// case) converts it to a project key once instead of once per line.
private struct ProjectKeyMemo {
    private let map: TokenProjectMap
    private var lastBytes: [UInt8] = []
    private var lastKey = TokenProject.otherKey

    init(_ map: TokenProjectMap) { self.map = map }

    mutating func key(_ scan: JSONScan, _ range: Range<Int>?) -> String {
        guard let range else { return TokenProject.otherKey }
        if lastBytes.count == range.count,
           lastBytes.withUnsafeBytes({ memcmp($0.baseAddress!, scan.bytes.baseAddress! + range.lowerBound, range.count) == 0 }) {
            return lastKey
        }
        lastBytes = Array(scan.bytes[range])
        lastKey = map.key(forCWD: scan.string(range))
        return lastKey
    }
}

/// Sums one file's records into (day, project) cells.
private struct BucketAccumulator {
    private struct Key: Hashable {
        let day: Int
        let project: String
    }

    private var cells: [Key: TokenTotals] = [:]

    mutating func add(_ totals: TokenTotals, day: Int, project: String) {
        cells[Key(day: day, project: project), default: TokenTotals()] += totals
    }

    /// Sorted so a re-scan of an unchanged file produces a byte-identical cache entry.
    func buckets() -> [TokenBucket] {
        cells.map { TokenBucket(day: $0.key.day, project: $0.key.project, totals: $0.value) }
            .sorted { ($0.day, $0.project) < ($1.day, $1.project) }
    }
}
