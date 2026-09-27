import Foundation

// Plan-split assertions (FleetMath byPlan, planTiers, plan rate keys), called from main.swift.
func runPlanSplitTests() {
    // MARK: Split by plan (FleetMath byPlan)

    func planned(_ id: String, provider: String = "codex", plan: String?,
                 metrics: [UsageMetric]) -> AccountUsage {
        AccountUsage(id: id, providerID: provider, accountLabel: id, planName: plan,
                     metrics: metrics, refreshedAt: now)
    }

    func split(_ accounts: [AccountUsage], minMembers: Int = 2) -> [FleetSummary] {
        FleetMath.summaries(accounts: accounts, now: now, minMembers: minMembers, byPlan: true) {
            $0.accountLabel
        }
    }

    let proTeam = [
        planned("pro", plan: "Pro", metrics: [metric(.weeklyAll, used: 20, resetIn: 5 * 86_400)]),
        planned("team", plan: "Team", metrics: [metric(.weeklyAll, used: 98, resetIn: 6 * 86_400)]),
    ]

    // 19a. The owner's sample: Pro at 80% left and Team at 2% left are two pools, never one 41%.
    do {
        let s = split(proTeam)
        expect(s.count == 2 && s[0].planTier?.name == "Pro" && s[1].planTier?.name == "Team",
               "two plans give two summaries, Pro then Team")
        expect(s.first?.headline?.averageRemaining == 80 && s.last?.headline?.averageRemaining == 2,
               "each plan's headline holds only its own account")
        let averages = s.flatMap(\.pools).map(\.averageRemaining)
        expect(!averages.contains { $0 > 2 && $0 < 80 }, "no cross-plan average (no 41%)")
    }

    // 19b. Each plan's refills, count and steady refill are its own.
    do {
        let s = split(proTeam)
        expect(s.count == 2
               && s[0].headline?.refills.allSatisfy { $0.accountLabel == "pro" } == true
               && s[1].headline?.refills.allSatisfy { $0.accountLabel == "team" } == true,
               "refills stay inside their plan")
        expect(s.allSatisfy { $0.accountCount == 1 }, "each plan counts one account")
        expect(s.allSatisfy { $0.headline.map { abs($0.steadyRefillPerHour(windowHours: 168) - 100.0 / 168) < 1e-9 } == true },
               "steady refill is one account's budget per plan")
    }

    // 19c. The demo shape: three Pro accounts pool equally, the Team account stands alone.
    do {
        let s = split([
            planned("p1", plan: "Pro", metrics: [metric(.weeklyAll, used: 31)]),
            planned("p2", plan: "Pro", metrics: [metric(.weeklyAll, used: 86)]),
            planned("t1", plan: "Team", metrics: [metric(.weeklyAll, used: 38)]),
            planned("p3", plan: "Pro", metrics: [metric(.weeklyAll, used: 17)]),
        ])
        expect(s.count == 2 && s[0].headline?.members.count == 3
               && s[0].headline.map { abs($0.averageRemaining - (69.0 + 14 + 83) / 3) < 1e-9 } == true,
               "Pro pools its three accounts")
        expect(s.count == 2 && s[1].headline?.averageRemaining == 62, "Team pools only itself")
    }

    // 19d-19f. Invariance: without two named plans the split pass equals the plain pass exactly.
    do {
        let same = (1...3).map { i in
            planned("c\(i)", provider: "claude", plan: "Max 20x", metrics: [
                metric(.session, used: Double(10 * i)), metric(.weeklyAll, used: Double(20 * i)),
                metric(.weeklyModel, used: Double(5 * i), model: "Fable 5"),
            ])
        }
        expect(split(same) == summarize(same) && split(same).first?.planTier == nil
               && split(same).first?.id == "claude", "one plan: split equals unsplit")
        let unknown = (1...3).map { i in
            planned("x\(i)", plan: nil, metrics: [metric(.weeklyAll, used: Double(30 * i))])
        }
        expect(split(unknown) == summarize(unknown), "no plan names: split equals unsplit")
        let partial = [
            planned("a", plan: "Pro", metrics: [metric(.weeklyAll, used: 10)]),
            planned("b", plan: nil, metrics: [metric(.weeklyAll, used: 50)]),
            planned("c", plan: "Pro", metrics: [metric(.weeklyAll, used: 70)]),
        ]
        expect(split(partial) == summarize(partial), "one name plus unknown: split equals unsplit")
    }

    // 19g. Three named plans plus an unknown: named plans in display order, unknown last.
    do {
        let s = split([
            planned("a", plan: "Plus", metrics: [metric(.weeklyAll, used: 10)]),
            planned("b", plan: nil, metrics: [metric(.weeklyAll, used: 20)]),
            planned("c", plan: "Pro", metrics: [metric(.weeklyAll, used: 30)]),
            planned("d", plan: "Team", metrics: [metric(.weeklyAll, used: 40)]),
        ])
        expect(s.map { $0.planTier?.name ?? "nil" } == ["Plus", "Pro", "Team", "nil"],
               "order Plus, Pro, Team, unknown")
        expect(s.count == 4 && s[3].planTier != nil && s[3].planTier?.name == nil
               && s[3].id == "codex|plan=?", "unknown plan is its own tier with a stable id")
    }

    // 19h. Model pools form inside each plan.
    do {
        let s = split([
            planned("m5", provider: "claude", plan: "Max 5x",
                    metrics: [metric(.weeklyModel, used: 50, model: "Fable 5")]),
            planned("m20a", provider: "claude", plan: "Max 20x",
                    metrics: [metric(.weeklyModel, used: 10, model: "Fable 5")]),
            planned("m20b", provider: "claude", plan: "Max 20x",
                    metrics: [metric(.weeklyModel, used: 30, model: "Fable 5")]),
        ])
        expect(s.count == 2 && s.allSatisfy { $0.modelPoolNames == ["Fable 5"] },
               "each plan has its own Fable 5 pool")
        expect(s.count == 2 && s[0].headline?.averageRemaining == 50
               && s[1].headline?.averageRemaining == 80, "5x at 50, 20x at 80")
    }

    // 19i. The provider gate still needs minMembers accounts; one plan alone never splits.
    do {
        let one = [planned("p", plan: "Pro", metrics: [metric(.weeklyAll, used: 10)])]
        expect(split(one).isEmpty, "one account: no fleet")
        expect(split(one, minMembers: 1).count == 1 && split(one, minMembers: 1)[0].planTier == nil,
               "one account at minMembers 1: one unsplit summary")
    }

    // 19j. An account without metrics takes no part in the split decision.
    do {
        let x = [
            planned("p1", plan: "Pro", metrics: [metric(.weeklyAll, used: 10)]),
            planned("p2", plan: "Pro", metrics: [metric(.weeklyAll, used: 30)]),
            planned("t", plan: "Team", metrics: []),
        ]
        expect(split(x) == summarize(x), "failed Team read: no split")
    }

    // 19k. The menu bar threshold and the panel threshold agree once split.
    do {
        expect(split(proTeam, minMembers: 1) == split(proTeam), "minMembers 1 equals 2 when split")
    }

    // 19l. Providers keep their order; an unsplit provider beside a split one is unchanged.
    do {
        let claude = [
            planned("c1", provider: "claude", plan: "Max 20x", metrics: [metric(.weeklyAll, used: 10)]),
            planned("c2", provider: "claude", plan: "Max 20x", metrics: [metric(.weeklyAll, used: 30)]),
        ]
        let s = split(claude + proTeam)
        expect(s.map(\.id) == ["claude", "codex|plan=pro", "codex|plan=team"], "claude, Pro, Team")
        expect(s.first == summarize(claude + proTeam).first, "claude summary is untouched")
    }

    // 20a. planTiers names only the accounts of a provider that splits.
    do {
        expect(FleetMath.planTiers(accounts: proTeam)
               == ["pro": FleetSummary.Tier(name: "Pro"), "team": FleetSummary.Tier(name: "Team")],
               "planTiers maps each split account to its plan")
        let same = [
            planned("c1", provider: "claude", plan: "Max 20x", metrics: [metric(.weeklyAll, used: 10)]),
            planned("c2", provider: "claude", plan: "Max 20x", metrics: [metric(.weeklyAll, used: 30)]),
        ]
        expect(FleetMath.planTiers(accounts: same).isEmpty, "one plan: no tiers")
    }

    // 20b. rateKey keeps its old strings and gains a plan suffix only on request.
    do {
        expect(FleetForecast.rateKey(provider: "codex", window: "weeklyAll", model: nil)
               == "codex|weeklyAll", "provider-wide key unchanged")
        expect(FleetForecast.rateKey(provider: "codex", window: "weeklyAll", model: nil, plan: "pro")
               == "codex|weeklyAll|plan=pro", "plan key suffix")
    }

    // 20c. Plan keys add per-plan pace without touching the provider-wide keys.
    do {
        let rows = [
            sample("a", tsHoursAgo: 10, used: 10), sample("a", tsHoursAgo: 0, used: 30),
            sample("b", tsHoursAgo: 10, used: 50), sample("b", tsHoursAgo: 0, used: 60),
        ]
        let plain = FleetForecast.weeklyRates(samples: rows, now: now)
        let planned = FleetForecast.weeklyRates(samples: rows, now: now,
                                                planOf: { $0 == "a" ? "pro" : "team" })
        expect(planned.filter { !$0.key.contains("|plan=") } == plain, "provider-wide rates unchanged")
        expect(planned["claude|weeklyAll|plan=pro"].map { abs($0.perHour - 2) < 1e-9 } == true
               && planned["claude|weeklyAll|plan=team"].map { abs($0.perHour - 1) < 1e-9 } == true,
               "each plan's pace is its own accounts' spending")
    }
}
