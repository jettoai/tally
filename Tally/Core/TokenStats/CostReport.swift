import Foundation

// THE CONTRACT OF `~/.tally/project-cost.json` AND OF `tally cost --json` (schema 1), compiled into
// both targets: the app writes the snapshot after every token scan (CostSnapshotWriter.swift) and
// the CLI only reads it (TallyCLI/CostCommand.swift), so one aggregation decides every figure either
// prints. The CLI never scans transcripts: it has no Rust core, and a second scanner would race the
// app for the token cache.
//
// Rules a reader may rely on: `costUSD` null means not priced (never 0); `projects` is ranked by
// cost and not truncated; a project key is its absolute path in NFC and Other's key is "". The
// snapshot keeps the last `cellDays` days cell by cell, so any `--days N` up to that is summed on
// the spot, and the four preset ranges (the whole history among them) precomputed.

enum CostReportFile {
    static let schema = 1
    /// Older than this, a report says `stale: true`: the app is closed or has not scanned.
    static let staleAfter: TimeInterval = 15 * 60
    static let cellDays = 90
    /// The preset ranges, by the name `--range` takes, and their length in days (nil: everything).
    static let presets: [(name: String, days: Int?)] = [("today", 1), ("7d", 7), ("30d", 30), ("all", nil)]

    /// An unshipped build (dev variant, build tree) writes its own file, so it never overwrites the
    /// installed app's; the CLI reads the shipped one.
    static func url(unshipped: Bool) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(unshipped ? ".tally/project-cost-dev.json" : ".tally/project-cost.json")
    }
}

/// An optional that encodes as JSON `null` rather than vanishing: the contract says "null means not
/// priced", and a missing key would read as an older schema.
@propertyWrapper
struct NullCoded<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var wrappedValue: T?
    init(wrappedValue: T?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? nil : try c.decode(T.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let v = wrappedValue { try c.encode(v) } else { try c.encodeNil() }
    }
}

struct CostTokens: Codable, Equatable, Sendable {
    var input: Int64 = 0
    var cacheWrite5m: Int64 = 0
    var cacheWrite1h: Int64 = 0
    var cacheRead: Int64 = 0
    var output: Int64 = 0

    var total: Int64 { input + cacheWrite5m + cacheWrite1h + cacheRead + output }

    static func += (lhs: inout CostTokens, rhs: CostTokens) {
        lhs.input += rhs.input
        lhs.cacheWrite5m += rhs.cacheWrite5m
        lhs.cacheWrite1h += rhs.cacheWrite1h
        lhs.cacheRead += rhs.cacheRead
        lhs.output += rhs.output
    }
}

/// One local day, project, provider, model and side, priced (rust tokenstats::cost::cost_cells).
struct CostCell: Codable, Equatable, Sendable {
    var date: String
    var project: String
    var provider: String
    /// The price table key when priced (`claude-opus-5-5`), else the id the transcript wrote.
    var model: String
    var subagent: Bool
    @NullCoded var costUSD: Double?
    var tokens: CostTokens
}

struct CostReport: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        @NullCoded var days: Int?
        @NullCoded var from: String?
        var to: String
        var timeZone: String
    }

    struct Pricing: Codable, Equatable, Sendable {
        var source = "tally-builtin"
        /// The date of the price table in rust/crates/core/src/tokenstats/pricing.rs.
        var version = "2026-09-23"
        var currency = "USD"
        var unpricedProviders: [String]
    }

    struct Totals: Codable, Equatable, Sendable {
        var costUSD: Double
        var tokens: CostTokens
    }

    struct ModelRow: Codable, Equatable, Sendable {
        var model: String
        @NullCoded var costUSD: Double?
        var tokens: CostTokens
    }

    struct Sides: Codable, Equatable, Sendable {
        var main: Double
        var subagent: Double
    }

    struct Day: Codable, Equatable, Sendable {
        var date: String
        var costUSD: Double
    }

    struct Project: Codable, Equatable, Sendable {
        var key: String
        var name: String
        var isOther: Bool
        /// The priced part; null when nothing in this project is priced.
        @NullCoded var costUSD: Double?
        @NullCoded var share: Double?
        /// Every provider's tokens, priced or not.
        var tokens: CostTokens
        var byModel: [ModelRow]
        var bySide: Sides
        var daily: [Day]
    }

    struct Provider: Codable, Equatable, Sendable {
        var id: String
        @NullCoded var costUSD: Double?
        var tokens: CostTokens
    }

    var schema = CostReportFile.schema
    var generatedAt: String
    var stale: Bool
    var range: Window
    var pricing: Pricing
    var totals: Totals
    var projects: [Project]
    var providers: [Provider]
}

struct CostSnapshot: Codable, Equatable, Sendable {
    var schema = CostReportFile.schema
    var generatedAt: String
    var timeZone: String
    /// The local day the ranges end on.
    var today: String
    /// Each project key's row label (the Tokens tab's rule).
    var names: [String: String]
    /// The preset ranges by `--range` name, each with `stale: false` as written.
    var ranges: [String: CostReport]
    /// The last `CostReportFile.cellDays` days, cell by cell.
    var cells: [CostCell]
}

/// Local day numbers (days since 1970-01-01, the Rust core's) as `yyyy-MM-dd`, and back.
enum CostDate {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func string(day: Int) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(day) * 86_400))
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    static func day(_ string: String) -> Int? {
        let p = string.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let date = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        else { return nil }
        return Int((date.timeIntervalSince1970 / 86_400).rounded())
    }

    /// `2026-10-06T12:50:00+08:00`, whole seconds, in `zone`.
    static func timestamp(_ date: Date, zone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func parse(_ timestamp: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: timestamp) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: timestamp)
    }
}

enum CostReportBuilder {
    /// The report for the `days` ending on `today` (nil: every cell given), from priced cells.
    static func report(cells: [CostCell], days: Int?, today: String, names: [String: String],
                       generatedAt: String, timeZone: String) -> CostReport {
        let from = days.flatMap { n in CostDate.day(today).map { CostDate.string(day: $0 - (n - 1)) } }
        let inRange = cells.filter { cell in cell.date <= today && (from.map { cell.date >= $0 } ?? true) }

        var providers: [String: (cost: Double?, tokens: CostTokens)] = [:]
        var projects: [String: ProjectAcc] = [:]
        var total = 0.0
        var tokens = CostTokens()
        for cell in inRange {
            providers[cell.provider, default: (nil, CostTokens())].tokens += cell.tokens
            projects[cell.project, default: ProjectAcc()].add(cell)
            if let c = cell.costUSD {
                providers[cell.provider]!.cost = (providers[cell.provider]!.cost ?? 0) + c
                total += c
                tokens += cell.tokens
            }
        }

        let ranked = projects.sorted { a, b in
            let (ca, cb) = (a.value.cost ?? -1, b.value.cost ?? -1)
            if ca != cb { return ca > cb }
            if a.value.tokens.total != b.value.tokens.total { return a.value.tokens.total > b.value.tokens.total }
            return a.key < b.key
        }
        let order = ["claude", "codex"]
        let providerRows = providers.keys.sorted {
            (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1)
        }.map { CostReport.Provider(id: $0, costUSD: providers[$0]!.cost, tokens: providers[$0]!.tokens) }

        return CostReport(
            generatedAt: generatedAt, stale: false,
            range: .init(days: days, from: from ?? inRange.map(\.date).min(), to: today, timeZone: timeZone),
            pricing: .init(unpricedProviders: providerRows.filter { $0.costUSD == nil }.map(\.id)),
            totals: .init(costUSD: total, tokens: tokens),
            projects: ranked.map { key, acc in
                acc.row(key: key, name: key.isEmpty ? "Other" : names[key] ?? (key as NSString).lastPathComponent,
                        total: total)
            },
            providers: providerRows)
    }

    private struct ProjectAcc {
        var cost: Double?
        var tokens = CostTokens()
        var models: [String: (cost: Double?, tokens: CostTokens)] = [:]
        var main = 0.0, subagent = 0.0
        var daily: [String: Double] = [:]

        mutating func add(_ cell: CostCell) {
            tokens += cell.tokens
            models[cell.model, default: (nil, CostTokens())].tokens += cell.tokens
            guard let c = cell.costUSD else { return }
            cost = (cost ?? 0) + c
            models[cell.model]!.cost = (models[cell.model]!.cost ?? 0) + c
            if cell.subagent { subagent += c } else { main += c }
            daily[cell.date, default: 0] += c
        }

        func row(key: String, name: String, total: Double) -> CostReport.Project {
            let byModel = models.sorted { a, b in
                let (ca, cb) = (a.value.cost ?? -1, b.value.cost ?? -1)
                return ca != cb ? ca > cb : a.key < b.key
            }.map { CostReport.ModelRow(model: $0.key, costUSD: $0.value.cost, tokens: $0.value.tokens) }
            return CostReport.Project(
                key: key, name: name, isOther: key.isEmpty, costUSD: cost,
                share: cost.flatMap { total > 0 ? $0 / total : nil }, tokens: tokens, byModel: byModel,
                bySide: .init(main: main, subagent: subagent),
                daily: daily.keys.sorted().map { CostReport.Day(date: $0, costUSD: daily[$0]!) })
        }
    }
}
