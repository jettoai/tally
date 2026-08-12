import Foundation

// Assertion harness for the menu-bar strip's two layouts (Tally/Core/MenuBarSegments.swift),
// compiled with the fleet math it pools through. What is checked here is the thing a screenshot
// cannot: that the pooled layout's numbers ARE the panel gauge's numbers, over the same members.

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

func account(_ id: String, provider: String = "claude", metrics: [UsageMetric],
             error: String? = nil, stale: Bool = false) -> AccountUsage {
    AccountUsage(id: id, providerID: provider, accountLabel: id, planName: nil,
                 metrics: metrics, refreshedAt: now, error: error, isStale: stale)
}

/// The app's own resolver, wired the way `UsageStore.focusedModel` wires it: no declared primary
/// model, so the flagship window leads.
func flagshipFocus(_ providerID: String, _ available: [String]) -> String? {
    FleetFocus.focusedModel(.all, primaryModel: nil, available: available,
                            flagshipOrder: ["fable", "opus"])
}

/// No model focus at all - the account-wide weekly leads (the `weekly` gauge focus).
func weeklyFocus(_ providerID: String, _ available: [String]) -> String? { nil }

func panelSummaries(_ accounts: [AccountUsage]) -> [FleetSummary] {
    FleetMath.summaries(accounts: accounts, now: now) { $0.accountLabel }
}

func stripSummaries(_ accounts: [AccountUsage]) -> [FleetSummary] {
    FleetMath.summaries(accounts: accounts, now: now, minMembers: 1) { $0.accountLabel }
}

func pooled(_ accounts: [AccountUsage], mode: DisplayMode = .remaining,
            focus: @escaping (String, [String]) -> String? = flagshipFocus) -> [MenuBarSegment] {
    MenuBarSegments.pooled(accounts, summaries: stripSummaries(accounts), mode: mode,
                           focusedModel: focus)
}

func perAccount(_ accounts: [AccountUsage], mode: DisplayMode = .remaining,
                focus: @escaping (String, [String]) -> String? = flagshipFocus) -> [MenuBarSegment] {
    MenuBarSegments.perAccount(accounts, mode: mode, focusedModel: focus)
}

/// Two Claude accounts and one Codex, the shape the pooled strip exists for.
let fleet: [AccountUsage] = [
    account("c1", metrics: [metric(.session, used: 20), metric(.weeklyAll, used: 40),
                            metric(.weeklyModel, used: 90, model: "Fable")]),
    account("c2", metrics: [metric(.session, used: 60), metric(.weeklyAll, used: 60),
                            metric(.weeklyModel, used: 70, model: "Fable")]),
    account("x1", provider: "codex", metrics: [metric(.session, used: 25),
                                               metric(.weeklyAll, used: 45)]),
]

// 1. One segment per provider, in the accounts' display order - not one per account.
do {
    let segments = pooled(fleet)
    expect(segments.count == 2, "pooled: one segment per provider")
    expect(segments.map(\.providerID) == ["claude", "codex"],
           "pooled: providers keep the accounts' display order")
    expect(perAccount(fleet).count == 3, "per-account: still one segment per account")
}

// 2. The numbers ARE the pool's, both lines: session (5h) on top, the focused weekly below.
// Claude sessions 80% and 40% left → 60; Fable windows 10% and 30% left → 20.
do {
    let claude = pooled(fleet)[0]
    expect(claude.lines == ["60%", "20%"], "pooled: session pool over the focused model pool")
    let pools = MenuBarSegments.pools(stripSummaries(fleet)[0], focusedModel: flagshipFocus)
    expect(pools.map { "\(Int($0.averageRemaining.rounded()))%" } == claude.lines,
           "pooled: the printed lines are the pools' own averages")
}

// 3. Used mode is the complement of the same average - one arithmetic, not a second one that
// could round the other way.
do {
    expect(pooled(fleet, mode: .used)[0].lines == ["40%", "80%"],
           "pooled: Used shows 100 - the pool average")
    expect(pooled(fleet, mode: .remaining)[0].lines == ["60%", "20%"],
           "pooled: Left shows the pool average")
}

// 4. THE SAME-SOURCE INVARIANT. Every pool the panel's gauge draws (minMembers 2) comes back from
// the strip's pass (minMembers 1) identical, member for member - so the two surfaces cannot print
// different numbers for one window.
do {
    let panel = panelSummaries(fleet)
    let strip = stripSummaries(fleet)
    let stripByProvider = Dictionary(strip.map { ($0.providerID, $0) },
                                     uniquingKeysWith: { first, _ in first })
    var matched = 0
    for summary in panel {
        guard let mirror = stripByProvider[summary.providerID] else {
            expect(false, "pooled: the strip has a summary for every gauged provider"); continue
        }
        for pool in summary.pools {
            guard let same = mirror.pools.first(where: {
                $0.kind == pool.kind && $0.modelName == pool.modelName
            }) else {
                expect(false, "pooled: the strip carries \(pool.kind) too"); continue
            }
            expect(same == pool, "pooled: \(pool.kind.rawValue) pool identical to the gauge's")
            matched += 1
        }
    }
    expect(matched == 3, "pooled: all three Claude pools were compared, none skipped")
    // …and the strip's extra pools are only the ones the gauge declines to draw: pools of one.
    let extra = strip.flatMap { summary in
        summary.pools.filter { pool in
            !(panel.first { $0.providerID == summary.providerID }?.pools.contains(pool) ?? false)
        }
    }
    expect(extra.allSatisfy { $0.members.count == 1 },
           "pooled: what the strip adds are pools of one, nothing else")
}

// 5. A single-account provider is a pool of one, and reads exactly like its own account segment -
// the whole reason the strip's pass asks for minMembers 1.
do {
    let segments = pooled(fleet)
    expect(segments[1].lines == ["75%", "55%"], "pooled: a lone account shows its own numbers")
    expect(segments[1].lines == perAccount(fleet)[2].lines,
           "pooled: and they are the numbers its per-account segment shows")
}

// 6. The badge counts members when there are several, and says nothing when there is one.
do {
    let segments = pooled(fleet)
    expect(segments[0].badge == 2, "pooled: the badge is the fleet size")
    expect(segments[1].badge == nil, "pooled: a lone account gets no badge")
    // Per-account keeps its own reading of that one slot: a 1-based index among siblings.
    expect(perAccount(fleet).map(\.badge) == [1, 2, nil],
           "per-account: the badge is still the account's number")
}

// 7. The weekly line follows the gauge focus, like the per-account layout does: the flagship model
// pool when one resolves, the account-wide weekly when none does.
do {
    expect(pooled(fleet, focus: weeklyFocus)[0].lines == ["60%", "50%"],
           "pooled: no model focus leads with the account-wide weekly pool")
    expect(perAccount(fleet, focus: weeklyFocus)[0].lines == ["80%", "60%"],
           "per-account: unchanged by the same switch")
}

// 8. A model window only one sibling reports still pools (as one) rather than vanishing from the
// strip - the gauge leaves it out, but the strip has nothing else to lead that provider with.
do {
    let mixed = [
        account("c1", metrics: [metric(.session, used: 20), metric(.weeklyAll, used: 40),
                                metric(.weeklyModel, used: 90, model: "Fable")]),
        account("c2", metrics: [metric(.session, used: 60), metric(.weeklyAll, used: 60)]),
    ]
    expect(panelSummaries(mixed)[0].pools.contains { $0.kind == .weeklyModel } == false,
           "the gauge does not draw a Fable pool only one account has")
    expect(pooled(mixed)[0].lines == ["60%", "10%"],
           "pooled: the strip leads with that account's Fable window rather than nothing")
}

// 9. Errors and empty data read the way a lone account's segment reads them.
do {
    let dead = [account("c1", metrics: [], error: "boom"),
                account("c2", metrics: [], error: "boom")]
    let segments = pooled(dead)
    expect(segments.count == 1 && segments[0].lines == ["!"],
           "pooled: a provider whose accounts all failed shows the error mark")
    expect(segments[0].badge == 2, "pooled: …and still says how many accounts it stands for")
    let empty = [account("c1", metrics: []), account("c2", metrics: [])]
    expect(pooled(empty)[0].lines == ["—"], "pooled: nothing reported reads as no data")
}

// 10. Stale members dim the whole segment: their last-good numbers are inside the average, and a
// bright segment would claim the pooled figure is fresh.
do {
    let partly = [
        account("c1", metrics: [metric(.weeklyAll, used: 40)], error: "boom", stale: true),
        account("c2", metrics: [metric(.weeklyAll, used: 60)]),
    ]
    let segment = pooled(partly)[0]
    expect(segment.dimmed, "pooled: one stale member dims the segment")
    expect(segment.lines == ["50%"], "pooled: and the stale account still counts toward the pool")
    expect(perAccount(partly).map(\.dimmed) == [true, false],
           "per-account: dimming stays per account")
}

// 11. An account that failed its FIRST fetch (no last-good numbers) is not in the pool, and the
// badge follows the gauge's own ×N rather than the raw account count - the two surfaces count one
// fleet one way.
do {
    let partial = [
        account("c1", metrics: [metric(.weeklyAll, used: 40)]),
        account("c2", metrics: [metric(.weeklyAll, used: 60)]),
        account("c3", metrics: [], error: "boom"),
    ]
    let segment = pooled(partial)[0]
    expect(segment.badge == 2, "pooled: the badge counts the accounts the gauge counts")
    expect(segment.lines == ["50%"], "pooled: an account with no numbers is not averaged in")
}

// 12. Per-account regression: the error mark, and a stale account keeping its numbers.
do {
    let segments = perAccount([
        account("c1", metrics: [metric(.session, used: 20)], error: "boom"),
        account("c2", metrics: [metric(.session, used: 20)], error: "boom", stale: true),
    ])
    expect(segments[0].lines == ["!"] && !segments[0].dimmed, "per-account: a fresh error is a mark")
    expect(segments[1].lines == ["80%"] && segments[1].dimmed,
           "per-account: a stale account keeps its last-good numbers, dimmed")
}

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all menu-bar layout tests passed")
