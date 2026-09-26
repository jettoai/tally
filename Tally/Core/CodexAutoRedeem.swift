import Foundation

// Codex's banked reset, spent automatically when an account's WEEKLY window runs dry.
//
// THE MIRROR OF CLAUDE'S AUTOMATIC SESSION-LIMIT RESET (TallyCLI/CapLimitReset.swift), with the
// same four rules: it answers a wall that has already been hit and nothing earlier, one wall gets
// one attempt, a failed attempt is never retried on the same wall, and a number held over from a
// failed poll is not a reading. A wall is one run-out: quota that comes back and runs out again,
// in the same week or the next, is a new wall. Every redeem, by hand or automatic, counts for its
// wall in both directions: while one is in flight no other starts, and once one spends (`settle`)
// no other starts on that wall within `rearmCooldown` (`blocksRedeem`). The difference is who acts: Codex exposes
// the redeem through its own app-server, so the installed app spends the credit through the exact
// call the card's button uses (`RedeemAction.redeem`), and no supervisor is involved.
//
// Pure and Foundation-only so tests/codexautoredeem compiles it with the account types alone.

/// What the automatic path remembers about one account's attempt. Persisted (UserDefaults) so a
/// relaunch or an auto-update never spends a second credit on a window one attempt already answered.
struct CodexAutoRedeemAccountState: Codable, Equatable {
    /// The weekly window the attempt answered (`DryPoolLogic.resetKey` of its `resetsAt`).
    var cycleKey: String
    var attemptedAt: Date
    /// What the attempt came to, for diagnosis only: the decision never reads it.
    var outcome: String
}

struct CodexAutoRedeemState: Codable, Equatable {
    var accounts: [String: CodexAutoRedeemAccountState] = [:]
}

enum CodexAutoRedeemLogic {
    static let providerID = "codex"

    /// Weekly quota left, in percentage points, that counts as "the account recovered". A redeem
    /// returns the whole window, so any real recovery clears this by far; a rounding wobble does not.
    static let rearmRemainingPercent = 1.0

    /// How long an attempt blocks the next one, whatever the numbers say. The provider keeps
    /// serving the spent numbers for a while after a redeem (`RedeemPropagation`), and a recovered
    /// reading followed by a stale 0% inside that gap must not spend a second credit.
    static let rearmCooldown: TimeInterval = 15 * 60

    /// Memory older than this names a window that has certainly ended (a weekly window is 7 days).
    static let memoryLifetime: TimeInterval = 8 * 24 * 3_600

    static func weekly(_ usage: AccountUsage) -> UsageMetric? {
        usage.metrics.first { $0.kind == .weeklyAll }
    }

    /// Whether this round's numbers were actually read this round.
    static func isFreshReading(_ usage: AccountUsage) -> Bool {
        usage.error == nil && !usage.lastRefreshFailed && !usage.isStale
    }

    /// Fold one refresh into the memory and name the accounts to redeem now. The returned state
    /// already records every named account, so the caller persists it BEFORE any redeem starts.
    static func decide(state: CodexAutoRedeemState, accounts: [AccountUsage], enabled: Bool,
                       isUnshipped: Bool, isDemo: Bool, inFlight: Set<String>,
                       now: Date) -> (state: CodexAutoRedeemState, redeem: [String]) {
        var next = state
        next.accounts = next.accounts.filter {
            now.timeIntervalSince($0.value.attemptedAt) < memoryLifetime
        }
        var due: [String] = []
        for usage in accounts where usage.providerID == providerID {
            // A round that did not read this account keeps its memory exactly as it was.
            guard isFreshReading(usage), let weekly = weekly(usage),
                  let key = DryPoolLogic.resetKey(weekly.resetsAt) else { continue }
            let remaining = weekly.remainingPercent
            if let entry = next.accounts[usage.id],
               now.timeIntervalSince(entry.attemptedAt) >= rearmCooldown,
               (!DryPoolLogic.namesSameCycle(entry.cycleKey, key)
                || remaining >= rearmRemainingPercent) {
                next.accounts[usage.id] = nil
            }
            guard enabled, !isUnshipped, !isDemo,
                  next.accounts[usage.id] == nil, !inFlight.contains(usage.id),
                  remaining <= 0,
                  let credits = usage.resetCreditsAvailable, credits > 0,
                  usage.resetCredits?.contains(where: { $0.status == "redeeming" }) != true
            else { continue }
            next.accounts[usage.id] = CodexAutoRedeemAccountState(cycleKey: key, attemptedAt: now,
                                                                  outcome: "pending")
            due.append(usage.id)
        }
        return (next, due.sorted())
    }

    /// Fold what a redeem came to into the memory, whichever control started it (the card, the
    /// notification, or `decide`). A credit spent, or found already spent, answers this wall: the
    /// entry is (re)written from this account's weekly window and `now`, so the provider's stale 0%
    /// during propagation cannot spend a second credit on the same wall. Anything else spent nothing
    /// and only updates the outcome of an entry that already exists: an automatic attempt keeps
    /// blocking its wall, and a manual attempt that spent nothing leaves the automatic path free.
    static func settle(outcome: String, usage: AccountUsage, in state: CodexAutoRedeemState,
                       now: Date) -> CodexAutoRedeemState {
        var next = state
        if outcome == "redeemed" || outcome == "alreadyUsed",
           let key = weekly(usage).flatMap({ DryPoolLogic.resetKey($0.resetsAt) }) {
            next.accounts[usage.id] = CodexAutoRedeemAccountState(cycleKey: key, attemptedAt: now,
                                                                  outcome: outcome)
        } else {
            next.accounts[usage.id]?.outcome = outcome
        }
        return next
    }

    /// Whether a redeem, from any control, must not start: a credit was already spent (or found
    /// spent) on this account's current weekly window within `rearmCooldown`, so the 0% on screen
    /// is the provider still catching up, not a wall. A window the usage cannot name counts as the
    /// same one, which only ever holds back a spend.
    static func blocksRedeem(state: CodexAutoRedeemState, usage: AccountUsage, now: Date) -> Bool {
        guard let entry = state.accounts[usage.id],
              entry.outcome == "redeemed" || entry.outcome == "alreadyUsed",
              now.timeIntervalSince(entry.attemptedAt) < rearmCooldown else { return false }
        guard let key = weekly(usage).flatMap({ DryPoolLogic.resetKey($0.resetsAt) }) else {
            return true
        }
        return DryPoolLogic.namesSameCycle(entry.cycleKey, key)
    }

    /// The reminder's "out of quota, a reset can clear it" is wrong advice for an account this
    /// round is already redeeming, so it is dropped for exactly that account and reason.
    static func silencesDrainedHint(isDrained: Bool, accountID: String,
                                    claimed: Set<String>) -> Bool {
        isDrained && claimed.contains(accountID)
    }
}
