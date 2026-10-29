import Foundation

// B-429: the weekly window's measured cycle length (FleetForecast.cycleGaps / cycleHours) and the
// rate each pool carries from it.
private func at(_ account: String, _ hoursAgo: Double, used: Double, resetInDays: Double = 3,
                provider: String = "codex", window: String = "weeklyAll",
                model: String? = nil) -> UsageHistory.Sample {
    UsageHistory.Sample(ts: now.addingTimeInterval(-hoursAgo * 3_600), account: account,
                        provider: provider, window: window, model: model, used: used,
                        resetAt: now.addingTimeInterval(resetInDays * 86_400))
}

/// Two rollovers `gap` hours apart for one account, the later one `lastAgo` hours ago. Each is a
/// high reading, the restart, and a low reading after it (the next reading is what confirms it).
private func rollovers(_ account: String, gap: Double, lastAgo: Double = 20,
                       provider: String = "codex") -> [UsageHistory.Sample] {
    [at(account, lastAgo + gap + 5, used: 80, provider: provider),
     at(account, lastAgo + gap, used: 4, provider: provider),
     at(account, lastAgo + gap - 1, used: 6, provider: provider),
     at(account, lastAgo + gap / 2, used: 60, provider: provider),
     at(account, lastAgo, used: 3, provider: provider),
     at(account, lastAgo - 1, used: 5, provider: provider)]
}

func runCycleTests() {
    /// The cycle for `accounts` (default: every account in the samples).
    func cycle(_ samples: [UsageHistory.Sample], accounts: Set<String>? = nil) -> Double {
        FleetForecast.cycleHours(of: accounts ?? Set(samples.map(\.account)),
                                 gaps: FleetForecast.cycleGaps(samples: samples, now: now))
    }
    func close(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 0.001 } ?? false }
    let nominal = FleetForecast.nominalCycleHours

    expect(cycle([]) == nominal, "cycle: no history is not measured (168 stands)")
    expect(cycle([at("a", 40, used: 50), at("a", 39, used: 3), at("a", 38, used: 4)]) == nominal,
           "cycle: one rollover has no gap to measure, so it stays on 168")
    expect(close(cycle(rollovers("a", gap: 52.8)), 52.8), "cycle: the 2.2 day Codex cadence reads 52.8 hours")
    expect(close(cycle(rollovers("a", gap: 10)), 24), "cycle: clamped at 24 hours below")
    expect(close(cycle(rollovers("a", gap: 400)), 168), "cycle: clamped at 168 hours above")
    expect(close(cycle(rollovers("a", gap: 48) + rollovers("b", gap: 96)), 72),
           "cycle: the mean of every account's gaps")
    expect(cycle(rollovers("a", gap: 52.8), accounts: ["elsewhere"]) == nominal,
           "cycle: accounts that were not measured keep 168")
    expect(cycle(rollovers("a", gap: 52.8).map { var s = $0; s.window = "weeklyModel"; return s }) == nominal,
           "cycle: only the account-wide weekly counts")
    expect(cycle(rollovers("a", gap: 52.8, lastAgo: 24 * 29)) == nominal,
           "cycle: rollovers older than 28 days are not read")

    // codex review of a185363, Critical 1: a reading that bounces straight back is no rollover.
    let blips = (0..<7).map { i in at("a", Double(7 - i) * 24, used: i % 2 == 0 ? 60 : 0, resetInDays: 5) }
    expect(cycle(blips) == nominal, "cycle: 60,0,60,0,60,0,60 a day apart reads 168, not 24")
    expect(cycle(Array(rollovers("a", gap: 52.8).dropLast(2))) == nominal,
           "cycle: a last restart no later reading confirms yet is not counted")

    // A low-use account rolls over without a visible drop; its reset time jumping days ahead is the
    // tell, once the next reading reports the same new time.
    let quiet = [at("a", 200, used: 2, resetInDays: -5), at("a", 150, used: 1, resetInDays: 2),
                 at("a", 149, used: 2, resetInDays: 2), at("a", 40, used: 0, resetInDays: 6),
                 at("a", 39, used: 0, resetInDays: 6)]
    expect(close(cycle(quiet), 110), "cycle: a reset time moving forward by more than a day is a rollover too")
    let flicker = [at("a", 200, used: 2, resetInDays: -5), at("a", 150, used: 1, resetInDays: 2),
                   at("a", 149, used: 2, resetInDays: -5), at("a", 40, used: 0, resetInDays: 6),
                   at("a", 39, used: 0, resetInDays: -5)]
    expect(cycle(flicker) == nominal, "cycle: a reset time that jumps and goes back is not a rollover")
    // Codex's idle reset time creeps forward minutes per poll; that is no rollover.
    let creeping = (0..<12).map { i in
        UsageHistory.Sample(ts: now.addingTimeInterval(-Double(48 - 4 * i) * 3_600), account: "a",
                            provider: "codex", window: "weeklyAll", model: nil, used: 30,
                            resetAt: now.addingTimeInterval(86_400 + Double(i) * 600))
    }
    expect(cycle(creeping) == nominal, "cycle: a creeping reset time is not a rollover")

    // The pace stays a 72 hour reading however much history the cycle is measured over.
    let year = rollovers("a", gap: 52.8) + [at("a", 1, used: 10), at("a", 0, used: 40)]
    let rate = FleetForecast.weeklyRates(samples: year, now: now)["codex|weeklyAll"]
    expect(close(rate?.cycleHours, 52.8) && close(rate?.perHour, 91 / 71.8),
           "cycle: weeklyRates carries the cycle and still paces over the last 72 hours only")
    expect(FleetForecast.weeklyRates(samples: [at("a", 40, used: 10), at("a", 0, used: 20)], now: now)["codex|weeklyAll"]?
               .cycleHours == nominal, "cycle: an unmeasured pool keeps 168 in its rate")

    // codex review of a185363, Critical 2: a pool takes the cycle of ITS accounts. Plan A resets
    // every 48 hours, plan B every 168, in one provider; B must not inherit the 108 hour mean.
    let model = rollovers("a1", gap: 48).map { sample -> UsageHistory.Sample in
        var m = sample; m.window = "weeklyModel"; m.model = "m"; return m
    }
    let fleet = rollovers("a1", gap: 48) + rollovers("b1", gap: 168) + model
    let rates = FleetForecast.weeklyRates(samples: fleet, now: now,
                                          planOf: { $0 == "a1" ? "a" : "b" })
    expect(close(rates["codex|weeklyAll|plan=a"]?.cycleHours, 48), "cycle: plan A pool reads its own 48 hours")
    expect(close(rates["codex|weeklyAll|plan=b"]?.cycleHours, 168), "cycle: plan B pool keeps 168, not the provider mean")
    expect(close(rates["codex|weeklyAll"]?.cycleHours, 108), "cycle: the unsplit pool is the mean of its accounts (108)")
    expect(close(rates["codex|weeklyModel|m"]?.cycleHours, 48), "cycle: a model pool takes its own accounts' cycle")
    expect(close(rates["codex|weeklyModel|m|plan=a"]?.cycleHours, 48), "cycle: …and so does its plan's")
}
