import Foundation

// Assertion harness for RedeemPropagation (compiled with Tally/Core/RedeemPropagation.swift
// alone - it is Foundation-only on purpose).

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let redeemedAt = Date(timeIntervalSince1970: 1_800_000_000)
let window = RedeemPropagation.settlingWindow

func settling(after seconds: TimeInterval, remaining: Double?,
              redeemed: Date? = redeemedAt) -> Bool {
    RedeemPropagation.isSettling(redeemedAt: redeemed,
                                 now: redeemedAt.addingTimeInterval(seconds),
                                 bindingRemaining: remaining)
}

// MARK: isSettling - the truth table of "a redeem landed recently AND the data is still capped"

expect(!settling(after: 5, remaining: 0, redeemed: nil),
       "no redeem on record - a capped account is just capped")
expect(settling(after: 5, remaining: 0),
       "fresh redeem over a still-exhausted window - the settling voice")
expect(settling(after: 0, remaining: 0),
       "the instant of the redeem is inside the window")
expect(settling(after: window, remaining: 0),
       "the last instant of the window still counts")
expect(!settling(after: window + 1, remaining: 0),
       "past the window a still-capped account goes back to reporting the limit")
expect(!settling(after: 5, remaining: 100),
       "the numbers moved - nothing left to wait for")
expect(!settling(after: 5, remaining: 0.4),
       "any quota at all means the window is not exhausted")
expect(!settling(after: 5, remaining: nil),
       "an account reporting no windows never reads as empty")
expect(!settling(after: -30, remaining: 0),
       "a timestamp in the future (clock jump) is not a fresh redeem")

// MARK: hasPropagated - what stops the retry ladder

func propagated(_ baseline: Double, _ current: Double) -> Bool {
    RedeemPropagation.hasPropagated(baselineRemaining: baseline, currentRemaining: current)
}

expect(!propagated(0, 0), "drained account, unchanged - keep retrying")
expect(propagated(0, 100), "drained account, quota back - done")
expect(!propagated(0, 0.3), "a rounding wobble is not a reset")
expect(propagated(40, 100), "redeemed with room left, quota back - done")
expect(!propagated(40, 40), "redeemed with room left, unchanged - keep retrying")
expect(!propagated(40, 39),
       "remaining fell (usage burnt while waiting) - still not a reset")

// MARK: the ladder itself

expect(RedeemPropagation.retryDelays.count == 3, "three deferred re-fetches")
expect(zip(RedeemPropagation.retryDelays, RedeemPropagation.retryDelays.dropFirst())
        .allSatisfy { $1 > $0 }, "the ladder backs off")
expect(RedeemPropagation.retryDelays.reduce(0, +) < window,
       "the whole ladder finishes inside the settling window")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
