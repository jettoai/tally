import Foundation
import Observation

/// Follows a successful redeem until the provider actually serves the cleared counters: it owns
/// the refresh behind the click, the short retry ladder after it, and the per-account timestamp
/// the card reads to keep its wording neutral in the meantime.
///
/// One owner for both, deliberately. The timestamp has to be dropped by whoever learns the numbers
/// moved, and that is the watcher; splitting them would leave the card guessing from a clock.
/// Shared singleton because a redeem can start from the card OR from the banked-reset
/// notification (which has no card on screen at all), and the panel must show the same state
/// either way.
@MainActor
@Observable
final class RedeemPropagationStore {
    static let shared = RedeemPropagationStore()

    /// When each account's last redeem succeeded. Observed by the cards, so both writing and
    /// clearing an entry re-renders on its own.
    private(set) var redeemedAt: [String: Date] = [:]

    private var watchers: [String: Task<Void, Never>] = [:]

    private init() {}

    /// Whether this account's card should still say a reset is landing rather than "Limit reached".
    func isSettling(_ usage: AccountUsage, now: Date = Date()) -> Bool {
        RedeemPropagation.isSettling(
            redeemedAt: redeemedAt[usage.id], now: now,
            bindingRemaining: ResetHintLogic.binding(usage)?.remainingPercent)
    }

    /// Start the follow-through for a redeem that just succeeded: refresh now, then re-fetch on the
    /// backoff ladder until the account's binding window gains quota. Returns immediately, so the
    /// caller's own chrome (the card's outcome line) is not held for the length of the ladder.
    ///
    /// Callers must invoke this INSTEAD of their own post-redeem refresh, never alongside it: the
    /// baseline is read from the pre-refresh snapshot, which is the only reading known to predate
    /// the reset.
    func begin(usage: AccountUsage) {
        let id = usage.id
        let baseline = ResetHintLogic.binding(usage)?.remainingPercent ?? 0
        // A second redeem on the same account restarts the follow-through against the newer
        // baseline; the old watcher must not outlive it and clear the new timestamp.
        watchers[id]?.cancel()
        redeemedAt[id] = Date()
        watchers[id] = Task { [self] in
            // The click's own refresh. User-initiated like every other refresh behind a direct
            // click, including the retries: the user is watching this card, and the account's
            // credentials just proved themselves on the redeem call itself.
            await UsageStore.shared.refresh(userInitiated: true)
            for delay in RedeemPropagation.retryDelays {
                if hasPropagated(id: id, baseline: baseline) { break }
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { break }
                await UsageStore.shared.refresh(userInitiated: true)
            }
            guard !Task.isCancelled else { return }
            redeemedAt[id] = nil
            watchers[id] = nil
        }
    }

    /// Whether the live snapshot has moved past the pre-redeem reading. An account that vanished
    /// from the snapshot (switched off mid-ladder) reports no movement; the ladder then runs out on
    /// its own rather than looping on a row nobody is looking at.
    private func hasPropagated(id: String, baseline: Double) -> Bool {
        guard let usage = UsageStore.shared.accounts.first(where: { $0.id == id }),
              let binding = ResetHintLogic.binding(usage) else { return false }
        return RedeemPropagation.hasPropagated(baselineRemaining: baseline,
                                               currentRemaining: binding.remainingPercent)
    }
}
