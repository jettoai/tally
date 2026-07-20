import Foundation

/// The fleet's measured spending pace, in pool units per hour (one account's full window = 100
/// units - the same currency as `FleetPool.totalRemaining`).
struct FleetRate: Hashable, Sendable {
    var perHour: Double
    /// How much history backs the estimate - surfaced so a young estimate can say so.
    var sampledHours: Double
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

    /// One pooled window's identity in the rates dictionary: provider + window kind + model (for
    /// model-scoped windows). The gauge looks its headline pool up with the same key, whichever
    /// window the focus resolves to.
    static func rateKey(provider: String, window: String, model: String?) -> String {
        "\(provider)|\(window)" + (model.map { "|\($0.lowercased())" } ?? "")
    }

    /// Burn rate per pooled weekly-cycle window (see `rateKey`) - the account-wide weekly AND each
    /// model-scoped weekly, so the forecast follows whichever pool the gauge headlines.
    /// Consumption = the sum of positive `used` deltas between consecutive samples of the same
    /// account whose window did not roll over in between (`resetAt` unchanged); a rollover resets
    /// `used` downward and contributes nothing.
    static func weeklyRates(samples: [UsageHistory.Sample], now: Date) -> [String: FleetRate] {
        let weekly = samples.filter {
            $0.window == MetricKind.weeklyAll.rawValue || $0.window == MetricKind.weeklyModel.rawValue
        }
        var consumed: [String: Double] = [:]
        var earliest: [String: Date] = [:]
        let bySeries = Dictionary(grouping: weekly) {
            "\($0.account)|" + rateKey(provider: $0.provider, window: $0.window, model: $0.model)
        }
        for (_, rows) in bySeries {
            let sorted = rows.sorted { $0.ts < $1.ts }
            guard let first = sorted.first else { continue }
            let key = rateKey(provider: first.provider, window: first.window, model: first.model)
            earliest[key] = min(earliest[key] ?? first.ts, first.ts)
            for (previous, current) in zip(sorted, sorted.dropFirst())
            where previous.resetAt == current.resetAt {
                consumed[key, default: 0] += max(0, current.used - previous.used)
            }
        }
        var rates: [String: FleetRate] = [:]
        for (key, start) in earliest {
            let hours = min(lookbackHours, now.timeIntervalSince(start) / 3_600)
            guard hours >= minimumSampleHours else { continue }
            rates[key] = FleetRate(perHour: (consumed[key] ?? 0) / hours, sampledHours: hours)
        }
        return rates
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
