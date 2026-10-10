import Foundation

// Twin of tests/smartpick/loadchecks.swift L1-L5 on the badge (jettoai/tally#4): same fleet, same
// expected account, so the panel marks the card a launch actually takes.
@MainActor
func runLoadBadgeChecks() {
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
    let fleet = [account("AM", weekly: 100, resetHours: 152.47), account("FP", weekly: 7, resetHours: 16.45),
                 account("FS", weekly: 7, resetHours: 3.47), account("GM", weekly: 100, resetHours: 152.47)]
    func pick(_ accounts: [AccountUsage], _ occupancy: [String: Int]?) -> String? {
        policy.autoPickID(providerID: "claude", accounts: accounts,
                          launchable: Set(accounts.map(\.id)), reserves: [:],
                          quarantined: [], occupancy: occupancy, now: now)
    }
    check("L0 badge premise: no live sessions, the badge sits on FS", pick(fleet, [:]) == "FS")
    check("L1 badge #4: FS carrying 9 sessions is not the badge", pick(fleet, ["FS": 9, "FP": 6]) == "AM")
    check("L3 badge …two is the cap", pick(fleet, ["FS": 2]) == "AM")
    check("L4 badge an unknown count (nil) is full", pick(fleet, nil) == "AM")
    check("L5 badge every account thin and crowded keeps the ranking",
          pick(Array(fleet[1...2]), ["FS": 9, "FP": 6]) == "FS")
}
