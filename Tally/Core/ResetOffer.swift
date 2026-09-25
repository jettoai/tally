import Foundation

/// What one account has to spend, answered for EVERY account. Foundation only, so the redeem
/// suite compiles it standalone; `RedeemAction.Offer` is this type.
///
/// Four states per account (available / used / not supported / unknown), and unknown is drawn
/// rather than hidden: an account nobody has observed must not read as an account with nothing.
enum ResetOffer: Equatable {
    /// Codex: `n` banked resets, spent soonest-expiry-first.
    case codexCredits(Int)
    /// Codex read fine and reports zero banked. Worded "no banked resets", never "used": zero
    /// cannot tell a spent credit from one never granted.
    case codexNone
    /// Codex read fine and the response has no reset-banking key at all for this login.
    case codexNotReported
    /// Codex could not say this round: the read failed with nothing held over, or a credit is
    /// still mid-redeem.
    case codexUnknown
    /// Claude's session-limit reset, in all four of its states, `unknown` included.
    case claudeSessionLimit(LimitResetState)

    /// The one decision. `claudeState` is what the Claude record (and its flag cache) says; the
    /// Codex side reads only the usage.
    static func of(_ usage: AccountUsage, claudeState: LimitResetState) -> ResetOffer {
        if usage.providerID == "claude" { return .claudeSessionLimit(claudeState) }
        if let count = usage.resetCreditsAvailable {
            if count > 0 { return .codexCredits(count) }
            if usage.resetCredits?.contains(where: { $0.status == "redeeming" }) == true {
                return .codexUnknown
            }
            return .codexNone
        }
        // A missing count is "not reported" only on a read that worked. A failed one, or one with
        // no windows, cannot tell an absent key from a lost answer.
        let readWorked = usage.error == nil && !usage.lastRefreshFailed && !usage.metrics.isEmpty
        return readWorked ? .codexNotReported : .codexUnknown
    }

    /// The state's name in the snapshot and `tally status`: available, used, notSupported, unknown.
    var stateName: String {
        switch self {
        case .codexCredits: return "available"
        case .codexNone: return "used"
        case .codexNotReported: return "notSupported"
        case .codexUnknown: return "unknown"
        case .claudeSessionLimit(let state):
            switch state {
            case .available: return "available"
            case .used: return "used"
            case .notEnabled: return "notSupported"
            case .unknown: return "unknown"
            }
        }
    }
}

/// How close a banked reset's expiry is, for the card's colour. Unknown is its own answer.
enum ResetExpiryUrgency: Equatable {
    case unknown, distant, thisWeek, soon, final

    static func of(_ expiry: Date?, now: Date) -> ResetExpiryUrgency {
        guard let expiry else { return .unknown }
        let left = expiry.timeIntervalSince(now)
        if left <= 6 * 3_600 { return .final }
        if left <= 48 * 3_600 { return .soon }
        if left < 7 * 86_400 { return .thisWeek }
        return .distant
    }
}

// MARK: - Claude's CLI flag cache (zero-credential)

/// The two feature flags that gate Claude Code's `/limit-reset` (`tengu_nifty_lemur`, the weekly
/// session reset, and `tengu_cedar_ember`, the granted-resets one). Obfuscated names that any CLI
/// release may rename, which is why a missing flag answers "cannot tell", never "off".
let claudeLimitResetFlags = ["tengu_nifty_lemur", "tengu_cedar_ember"]

/// The `cachedGrowthBookFeatures` object of a `.claude.json`, or nil when the file is not JSON or
/// the object is missing or not a dictionary. Both flag readers below go through it.
private func claudeCachedFeatures(inState raw: Data) -> [String: Any]? {
    let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
    return root?["cachedGrowthBookFeatures"] as? [String: Any]
}

/// Whether a Claude login's cached flags say its CLI reset path is off, read from the account's
/// `.claude.json` (`cachedGrowthBookFeatures`). Only these two keys are looked at.
///
/// true: at least one flag present and none enabled. false: one is enabled. nil: neither present
/// (renamed, or never evaluated) or a shape this cannot read, which must stay `unknown`.
func claudeLimitResetFlagsOff(inState raw: Data) -> Bool? {
    guard let features = claudeCachedFeatures(inState: raw) else { return nil }
    let present = claudeLimitResetFlags.compactMap { features[$0] }
    guard !present.isEmpty else { return nil }
    for flag in present {
        guard let enabled = (flag as? [String: Any])?["enabled"] as? Bool else { return nil }
        if enabled { return false }
    }
    return true
}

/// Whether a Claude login's cached flags open the path a press takes: `tengu_nifty_lemur` enabled
/// and `tengu_cedar_ember` not. With cedar on, the CLI asks its own confirmation before spending,
/// and Tally never types into a dialog, so that login goes to claude.ai instead.
///
/// FAIL-CLOSED: a missing flag, a renamed one or an unreadable file answers false, which draws the
/// claude.ai pointer rather than a button that would type an unknown command into a session.
func claudeLimitResetPressPathOpen(inState raw: Data) -> Bool {
    guard let features = claudeCachedFeatures(inState: raw) else { return false }
    func enabled(_ key: String) -> Bool? { (features[key] as? [String: Any])?["enabled"] as? Bool }
    return enabled("tengu_nifty_lemur") == true && enabled("tengu_cedar_ember") != true
}

/// The Claude state a card shows: an unobserved account whose CLI path is off is "not supported
/// here" (redeemable on claude.ai only). The flag never overrides a state a sentence settled.
func claudeResetState(observed: LimitResetState, flagsOff: Bool?) -> LimitResetState {
    observed == .unknown && flagsOff == true ? .notEnabled : observed
}
