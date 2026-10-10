import Foundation

// Twin of tests/smartpick/sharedloginchecks.swift on the badge (jettoai/tally#6): two config homes on
// one Claude login. The duplicate row (AM, re-signed into GM's account) is shaped the way the refresh
// publishes it: an error, no numbers, `sameAccountAs` = GM, and no launch home.
@MainActor
func runSharedLoginBadgeChecks() {
    let policy = LaunchPolicyStore.shared
    let now = Date()
    func account(_ id: String, weekly: Double, resetHours: Double) -> AccountUsage {
        AccountUsage(
            id: id, providerID: "claude", accountLabel: id, planName: "Max 20x", accountEmail: nil,
            metrics: [
                UsageMetric(id: "session", kind: .session, label: "Session", modelName: nil,
                            usedPercent: 0, severity: .normal, resetsAt: nil, isActive: false),
                UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly", modelName: nil,
                            usedPercent: 100 - weekly, severity: .normal,
                            resetsAt: now.addingTimeInterval(resetHours * 3600), isActive: false),
            ],
            refreshedAt: now)
    }
    func duplicate(_ id: String, of kept: String) -> AccountUsage {
        var row = AccountUsage(id: id, providerID: "claude", accountLabel: id, planName: "Max 20x",
                               accountEmail: nil, metrics: [], refreshedAt: now,
                               error: "\(id) and \(kept) are signed into the same Claude account")
        row.sameAccountAs = kept
        return row
    }
    func pick(_ accounts: [AccountUsage], _ occupancy: [String: Int]?,
              launchable: Set<String>? = nil) -> String? {
        policy.autoPickID(providerID: "claude", accounts: accounts,
                          launchable: launchable ?? Set(accounts.filter { $0.sameAccountAs == nil }.map(\.id)),
                          reserves: [:], quarantined: [], occupancy: occupancy, now: now)
    }
    let am = duplicate("AM", of: "GM")
    let gm = account("GM", weekly: 98, resetHours: 150)
    check("B1 the duplicate never carries the badge, even if it were launchable",
          pick([am, gm], [:], launchable: ["AM", "GM"]) == "GM")
    let thinGM = account("GM", weekly: 7, resetHours: 3.47)
    let healthy = account("X", weekly: 100, resetHours: 150)
    let fleet = [am, thinGM, healthy]
    check("B2 premise: an empty thin GM carries the badge", pick(fleet, [:]) == "GM")
    check("B2 two sessions in AM's home count on GM: the badge moves to X", pick(fleet, ["AM": 2]) == "X")
    check("B2 …one is still under the cap", pick(fleet, ["AM": 1]) == "GM")
    check("B2 …and split across the two homes they add up", pick(fleet, ["AM": 1, "GM": 1]) == "X")
    check("B2b occupancy not read: full", pick(fleet, nil) == "X")
    check("A2 the advisor's seat rule leaves the duplicate out",
          Set(fleet.filter { SharedLogin.isSeat($0.sameAccountAs) }.map(\.id)) == ["GM", "X"])
}
