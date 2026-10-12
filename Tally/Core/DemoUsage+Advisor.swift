import Foundation

/// Fleet burn-rate and advisor fixtures for the demo launch (split out of DemoUsage.swift).
extension DemoUsage {
    /// Fabricated burn rates so the fleet strip's forecast renders in screenshots: Claude spends
    /// faster than its combined refill budget (a concrete "lasts about …"), Codex within it
    /// (the "sustainable" state). Codex mixes Pro and Team, so its gauge splits by plan and each
    /// plan reads its own key. Real instances estimate these from ~/.tally/history.jsonl.
    static var fleetRates: [String: FleetRate] {
        // Keys cover every window the gauge focus can headline, so the forecast renders in demo
        // whichever focus is active (Fable pool by default, weekly when switched).
        ["claude|weeklyModel|fable": FleetRate(perHour: 4.6, sampledHours: 72),
         "claude|weeklyModel|sonnet": FleetRate(perHour: 3.1, sampledHours: 72),
         "claude|weeklyAll": FleetRate(perHour: 4.6, sampledHours: 72),
         // A Claude fleet that mixes plans (-TallyDemoAccounts past five adds a Max 5x seat) splits
         // its gauge by plan, and each plan reads its own key; without these every row there read
         // "still measuring" (B-1570). Both plans last until their refill at these rates.
         "claude|weeklyAll|plan=max 20x": FleetRate(perHour: 2.0, sampledHours: 72),
         "claude|weeklyModel|fable|plan=max 20x": FleetRate(perHour: 2.0, sampledHours: 72),
         "claude|weeklyAll|plan=max 5x": FleetRate(perHour: 0.8, sampledHours: 72),
         "claude|weeklyModel|fable|plan=max 5x": FleetRate(perHour: 0.8, sampledHours: 72),
         "codex|weeklyAll": FleetRate(perHour: 1.4, sampledHours: 72),
         "codex|weeklyAll|plan=pro": FleetRate(perHour: 1.0, sampledHours: 72),
         "codex|weeklyAll|plan=team": FleetRate(perHour: 0.9, sampledHours: 72)].mapValues { FleetRate(perHour: $0.perHour * burnScale, sampledHours: $0.sampledHours) }
    }

    /// Fabricated advisor readings so the advisor strip renders in screenshots too. Real instances
    /// derive these from ~/.tally/history.jsonl, which a demo launch never has, so without fixtures
    /// the strip is simply absent from the shot. The numbers continue the story the gauges above
    /// already tell: the five Claude accounts spend more per week than they refill (the row reads
    /// "add 1 account"), while the four Codex accounts are enough on the four-week average, but
    /// the Team pool's own pace runs it dry before its refill, so the row reads "Team not enough at
    /// this pace".
    static var advisorReadings: [UsageAdvisor.Reading] {
        // 5.8 account-weeks over 5 accounts puts the pool past the 0.9 trigger on its own, and the
        // starved hours cross their 2h/wk trigger too, so both paths to "add an account" agree.
        // The active burn is the same working week seen from each provider: ~580 percent-points a
        // week at 11%/h and ~260 at 5%/h are both about 53 hours of hands-on time.
        //
        // The tier splits mirror the fixture accounts above: five Claude seats on one plan (so the
        // strip shows the pooled figure, the uniform-fleet case), and Codex spread over Pro and
        // Team, which is what puts the per-tier reading on screen. Each split sums to its own
        // pooled demand, the same invariant a real reading keeps.
        // The window ladder the hover lists, built from the same pooled numbers
        // so the demo reads like a real fortnight: a slightly hotter recent week than the month
        // behind it, which is the situation the shorter windows exist for. The 28-day rung IS the
        // pooled figure, exactly as a live reading's is.
        let claudeTiers = [UsageAdvisor.TierDemand(plan: "Max 20x", demandPerWeek: 5.8,
                                                   accountCount: 5)]
        let codexTiers = [UsageAdvisor.TierDemand(plan: "Pro", demandPerWeek: 1.7, accountCount: 3),
                          UsageAdvisor.TierDemand(plan: "Team", demandPerWeek: 0.9, accountCount: 1)]
        func ladder(_ figures: [Double], tiers: [UsageAdvisor.TierDemand]) -> [UsageAdvisor.WindowDemand] {
            zip(UsageAdvisor.displayWindows, figures).map { window, figure in
                let scale = figure / (figures.last ?? figure)
                return UsageAdvisor.WindowDemand(
                    days: window, demandPerWeek: figure,
                    tierDemands: tiers.map { .init(plan: $0.plan,
                                                   demandPerWeek: $0.demandPerWeek * scale,
                                                   accountCount: $0.accountCount) },
                    minimumDays: min(window, UsageAdvisor.minimumDays))
            }
        }
        // These figures are the full fleet's; `rescoped` reads them again for a scoped one.
        let shown = accounts()
        return [UsageAdvisor.Reading(provider: "claude", verdict: .addAccount, demandPerWeek: 5.8,
                                     activeBurnPerHour: 11, starvedHoursPerWeek: 3.4,
                                     daysOfData: 14, accountCount: 5,
                                     tierDemands: claudeTiers,
                                     windowDemands: ladder([6.4, 6.1, 6.0, 5.8], tiers: claudeTiers)),
                UsageAdvisor.Reading(provider: "codex", verdict: .sufficient, demandPerWeek: 2.6,
                                     activeBurnPerHour: 5, starvedHoursPerWeek: 0,
                                     daysOfData: 14, accountCount: 4,
                                     tierDemands: codexTiers,
                                     windowDemands: ladder([3.0, 2.8, 2.7, 2.6], tiers: codexTiers))]
            .compactMap { rescoped($0, shown: shown) }
    }
}
