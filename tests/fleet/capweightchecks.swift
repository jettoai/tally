import Foundation

// Plan capacity weights (PlanWeight) and the cross-plan weighted weekly remaining
// (FleetMath.weighted). Multiples: Claude Pro 1 / Max 5 / Ultra 10; Codex Plus, Team 1 and the
// Pro tiers prolite 5 / pro 10 / promax 25 (B-4685); a plan the table does not list has none.
// Codex accounts carry the raw planType in `planKey`, Claude's plan name is its own key.
func planAccount(_ id: String, provider: String, plan: String?, weeklyUsed: Double?,
                 stale: Bool = false, planKey: String? = nil) -> AccountUsage {
    var usage = AccountUsage(id: id, providerID: provider, accountLabel: id, planName: plan,
                             planKey: planKey,
                             metrics: weeklyUsed.map { [metric(.weeklyAll, used: $0)] }
                                 ?? [metric(.session, used: 10)],
                             refreshedAt: now)
    usage.isStale = stale
    return usage
}

func runCapWeightTests() {
    func w(_ provider: String, _ plan: String?) -> (Double, PlanWeight.Source)? {
        PlanWeight.weight(providerID: provider, plan: plan).map { ($0.value, $0.source) }
    }
    expect(w("claude", "Max 20x")! == (10, .detected), "weight: Claude Max 20x = 10 detected")
    expect(w("claude", "Ultra")! == (10, .detected) && w("claude", "ultra")! == (10, .detected)
               && w("claude", "ULTRA")! == (10, .detected)
               && w("claude", "Claude Ultra")! == (10, .detected)
               && w("claude", "max_20x")! == (10, .detected),
           "weight: Claude Ultra (any case) = 10 detected (weekly 10x Pro, claude.com/pricing)")
    expect(w("claude", "Max 5x")! == (5, .detected) && w("claude", "Max")! == (5, .detected),
           "weight: Claude Max and Max 5x = 5 detected")
    expect(w("claude", "Pro")! == (1, .detected), "weight: Claude Pro = 1 detected")
    expect(w("claude", nil) == nil && w("claude", "Team") == nil && w("claude", "Enterprise") == nil,
           "weight: Claude without a plan, Team and Enterprise have no multiple")
    expect(["plus", "team", "business", "edu"].allSatisfy { w("codex", $0)! == (1, .detected) },
           "weight: Codex plus, team, business, edu = 1 detected")
    expect(w("codex", "prolite")! == (5, .announced) && w("codex", "pro")! == (10, .announced)
               && w("codex", "promax")! == (25, .announced),
           "weight: Codex Pro 100 / 200 / 500 = 5 / 10 / 25 announced")
    expect(["free", "go", "self_serve_business_prolite", "enterprise_cbp_usage_based", "unknown",
            "enterprise", ""].allSatisfy { w("codex", $0) == nil } && w("codex", nil) == nil,
           "weight: unlisted Codex plans and no plan have no multiple (never 1)")

    // Codex weighs by planKey, not by the display name.
    let pro = planAccount("x1", provider: "codex", plan: "Pro 200", weeklyUsed: 88, planKey: "pro")
    let team = planAccount("x2", provider: "codex", plan: "Team", weeklyUsed: 3, planKey: "team")
    let brief = FleetMath.weighted(accounts: [pro, team])["codex"]
    expect(brief == FleetWeighted(remainingPercent: 20, source: .announced),
           "weighted: Pro 200 at 12 + Team at 97 = 19.7, published as 20, announced")
    let stalePro = planAccount("x1", provider: "codex", plan: "Pro 200", weeklyUsed: 88, stale: true,
                               planKey: "pro")
    expect(FleetMath.weighted(accounts: [stalePro, team])["codex"]
               == FleetWeighted(remainingPercent: 97, source: .detected),
           "weighted: a stale account stays out of both sums")
    let staleTeam = planAccount("x2", provider: "codex", plan: "Team", weeklyUsed: 3, stale: true,
                                planKey: "team")
    expect(FleetMath.weighted(accounts: [stalePro, staleTeam])["codex"] == nil,
           "weighted: no fresh reading, no figure")
    let sessionOnly = planAccount("x3", provider: "codex", plan: "Pro", weeklyUsed: nil, planKey: "pro")
    expect(FleetMath.weighted(accounts: [sessionOnly])["codex"] == nil,
           "weighted: an account without a weekly window is skipped")
    let solo = planAccount("c1", provider: "claude", plan: "Max 20x", weeklyUsed: 30)
    expect(FleetMath.weighted(accounts: [solo])["claude"]
               == FleetWeighted(remainingPercent: 70, source: .detected),
           "weighted: a single account reads its own remaining")
    let unnamed = planAccount("c2", provider: "claude", plan: nil, weeklyUsed: 90)
    let blended = planAccount("c1", provider: "claude", plan: "Max 20x", weeklyUsed: 40)
    expect(FleetMath.weighted(accounts: [blended, unnamed])["claude"] == nil,
           "weighted: a named plan beside an unknown one gives no figure, not a weight of 1")
    let twinUnnamed = [unnamed, planAccount("c3", provider: "claude", plan: nil, weeklyUsed: 50)]
    expect(FleetMath.weighted(accounts: twinUnnamed)["claude"]
               == FleetWeighted(remainingPercent: 30, source: .assumed),
           "weighted: unknown plans alike on every account pool equally, marked assumed")
    let proPair = [planAccount("p1", provider: "codex", plan: "Pro 200", weeklyUsed: 88, planKey: "pro"),
                   planAccount("p2", provider: "codex", plan: "Pro 200", weeklyUsed: 3, planKey: "pro")]
    expect(FleetMath.weighted(accounts: proPair)["codex"]?.remainingPercent == 55,
           "weighted: two accounts of one plan are the plain mean (12 + 97) / 2 = 54.5 -> 55")
    let pro100 = planAccount("p3", provider: "codex", plan: "Pro 100", weeklyUsed: 50, planKey: "prolite")
    expect(FleetMath.weighted(accounts: [pro, pro100])["codex"]
               == FleetWeighted(remainingPercent: 25, source: .announced),
           "weighted: Pro 200 at 12 (x10) + Pro 100 at 50 (x5) = 370/15 = 24.7 -> 25")

    let split = FleetMath.summaries(accounts: [pro, team], now: now, byPlan: true) { $0.id }
    expect(split.map { FleetMath.planName(of: $0, accounts: [pro, team]) } == ["Pro 200", "Team"],
           "planName: a split summary names its tier")
    let twins = [planAccount("c1", provider: "claude", plan: "Max 20x", weeklyUsed: 10),
                 planAccount("c2", provider: "claude", plan: "Max 20x", weeklyUsed: 20)]
    let unsplit = FleetMath.summaries(accounts: twins, now: now, byPlan: true) { $0.id }
    expect(unsplit.map { FleetMath.planName(of: $0, accounts: twins) } == ["Max 20x"],
           "planName: an unsplit provider names the plan every account shares")
    let mixed = [planAccount("x1", provider: "codex", plan: "Pro", weeklyUsed: 10, planKey: "pro"),
                 planAccount("x9", provider: "codex", plan: nil, weeklyUsed: 20)]
    let mixedSummary = FleetMath.summaries(accounts: mixed, now: now, byPlan: true) { $0.id }
    expect(mixedSummary.map { FleetMath.planName(of: $0, accounts: mixed) } == [nil],
           "planName: a named plan beside an unknown one names none")

    let ultra = planAccount("u1", provider: "claude", plan: "Ultra", weeklyUsed: 30)
    var maxSeat = planAccount("m1", provider: "claude", plan: "Max", weeklyUsed: 30)
    maxSeat.metrics.append(metric(.session, used: 10))
    let pending = AccountUsage(id: "p1", providerID: "claude", accountLabel: "p1", planName: nil,
                               metrics: [], refreshedAt: now)
    expect(!FleetMath.hasSessionWindow([ultra], provider: "claude")
               && FleetMath.hasSessionWindow([ultra, maxSeat], provider: "claude")
               && !FleetMath.hasSessionWindow([maxSeat], provider: "codex"),
           "5-hour: only an account that reports a session window has one")
    expect(!FleetMath.showsSessionSettings([ultra], provider: "claude")
               && FleetMath.showsSessionSettings([ultra, maxSeat], provider: "claude")
               && FleetMath.showsSessionSettings([pending], provider: "claude")
               && FleetMath.showsSessionSettings([], provider: "claude")
               && FleetMath.showsSessionSettings([ultra], provider: "claude", alreadyOn: true),
           "5-hour settings: hidden for a two-bar fleet, shown before a reading or while switched on")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let published = UsageSnapshot.make(
        accounts: [], launchHomes: [:],
        fleetWeighted: ["codex": .init(remainingPercent: 20, weightSource: "announced")])
    let json = String(decoding: try! encoder.encode(published), as: UTF8.self)
    expect(json.contains(#""fleetWeighted":{"codex":{"remainingPercent":20,"weightSource":"announced"}}"#),
           "snapshot: fleetWeighted is published")
    let bare = String(decoding: try! encoder.encode(
        UsageSnapshot.make(accounts: [], launchHomes: [:])), as: UTF8.self)
    expect(!bare.contains("fleetWeighted"), "snapshot: no figure, no key")
}
