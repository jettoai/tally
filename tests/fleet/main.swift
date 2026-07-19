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

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all fleet tests passed")
