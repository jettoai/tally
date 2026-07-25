import Foundation

// Assertion harness for ResetHintLogic (compiled with Tally/Core/ResetHintLogic.swift,
// Tally/Core/DryPoolLogic.swift and Tally/Providers/ProviderModels.swift).

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let cycle1 = now.addingTimeInterval(3 * 86_400)    // this window's reset
let cycle2 = now.addingTimeInterval(10 * 86_400)   // the next window's reset
let soon = now.addingTimeInterval(24 * 3_600)      // a credit expiring inside the horizon
let far = now.addingTimeInterval(10 * 86_400)      // a credit expiring well outside it

func metric(_ id: String, kind: MetricKind = .weeklyAll, remaining: Double,
            resetsAt: Date? = cycle1) -> UsageMetric {
    UsageMetric(id: id, kind: kind, label: id, modelName: nil, usedPercent: 100 - remaining,
                severity: .fromUsedPercent(100 - remaining), resetsAt: resetsAt, isActive: false)
}

func account(_ id: String, label: String? = nil, remaining: Double, credits: Int? = 1,
             expiry: Date? = nil, resetsAt: Date? = cycle1, error: String? = nil,
             metrics: [UsageMetric]? = nil) -> AccountUsage {
    AccountUsage(id: id, providerID: "codex", accountLabel: label ?? id, planName: nil,
                 metrics: metrics ?? [metric("weekly_all", remaining: remaining, resetsAt: resetsAt)],
                 refreshedAt: now, error: error,
                 resetCreditsAvailable: credits, resetCreditsNextExpiry: expiry)
}

func hint(_ accounts: [AccountUsage], state: ResetHintState = ResetHintState())
    -> (ResetHintState, ResetHint?) {
    ResetHintLogic.advance(state: state, accounts: accounts, now: now)
}

// 1. Nothing banked, nothing to say: an account can sit at zero all week without a hint, because
//    there is no action to offer, and an expiry is only news while there is a credit to lose (a
//    redeem spends the credit, and what it leaves behind is this).
do {
    let (state, note) = hint([account("a", remaining: 0, credits: 0)])
    expect(note == nil, "no banked credit does not hint at 0 remaining")
    let (_, none) = hint([account("a", remaining: 0, credits: nil)])
    expect(none == nil, "a provider that does not bank resets never hints")
    let (_, expiring) = hint([account("a", remaining: 0, credits: 0, expiry: soon)])
    expect(expiring == nil, "no credit means no hint, whatever the expiry says")
    expect(state.accounts["a"]?.firedDrained == false, "an unhintable account stays unarmed")
}

// 2. The drained case names the account and carries its reason.
do {
    let (state, note) = hint([account("a", label: "Codex 2", remaining: 0)])
    expect(note?.reason == .drained, "a spent account with a credit hints drained")
    expect(note?.accountID == "a" && note?.accountLabel == "Codex 2", "the hint names the account")
    expect(state.accounts["a"]?.firedDrained == true, "the drained flag is set after firing")
}

// 3. The drained line is 5% remaining, the same line the flagship pool alert calls nearly dry.
do {
    let (_, at) = hint([account("a", remaining: 5)])
    expect(at?.reason == .drained, "5% remaining is drained")
    let (_, above) = hint([account("a", remaining: 6)])
    expect(above == nil, "6% remaining is not drained (and no credit is expiring)")
}

// 4. The expiring case fires well above the drained line, because an expiring credit is nearly
//    free to spend.
do {
    let (state, note) = hint([account("a", remaining: 20, expiry: soon)])
    expect(note?.reason == .expiring, "a credit expiring inside 48h hints on a 20% account")
    expect(note?.creditExpiresAt == soon, "the hint carries the expiry for the body")
    expect(state.accounts["a"]?.firedExpiring == true && state.accounts["a"]?.firedDrained == false,
           "only the expiring flag is spent")
}

// 5. Above the waste line the redeem dialog already calls a redeem mostly wasted, so an expiring
//    credit is not worth waking anyone for.
do {
    let (_, note) = hint([account("a", remaining: 31, expiry: soon)])
    expect(note == nil, "31% remaining is too full to spend an expiring credit on")
    let (_, edge) = hint([account("a", remaining: 30, expiry: soon)])
    expect(edge?.reason == .expiring, "30% remaining is exactly the waste line and still hints")
}

// 6. The 48h horizon.
do {
    let (_, inside) = hint([account("a", remaining: 20,
                                    expiry: now.addingTimeInterval(47 * 3_600))])
    expect(inside?.reason == .expiring, "47h out is inside the horizon")
    let (_, outside) = hint([account("a", remaining: 20,
                                     expiry: now.addingTimeInterval(49 * 3_600))])
    expect(outside == nil, "49h out is not news yet")
    let (_, overdue) = hint([account("a", remaining: 20,
                                     expiry: now.addingTimeInterval(-3_600))])
    expect(overdue?.reason == .expiring, "a credit the server still reports past its expiry is urgent")
}

// 7. Several accounts qualify, one is named: the least wasteful redeem wins.
do {
    let (_, note) = hint([account("a", remaining: 25, expiry: soon),
                          account("b", remaining: 0),
                          account("c", remaining: 12, expiry: soon)])
    expect(note?.accountID == "b", "the emptiest account is the smart pick")
    expect(note?.reason == .drained, "and it is named with its own reason")
}

// 8. A tie on emptiness is broken by the soonest expiry, then by id so the pick is stable.
do {
    let (_, note) = hint([account("a", remaining: 0, expiry: far),
                          account("b", remaining: 0, expiry: soon)])
    expect(note?.accountID == "b", "equally empty accounts are ranked by soonest expiry")
    let (_, stable) = hint([account("b", remaining: 0, expiry: soon),
                            account("a", remaining: 0, expiry: soon)])
    expect(stable?.accountID == "a", "a full tie is broken by id, not by input order")
}

// 9. Ignoring a hint does not mean hearing it on every refresh.
do {
    let accounts = [account("a", remaining: 0)]
    let (once, first) = hint(accounts)
    let (_, second) = hint(accounts, state: once)
    expect(first?.reason == .drained && second == nil, "a repeated drained reading is suppressed")
}

// 10. The two reasons are separately armed: a credit that started expiring after the drained
//     hint was ignored is new news (use it or lose it), not a repeat.
do {
    let (afterDrained, first) = hint([account("a", remaining: 0, expiry: far)])
    let (_, second) = hint([account("a", remaining: 0, expiry: soon)], state: afterDrained)
    expect(first?.reason == .drained, "the drained hint fires first")
    expect(second?.reason == .expiring, "the same account still reports its credit expiring")
}

// 11. A new reset cycle re-arms everything.
do {
    let (fired, _) = hint([account("a", remaining: 0)])
    let (state, note) = hint([account("a", remaining: 0, resetsAt: cycle2)], state: fired)
    expect(note?.reason == .drained, "the next weekly window hints again")
    expect(state.accounts["a"]?.cycleKey == DryPoolLogic.resetKey(cycle2),
           "state tracks the new cycle key")
}

// 12. Recovery inside one cycle re-arms too: a redeem refills the account, and the next drain is
//     a fresh opportunity rather than the same one.
do {
    let (fired, _) = hint([account("a", remaining: 0)])
    let (recovered, quiet) = hint([account("a", remaining: 100, credits: 1)], state: fired)
    expect(quiet == nil, "a refilled account has nothing to hint about")
    expect(recovered.accounts["a"]?.firedDrained == false, "recovery above the waste line re-arms")
    let (_, again) = hint([account("a", remaining: 0)], state: recovered)
    expect(again?.reason == .drained, "draining again in the same cycle hints again")
}

// 13. A failed fetch is not a recovery and not a new cycle: an account we could not read this
//     round keeps exactly the flags it had, so a network blip cannot re-fire a dismissed hint.
do {
    let (fired, _) = hint([account("a", remaining: 0)])
    let (carried, note) = hint([account("a", remaining: 0, error: "read failed")], state: fired)
    expect(note == nil, "an errored account is not a candidate")
    expect(carried.accounts["a"] == fired.accounts["a"], "its dedup state is carried untouched")
}

// 14. No metrics is not the same as an empty account: a card that renders 0% from nothing would
//     otherwise read as maximally drained.
do {
    let (_, note) = hint([account("a", remaining: 0, metrics: [])])
    expect(note == nil, "an account with no windows never reads as drained")
}

// 15. A window with no known reset is skipped (its cycle cannot be identified), and any state it
//     already had survives.
do {
    let (fired, _) = hint([account("a", remaining: 0)])
    let (carried, note) = hint([account("a", remaining: 0, resetsAt: nil)], state: fired)
    expect(note == nil, "a window with no reset time is not a candidate")
    expect(carried.accounts["a"] == fired.accounts["a"], "and its state is carried untouched")
}

// 16. Accounts that are gone (signed out, switched off) do not keep state forever.
do {
    let (fired, _) = hint([account("a", remaining: 0)])
    let (pruned, _) = hint([account("b", remaining: 90, credits: 0)], state: fired)
    expect(pruned.accounts["a"] == nil, "a vanished account is pruned from the state")
}

// 17. The binding window is the emptiest one, not the first: a spent weekly under a fresh session
//     still counts as drained, and the cycle is keyed on the window that binds.
do {
    let (state, note) = hint([account("a", remaining: 0, metrics: [
        metric("session", kind: .session, remaining: 80, resetsAt: cycle2),
        metric("weekly_all", remaining: 1, resetsAt: cycle1)])])
    expect(note?.reason == .drained, "the emptiest window decides")
    expect(note?.bindingRemainingPercent == 1, "the hint reports the binding window")
    expect(state.accounts["a"]?.cycleKey == DryPoolLogic.resetKey(cycle1),
           "the cycle is keyed on the binding window's reset")
}

// 18. Drained beats expiring when both apply, so the strongest reason is the one that is spent.
do {
    let (state, note) = hint([account("a", remaining: 0, expiry: soon)])
    expect(note?.reason == .drained, "a spent account with an expiring credit hints drained")
    expect(state.accounts["a"]?.firedExpiring == false, "the expiring reason stays armed")
}

// 19. Two accounts qualify, and the second is heard on the next refresh rather than never: each
//     names a different redeem, so neither is a repeat of the other.
do {
    let accounts = [account("a", remaining: 0), account("b", remaining: 0)]
    let (afterFirst, first) = hint(accounts)
    let (_, second) = hint(accounts, state: afterFirst)
    expect(first?.accountID == "a" && second?.accountID == "b",
           "the runner-up account is named on the next refresh")
}

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all reset-hint tests passed")
