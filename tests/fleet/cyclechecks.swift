import Foundation

// B-429: the weekly window's measured cycle length (FleetForecast.measuredCycleHours).
private func at(_ account: String, _ hoursAgo: Double, used: Double, resetInDays: Double = 3,
                provider: String = "codex", window: String = "weeklyAll") -> UsageHistory.Sample {
    UsageHistory.Sample(ts: now.addingTimeInterval(-hoursAgo * 3_600), account: account,
                        provider: provider, window: window, model: nil, used: used,
                        resetAt: now.addingTimeInterval(resetInDays * 86_400))
}

/// Two rollovers `gap` hours apart for one account, the later one `lastAgo` hours ago.
private func rollovers(_ account: String, gap: Double, lastAgo: Double = 20,
                       provider: String = "codex") -> [UsageHistory.Sample] {
    [at(account, lastAgo + gap + 5, used: 80, provider: provider),
     at(account, lastAgo + gap, used: 4, provider: provider),
     at(account, lastAgo + gap / 2, used: 60, provider: provider),
     at(account, lastAgo, used: 3, provider: provider)]
}

func runCycleTests() {
    func cycle(_ samples: [UsageHistory.Sample], _ provider: String = "codex") -> Double? {
        FleetForecast.measuredCycleHours(samples: samples, now: now)[provider]
    }
    func close(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 0.001 } ?? false }

    expect(cycle([]) == nil, "cycle: no history is not measured (the caller keeps 168)")
    expect(cycle([at("a", 40, used: 50), at("a", 20, used: 3)]) == nil,
           "cycle: one rollover has no gap to measure, so it stays on 168")
    expect(close(cycle(rollovers("a", gap: 52.8)), 52.8), "cycle: the 2.2 day Codex cadence reads 52.8 hours")
    expect(close(cycle(rollovers("a", gap: 10)), 24), "cycle: clamped at 24 hours below")
    expect(close(cycle(rollovers("a", gap: 400)), 168), "cycle: clamped at 168 hours above")
    expect(close(cycle(rollovers("a", gap: 48) + rollovers("b", gap: 96)), 72),
           "cycle: the mean of every account's gaps")
    expect(cycle(rollovers("a", gap: 52.8), "claude") == nil, "cycle: another provider is not measured by it")
    expect(cycle(rollovers("a", gap: 52.8).map { var s = $0; s.window = "weeklyModel"; return s }) == nil,
           "cycle: only the account-wide weekly counts")
    expect(cycle(rollovers("a", gap: 52.8, lastAgo: 24 * 29)) == nil, "cycle: rollovers older than 28 days are not read")
    // The pace stays a 72 hour reading however much history the cycle is measured over.
    let year = rollovers("a", gap: 52.8) + [at("a", 1, used: 10), at("a", 0, used: 40)]
    let rate = FleetForecast.weeklyRates(samples: year, now: now)["codex|weeklyAll"]
    expect(close(rate?.cycleHours, 52.8) && close(rate?.perHour, 37 / 46.4),
           "cycle: weeklyRates carries the cycle and still paces over the last 72 hours only (the older samples would read 93 / 72)")
    expect(FleetForecast.weeklyRates(samples: [at("a", 40, used: 10), at("a", 0, used: 20)], now: now)["codex|weeklyAll"]?
               .cycleHours == FleetForecast.nominalCycleHours, "cycle: an unmeasured provider keeps 168 in its rate")
    // A low-use account rolls over without a visible drop; its reset time jumping days ahead is the tell.
    let quiet = [at("a", 200, used: 2, resetInDays: -5), at("a", 150, used: 1, resetInDays: 2),
                 at("a", 100, used: 2, resetInDays: 2), at("a", 40, used: 0, resetInDays: 6)]
    expect(close(cycle(quiet), 110), "cycle: a reset time moving forward by more than a day is a rollover too")
    // Codex's idle reset time creeps forward minutes per poll; that is no rollover.
    let creeping = (0..<12).map { i in
        UsageHistory.Sample(ts: now.addingTimeInterval(-Double(48 - 4 * i) * 3_600), account: "a",
                            provider: "codex", window: "weeklyAll", model: nil, used: 30,
                            resetAt: now.addingTimeInterval(86_400 + Double(i) * 600))
    }
    expect(cycle(creeping) == nil, "cycle: a creeping reset time is not a rollover")
}
