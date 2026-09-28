import Foundation

// Assertion harness for AdvisorConclusion, compiled against the real source. The one hard rule:
// while any plan's pool is forecast to run dry, the advisor row never says "enough".

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

typealias Tier = AdvisorConclusion.Tier
func tier(_ plan: String?, _ demand: Double, _ owned: Int, dry: Bool) -> Tier {
    Tier(plan: plan, demandPerWeek: demand, accountCount: owned, runsDry: dry)
}
func decide(_ verdict: UsageAdvisor.Verdict, _ days: Double, _ tiers: [Tier],
            split: Bool) -> AdvisorConclusion {
    AdvisorConclusion.decide(verdict: verdict, daysOfData: days, tiers: tiers, split: split)
}

// T1: the demo Codex fleet, sufficient on the pooled four weeks while the Team pool runs dry.
check("T1 demo Codex names the short plan",
      decide(.sufficient, 14, [tier("Pro", 1.7, 3, dry: false), tier("Team", 0.9, 1, dry: true)],
             split: true) == .shortAtPace(plans: ["Team"]))
// T2: the demo Claude fleet, 5.8 account-weeks over 5 accounts.
check("T2 demo Claude asks for one more",
      decide(.addAccount, 14, [tier(nil, 5.8, 5, dry: true)], split: false) == .add(count: 1, plan: nil))
// T3: split and nothing dry, the tier most over its own capacity is named.
check("T3 split add names the tightest tier",
      decide(.addAccount, 14, [tier("Pro", 1.7, 3, dry: false), tier("Team", 0.9, 1, dry: false)],
             split: true) == .add(count: 1, plan: "Team"))
// T4: a dry tier wins over a tighter one that still lasts.
check("T4 split add prefers the dry tier",
      decide(.addAccount, 14, [tier("Pro", 1.7, 3, dry: true), tier("Team", 0.9, 1, dry: false)],
             split: true) == .add(count: 1, plan: "Pro"))
check("T5 sufficient and nothing dry reads enough",
      decide(.sufficient, 14, [tier(nil, 2.0, 4, dry: false)], split: false) == .enough)
check("T6 collecting 5.2 days leaves 2",
      decide(.collecting, 5.2, [tier(nil, 1, 2, dry: false)], split: false) == .collecting(daysLeft: 2))
check("T6 collecting 6.4 days leaves 1",
      decide(.collecting, 6.4, [tier(nil, 1, 2, dry: false)], split: false) == .collecting(daysLeft: 1))
check("T6 collecting 6.99 days leaves 1",
      decide(.collecting, 6.99, [tier(nil, 1, 2, dry: false)], split: false) == .collecting(daysLeft: 1))
check("T7 a dry pool overrides collecting",
      decide(.collecting, 3, [tier(nil, 1, 2, dry: true)], split: false) == .shortAtPace(plans: []))
check("T8 every tier dry names none",
      decide(.sufficient, 14, [tier("Pro", 1, 3, dry: true), tier("Team", 1, 1, dry: true)],
             split: true) == .shortAtPace(plans: []))

// T9: exhaustive consistency, any dry tier means the conclusion is not "enough".
var t9Cases = 0, t9Bad = 0
for verdict in [UsageAdvisor.Verdict.collecting, .sufficient, .addAccount] {
    for days in [3.0, 14.0] {
        for a in [false, true] {
            let single = [tier(nil, 1.5, 2, dry: a)]
            t9Cases += 1
            if a, decide(verdict, days, single, split: false) == .enough { t9Bad += 1 }
            for b in [false, true] {
                let pair = [tier("Pro", 1.7, 3, dry: a), tier("Team", 0.9, 1, dry: b)]
                t9Cases += 1
                if a || b, decide(verdict, days, pair, split: true) == .enough { t9Bad += 1 }
            }
        }
    }
}
check("T9 no dry combination reads enough (\(t9Cases) cases)", t9Bad == 0 && t9Cases == 36)

check("T10 empty tiers add does not crash", decide(.addAccount, 14, [], split: false) == .add(count: 1, plan: nil))
check("T10 empty tiers sufficient", decide(.sufficient, 14, [], split: false) == .enough)
check("T10 empty tiers split add does not crash", decide(.addAccount, 14, [], split: true) == .add(count: 1, plan: nil))

check("T11 shortfall 8.2 over 5 is 4", AdvisorConclusion.shortfall(demandPerWeek: 8.2, owned: 5) == 4)
check("T11 shortfall 5.8 over 5 is 1", AdvisorConclusion.shortfall(demandPerWeek: 5.8, owned: 5) == 1)
check("T11 shortfall 0.9 over 1 is 1", AdvisorConclusion.shortfall(demandPerWeek: 0.9, owned: 1) == 1)
check("T11 shortfall 3 over 0 counts owned as 1", AdvisorConclusion.shortfall(demandPerWeek: 3, owned: 0) == 2)

check("T12 an unnamed dry plan is kept as nil",
      decide(.sufficient, 14, [tier("Pro", 1, 3, dry: false), tier(nil, 0, 1, dry: true)],
             split: true) == .shortAtPace(plans: [nil]))

// T14: the join with the gauge's dry pools, then the decision. The failure shape: the gauge draws
// the provider unsplit (one of its named-plan accounts has no metrics) and forecasts that pool dry,
// while the history splits into two named plans. The unsplit pool is every plan's.
typealias Demand = UsageAdvisor.TierDemand
typealias Dry = AdvisorConclusion.DryPool
func join(_ verdict: UsageAdvisor.Verdict, _ demands: [Demand], _ dry: [Dry]) -> AdvisorConclusion {
    AdvisorConclusion.join(verdict: verdict, daysOfData: 20, pooledDemandPerWeek: 3.0,
                           tierDemands: demands, ownedAccounts: 4, dryPools: dry)
}
let proTeam = [Demand(plan: "Pro", demandPerWeek: 2.4, accountCount: 3),
               Demand(plan: "Team", demandPerWeek: 0.6, accountCount: 1)]
let unsplitDry = [Dry(byPlan: false, plan: nil, accountCount: 3)]
check("T14 unsplit dry pool under split history is not enough",
      join(.sufficient, proTeam, unsplitDry) != .enough)
check("T14 unsplit dry pool marks every tier short",
      join(.sufficient, proTeam, unsplitDry) == .shortAtPace(plans: []))
check("T14 unsplit dry pool under split history, add names a plan",
      join(.addAccount, proTeam, unsplitDry) == .add(count: 1, plan: "Pro"))
check("T14 split history, nothing dry reads enough", join(.sufficient, proTeam, []) == .enough)
check("T14 split history, one plan's pool dry names it",
      join(.sufficient, proTeam, [Dry(byPlan: true, plan: "team", accountCount: 1)])
        == .shortAtPace(plans: ["Team"]))
check("T14 gauge-only plan still counts",
      join(.sufficient, proTeam, [Dry(byPlan: true, plan: "Max", accountCount: 1)])
        == .shortAtPace(plans: ["Max"]))
check("T14 unsplit history and unsplit dry pool",
      join(.sufficient, [Demand(plan: "Pro", demandPerWeek: 3, accountCount: 4)], unsplitDry)
        == .shortAtPace(plans: []))
check("T14 unsplit history, nothing dry reads enough",
      join(.sufficient, [Demand(plan: "Pro", demandPerWeek: 3, accountCount: 4)], []) == .enough)

// T13: source locks. The row goes through the one decision, and the gauge's forecast line reads
// the shared dry predicate instead of calling the forecast math a second time.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}
let advisor = source("Tally/Views/AdvisorStripView.swift")
check("T13 advisor source readable", !advisor.isEmpty)
check("T13 row decides through AdvisorConclusion.join", advisor.contains("AdvisorConclusion.join("))
check("T13 no pips", !advisor.contains("demandPips("))
check("T13 no click-to-cycle window", !advisor.contains("cycleAdvisorWindow"))
var rowBody = ""
if let start = advisor.range(of: "private func advisorRow") {
    let rest = advisor[start.upperBound...]
    rowBody = String(rest[..<(rest.range(of: "    private ")?.lowerBound ?? rest.endIndex)])
}
check("T13 advisorRow found", !rowBody.isEmpty)
// The window ladder is on the panel, not only in the hover (2026-09-28: hiding it lost the figures).
check("T13 row shows the window ladder", rowBody.contains("Text(ladder)") && rowBody.contains("ladderLine(reading)"))
let fleet = source("Tally/Views/FleetStripView.swift")
var phraseBody = ""
if let start = fleet.range(of: "private func forecastPhrase") {
    let rest = fleet[start.upperBound...]
    let ends = ["    /// ", "    private func"].compactMap { rest.range(of: $0)?.lowerBound }
    phraseBody = String(rest[..<(ends.min() ?? rest.endIndex)])
}
check("T13 forecastPhrase found", !phraseBody.isEmpty)
check("T13 forecastPhrase reads poolDryDate", phraseBody.contains("poolDryDate("))
check("T13 forecastPhrase does not call depletion itself", !phraseBody.contains("FleetForecast.depletion("))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
