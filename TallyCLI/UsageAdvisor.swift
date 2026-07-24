import Foundation

/// Usage advisor: turns the raw burn-rate history (`~/.tally/history.jsonl`) into a plain
/// "do I need another account?" verdict. Pure math over decoded samples, no I/O and no
/// `MetricKind` dependency, so ONE copy of this file compiles into both the app (Tally target,
/// wired in via project.yml) and the `tally` CLI (this folder), and the test harness builds it
/// standalone. Presentation is layered on top: the panel localizes its own headline from the
/// verdict, the CLI/JSON layer formats English. This layer only produces numbers and a verdict.
enum UsageAdvisor {
    // Window identifiers matched as raw strings so this file needs no MetricKind (which lives in
    // the app-only Providers layer). Kept in step with MetricKind.rawValue.
    static let weeklyAllWindow = "weeklyAll"
    static let weeklyModelWindow = "weeklyModel"

    /// How far back the reading looks - four weeks, matching the history's retention, so the
    /// weekly-demand trend has room to average out day-to-day swings.
    static let lookbackDays: Double = 28
    /// Below this much history the pace is noise, not a trend: show "collecting data", never a
    /// recommendation.
    static let minimumDays: Double = 7
    /// A window at or above this percent used has no usable quota left - it is starved.
    static let starvedThreshold: Double = 99
    /// Two samples farther apart than this aren't one continuous stretch of work; cap the gap so an
    /// overnight idle span counts as neither active nor starved time.
    static let maxGap: TimeInterval = 30 * 60
    /// Recommend another account once weekly demand reaches this fraction of pooled capacity...
    static let demandTriggerRatio: Double = 0.9
    /// ...or once the fleet sits starved more than this many hours in a week.
    static let starvedTriggerHours: Double = 2

    /// One history row, decoded straight from the JSONL file. Field-for-field the same as
    /// `UsageHistory.Sample`; kept separate so this pure file carries no app dependency.
    struct Sample: Codable, Sendable {
        var ts: Date
        var account: String
        var provider: String
        var window: String
        var model: String?
        var used: Double
        var resetAt: Date?
    }

    enum Verdict: String, Sendable, Equatable {
        case collecting   // not enough history yet
        case addAccount   // demand or starvation crossed the trigger
        case sufficient   // current accounts cover the demand
    }

    /// One provider's verdict plus the numbers behind it. Language-free on purpose: the panel
    /// builds a localized headline from `verdict`, the CLI/JSON layer an English one.
    struct Reading: Sendable, Equatable {
        var provider: String
        var verdict: Verdict
        /// Pooled weekly burn in account-weeks: 1.0 means one full account's weekly quota per week.
        var demandPerWeek: Double
        /// Percent of a window spent per hour of active work.
        var activeBurnPerHour: Double
        var starvedHoursPerWeek: Double
        var daysOfData: Double
        var accountCount: Int
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Tolerant line-by-line decode (fail-open: one malformed line costs only itself, never the
    /// whole file), keeping samples at or after `since`.
    static func decodeSamples(_ data: Data, since: Date) -> [Sample] {
        var out: [Sample] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let s = try? decoder.decode(Sample.self, from: Data(line)), s.ts >= since
            else { continue }
            out.append(s)
        }
        return out
    }

    /// One reading per provider present in the samples, providers in stable alphabetical order.
    static func readings(samples: [Sample], now: Date = Date()) -> [Reading] {
        Dictionary(grouping: samples, by: \.provider).keys.sorted().compactMap { provider in
            reading(provider: provider, samples: samples.filter { $0.provider == provider }, now: now)
        }
    }

    static func reading(provider: String, samples: [Sample], now: Date = Date()) -> Reading? {
        guard let earliest = samples.map(\.ts).min() else { return nil }
        let days = now.timeIntervalSince(earliest) / 86_400
        let weeks = max(days / 7, 1e-6)   // div-safety only; the collecting gate handles young data
        let accounts = Set(samples.map(\.account))

        let weeklyAll = samples.filter { $0.window == weeklyAllWindow }
        let weeklyModel = samples.filter { $0.window == weeklyModelWindow }

        let demandPerWeek = burnSum(weeklyAll) / weeks / 100

        // Binding constraint: the most saturated pool relative to its OWN account capacity - the
        // account-wide weekly, or any single model window. A fable window can be the wall while
        // the account-wide weekly still reads healthy.
        var bindingRatio = poolRatio(weeklyAll, weeks: weeks)
        for model in Set(weeklyModel.compactMap(\.model)) {
            bindingRatio = max(bindingRatio, poolRatio(weeklyModel.filter { $0.model == model },
                                                       weeks: weeks))
        }

        let (burn, activeHours) = activeBurn(weeklyAll)
        let activeBurnPerHour = activeHours > 0 ? burn / activeHours : 0

        // Starvation is pool-level and conservative: a pool only counts as starved while EVERY one
        // of its accounts is simultaneously at/above the threshold (any account with quota can
        // absorb a handoff). Provider value = the most-starved pool, mirroring bindingRatio.
        var starvedSeconds = poolStarvedSeconds(weeklyAll, now: now)
        for model in Set(weeklyModel.compactMap(\.model)) {
            starvedSeconds = max(starvedSeconds,
                                 poolStarvedSeconds(weeklyModel.filter { $0.model == model }, now: now))
        }
        let starvedHoursPerWeek = starvedSeconds / 3_600 / weeks

        let verdict: Verdict
        if days < minimumDays {
            verdict = .collecting
        } else if bindingRatio >= demandTriggerRatio || starvedHoursPerWeek > starvedTriggerHours {
            verdict = .addAccount
        } else {
            verdict = .sufficient
        }
        return Reading(provider: provider, verdict: verdict, demandPerWeek: demandPerWeek,
                       activeBurnPerHour: activeBurnPerHour, starvedHoursPerWeek: starvedHoursPerWeek,
                       daysOfData: days, accountCount: accounts.count)
    }

    /// A pool's weekly demand as a fraction of its own account capacity (accounts contributing the
    /// window). Zero when the pool has no accounts.
    private static func poolRatio(_ samples: [Sample], weeks: Double) -> Double {
        let capacity = Set(samples.map(\.account)).count
        guard capacity > 0 else { return 0 }
        return burnSum(samples) / weeks / 100 / Double(capacity)
    }

    /// Series = one (account, window, model). Consumption = sum of positive `used` deltas between
    /// consecutive samples whose window did not roll over between them (`resetAt` unchanged); a
    /// rollover drops `used` and contributes nothing.
    private static func burnSum(_ samples: [Sample]) -> Double {
        var total = 0.0
        for (_, rows) in Dictionary(grouping: samples, by: seriesKey) {
            let sorted = rows.sorted { $0.ts < $1.ts }
            for (prev, cur) in zip(sorted, sorted.dropFirst()) where prev.resetAt == cur.resetAt {
                total += max(0, cur.used - prev.used)
            }
        }
        return total
    }

    /// Burn and active time over the pairs that actually spent, gap-capped so idle stretches don't
    /// dilute the "while working" pace.
    private static func activeBurn(_ samples: [Sample]) -> (burn: Double, hours: Double) {
        var burn = 0.0, seconds = 0.0
        for (_, rows) in Dictionary(grouping: samples, by: seriesKey) {
            let sorted = rows.sorted { $0.ts < $1.ts }
            for (prev, cur) in zip(sorted, sorted.dropFirst()) where prev.resetAt == cur.resetAt {
                let delta = cur.used - prev.used
                guard delta > 0 else { continue }
                burn += delta
                seconds += min(maxGap, cur.ts.timeIntervalSince(prev.ts))
            }
        }
        return (burn, seconds / 3_600)
    }

    /// Seconds a whole pool sat starved: the time ALL of its accounts were simultaneously at or
    /// above the starved threshold. One account keeping quota means the pool can still absorb a
    /// handoff, so it is not starved. Zero for an empty pool or any account that never starved.
    private static func poolStarvedSeconds(_ samples: [Sample], now: Date) -> Double {
        let byAccount = Dictionary(grouping: samples, by: \.account)
        guard !byAccount.isEmpty else { return 0 }
        var intersection: [Interval]?
        for (_, rows) in byAccount {
            let starved = merge(starvedIntervals(rows, now: now))
            if starved.isEmpty { return 0 }
            intersection = intersection.map { intersect($0, starved) } ?? starved
            if intersection?.isEmpty == true { return 0 }
        }
        return (intersection ?? []).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// Half-open `[start, end)` span.
    private struct Interval { var start: Date; var end: Date }

    /// The spans one account's series sat starved. Per the recorder's change-only contract each
    /// sample's value persists until the next; the last sample extends to `now`.
    private static func starvedIntervals(_ samples: [Sample], now: Date) -> [Interval] {
        let sorted = samples.sorted { $0.ts < $1.ts }
        var out: [Interval] = []
        for (i, s) in sorted.enumerated() {
            let end = i + 1 < sorted.count ? sorted[i + 1].ts : now
            guard s.used >= starvedThreshold, end > s.ts else { continue }
            out.append(Interval(start: s.ts, end: end))
        }
        return out
    }

    /// Coalesce overlapping or touching spans so intersection can sweep them linearly.
    private static func merge(_ intervals: [Interval]) -> [Interval] {
        var out: [Interval] = []
        for iv in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, iv.start <= last.end {
                out[out.count - 1].end = max(last.end, iv.end)
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// The overlap of two coalesced span lists (time covered by both).
    private static func intersect(_ a: [Interval], _ b: [Interval]) -> [Interval] {
        var out: [Interval] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let start = max(a[i].start, b[j].start)
            let end = min(a[i].end, b[j].end)
            if start < end { out.append(Interval(start: start, end: end)) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return out
    }

    private static func seriesKey(_ s: Sample) -> String {
        "\(s.account)|\(s.window)|\(s.model ?? "")"
    }

    /// English one-liner for the CLI and the --json `headline` field. The panel builds its own
    /// localized version from `verdict`.
    static func englishHeadline(_ r: Reading) -> String {
        switch r.verdict {
        case .collecting:
            // Floor, never round: at 6.6 days the reading is still collecting, so "7 of 7 days"
            // would read as a contradiction.
            return "collecting data (\(Int(r.daysOfData)) of \(Int(minimumDays)) days)"
        case .addAccount:
            return "consider adding an account"
        case .sufficient:
            return "current accounts are sufficient"
        }
    }
}
