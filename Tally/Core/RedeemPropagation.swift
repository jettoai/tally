import Foundation

/// The gap between "the redeem succeeded" and "the provider serves the cleared counters".
///
/// Redeeming a banked reset is instant on the server's ledger but not in its usage endpoint: the
/// refresh right behind the click still answers with the spent numbers for a few seconds. Left
/// alone the card says both things at once ("Reset redeemed" in green over a red "Limit reached"
/// at 0%), which reads as a redeem that did nothing (live report 2026-07-27).
///
/// Two answers, both here so they can never disagree: keep re-fetching for a short while, and keep
/// the card's wording neutral until the numbers move. Pure and Foundation-only so the assertion
/// harness compiles this file alone.
enum RedeemPropagation {
    /// How long after a successful redeem the card is allowed to speak in the settling voice. A
    /// bound, not a schedule: the watcher below normally clears the state as soon as the numbers
    /// move, and the whole retry ladder finishes well inside this. It exists so a redeem whose
    /// watcher never got to finish (app quit mid-ladder, a refresh that hung) cannot leave a card
    /// claiming a reset is landing minutes later.
    static let settlingWindow: TimeInterval = 120

    /// Deferred re-fetches after the immediate one, doubling so a slow propagation is still caught
    /// without hammering the provider. 10 + 20 + 40s covers the observed delay with room to spare,
    /// and the ladder stops the moment the numbers move.
    static let retryDelays: [TimeInterval] = [10, 20, 40]

    /// Percentage points the binding window has to gain before the reset counts as landed. A plain
    /// inequality would call a rounding wobble in the provider's own percentage a propagation, and
    /// a redeem always returns far more than this.
    static let propagatedGainPercent = 0.5

    /// Whether the numbers have moved since the redeem. Compares the binding window's remaining
    /// quota against what it was at the moment of the click, so it reads the same for an account
    /// that was fully drained (0 -> 100) as for one redeemed with room left (40 -> 100). Usage
    /// burnt in the meantime only pushes remaining DOWN, so it can never be mistaken for a reset.
    static func hasPropagated(baselineRemaining: Double, currentRemaining: Double) -> Bool {
        currentRemaining - baselineRemaining > propagatedGainPercent
    }

    /// Whether a card should still be speaking in the settling voice: a redeem landed recently and
    /// the account is STILL reporting an exhausted window. Both halves matter. Without the
    /// timestamp every capped account would claim a reset is on the way; without the capped check
    /// the wording would linger over numbers that already recovered.
    ///
    /// `bindingRemaining` is the emptiest window's remaining quota, nil when the account reports no
    /// windows at all (errored or half-loaded) - which must never read as "empty".
    static func isSettling(redeemedAt: Date?, now: Date, bindingRemaining: Double?) -> Bool {
        guard let redeemedAt, let bindingRemaining, bindingRemaining <= 0 else { return false }
        let elapsed = now.timeIntervalSince(redeemedAt)
        // A negative elapsed means the timestamp is in the future (a clock jump), not a fresh
        // redeem: nothing to say.
        return elapsed >= 0 && elapsed <= settlingWindow
    }
}
