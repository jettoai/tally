import Foundation

/// Why one banked reset is worth spending right now. The two cases stay distinct all the way into
/// the notification body: "you are out" and "you are about to lose one" are different news, and a
/// user who reads only the title should still know which one arrived.
enum ResetHintReason: String, Codable, Equatable {
    /// The account's binding window is spent while a credit sits banked: redeeming buys back a
    /// whole window, which is the most a credit can ever be worth.
    case drained
    /// A banked credit is about to expire unused, and the account is already low enough that
    /// spending it recovers something real rather than throwing most of it away.
    case expiring
}

/// The single account a hint names, with the numbers the notification body needs.
struct ResetHint: Equatable {
    var accountID: String
    var accountLabel: String
    var reason: ResetHintReason
    var bindingRemainingPercent: Double
    var creditExpiresAt: Date?
}

/// Per-account dedup memory. `cycleKey` identifies the binding window's current cycle: when that
/// window resets, the whole entry re-arms. The two reasons are armed separately, mirroring
/// `DryPoolState`'s two tiers, so a drained hint that went unread does not swallow the later
/// use-it-or-lose-it one.
struct ResetHintAccountState: Codable, Equatable {
    var cycleKey: String?
    var firedDrained = false
    var firedExpiring = false
}

/// Dedup memory for every account, persisted (UserDefaults) so an app restart or auto-update does
/// not repeat a hint already delivered this cycle.
struct ResetHintState: Codable, Equatable {
    var accounts: [String: ResetHintAccountState] = [:]
}

/// Pure trigger, ranking and dedup logic for the banked-reset reminder. Foundation only (no AppKit,
/// no UserNotifications) so the CLI test harness compiles it standalone.
///
/// The feature exists because the user has to REMEMBER to look at a banked credit; it never acts on
/// one. Everything smart here goes into WHEN to speak and WHICH account to name.
enum ResetHintLogic {
    /// Drained: at or below 5% of the binding window left. The same line `DryPoolLogic.lowFraction`
    /// calls nearly dry, so "drained" means one thing across both alerts.
    static let drainedRemainingPercent = 5.0
    /// Above this much left, the redeem confirmation already tells the user a redeem "would mostly
    /// be wasted" (it reads this very constant, so the two can never disagree), and nothing above
    /// it is worth a notification. It doubles as the re-arm line: an account back above it has
    /// nothing to hint about, and its next drain is a fresh opportunity rather than a repeat of
    /// the last one.
    static let wasteRemainingPercent = 30.0
    /// How close an expiry has to be before it is news. 48h survives a weekend away from the
    /// machine while still leaving a day of runway to act, and at the default refresh interval it
    /// is reached long before the credit evaporates.
    static let expiryHorizon: TimeInterval = 48 * 3_600

    /// The window that binds the account: the emptiest one. A spent weekly under a fresh session
    /// window is a spent account, and it is the weekly's reset that ends the drought. Nil when the
    /// account reports no windows at all, which must never read as "empty" (an errored or
    /// half-loaded account has no metrics, and 0-of-nothing is not a quota worth resetting).
    static func binding(_ usage: AccountUsage) -> UsageMetric? {
        usage.metrics.min { $0.remainingPercent < $1.remainingPercent }
    }

    /// Fold one refresh into the dedup state, returning the next state and the ONE account worth
    /// naming (nil when nothing qualifies or everything qualifying was already said this cycle).
    ///
    /// One hint per evaluation even when several accounts qualify: the user has attention for one
    /// redeem, so the ranking picks the least wasteful one (emptiest first, then the soonest
    /// expiry, then the id so the pick is stable). A runner-up is not silenced forever, it is named
    /// on the next refresh, because it is a different redeem rather than a repeat of this one.
    static func advance(state: ResetHintState, accounts: [AccountUsage],
                        now: Date) -> (ResetHintState, ResetHint?) {
        var next = ResetHintState()
        var candidates: [ResetHint] = []

        for usage in accounts {
            let previous = state.accounts[usage.id]
            // An account we cannot read this round (failed fetch, no windows, no known reset)
            // keeps exactly the memory it had. Treating it as fresh would re-arm a hint the user
            // already dismissed, and a nil reset time reads as a new cycle on the way back in.
            guard usage.error == nil, let binding = binding(usage),
                  let resetsAt = binding.resetsAt, let key = DryPoolLogic.resetKey(resetsAt) else {
                if let previous { next.accounts[usage.id] = previous }
                continue
            }
            // A cycle key that still matches keeps the flags fired inside it; anything else (a new
            // cycle, or an account seen for the first time) starts fresh.
            var entry = ResetHintAccountState(cycleKey: key)
            if let previous, previous.cycleKey == key { entry = previous }
            let remaining = binding.remainingPercent
            if remaining > wasteRemainingPercent {
                entry.firedDrained = false
                entry.firedExpiring = false
            }
            next.accounts[usage.id] = entry

            guard let credits = usage.resetCreditsAvailable, credits > 0 else { continue }
            let expiry = usage.resetCreditsNextExpiry
            let reason: ResetHintReason?
            if remaining <= drainedRemainingPercent, !entry.firedDrained {
                reason = .drained
            } else if let expiry, expiry.timeIntervalSince(now) <= expiryHorizon,
                      remaining <= wasteRemainingPercent, !entry.firedExpiring {
                // No lower bound on the expiry: a credit the server still reports as available
                // past its stated expiry is the most urgent one there is, not a reason to wait.
                reason = .expiring
            } else {
                reason = nil
            }
            if let reason {
                candidates.append(ResetHint(accountID: usage.id, accountLabel: usage.accountLabel,
                                            reason: reason, bindingRemainingPercent: remaining,
                                            creditExpiresAt: expiry))
            }
        }

        guard let hint = candidates.min(by: leastWasteful) else { return (next, nil) }
        switch hint.reason {
        case .drained: next.accounts[hint.accountID]?.firedDrained = true
        case .expiring: next.accounts[hint.accountID]?.firedExpiring = true
        }
        return (next, hint)
    }

    /// Least waste first: the emptiest account recovers the most from one credit. Ties go to the
    /// credit that disappears soonest, then to the id, so the same fleet always produces the same
    /// pick rather than one that follows the array's order.
    private static func leastWasteful(_ a: ResetHint, _ b: ResetHint) -> Bool {
        if a.bindingRemainingPercent != b.bindingRemainingPercent {
            return a.bindingRemainingPercent < b.bindingRemainingPercent
        }
        let aExpiry = a.creditExpiresAt ?? .distantFuture
        let bExpiry = b.creditExpiresAt ?? .distantFuture
        if aExpiry != bExpiry { return aExpiry < bExpiry }
        return a.accountID < b.accountID
    }
}
