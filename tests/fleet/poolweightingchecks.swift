import Foundation

// B-4685 WP3: what a pool's weighting reads as on the card head and in its hover (PoolWeighting).
// Decided in Core so the degrade states are testable without a window.
func runPoolWeightingTests() {
    func seat(_ id: String, _ plan: String?, key: String?, used: Double) -> AccountUsage {
        AccountUsage(id: id, providerID: "codex", accountLabel: id, planName: plan, planKey: key,
                     metrics: [metric(.weeklyAll, used: used, resetIn: 3_600)], refreshedAt: now)
    }
    func pool(_ accounts: [AccountUsage]) -> FleetPool {
        FleetMath.summaries(accounts: accounts, now: now) { $0.accountLabel }.first!.headline!
    }
    let pro = seat("codex1", "Pro 200", key: "pro", used: 88)
    let team = seat("codex2", "Team", key: "team", used: 3)

    // The screenshot pair: weighted, ring 16.0% left (84.0% used), unit and seats spelled out.
    let pair = pool([pro, team])
    let weighting = PoolWeighting(pair, unknownPlan: "Unknown plan")
    expect(weighting.kind == .weighted && PoolWeighting.kind(of: pair) == .weighted,
           "B-4685 WP3 Pro 200 + Team is a weighted pool")
    expect(PoolWeighting.ringShare(pair, used: false).map { abs($0 - 337.0 / 21) < 1e-9 } == true
               && PoolWeighting.ringShare(pair, used: true).map { abs($0 - (100 - 337.0 / 21)) < 1e-9 } == true,
           "B-4685 WP3 the ring reads the combined average in either mode")
    expect(abs(weighting.weeksLeft - 3.37) < 1e-9 && weighting.weeksTotal == 21,
           "B-4685 WP3 the hover counts 3.37 of 21 lowest-plan weeks")
    expect(weighting.seatsText(announcedWord: "announced")
               == "codex1 Pro 200 \u{00D7}20 announced \u{00B7} codex2 Team \u{00D7}1",
           "B-4685 WP3 seats list their multiples, the announced one marked")
    expect(pair.members.map(\.multiple) == [20, 1]
               && pair.members.map(\.multipleSource) == [.announced, .detected],
           "B-4685 WP3 members carry the published multiple and how sure it is")

    // One weight across the pool says nothing: same plan, or plans of equal multiple.
    let twins = pool([seat("a", "Pro 200", key: "pro", used: 88), seat("b", "Pro 200", key: "pro", used: 3)])
    let plusTeam = pool([seat("a", "Plus", key: "plus", used: 20), seat("b", "Team", key: "team", used: 40)])
    expect(PoolWeighting.kind(of: twins) == .equal && PoolWeighting.kind(of: plusTeam) == .equal
               && PoolWeighting.ringShare(twins, used: false) == 54.5,
           "B-4685 WP3 one plan, or equal multiples: equal, the ring unchanged at 54.5%")

    // No published multiple: no ring figure, never the placeholder average, and the plan is named.
    let premium = seat("codex2", "Business Premium", key: "self_serve_business_prolite", used: 20)
    let unknown = pool([pro, premium])
    let degraded = PoolWeighting(unknown, unknownPlan: "Unknown plan")
    expect(degraded.kind == .unknown && PoolWeighting.ringShare(unknown, used: false) == nil
               && PoolWeighting.ringShare(unknown, used: true) == nil
               && unknown.averageRemaining.isFinite,
           "B-4685 WP3 Pro 200 + Business Premium: no ring figure (the placeholder average exists but is not read)")
    expect(degraded.unpublishedPlans == ["Business Premium"]
               && degraded.planShares.map(\.plan) == ["Pro 200", "Business Premium"]
               && degraded.planShares.map(\.remaining) == [12, 80]
               && degraded.planShares.map(\.published) == [true, false],
           "B-4685 WP3 the hover lists each plan's own remaining and which has no published multiple")
    let unnamed = pool([pro, seat("codex3", nil, key: nil, used: 20)])
    expect(PoolWeighting(unnamed, unknownPlan: "Unknown plan").unpublishedPlans == ["Unknown plan"],
           "B-4685 WP3 a plan-less account is named as an unknown plan")

    expect(PoolWeighting.multipleText(10) == "\u{00D7}10" && PoolWeighting.multipleText(2.5) == "\u{00D7}2.5",
           "B-4685 WP3 multiples print whole, or with one decimal")
}
