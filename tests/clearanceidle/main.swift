import Foundation

// Assertion harness for the B-1395 leftovers alert (Tally/Core/ClearanceIdleAlert.swift), compiled
// with the cycle keys it dedups on (DryPoolLogic.swift) and the clearance rule that decides which
// accounts have leftovers at all (TallyCLI/AccountComfort.swift). 2026-10-10: an account sat at 3%
// of its weekly window two hours before the reset with no session on it, and nobody was told.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let hour: TimeInterval = 3600
func candidate(_ id: String = "claude:.claude", resetIn: TimeInterval = hour) -> ClearanceIdleCandidate {
    ClearanceIdleCandidate(accountID: id, label: id, remaining: 3, resetsAt: now + resetIn)
}
func due(_ c: [ClearanceIdleCandidate], live: [String: Int]? = [:],
         announced: [String: String] = [:]) -> [ClearanceIdleCandidate] {
    ClearanceIdleAlert.due(c, live: live, announced: announced, now: now)
}
let one = candidate()

expect(due([one]) == [one], "C1 3% left, resets in an hour, no session on it: announce")
expect(due([one], live: [one.accountID: 1]).isEmpty, "C2 a live session on it: nothing to say")
expect(due([one], live: nil).isEmpty, "C3 sessions unreadable: say nothing rather than guess")
expect(due([candidate(resetIn: 2 * hour + 60)]).isEmpty, "C4 2h01m out is not soon yet")
let jittered = [one.accountID: DryPoolLogic.resetKey(one.resetsAt + 60)!]
expect(due([one], announced: jittered).isEmpty, "C5 the same cycle a minute of jitter later: once")
let lastWeek = [one.accountID: DryPoolLogic.resetKey(one.resetsAt - 7 * 24 * hour)!]
expect(due([one], announced: lastWeek) == [one], "C6 the next cycle announces again")
expect(due([candidate(resetIn: -60)]).isEmpty, "C7 a reset already past")
let other = candidate("claude:.claude2")
expect(due([one, other], live: [other.accountID: 2]) == [one],
       "C8 a session on another account does not silence this one")

// C9: the leftovers come from the clearance rule itself, so the alert and the launcher agree.
func window(_ remaining: Double, resetIn: TimeInterval, session: Bool) -> ClearanceWindow {
    ClearanceWindow(comfort: ComfortWindow(remaining: remaining, resetsAt: now + resetIn, reserve: 0),
                    resetsAt: now + resetIn, isSession: session)
}
expect(clearanceLeftover([window(3, resetIn: hour, session: false),
                          window(80, resetIn: 3 * hour, session: true)], now: now) != nil,
       "C9 weekly 3% resetting in an hour beside a healthy session window is a clearance account")
expect(clearanceLeftover([window(3, resetIn: hour, session: false),
                          window(2, resetIn: 3 * hour, session: true)], now: now) == nil,
       "C9 with the session window dry too, there is nothing usable to announce")

// R1: both new alerts are routed before the router's catch-all, which presents a redeem dialog.
let router = (try? String(contentsOfFile: "Tally/App/NotificationRouter.swift", encoding: .utf8)) ?? ""
func position(_ needle: String) -> String.Index? { router.range(of: needle)?.lowerBound }
if let redeem = position("RedeemAction.present"),
   let lag = position("== UpdateLagNotifier.categoryID"),
   let idle = position("== ClearanceIdleNotifier.categoryID") {
    expect(lag < redeem && idle < redeem, "R1 both categories are handled before the redeem default")
} else {
    expect(false, "R1 the router branches and its redeem default were all found")
}
expect(router.contains("UpdateLagNotifier.category,") && router.contains("ClearanceIdleNotifier.category]"),
       "R1 both categories are registered")

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all passed")
