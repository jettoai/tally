import Foundation

// Assertion harness for DryPoolLogic (compiled with Tally/Core/DryPoolLogic.swift).

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let t1 = Date(timeIntervalSince1970: 1_800_000_000)
let t2 = Date(timeIntervalSince1970: 1_800_600_000)   // a different reset cycle

// 1. A single account never arms, even at zero remaining (the ordinary single-subscription state).
do {
    let (state, note) = DryPoolLogic.advance(state: DryPoolState(), remaining: 0, capacity: 100,
                                             accountCount: 1, resetAt: t1)
    expect(note == nil, "single account does not fire at 0")
    expect(state.firedLow == false && state.firedDry == false, "single account leaves flags unarmed")
    expect(DryPoolLogic.tier(remaining: 0, capacity: 100, accountCount: 1) == .normal,
           "single-account tier is normal at 0")
}

// 2. Two accounts, the low threshold boundary: 10/200 fires, 11/200 does not (5% of 200 = 10).
do {
    let (_, fires) = DryPoolLogic.advance(state: DryPoolState(), remaining: 10, capacity: 200,
                                          accountCount: 2, resetAt: t1)
    expect(fires == .low, "10 of 200 fires low")
    let (_, holds) = DryPoolLogic.advance(state: DryPoolState(), remaining: 11, capacity: 200,
                                          accountCount: 2, resetAt: t1)
    expect(holds == nil, "11 of 200 does not fire")
}

// 3. Dry fires at zero remaining.
do {
    let (state, note) = DryPoolLogic.advance(state: DryPoolState(), remaining: 0, capacity: 200,
                                             accountCount: 2, resetAt: t1)
    expect(note == .dry, "0 of 200 fires dry")
    expect(state.firedDry, "dry flag is set after firing")
}

// 4. Low then dry within one cycle is two notifications total.
do {
    let (afterLow, low) = DryPoolLogic.advance(state: DryPoolState(), remaining: 10, capacity: 200,
                                               accountCount: 2, resetAt: t1)
    let (afterDry, dry) = DryPoolLogic.advance(state: afterLow, remaining: 0, capacity: 200,
                                               accountCount: 2, resetAt: t1)
    expect(low == .low && dry == .dry, "low then dry emits both")
    expect(afterDry.firedLow && afterDry.firedDry, "both flags set after the pair")
}

// 5. Repeating the same reading in one cycle never duplicates.
do {
    let (afterLow, first) = DryPoolLogic.advance(state: DryPoolState(), remaining: 8, capacity: 200,
                                                 accountCount: 2, resetAt: t1)
    let (_, second) = DryPoolLogic.advance(state: afterLow, remaining: 8, capacity: 200,
                                           accountCount: 2, resetAt: t1)
    expect(first == .low && second == nil, "duplicate low reading is suppressed")
    let (afterDry, dryFirst) = DryPoolLogic.advance(state: afterLow, remaining: 0, capacity: 200,
                                                    accountCount: 2, resetAt: t1)
    let (_, drySecond) = DryPoolLogic.advance(state: afterDry, remaining: 0, capacity: 200,
                                              accountCount: 2, resetAt: t1)
    expect(dryFirst == .dry && drySecond == nil, "duplicate dry reading is suppressed")
}

// 6. A reset-time change re-arms everything (a new cycle fires again).
do {
    let (afterDry, _) = DryPoolLogic.advance(state: DryPoolState(), remaining: 0, capacity: 200,
                                             accountCount: 2, resetAt: t1)
    let (state, note) = DryPoolLogic.advance(state: afterDry, remaining: 0, capacity: 200,
                                             accountCount: 2, resetAt: t2)
    expect(note == .dry, "a new reset cycle re-fires dry")
    expect(state.resetKey == DryPoolLogic.resetKey(t2), "state tracks the new cycle key")
}

// 7. Recovery above 10% then falling again re-fires within the same cycle.
do {
    let (afterLow, low) = DryPoolLogic.advance(state: DryPoolState(), remaining: 10, capacity: 200,
                                               accountCount: 2, resetAt: t1)
    let (recovered, quiet) = DryPoolLogic.advance(state: afterLow, remaining: 30, capacity: 200,
                                                  accountCount: 2, resetAt: t1)
    let (_, again) = DryPoolLogic.advance(state: recovered, remaining: 10, capacity: 200,
                                          accountCount: 2, resetAt: t1)
    expect(low == .low, "first low fires")
    expect(quiet == nil && recovered.firedLow == false, "recovery above 10% clears the low flag")
    expect(again == .low, "falling back below 5% re-fires low in the same cycle")
}

// 8. Thresholds scale with capacity: three accounts (capacity 300) fire low at 15, hold at 16,
//    and re-arm above 30 (10% of 300).
do {
    expect(DryPoolLogic.tier(remaining: 15, capacity: 300, accountCount: 3) == .low,
           "15 of 300 is low (5% boundary)")
    expect(DryPoolLogic.tier(remaining: 16, capacity: 300, accountCount: 3) == .normal,
           "16 of 300 is normal")
    let (afterLow, _) = DryPoolLogic.advance(state: DryPoolState(), remaining: 15, capacity: 300,
                                             accountCount: 3, resetAt: t1)
    let (recovered, _) = DryPoolLogic.advance(state: afterLow, remaining: 45, capacity: 300,
                                              accountCount: 3, resetAt: t1)
    expect(recovered.firedLow == false, "recovery above 30 re-arms the 300-capacity pool")
    let (_, again) = DryPoolLogic.advance(state: recovered, remaining: 15, capacity: 300,
                                          accountCount: 3, resetAt: t1)
    expect(again == .low, "the scaled pool re-fires low after recovery")
}

// 9. The key rounds to whole seconds, so sub-second jitter in the pooled reset cannot even change
//    it. That is only half the answer, though: two seconds later is already a different key, and
//    still the same cycle, so the rest of the answer is in the comparison.
do {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    expect(DryPoolLogic.resetKey(base.addingTimeInterval(0.3)) == DryPoolLogic.resetKey(base),
           "sub-second jitter keeps the same reset key")
    expect(DryPoolLogic.resetKey(base.addingTimeInterval(2)) != DryPoolLogic.resetKey(base),
           "a reset time two seconds later is a different key")
    expect(DryPoolLogic.namesSameCycle(DryPoolLogic.resetKey(base.addingTimeInterval(2)),
                                       DryPoolLogic.resetKey(base)),
           "which still names the same cycle")
}

// 10. A reported reset that moves is still one cycle. These times are parsed out of what the
//     providers report in human text, whose finest unit is the minute, so one unbroken window is
//     reported a minute later or earlier as the underlying instant rounds one way or the other.
//     Matching cycles by equality read that wobble as a new cycle and re-fired the alert the dedup
//     exists to suppress, which for a pool sitting at zero is every refresh that happens to land on
//     the other side of the rounding.
do {
    let (fired, first) = DryPoolLogic.advance(state: DryPoolState(), remaining: 0, capacity: 200,
                                              accountCount: 2, resetAt: t1)
    expect(first == .dry, "the pool running dry fires once")
    let (afterWobble, later) = DryPoolLogic.advance(state: fired, remaining: 0, capacity: 200,
                                                    accountCount: 2,
                                                    resetAt: t1.addingTimeInterval(60))
    expect(later == nil, "the same window reported a minute later is not a second alert")
    expect(afterWobble.resetKey == DryPoolLogic.resetKey(t1),
           "and the cycle keeps the identity it was first seen under, so a wobble cannot walk")
    let (_, earlier) = DryPoolLogic.advance(state: fired, remaining: 0, capacity: 200,
                                            accountCount: 2, resetAt: t1.addingTimeInterval(-60))
    expect(earlier == nil, "nor is a minute earlier")
    let (_, edge) = DryPoolLogic.advance(state: fired, remaining: 0, capacity: 200,
                                         accountCount: 2,
                                         resetAt: t1.addingTimeInterval(DryPoolLogic.cycleTolerance))
    expect(edge == nil, "nor anything else inside the tolerance")
    // The low tier is deduped by the same key, so it wobbles the same way.
    let (firedLow, low) = DryPoolLogic.advance(state: DryPoolState(), remaining: 10, capacity: 200,
                                               accountCount: 2, resetAt: t1)
    let (_, lowAgain) = DryPoolLogic.advance(state: firedLow, remaining: 10, capacity: 200,
                                             accountCount: 2, resetAt: t1.addingTimeInterval(60))
    expect(low == .low && lowAgain == nil, "the low tier survives the same wobble")
}

// 11. The re-arm the tolerance must not swallow: windows are hours long, so a genuinely new cycle
//     is never a few minutes away. The 5h session window is the shortest one there is.
do {
    let (fired, _) = DryPoolLogic.advance(state: DryPoolState(), remaining: 0, capacity: 200,
                                          accountCount: 2, resetAt: t1)
    let reset = t1.addingTimeInterval(5 * 3_600)
    let (state, again) = DryPoolLogic.advance(state: fired, remaining: 0, capacity: 200,
                                              accountCount: 2, resetAt: reset)
    expect(again == .dry, "the window actually resetting five hours on fires again")
    expect(state.resetKey == DryPoolLogic.resetKey(reset), "and the state tracks the new cycle")
}

// 12. A pool with no known reset time has one unknown cycle rather than a new one each refresh,
//     which is what equality gave it and what the nearness check has to keep giving it.
do {
    let (fired, first) = DryPoolLogic.advance(state: DryPoolState(), remaining: 0, capacity: 200,
                                              accountCount: 2, resetAt: nil)
    let (_, second) = DryPoolLogic.advance(state: fired, remaining: 0, capacity: 200,
                                           accountCount: 2, resetAt: nil)
    expect(first == .dry && second == nil, "an unknown reset does not re-fire on the next refresh")
    let (_, known) = DryPoolLogic.advance(state: fired, remaining: 0, capacity: 200,
                                          accountCount: 2, resetAt: t1)
    expect(known == .dry, "and learning the reset time is a cycle we have not alerted on")
}

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all dry-notify tests passed")
