import Foundation

/// The fleet's measured spending pace, in pool units per hour (one account's full window = 100
/// units - the same currency as `FleetPool.totalRemaining`).
struct FleetRate: Hashable, Sendable {
    var perHour: Double
    /// How much history backs the estimate - surfaced so a young estimate can say so.
    var sampledHours: Double
    /// The weekly window as measured on the accounts that feed THIS pool
    /// (`FleetForecast.cycleHours`): what the steady refill speed divides a full window by. 168
    /// until those accounts have shown two rollovers.
    var cycleHours: Double = FleetForecast.nominalCycleHours
}

/// Burn-rate estimation and pool depletion forecasting over the usage history: "at my recent
/// pace, how long does the whole fleet last, counting the quota that comes back at each reset?"
/// Pure math over `UsageHistory.Sample` rows, so the test harness compiles it standalone.
enum FleetForecast {
    /// Below this much history the pace is noise, not a trend - show "measuring" instead.
    static let minimumSampleHours: Double = 6
    /// Pace lookback: long enough to smooth day/night rhythm, short enough to track this week's
    /// actual behaviour.
    static let lookbackHours: Double = 72
    /// Forecasts beyond this read as false precision; a pool that survives it is "sustainable".
    static let horizon: TimeInterval = 14 * 86_400
    /// A weekly window's nominal cycle, which is what the steady refill speed assumed for every
    /// account until the cycle was measured (`cycleHours`).
    static let nominalCycleHours: Double = 168
    /// The shortest cycle a measurement may report: a window refilling faster than daily is a
    /// glitch in the history, and the refill speed it would imply is not a budget anyone has.
    static let minimumCycleHours: Double = 24
    /// How much history the cycle is measured over (the advisor's lookback).
    static let cycleLookbackDays: Double = 28

    /// One pooled window's identity in the rates dictionary: provider + window kind + model (for
    /// model-scoped windows). The gauge looks its headline pool up with the same key, whichever
    /// window the focus resolves to. `plan` is `FleetSummary.Tier.key` for a provider whose gauge
    /// splits by plan; nil keeps the provider-wide key.
    static func rateKey(provider: String, window: String, model: String?,
                        plan: String? = nil) -> String {
        "\(provider)|\(window)" + (model.map { "|\($0.lowercased())" } ?? "")
            + (plan.map { "|plan=\($0)" } ?? "")
    }

    /// Burn rate per pooled weekly-cycle window (see `rateKey`) - the account-wide weekly AND each
    /// model-scoped weekly, so the forecast follows whichever pool the gauge headlines. `samples`
    /// is the whole cycle lookback: the pace reads only the last `lookbackHours` of it, the cycle
    /// length all of it.
    /// Consumption = the sum of positive `used` deltas between consecutive samples of the same
    /// account whose window did not roll over in between (`resetAt` unchanged); a rollover resets
    /// `used` downward and contributes nothing. `planOf` maps a sample's account id to its plan
    /// key when the gauge splits that provider by plan (`FleetMath.planTiers`).
    static func weeklyRates(samples: [UsageHistory.Sample], now: Date,
                            planOf: (String) -> String? = { _ in nil }) -> [String: FleetRate] {
        let paceFloor = now.addingTimeInterval(-lookbackHours * 3_600)
        let weekly = samples.filter {
            $0.ts >= paceFloor
                && ($0.window == MetricKind.weeklyAll.rawValue || $0.window == MetricKind.weeklyModel.rawValue)
        }
        let gaps = cycleGaps(samples: samples, now: now)
        var accountsOf: [String: Set<String>] = [:]
        var consumed: [String: Double] = [:]
        var earliest: [String: Date] = [:]
        let bySeries = Dictionary(grouping: weekly) {
            "\($0.account)|" + rateKey(provider: $0.provider, window: $0.window, model: $0.model)
        }
        for (_, rows) in bySeries {
            let sorted = rows.sorted { $0.ts < $1.ts }
            guard let first = sorted.first else { continue }
            var used = 0.0
            for (previous, current) in zip(sorted, sorted.dropFirst())
            where previous.resetAt == current.resetAt {
                used += max(0, current.used - previous.used)
            }
            // The provider-wide key accumulates exactly as before; a split provider's account ALSO
            // feeds its plan's own key, so a plan's pool is forecast from that plan's spending only.
            var keys = [rateKey(provider: first.provider, window: first.window, model: first.model)]
            if let plan = planOf(first.account) {
                keys.append(rateKey(provider: first.provider, window: first.window,
                                    model: first.model, plan: plan))
            }
            for key in keys {
                earliest[key] = min(earliest[key] ?? first.ts, first.ts)
                consumed[key, default: 0] += used
                accountsOf[key, default: []].insert(first.account)
            }
        }
        var rates: [String: FleetRate] = [:]
        for (key, start) in earliest {
            let hours = min(lookbackHours, now.timeIntervalSince(start) / 3_600)
            guard hours >= minimumSampleHours else { continue }
            rates[key] = FleetRate(perHour: (consumed[key] ?? 0) / hours, sampledHours: hours,
                                   cycleHours: cycleHours(of: accountsOf[key] ?? [], gaps: gaps))
        }
        return rates
    }

    /// The gaps between each account's consecutive weekly rollovers over the last
    /// `cycleLookbackDays`, by account (accounts without two rollovers are absent). A rollover is
    /// a restart `UsageAdvisor.confirmedRestarts` confirms, by drop or by the reset time jumping
    /// forward by more than a day (Codex's idle reset time creeps forward a few minutes per poll,
    /// which is neither).
    static func cycleGaps(samples: [UsageHistory.Sample], now: Date) -> [String: [TimeInterval]] {
        let since = now.addingTimeInterval(-cycleLookbackDays * 86_400)
        let weekly = samples.filter { $0.window == MetricKind.weeklyAll.rawValue && $0.ts >= since }
        var out: [String: [TimeInterval]] = [:]
        for (account, rows) in Dictionary(grouping: weekly, by: \.account) {
            let times = UsageAdvisor.confirmedRestarts(rows.map {
                UsageAdvisor.Sample(ts: $0.ts, account: $0.account, provider: $0.provider,
                                    window: $0.window, model: $0.model, used: $0.used, resetAt: $0.resetAt)
            }).map(\.at)
            let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
            if !gaps.isEmpty { out[account] = gaps }
        }
        return out
    }

    /// The weekly window's cycle in hours for the pool these `accounts` feed: the mean of THEIR
    /// rollover gaps, clamped to [`minimumCycleHours`, `nominalCycleHours`]. Each rate key brings
    /// its own account set (the provider's for the unsplit pool, one plan's for a plan's pool, the
    /// accounts reporting a model window for that window), so one plan resetting every two days
    /// never speeds up another plan's refill. No gap among them means no measurement and the
    /// calendar's `nominalCycleHours` stands. The steady refill speed is `members x 100 / cycle`;
    /// a pool that resets every 2.2 days refills 3x faster than the 168 hours assumed before
    /// (B-429).
    static func cycleHours(of accounts: Set<String>, gaps: [String: [TimeInterval]]) -> Double {
        let pooled = accounts.flatMap { gaps[$0] ?? [] }
        guard !pooled.isEmpty else { return nominalCycleHours }
        return min(nominalCycleHours,
                   max(minimumCycleHours, pooled.reduce(0, +) / Double(pooled.count) / 3_600))
    }

    /// When the pool runs dry at `perHour`, or nil when it survives the horizon.
    ///
    /// Event simulation: drain the pool at the measured pace; at each scheduled refill add its
    /// gain back. Past the listed refills (one cycle), every member's window is cycling, so the
    /// drain continues at the NET pace (spend minus `steadyRefillPerHour`, the long-run refill
    /// speed) - a fleet spending faster than its combined budget still dries out eventually, and
    /// one spending slower never does.
    static func depletion(remaining: Double, refills: [(at: Date, gain: Double)],
                          perHour: Double, steadyRefillPerHour: Double, now: Date) -> Date? {
        guard perHour > 0 else { return nil }
        let end = now.addingTimeInterval(horizon)
        var level = remaining
        var t = now
        for refill in refills.sorted(by: { $0.at < $1.at }) where refill.at <= end {
            let dry = t.addingTimeInterval(level / perHour * 3_600)
            if dry <= refill.at { return dry }
            level -= perHour * refill.at.timeIntervalSince(t) / 3_600
            level += refill.gain
            t = refill.at
        }
        let net = perHour - steadyRefillPerHour
        guard net > 0 else { return nil }
        let dry = t.addingTimeInterval(level / net * 3_600)
        return dry <= end ? dry : nil
    }
}
