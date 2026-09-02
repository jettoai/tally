import Foundation

/// The usage advisor's half of a refresh: read the recorded burn history and hand the pure engine
/// (TallyCLI/UsageAdvisor.swift) the three things it cannot learn from a sample - which plan each
/// account is on, what its owner keeps for themselves, and which accounts still exist.
///
/// Split out of UsageStore for file size, and it earns the seam: everything here is about joining
/// live facts onto a file the refresh path otherwise never touches.
@MainActor
extension UsageStore {
    /// Recompute the advisor's readings off the main actor and publish them when they land.
    ///
    /// `known` is every account this machine has, dormant ones included - the reserve join needs a
    /// config home and a signed-out account still has one. `accounts` (the rows on screen) is the
    /// LIVE fleet, which is a different question and gets a different answer below.
    func recomputeAdvisor(known: [ProviderAccount], now: Date) {
        // Which plan each account is on, for the advisor's tier split. Taken from the live rows
        // here on the main actor rather than inside the read below, which runs on the history
        // queue; a plain dictionary is what can cross to it.
        let plans = Dictionary(accounts.compactMap { usage in usage.planName.map { (usage.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        // AND WHAT EACH ACCOUNT'S OWNER KEEPS FOR THEMSELVES, on exactly the same terms. The engine
        // has always taken a reserve lookup and the CLI has always passed one (StatusReport.swift);
        // this surface passed nothing, so the panel answered "do these accounts cover the demand"
        // about quota Tally is not allowed to spend, and could read `sufficient` on a fleet the CLI
        // was already telling to buy a seat (2026-09-02).
        let reserves = Dictionary(known.compactMap { account -> (String, Double)? in
            guard let home = account.launchHome else { return nil }
            let reserve = LaunchPolicyStore.shared.reserve(home: home)
            return reserve > 0 ? (account.id, Double(reserve)) : nil
        }, uniquingKeysWith: { first, _ in first })
        // The fleet AS IT IS NOW. The history remembers an account for four weeks after it is
        // removed, and every one of those days it is a seat of capacity nobody has, a pip nobody
        // owns, and a member of the starvation intersection that can never starve - so a fleet that
        // just lost a quarter of itself reads as comfortable. The same rows the strip draws its
        // pips from, so the two surfaces cannot disagree about how many accounts there are.
        let live = Set(accounts.map(\.id))
        UsageHistory.shared.samples(
            since: now.addingTimeInterval(-UsageAdvisor.lookbackDays * 86_400)) { samples in
            let advisorSamples = samples.map {
                UsageAdvisor.Sample(ts: $0.ts, account: $0.account, provider: $0.provider,
                                    window: $0.window, model: $0.model, used: $0.used,
                                    resetAt: $0.resetAt)
            }
            let readings = UsageAdvisor.readings(samples: advisorSamples, now: now,
                                                 planOf: { plans[$0] },
                                                 reserveOf: { reserves[$0] ?? 0 },
                                                 liveAccounts: live)
            Task { @MainActor in
                UsageStore.shared.publishAdvisorReadings(readings)
            }
        }
    }
}
