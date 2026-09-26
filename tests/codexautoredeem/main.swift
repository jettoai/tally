import Foundation

// Assertion harness for the automatic Codex redeem decision (Tally/Core/CodexAutoRedeem.swift),
// compiled with the account types and the reset-cycle key it reads. Foundation only.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let day: TimeInterval = 86_400
let windowEnd = t0.addingTimeInterval(3 * day)

func usage(id: String = "codex:a", provider: String = "codex", weeklyUsed: Double? = 100,
           resetsAt: Date? = windowEnd, sessionUsed: Double? = nil,
           credits: Int? = 1, status: String? = "available",
           error: String? = nil, lastRefreshFailed: Bool = false,
           isStale: Bool = false) -> AccountUsage {
    var metrics: [UsageMetric] = []
    if let weeklyUsed {
        metrics.append(UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly",
                                   modelName: nil, usedPercent: weeklyUsed,
                                   severity: .fromUsedPercent(weeklyUsed), resetsAt: resetsAt,
                                   isActive: false))
    }
    if let sessionUsed {
        metrics.append(UsageMetric(id: "session", kind: .session, label: "5h", modelName: nil,
                                   usedPercent: sessionUsed,
                                   severity: .fromUsedPercent(sessionUsed),
                                   resetsAt: t0.addingTimeInterval(3_600), isActive: false))
    }
    var u = AccountUsage(id: id, providerID: provider, accountLabel: id, planName: nil,
                         metrics: metrics, refreshedAt: t0, error: error,
                         resetCreditsAvailable: credits,
                         resetCredits: [BankedResetCredit(id: "c1", resetType: "codexRateLimits",
                                                          status: status,
                                                          expiresAt: t0.addingTimeInterval(2 * day))])
    u.lastRefreshFailed = lastRefreshFailed
    u.isStale = isStale
    return u
}

func decide(_ accounts: [AccountUsage], state: CodexAutoRedeemState = CodexAutoRedeemState(),
            enabled: Bool = true, isUnshipped: Bool = false, isDemo: Bool = false,
            inFlight: Set<String> = [], now: Date = t0)
    -> (state: CodexAutoRedeemState, redeem: [String]) {
    CodexAutoRedeemLogic.decide(state: state, accounts: accounts, enabled: enabled,
                                isUnshipped: isUnshipped, isDemo: isDemo, inFlight: inFlight,
                                now: now)
}

func entry(_ key: Date = windowEnd, at: Date, outcome: String = "redeemed")
    -> CodexAutoRedeemState {
    CodexAutoRedeemState(accounts: ["codex:a": CodexAutoRedeemAccountState(
        cycleKey: DryPoolLogic.resetKey(key)!, attemptedAt: at, outcome: outcome)])
}

// 1
let r1 = decide([usage()])
expect(r1.redeem == ["codex:a"], "1 weekly empty with a credit redeems")
expect(r1.state.accounts["codex:a"]?.cycleKey == DryPoolLogic.resetKey(windowEnd)
       && r1.state.accounts["codex:a"]?.outcome == "pending",
       "1 the attempt is recorded before the redeem, keyed on the weekly window")
// 2
expect(decide([usage(weeklyUsed: 99)]).redeem.isEmpty, "2 one percent left is not a wall")
// 3
expect(decide([usage(credits: 0)]).redeem.isEmpty, "3 no credit, nothing to spend")
expect(decide([usage(credits: nil)]).redeem.isEmpty, "3 unreported credit count, nothing to spend")
// 4
expect(decide([usage()], state: entry(at: t0.addingTimeInterval(-3_600))).redeem.isEmpty,
       "4 same window already redeemed: spent numbers during propagation do not redeem again")
// 5
let failed = entry(at: t0, outcome: "failed")
expect(decide([usage()], state: failed, now: t0.addingTimeInterval(7_200)).redeem.isEmpty,
       "5 a failed attempt is not retried on the same window")
// 6
let r6 = decide([usage()], isUnshipped: true)
expect(r6.redeem.isEmpty && r6.state.accounts.isEmpty, "6 unshipped build never redeems or marks")
// 7
expect(decide([usage()], isDemo: true).redeem.isEmpty, "7 demo mode never redeems")
expect(decide([usage()], enabled: false).redeem.isEmpty, "7 switched off never redeems")
// 8
let kept = entry(at: t0.addingTimeInterval(-3 * 3_600))
let r8 = decide([usage(weeklyUsed: 0, lastRefreshFailed: true)], state: kept)
expect(decide([usage(lastRefreshFailed: true)]).redeem.isEmpty,
       "8 held-over 100% from a failed poll is not a reading")
expect(r8.state == kept, "8 a round that did not read keeps the memory exactly as it was")
// 9
expect(decide([usage(isStale: true)]).redeem.isEmpty, "9 stale numbers are not a reading")
expect(decide([usage(error: "boom")]).redeem.isEmpty, "9 an errored account is not a reading")
// 10
expect(decide([usage()], inFlight: ["codex:a"]).redeem.isEmpty, "10 a redeem already in flight")
// 11
expect(decide([usage(status: "redeeming")]).redeem.isEmpty, "11 a credit already redeeming")
// 12
expect(decide([usage(weeklyUsed: nil, sessionUsed: 100)]).redeem.isEmpty,
       "12 no weekly window (only a full session) does not trigger")
// 13
let r13a = decide([usage(weeklyUsed: 50)], state: entry(at: t0.addingTimeInterval(-20 * 60)))
expect(r13a.state.accounts.isEmpty, "13 recovered past the cooldown clears the memory")
let r13b = decide([usage()], state: r13a.state, now: t0.addingTimeInterval(60))
expect(r13b.redeem == ["codex:a"], "13 the next wall in the same window redeems again")
// 14
let r14a = decide([usage(weeklyUsed: 0)], state: entry(at: t0.addingTimeInterval(-5 * 60)))
expect(r14a.state.accounts["codex:a"] != nil, "14 recovered inside the cooldown keeps the memory")
expect(decide([usage()], state: r14a.state).redeem.isEmpty,
       "14 a stale 0% right after a redeem does not spend a second credit")
// 15
let old = entry(t0.addingTimeInterval(-4 * day), at: t0.addingTimeInterval(-5 * day))
expect(decide([usage()], state: old).redeem == ["codex:a"],
       "15 a new weekly window redeems even though the last one was answered")
// 16
expect(decide([usage(resetsAt: windowEnd.addingTimeInterval(120))],
              state: entry(at: t0.addingTimeInterval(-3_600))).redeem.isEmpty,
       "16 two minutes of reset-time drift is the same window")
// 17
let two = decide([usage(id: "codex:b"), usage(id: "codex:a")])
expect(two.redeem == ["codex:a", "codex:b"], "17 two accounts at 0% each redeem, stable order")
// 18
expect(decide([usage(id: "claude:x", provider: "claude")]).redeem.isEmpty,
       "18 a Claude account is not this path's business")
// 19
let ancient = CodexAutoRedeemState(accounts: ["codex:z": CodexAutoRedeemAccountState(
    cycleKey: "1", attemptedAt: t0.addingTimeInterval(-9 * day), outcome: "redeemed")])
expect(decide([], state: ancient).state.accounts.isEmpty, "19 memory older than 8 days is pruned")
// 20
func settle(_ outcome: String, _ state: CodexAutoRedeemState, now: Date = t0,
            _ u: AccountUsage = usage()) -> CodexAutoRedeemState {
    CodexAutoRedeemLogic.settle(outcome: outcome, usage: u, in: state, now: now)
}
let autoFailed = settle("failed", entry(at: t0, outcome: "pending"), now: t0.addingTimeInterval(30))
expect(autoFailed.accounts["codex:a"]?.outcome == "failed"
       && autoFailed.accounts["codex:a"]?.attemptedAt == t0
       && autoFailed.accounts["codex:a"]?.cycleKey == DryPoolLogic.resetKey(windowEnd),
       "20 an attempt that spent nothing changes only the outcome, so it still blocks its wall")
expect(settle("failed", CodexAutoRedeemState()).accounts.isEmpty,
       "20 a manual redeem that spent nothing leaves the automatic path free")
expect(decide([usage()], state: settle("noCredit", CodexAutoRedeemState())).redeem == ["codex:a"],
       "20 ... and the automatic path still answers the wall")
let spent = settle("redeemed", entry(t0.addingTimeInterval(-4 * day), at: t0.addingTimeInterval(-5 * day)))
expect(spent.accounts["codex:a"]?.cycleKey == DryPoolLogic.resetKey(windowEnd)
       && spent.accounts["codex:a"]?.attemptedAt == t0,
       "20 a spent credit rewrites the entry for this wall and restarts the cooldown")
// 21
expect(CodexAutoRedeemLogic.silencesDrainedHint(isDrained: true, accountID: "a", claimed: ["a"]),
       "21 drained hint for a claimed account is silenced")
expect(!CodexAutoRedeemLogic.silencesDrainedHint(isDrained: true, accountID: "b", claimed: ["a"]),
       "21 drained hint for another account still speaks")
expect(!CodexAutoRedeemLogic.silencesDrainedHint(isDrained: false, accountID: "a", claimed: ["a"]),
       "21 an expiry hint is never silenced")
// 22 The review's failure sample: two credits, the user redeems by hand, and the refreshes right
// behind it still report the spent 0% while the provider catches up.
let twoCredits = usage(credits: 2)
expect(decide([twoCredits], inFlight: ["codex:a"]).redeem.isEmpty,
       "22 a manual redeem still on the wire blocks the automatic one")
for outcome in ["redeemed", "alreadyUsed"] {
    let afterManual = settle(outcome, CodexAutoRedeemState(), now: t0, twoCredits)
    for lag: TimeInterval in [5, 60, 600] {
        expect(decide([twoCredits], state: afterManual, now: t0.addingTimeInterval(lag)).redeem.isEmpty,
               "22 manual \(outcome), stale 0% \(Int(lag))s later does not spend a second credit")
    }
}
// 23 The reverse order: the automatic redeem spends first, then the user confirms a redeem on the
// same wall while the provider still reports 0%.
func blocks(_ state: CodexAutoRedeemState, _ u: AccountUsage = twoCredits, at: Date) -> Bool {
    CodexAutoRedeemLogic.blocksRedeem(state: state, usage: u, now: at)
}
let autoPending = decide([twoCredits]).state
expect(!blocks(autoPending, at: t0), "23 an automatic attempt still pending does not block by memory")
for outcome in ["redeemed", "alreadyUsed"] {
    let afterAuto = settle(outcome, autoPending, now: t0, twoCredits)
    for lag: TimeInterval in [0, 30, 600] {
        expect(blocks(afterAuto, at: t0.addingTimeInterval(lag)),
               "23 automatic \(outcome), manual \(Int(lag))s later sends no request")
    }
}
// 24 What the block leaves alone: the user's first redeem on a wall, a spend that is past the
// cooldown, a window that has rolled over, and an attempt that spent nothing.
expect(!blocks(CodexAutoRedeemState(), at: t0), "24 first redeem on a wall still spends")
let spentAt0 = settle("redeemed", CodexAutoRedeemState(), now: t0, twoCredits)
expect(!blocks(spentAt0, at: t0.addingTimeInterval(CodexAutoRedeemLogic.rearmCooldown)),
       "24 a spend past the cooldown no longer blocks")
expect(!blocks(spentAt0, usage(resetsAt: windowEnd.addingTimeInterval(7 * day), credits: 2),
               at: t0.addingTimeInterval(60)),
       "24 a new weekly window is a new wall")
expect(!blocks(settle("failed", autoPending, now: t0, twoCredits), at: t0.addingTimeInterval(60)),
       "24 a failed attempt does not block a manual redeem")
expect(blocks(spentAt0, usage(weeklyUsed: nil, credits: 2), at: t0.addingTimeInterval(60)),
       "24 a window the usage cannot name holds the spend back")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
