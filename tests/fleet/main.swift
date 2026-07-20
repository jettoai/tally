import Foundation

// Assertion harness for FleetMath (compiled with ProviderModels.swift + FleetMath.swift).

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)

func metric(_ kind: MetricKind, used: Double, label: String? = nil, model: String? = nil,
            resetIn: TimeInterval? = nil) -> UsageMetric {
    let name = label ?? (kind == .session ? "Session" : kind == .weeklyAll ? "Weekly" : (model ?? "Model"))
    return UsageMetric(id: "\(kind.rawValue):\(name)", kind: kind, label: name, modelName: model,
                       usedPercent: used, severity: .normal,
                       resetsAt: resetIn.map { now.addingTimeInterval($0) }, isActive: false)
}

func account(_ id: String, provider: String = "claude", metrics: [UsageMetric]) -> AccountUsage {
    AccountUsage(id: id, providerID: provider, accountLabel: id, planName: nil,
                 metrics: metrics, refreshedAt: now)
}

func summarize(_ accounts: [AccountUsage]) -> [FleetSummary] {
    FleetMath.summaries(accounts: accounts, now: now) { $0.accountLabel }
}

// 1. Weekly pool averages remaining with equal weights; weakest account identified.
do {
    let s = summarize([
        account("c1", metrics: [metric(.weeklyAll, used: 94)]),   // 6% left
        account("c2", metrics: [metric(.weeklyAll, used: 40)]),   // 60% left
    ])
    let pool = s.first?.headline
    expect(s.count == 1 && pool?.kind == .weeklyAll, "weekly pool exists")
    expect(pool.map { abs($0.averageRemaining - 33) < 0.001 } == true, "average = mean of remaining")
    expect(pool?.minAccountLabel == "c1" && pool?.minRemaining == 6, "weakest account is c1 at 6%")
}

// 2. A provider with one account contributes nothing.
do {
    let s = summarize([account("c1", metrics: [metric(.weeklyAll, used: 10)])])
    expect(s.isEmpty, "single-account provider has no fleet")
}

// 3. A window class held by only one member does not pool; shared classes still do.
do {
    let s = summarize([
        account("c1", metrics: [metric(.session, used: 50), metric(.weeklyAll, used: 50)]),
        account("c2", metrics: [metric(.weeklyAll, used: 30)]),
    ])
    expect(s.first?.pools.count == 1 && s.first?.pools[0].kind == .weeklyAll,
           "unshared session window does not pool")
}

// 4. Model pools group by model name; different models never merge.
do {
    let s = summarize([
        account("c1", metrics: [metric(.weeklyModel, used: 80, model: "Fable 5"),
                                metric(.weeklyModel, used: 10, model: "Opus")]),
        account("c2", metrics: [metric(.weeklyModel, used: 60, model: "Fable 5")]),
    ])
    let models = s.first?.pools.filter { $0.kind == .weeklyModel } ?? []
    expect(models.count == 1 && models[0].label == "Fable 5", "only the shared model pools")
    expect(abs(models[0].averageRemaining - 30) < 0.001, "model pool averages its own windows")
}

// 5. Next refill is the soonest FUTURE reset, with its account; past resets are ignored.
do {
    let s = summarize([
        account("c1", metrics: [metric(.weeklyAll, used: 20, resetIn: -3_600)]),
        account("c2", metrics: [metric(.weeklyAll, used: 20, resetIn: 7_200)]),
        account("c3", metrics: [metric(.weeklyAll, used: 20, resetIn: 86_400)]),
    ])
    let pool = s.first?.headline
    expect(pool?.nextReset == now.addingTimeInterval(7_200)
           && pool?.nextResetAccountLabel == "c2", "soonest future reset wins")
}

// 6. Headline prefers weekly over session; falls back to session when no weekly exists.
do {
    let both = summarize([
        account("c1", metrics: [metric(.session, used: 10), metric(.weeklyAll, used: 10)]),
        account("c2", metrics: [metric(.session, used: 10), metric(.weeklyAll, used: 10)]),
    ])
    expect(both.first?.headline?.kind == .weeklyAll, "headline prefers weekly")
    let sessionOnly = summarize([
        account("x1", provider: "codex", metrics: [metric(.session, used: 10)]),
        account("x2", provider: "codex", metrics: [metric(.session, used: 10)]),
    ])
    expect(sessionOnly.first?.headline?.kind == .session, "headline falls back to session")
}

// 7. Providers keep account order; error accounts (no metrics) don't count toward the fleet.
do {
    let s = summarize([
        account("x1", provider: "codex", metrics: [metric(.weeklyAll, used: 10)]),
        account("c1", metrics: [metric(.weeklyAll, used: 10)]),
        account("c2", metrics: []),
        account("c3", metrics: [metric(.weeklyAll, used: 30)]),
    ])
    expect(s.count == 1 && s.first?.providerID == "claude", "metric-less account excluded; codex stays single")
    expect(s.first?.accountCount == 2, "fleet counts only accounts with metrics")
}

// 8. Members keep display order with their own numbers; refills sort soonest-first with gains.
do {
    let s = summarize([
        account("c1", metrics: [metric(.weeklyAll, used: 94, resetIn: 86_400)]),
        account("c2", metrics: [metric(.weeklyAll, used: 40, resetIn: 3_600)]),
    ])
    let pool = s.first!.headline!
    expect(pool.members.map(\.accountLabel) == ["c1", "c2"], "members keep account order")
    expect(abs(pool.totalRemaining - 66) < 0.001, "total pools remaining units")
    expect(pool.refills.map(\.accountLabel) == ["c2", "c1"]
           && pool.refills.map(\.gain) == [40, 94], "refills soonest-first with gains")
}

// MARK: FleetForecast

func sample(_ account: String, provider: String = "claude", tsHoursAgo: Double, used: Double,
            window: String = "weeklyAll", resetInDays: Double? = 3) -> UsageHistory.Sample {
    UsageHistory.Sample(ts: now.addingTimeInterval(-tsHoursAgo * 3_600), account: account,
                        provider: provider, window: window, model: nil, used: used,
                        resetAt: resetInDays.map { now.addingTimeInterval($0 * 86_400) })
}

// 9. Pace = summed positive deltas across accounts over the sampled hours.
do {
    let rates = FleetForecast.weeklyRates(samples: [
        sample("c1", tsHoursAgo: 10, used: 10), sample("c1", tsHoursAgo: 0, used: 30),
        sample("c2", tsHoursAgo: 10, used: 50), sample("c2", tsHoursAgo: 0, used: 60),
    ], now: now)
    expect(rates["claude|weeklyAll"].map { abs($0.perHour - 3) < 0.001 } == true,
           "pace sums both accounts (30 units / 10h)")
}

// 10. A window rollover (resetAt changed, used dropped) contributes nothing to the pace.
do {
    let rates = FleetForecast.weeklyRates(samples: [
        sample("c1", tsHoursAgo: 12, used: 90, resetInDays: 0.1),
        sample("c1", tsHoursAgo: 6, used: 5, resetInDays: 7),
        sample("c1", tsHoursAgo: 0, used: 11, resetInDays: 7),
    ], now: now)
    expect(rates["claude|weeklyAll"].map { abs($0.perHour - 0.5) < 0.001 } == true,
           "rollover excluded (6 units / 12h)")
}

// 11. Too little history → no estimate (the strip says "measuring", not a noise forecast).
do {
    let rates = FleetForecast.weeklyRates(samples: [
        sample("c1", tsHoursAgo: 2, used: 10), sample("c1", tsHoursAgo: 0, used: 20),
    ], now: now)
    expect(rates["claude|weeklyAll"] == nil,
           "under \(Int(FleetForecast.minimumSampleHours))h of history gives no pace")
}

// 12. Depletion: linear without refills; a refill pushes the dry point out.
do {
    let bare = FleetForecast.depletion(remaining: 100, refills: [], perHour: 10,
                                       steadyRefillPerHour: 0, now: now)
    expect(bare == now.addingTimeInterval(10 * 3_600), "dry = remaining/pace without refills")
    let extended = FleetForecast.depletion(
        remaining: 50, refills: [(at: now.addingTimeInterval(3 * 3_600), gain: 100)],
        perHour: 10, steadyRefillPerHour: 0, now: now)
    expect(extended == now.addingTimeInterval(15 * 3_600), "refill extends the dry point")
}

// 13. A pace under the steady refill budget never dries; over it dries after the listed cycle.
do {
    let sustainable = FleetForecast.depletion(remaining: 200, refills: [], perHour: 1,
                                              steadyRefillPerHour: 1.19, now: now)
    expect(sustainable == nil, "pace within the weekly budget is sustainable")
    let dries = FleetForecast.depletion(remaining: 200, refills: [], perHour: 2,
                                        steadyRefillPerHour: 1, now: now)
    expect(dries == now.addingTimeInterval(200 * 3_600), "net overspend dries at remaining/net")
}

// MARK: FleetFocus (gauge focus resolution)

// 14. Auto follows the declared primary: a flagship primary focuses its window (alias matches
// the versioned name), a non-flagship primary focuses nothing (weekly), and no primary is
// flagship-first - the smart launcher's rule.
do {
    let order = ["fable", "opus", "sonnet", "haiku"]
    let available = ["Fable 5"]
    expect(FleetFocus.focusedModel(.auto, primaryModel: "fable", available: available,
                                   flagshipOrder: order) == "Fable 5",
           "auto + fable primary focuses the Fable window")
    expect(FleetFocus.focusedModel(.auto, primaryModel: "sonnet", available: available,
                                   flagshipOrder: order) == nil,
           "auto + sonnet primary focuses the weekly budget")
    expect(FleetFocus.focusedModel(.auto, primaryModel: nil, available: available,
                                   flagshipOrder: order) == "Fable 5",
           "auto without a primary is flagship-first")
    expect(FleetFocus.focusedModel(.auto, primaryModel: "fable", available: [],
                                   flagshipOrder: order) == nil,
           "no model windows means nothing to focus")
}

// 15. Explicit focus: flagship ranks by tier order; weekly always declines to focus.
do {
    let order = ["fable", "opus", "sonnet", "haiku"]
    let available = ["Opus", "Fable 5"]
    expect(FleetFocus.focusedModel(.flagship, primaryModel: "sonnet", available: available,
                                   flagshipOrder: order) == "Fable 5",
           "flagship picks the top tier regardless of primary")
    expect(FleetFocus.focusedModel(.weekly, primaryModel: "fable", available: available,
                                   flagshipOrder: order) == nil,
           "weekly focus pins the account-wide budget")
}

// 16. headline(focusedModel:) returns the named model pool, and degrades to the weekly budget
// when the name matches no pool (schema drift / missing window).
do {
    let s = summarize([
        account("c1", metrics: [metric(.weeklyAll, used: 10),
                                metric(.weeklyModel, used: 40, model: "Fable 5")]),
        account("c2", metrics: [metric(.weeklyAll, used: 20),
                                metric(.weeklyModel, used: 60, model: "Fable 5")]),
    ])
    expect(s.first?.headline(focusedModel: "Fable 5")?.kind == .weeklyModel,
           "focused headline is the model pool")
    expect(s.first?.modelPoolNames == ["Fable 5"], "model pool names are exposed for resolution")
    expect(s.first?.headline(focusedModel: "Ghost")?.kind == .weeklyAll,
           "unknown focus degrades to the weekly pool")
    expect(s.first?.headline(focusedModel: nil)?.kind == .weeklyAll,
           "nil focus is the weekly pool")
}

// 17. Model-scoped samples get their own rate series, keyed by rateKey.
do {
    let fable = { (account: String, hoursAgo: Double, used: Double) in
        UsageHistory.Sample(ts: now.addingTimeInterval(-hoursAgo * 3_600), account: account,
                            provider: "claude", window: "weeklyModel", model: "Fable 5",
                            used: used, resetAt: now.addingTimeInterval(3 * 86_400))
    }
    let rates = FleetForecast.weeklyRates(samples: [
        sample("c1", tsHoursAgo: 10, used: 10), sample("c1", tsHoursAgo: 0, used: 20),
        fable("c1", 10, 0), fable("c1", 0, 40),
    ], now: now)
    expect(rates["claude|weeklyAll"].map { abs($0.perHour - 1) < 0.001 } == true,
           "weekly series unchanged by model samples")
    expect(rates["claude|weeklyModel|fable 5"].map { abs($0.perHour - 4) < 0.001 } == true,
           "model series keyed separately (lowercased)")
}

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all fleet tests passed")
