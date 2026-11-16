import Foundation

// B-4685: a pool that mixes plans weighs each member by its plan's multiple (PlanWeight), in the
// unit of one lowest-plan account's window. Pools of one plan must not move at all.
// The owner's screenshot: codex1 Pro 200 at 12% left (resets in 6.5h), codex2 Team at 97% left.
func runWeightedPoolTests() {
    func seat(_ id: String, _ plan: String?, key: String?, used: Double, resetIn: Double,
              provider: String = "codex") -> AccountUsage {
        AccountUsage(id: id, providerID: provider, accountLabel: id, planName: plan, planKey: key,
                     metrics: [metric(.weeklyAll, used: used, resetIn: resetIn * 3_600)],
                     refreshedAt: now)
    }
    func pooled(_ accounts: [AccountUsage], byPlan: Bool = false) -> FleetPool? {
        FleetMath.summaries(accounts: accounts, now: now, byPlan: byPlan) { $0.accountLabel }
            .first?.headline
    }
    let pro = seat("codex1", "Pro 200", key: "pro", used: 88, resetIn: 6.5)
    let team = seat("codex2", "Team", key: "team", used: 3, resetIn: 144)

    // The screenshot pair (A1-A3, A6).
    let pair = pooled([pro, team])
    expect(pair.map { abs($0.averageRemaining - 217.0 / 11) < 1e-9 } == true
               && pair.map { abs($0.averageRemaining - 19.7) < 0.05 } == true,
           "B-4685 Pro 200 at 12 + Team at 97 = 19.7% left, not 54.5%")
    expect(pair?.totalRemaining == 217 && pair?.capacity == 1100 && pair?.totalWeight == 11,
           "B-4685 the pair holds 217 of 1100 units")
    expect(pair?.members.map(\.weight) == [10, 1] && pair?.weightUnknown == false
               && pair?.combinedAverage == pair?.averageRemaining,
           "B-4685 members carry their multiples and the pool is weighed")
    let refill = pair?.refills.first
    expect(refill?.accountLabel == "codex1" && refill?.gain == 880 && refill?.ownGain == 88
               && refill?.poolWeight == 11 && refill?.poolShare == 80 && refill?.poolShareText == "80%"
               && refill?.gainText == "88%",
           "B-4685 Pro 200's reset refills +80% of the pool (88% of its own window)")
    expect(pair.map { abs($0.steadyRefillPerHour(windowHours: 168) - 1100.0 / 168) < 1e-12 } == true,
           "B-4685 steady refill speed follows the weighted capacity")
    expect(pair?.minAccountLabel == "codex1" && pair?.minRemaining == 12,
           "B-4685 the tightest account still compares each account's own percent")

    // Same plan: every number as before (equal weights, bit for bit).
    let twins = pooled([seat("a", "Pro 200", key: "pro", used: 88, resetIn: 6.5),
                        seat("b", "Pro 200", key: "pro", used: 3, resetIn: 144)])
    expect(twins?.averageRemaining == 54.5 && twins?.totalRemaining == 109 && twins?.capacity == 200
               && twins?.members.allSatisfy { $0.weight == 1 } == true && twins?.weightUnknown == false
               && twins?.refills.first?.poolShare == 44 && twins?.refills.first?.gain == 88
               && twins?.steadyRefillPerHour(windowHours: 168) == 200.0 / 168,
           "B-4685 two accounts of one plan pool exactly as before: 54.5%, +44%")
    let plusTeam = pooled([seat("a", "Plus", key: "plus", used: 20, resetIn: 5),
                           seat("b", "Team", key: "team", used: 40, resetIn: 9)])
    expect(plusTeam?.capacity == 200 && plusTeam?.averageRemaining == 70
               && plusTeam?.weightUnknown == false,
           "B-4685 plans of equal multiple keep weight 1 (Plus + Team)")
    let claudeTwo = pooled([seat("c1", "Max 20x", key: nil, used: 10, resetIn: 5, provider: "claude"),
                            seat("c2", "Ultra", key: nil, used: 30, resetIn: 9, provider: "claude")])
    expect(claudeTwo?.capacity == 200 && claudeTwo?.averageRemaining == 80,
           "B-4685 Claude Max 20x beside Ultra (both 10x) stays equal weight")
    let claudeMix = pooled([seat("c1", "Max", key: nil, used: 50, resetIn: 5, provider: "claude"),
                            seat("c2", "Ultra", key: nil, used: 0, resetIn: 9, provider: "claude")])
    expect(claudeMix?.members.map(\.weight) == [5, 10] && claudeMix?.capacity == 1500
               && claudeMix?.averageRemaining == (5 * 50 + 10 * 100) / 15,
           "B-4685 Claude Max (x5) beside Ultra (x10) weighs 5:10")

    // Unknown multiples: flagged, never read as 1 (A9 too: a named plan beside an unnamed one).
    let premium = seat("codex3", "Self Serve Business Prolite", key: "self_serve_business_prolite",
                       used: 20, resetIn: 50)
    let unknownMix = pooled([pro, premium])
    expect(unknownMix?.weightUnknown == true && unknownMix?.combinedAverage == nil
               && unknownMix?.averageRemaining.isFinite == true,
           "B-4685 Pro 200 + Business Premium: weightUnknown, no combined figure")
    let unnamed = seat("codex4", nil, key: nil, used: 20, resetIn: 50)
    let proPlusUnnamed = pooled([pro, unnamed], byPlan: true)
    expect(proPlusUnnamed?.weightUnknown == true && proPlusUnnamed?.combinedAverage == nil,
           "B-4685 A9: Pro 200 + a plan-less account (not split) is weightUnknown")
    expect(pooled([seat("f1", "Free", key: "free", used: 10, resetIn: 5),
                   seat("f2", "Free", key: "free", used: 30, resetIn: 9)])?.weightUnknown == false,
           "B-4685 unknown plans alike on every account pool equally, no flag")

    // Split by plan: each tier's pool is one plan, and its multiple rides on the summary (snapshot).
    let split = FleetMath.summaries(accounts: [pro, team], now: now, byPlan: true) { $0.accountLabel }
    expect(split.map { FleetMath.planWeight(of: $0, accounts: [pro, team])?.value } == [10, 1]
               && split.first.flatMap { FleetMath.planWeight(of: $0, accounts: [pro, team])?.source }
               == .announced,
           "B-4685 a split summary's multiple is its plan's (Pro 200 = 10 announced, Team = 1)")
    expect(FleetMath.summaries(accounts: [pro, team], now: now) { $0.accountLabel }
               .first.flatMap { FleetMath.planWeight(of: $0, accounts: [pro, team]) } == nil,
           "B-4685 a summary spanning plans has no single multiple")

    // The hover (A6).
    let summary = FleetMath.summaries(accounts: [pro, team], now: now) { $0.accountLabel }
    let model = summary.first.flatMap { FleetTooltip.model($0, displayed: $0.pools) }
    expect(model?.unitsRemaining == 217 && model?.capacity == 1100 && model?.weightUnknown == false
               && model?.poolAccountCount == 2,
           "B-4685 hover: 217 of 1100 units, 2 accounts")

    // Burn rate (A4/A5): Pro 200 spends 10 points, Team 10 points -> 110 units, not 20.
    func rows(_ account: String, from: Double, to: Double) -> [UsageHistory.Sample] {
        [sample(account, provider: "codex", tsHoursAgo: 10, used: from),
         sample(account, provider: "codex", tsHoursAgo: 0, used: to)]
    }
    let samples = rows("codex1", from: 50, to: 60) + rows("codex2", from: 5, to: 15)
    let lookup = FleetMath.weightLookup(accounts: [pro, team])
    let weighted = FleetForecast.weeklyRates(samples: samples, now: now, poolWeights: lookup)
    expect(weighted["codex|weeklyAll"].map { abs($0.perHour - 11) < 1e-9 } == true,
           "B-4685 pace: 10 pts of Pro 200 + 10 pts of Team = 110 units / 10h")
    let plain = FleetForecast.weeklyRates(samples: samples, now: now)
    expect(plain["codex|weeklyAll"].map { abs($0.perHour - 2) < 1e-9 } == true,
           "B-4685 pace without weights is the old unweighted sum")
    let planned = FleetForecast.weeklyRates(samples: samples, now: now,
                                            planOf: { $0 == "codex1" ? "pro 200" : "team" },
                                            poolWeights: lookup)
    expect(planned["codex|weeklyAll|plan=pro 200"].map { abs($0.perHour - 1) < 1e-9 } == true
               && planned["codex|weeklyAll|plan=team"].map { abs($0.perHour - 1) < 1e-9 } == true,
           "B-4685 pace: a plan's own key is never weighted")
    let unknownLookup = FleetMath.weightLookup(accounts: [pro, premium])
    let noRate = FleetForecast.weeklyRates(samples: rows("codex1", from: 50, to: 60)
                                               + rows("codex3", from: 5, to: 15),
                                           now: now,
                                           planOf: { $0 == "codex1" ? "pro 200" : "premium" },
                                           poolWeights: unknownLookup)
    expect(noRate["codex|weeklyAll"] == nil && noRate["codex|weeklyAll|plan=pro 200"] != nil,
           "B-4685 pace: unknown weights leave the provider-wide key unmeasured, plan keys stay")
    let alike = FleetForecast.weeklyRates(
        samples: rows("a", from: 0, to: 10) + rows("b", from: 0, to: 20), now: now,
        poolWeights: FleetMath.weightLookup(accounts: [
            seat("a", "Pro 200", key: "pro", used: 1, resetIn: 5),
            seat("b", "Pro 200", key: "pro", used: 1, resetIn: 5)]))
    expect(alike["codex|weeklyAll"].map { abs($0.perHour - 3) < 1e-9 } == true,
           "B-4685 pace: one plan on every account paces exactly as before")

    // Samples cover only the heavy plan (the light plan sat unchanged for the whole lookback): the
    // pool is still weighed by its full membership, so Pro 200's 10 points are 100 units / 10h.
    let heavyOnly = FleetForecast.weeklyRates(samples: rows("codex1", from: 40, to: 50), now: now,
                                              poolWeights: lookup)
    expect(heavyOnly["codex|weeklyAll"].map { abs($0.perHour - 10) < 1e-9 } == true,
           "B-4685 pace: a heavy plan with samples next to a light plan with none is still weighted")

    // Unknown weights are neither published nor notified (UsageStore cannot compile standalone, so
    // the guards are pinned in source).
    let publishing = (try? String(contentsOfFile: "Tally/Stores/UsageStorePublishing.swift",
                                  encoding: .utf8)) ?? ""
    expect(publishing.components(separatedBy: "!pool.weightUnknown").count == 3,
           "B-4685 the snapshot and the dry-pool notifier both skip a weightUnknown pool")

    // Dryness: 217 units, 11 units an hour, the Pro 200 reset refilling 880 in 6.5h.
    if let pair {
        let dry = FleetForecast.depletion(
            remaining: pair.totalRemaining, refills: pair.refills.map { ($0.at, $0.gain) },
            perHour: 11, steadyRefillPerHour: pair.steadyRefillPerHour(windowHours: 168), now: now)
        expect(dry == nil || dry! > now.addingTimeInterval(6.5 * 3_600),
               "B-4685 the weighted refill carries the pool past the Pro 200 reset")
    }

    // The raw planType and how it reads (C3).
    expect(CodexPlan.displayName(planType: "prolite") == "Pro 100"
               && CodexPlan.displayName(planType: "pro") == "Pro 200"
               && CodexPlan.displayName(planType: "promax") == "Pro 500"
               && CodexPlan.displayName(planType: " Plus ") == "Plus"
               && CodexPlan.displayName(planType: "team") == "Team"
               && CodexPlan.displayName(planType: "self_serve_business_prolite")
               == "Self Serve Business Prolite"
               && CodexPlan.displayName(planType: "") == nil && CodexPlan.displayName(planType: nil) == nil,
           "B-4685 Codex plan codes read as the official tier names")
    expect(CodexPlan.key(planType: " ProLite ") == "prolite" && CodexPlan.key(planType: "  ") == nil,
           "B-4685 the plan key is the trimmed lower-case code")
}
