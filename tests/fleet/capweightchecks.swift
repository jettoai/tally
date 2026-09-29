import Foundation

// Plan capacity weights (PlanWeight) and the cross-plan weighted weekly remaining
// (FleetMath.weighted). The Codex numbers are the 2026-09-29 Baton report: Pro 43%, Team 2%.
func planAccount(_ id: String, provider: String, plan: String?, weeklyUsed: Double?,
                 stale: Bool = false) -> AccountUsage {
    var usage = AccountUsage(id: id, providerID: provider, accountLabel: id, planName: plan,
                             metrics: weeklyUsed.map { [metric(.weeklyAll, used: $0)] }
                                 ?? [metric(.session, used: 10)],
                             refreshedAt: now)
    usage.isStale = stale
    return usage
}

func runCapWeightTests() {
    func w(_ provider: String, _ plan: String?, _ multiple: Double? = nil)
        -> (Double, PlanWeight.Source) {
        let r = PlanWeight.weight(providerID: provider, planName: plan, codexProMultiple: multiple)
        return (r.value, r.source)
    }
    expect(w("claude", "Max 20x") == (20, .detected), "weight: Claude Max 20x = 20 detected")
    expect(w("claude", "Max 5x") == (5, .detected), "weight: Claude Max 5x = 5 detected")
    expect(w("claude", "Pro") == (1, .detected), "weight: Claude Pro = 1 detected")
    expect(w("claude", nil) == (1, .assumed), "weight: Claude without a plan = 1 assumed")
    expect(w("claude", "Max") == (1, .assumed), "weight: Claude bare Max = 1 assumed")
    expect(w("codex", "Plus") == (1, .detected) && w("codex", "Team") == (1, .detected)
               && w("codex", "Business") == (1, .detected), "weight: Plus, Team, Business = 1")
    expect(w("codex", "Pro") == (5, .assumed), "weight: Codex Pro unset = 5 assumed")
    expect(w("codex", "Pro", 20) == (20, .config), "weight: Codex Pro set to 20 = 20 config")
    expect(w("codex", "Pro", 5) == (5, .config), "weight: Codex Pro set to 5 = 5 config")
    expect(w("codex", "Pro", 7) == (5, .assumed), "weight: Codex Pro set to 7 is ignored")
    expect(w("codex", "Enterprise") == (1, .assumed), "weight: unknown Codex plan = 1 assumed")

    let pro = planAccount("x1", provider: "codex", plan: "Pro", weeklyUsed: 57)   // 43 left
    let team = planAccount("x2", provider: "codex", plan: "Team", weeklyUsed: 98) // 2 left
    let brief = FleetMath.weighted(accounts: [pro, team], codexProMultiple: nil)["codex"]
    expect(brief == FleetWeighted(remainingPercent: 36, source: .assumed),
           "weighted: Pro 43 + Team 2 = 36 assumed")
    let set20 = FleetMath.weighted(accounts: [pro, team], codexProMultiple: 20)["codex"]
    expect(set20 == FleetWeighted(remainingPercent: 41, source: .config),
           "weighted: Pro set to 20 moves the figure to 41 config")
    let stalePro = planAccount("x1", provider: "codex", plan: "Pro", weeklyUsed: 57, stale: true)
    expect(FleetMath.weighted(accounts: [stalePro, team], codexProMultiple: nil)["codex"]
               == FleetWeighted(remainingPercent: 2, source: .detected),
           "weighted: a stale account stays out of both sums")
    let staleTeam = planAccount("x2", provider: "codex", plan: "Team", weeklyUsed: 98, stale: true)
    expect(FleetMath.weighted(accounts: [stalePro, staleTeam], codexProMultiple: nil)["codex"]
               == nil, "weighted: no fresh reading, no figure")
    let sessionOnly = planAccount("x3", provider: "codex", plan: "Pro", weeklyUsed: nil)
    expect(FleetMath.weighted(accounts: [sessionOnly], codexProMultiple: nil)["codex"] == nil,
           "weighted: an account without a weekly window is skipped")
    let solo = planAccount("c1", provider: "claude", plan: "Max 20x", weeklyUsed: 30)
    expect(FleetMath.weighted(accounts: [solo], codexProMultiple: nil)["claude"]
               == FleetWeighted(remainingPercent: 70, source: .detected),
           "weighted: a single account reads its own remaining")
    let unnamed = planAccount("c2", provider: "claude", plan: nil, weeklyUsed: 90)
    let blended = planAccount("c1", provider: "claude", plan: "Max 20x", weeklyUsed: 40)
    expect(FleetMath.weighted(accounts: [blended, unnamed], codexProMultiple: nil)["claude"]
               == FleetWeighted(remainingPercent: 58, source: .assumed),
           "weighted: one assumed member makes the figure assumed")

    let split = FleetMath.summaries(accounts: [pro, team], now: now, byPlan: true) { $0.id }
    expect(split.map { FleetMath.planName(of: $0, accounts: [pro, team]) } == ["Pro", "Team"],
           "planName: a split summary names its tier")
    let twins = [planAccount("c1", provider: "claude", plan: "Max 20x", weeklyUsed: 10),
                 planAccount("c2", provider: "claude", plan: "Max 20x", weeklyUsed: 20)]
    let unsplit = FleetMath.summaries(accounts: twins, now: now, byPlan: true) { $0.id }
    expect(unsplit.map { FleetMath.planName(of: $0, accounts: twins) } == ["Max 20x"],
           "planName: an unsplit provider names the plan every account shares")
    let mixed = [planAccount("x1", provider: "codex", plan: "Pro", weeklyUsed: 10),
                 planAccount("x9", provider: "codex", plan: nil, weeklyUsed: 20)]
    let mixedSummary = FleetMath.summaries(accounts: mixed, now: now, byPlan: true) { $0.id }
    expect(mixedSummary.map { FleetMath.planName(of: $0, accounts: mixed) } == [nil],
           "planName: a named plan beside an unknown one names none")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let published = UsageSnapshot.make(
        accounts: [], launchHomes: [:],
        fleetWeighted: ["codex": .init(remainingPercent: 36, weightSource: "assumed")])
    let json = String(decoding: try! encoder.encode(published), as: UTF8.self)
    expect(json.contains(#""fleetWeighted":{"codex":{"remainingPercent":36,"weightSource":"assumed"}}"#),
           "snapshot: fleetWeighted is published")
    let bare = String(decoding: try! encoder.encode(
        UsageSnapshot.make(accounts: [], launchHomes: [:])), as: UTF8.self)
    expect(!bare.contains("fleetWeighted"), "snapshot: no figure, no key")
}
