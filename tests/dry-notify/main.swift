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

// 9. Sub-second jitter in the pooled reset time is not a new cycle (resetKey rounds to whole
//    seconds), while a genuinely different reset time is.
do {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    expect(DryPoolLogic.resetKey(base.addingTimeInterval(0.3)) == DryPoolLogic.resetKey(base),
           "sub-second jitter keeps the same reset key")
    expect(DryPoolLogic.resetKey(base.addingTimeInterval(2)) != DryPoolLogic.resetKey(base),
           "a genuinely different reset time changes the key")
}

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all dry-notify tests passed")
