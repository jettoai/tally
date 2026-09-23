import Foundation

/// Why one banked reset is worth spending right now. The cases stay distinct all the way into the
/// notification body: "you are out" and "you are about to lose one" are different news, and a
/// user who reads only the title should still know which one arrived.
///
/// The three expiry stages are ordered (early < preReset < final) and fire once per credit each;
/// a later stage that has fired silences the earlier ones for that credit.
enum ResetHintReason: String, Codable, Equatable, Comparable {
    /// The account's binding window is spent while a credit sits banked: redeeming buys back a
    /// whole window, which is the most a credit can ever be worth.
    case drained
    /// A banked credit expires within 48 hours.
    case expiryEarly
    /// A credit expires after the binding window's next refill, and that refill is 2 hours away:
    /// the last moment spending it still recovers something the refill would not.
    case expiryPreReset
    /// A banked credit expires within 6 hours (or is already past its stated expiry).
    case expiryFinal

    var rank: Int {
        switch self {
        case .drained: return 0
        case .expiryEarly: return 1
        case .expiryPreReset: return 2
        case .expiryFinal: return 3
        }
    }

    static func < (a: ResetHintReason, b: ResetHintReason) -> Bool { a.rank < b.rank }
}

/// How an expiry hint words the value of spending now, decided apart from whether to speak.
enum ResetHintValue: Equatable {
    /// Little left: redeeming now recovers most of a window.
    case recovers
    /// Plenty left, and the binding window refills before the credit expires.
    case refillsFirst(Date)
    /// Plenty left, and no refill comes before the credit expires: unused, it is lost.
    case lostUnused
}

/// What the redeem confirmation advises beyond the cost, decided here so the hint and the dialog
/// can never disagree.
enum RedeemTiming: Equatable {
    /// Little left: redeeming now is worth it.
    case worthIt
    /// Plenty left and the counters refill before the credit expires: waiting recovers more.
    case waitForRefill(Date)
    /// Plenty left, no refill before expiry (or expiry inside 48 hours): unused, it is lost.
    case useOrLose(Date)
    /// Plenty left and nobody reported when the credit expires.
    case expiryUnknown
}

/// The single account a hint names, with the numbers the notification body needs.
struct ResetHint: Equatable {
    var accountID: String
    var accountLabel: String
    var reason: ResetHintReason
    var bindingRemainingPercent: Double
    var creditExpiresAt: Date?
    /// Which credit an expiry hint is about (`ResetHintLogic.creditKey`); nil for drained.
    var creditKey: String? = nil
    /// When the binding window refills, for the "best used before" wording.
    var bindingResetsAt: Date? = nil
}

/// Per-account dedup memory. `cycleKey` identifies the binding window's current cycle: when that
/// window resets, the drained flag re-arms. Expiry stages are remembered PER CREDIT instead and
/// survive cycles and refills, because a refill does not make an expiring credit news again.
struct ResetHintAccountState: Codable, Equatable {
    var cycleKey: String?
    var firedDrained = false
    /// Whether this cycle's one delivery retry has already been handed back (`rearm`).
    var rearmedDrained = false
    /// Credit key to the expiry stages already announced for it (raw values).
    var expiryStages: [String: [String]] = [:]
    /// Credit key to the expiry stages whose one delivery retry has been handed back.
    var expiryRearmed: [String: [String]] = [:]
}

/// Decoded key by key so a payload written by an older build still reads. Synthesized `Decodable`
/// throws on a missing key instead of falling back to the property default, and
/// `ResetHintNotifier` reads a decode failure as "no state at all", which would re-fire every hint
/// already delivered. Keys an older build wrote and this one dropped (`firedExpiring`) are ignored.
/// Declared in an extension so the memberwise init survives.
extension ResetHintAccountState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cycleKey = try container.decodeIfPresent(String.self, forKey: .cycleKey)
        firedDrained = try container.decodeIfPresent(Bool.self, forKey: .firedDrained) ?? false
        rearmedDrained = try container.decodeIfPresent(Bool.self, forKey: .rearmedDrained) ?? false
        expiryStages = try container.decodeIfPresent([String: [String]].self,
                                                     forKey: .expiryStages) ?? [:]
        expiryRearmed = try container.decodeIfPresent([String: [String]].self,
                                                      forKey: .expiryRearmed) ?? [:]
    }
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
    /// The value line: at or below this much left, spending a credit recovers most of a window.
    /// Above it, whether spending now is right depends on the expiry, and the wording says which.
    /// It doubles as the drained re-arm line: an account back above it has recovered.
    static let wasteRemainingPercent = 30.0
    /// The first expiry stage. 48h survives a weekend away while leaving a day of runway.
    static let expiryHorizon: TimeInterval = 48 * 3_600
    /// The last expiry stage.
    static let expiryFinalHorizon: TimeInterval = 6 * 3_600
    /// How long before the binding window's refill the pre-refill stage speaks.
    static let preResetLead: TimeInterval = 2 * 3_600

    /// The window that binds the account: the emptiest one. A spent weekly under a fresh session
    /// window is a spent account, and it is the weekly's reset that ends the drought. Nil when the
    /// account reports no windows at all, which must never read as "empty" (an errored or
    /// half-loaded account has no metrics, and 0-of-nothing is not a quota worth resetting).
    static func binding(_ usage: AccountUsage) -> UsageMetric? {
        usage.metrics.min { $0.remainingPercent < $1.remainingPercent }
    }

    /// A credit's dedup key: its id, else its expiry, else nothing (such a credit has no stage
    /// to announce anyway).
    static func creditKey(_ credit: BankedResetCredit) -> String? {
        if let id = credit.id, !id.isEmpty { return id }
        return credit.expiresAt.map { "exp:\(Int($0.timeIntervalSince1970))" }
    }

    /// The latest expiry stage a credit has reached, or nil. Never reads a window's `resetsAt` as
    /// the credit's expiry: with no expiry there is no stage.
    static func expiryStage(expiresAt: Date?, remaining: Double, bindingResetsAt: Date?,
                            now: Date) -> ResetHintReason? {
        guard let expiresAt else { return nil }
        let left = expiresAt.timeIntervalSince(now)
        if left <= expiryFinalHorizon { return .expiryFinal }
        guard left <= expiryHorizon else { return nil }
        if remaining > wasteRemainingPercent, let refill = bindingResetsAt, refill < expiresAt,
           now >= refill.addingTimeInterval(-preResetLead), now < refill {
            return .expiryPreReset
        }
        return .expiryEarly
    }

    /// How an expiry hint words the value of spending now.
    static func value(remaining: Double, expiresAt: Date?, bindingResetsAt: Date?) -> ResetHintValue {
        if remaining <= wasteRemainingPercent { return .recovers }
        if let refill = bindingResetsAt, let expiresAt, refill < expiresAt { return .refillsFirst(refill) }
        return .lostUnused
    }

    /// What the redeem confirmation advises for the credit a redeem would spend (the soonest one).
    static func redeemTiming(_ usage: AccountUsage, now: Date) -> RedeemTiming {
        let bound = binding(usage)
        let remaining = bound?.remainingPercent ?? 0
        if remaining <= wasteRemainingPercent { return .worthIt }
        guard let expiry = usage.resetCreditsNextExpiry else { return .expiryUnknown }
        if expiry.timeIntervalSince(now) > expiryHorizon, let refill = bound?.resetsAt, refill < expiry {
            return .waitForRefill(refill)
        }
        return .useOrLose(expiry)
    }

    /// Fold one refresh into the dedup state, returning the next state and the ONE account worth
    /// naming (nil when nothing qualifies or everything qualifying was already said).
    ///
    /// One hint per evaluation even when several accounts qualify: the user has attention for one
    /// redeem, so the ranking picks the least wasteful one (emptiest first, then the later stage,
    /// then the soonest expiry, then the id so the pick is stable). A runner-up is named on the
    /// next refresh, because it is a different redeem rather than a repeat of this one.
    static func advance(state: ResetHintState, accounts: [AccountUsage],
                        now: Date) -> (ResetHintState, ResetHint?) {
        var next = ResetHintState()
        var candidates: [ResetHint] = []

        for usage in accounts {
            let previous = state.accounts[usage.id]
            // An account we cannot read this round (failed fetch, no windows, no known reset)
            // keeps exactly the memory it had, expiry stages included: a failed read is not a
            // credit that went away.
            guard usage.error == nil, let binding = binding(usage),
                  let resetsAt = binding.resetsAt, let key = DryPoolLogic.resetKey(resetsAt) else {
                if let previous { next.accounts[usage.id] = previous }
                continue
            }
            // A cycle key that still names the same window keeps the drained flags fired inside
            // it, matched by nearness because a reported reset drifts by a minute between polls
            // (`DryPoolLogic.namesSameCycle`).
            var entry = ResetHintAccountState(cycleKey: key)
            if let previous, DryPoolLogic.namesSameCycle(previous.cycleKey, key) { entry = previous }
            let remaining = binding.remainingPercent
            // A recovery re-arms drained inside the same cycle, rebuilt on the cycle the entry
            // already carries so a refill cannot hand it a drifted key.
            if remaining > wasteRemainingPercent {
                entry = ResetHintAccountState(cycleKey: entry.cycleKey)
            }
            // Expiry memory is per credit and outlives cycles and refills. It is pruned only on
            // this successful read, down to the credits the provider still lists. A nil list is a
            // round that did not list them, not one that lists none, so it prunes nothing.
            var stages = previous?.expiryStages ?? [:]
            var rearmed = previous?.expiryRearmed ?? [:]
            if let listed = usage.resetCredits {
                let live = Set(listed.compactMap(creditKey))
                stages = stages.filter { live.contains($0.key) }
                rearmed = rearmed.filter { live.contains($0.key) }
            }
            entry.expiryStages = stages
            entry.expiryRearmed = rearmed
            next.accounts[usage.id] = entry

            guard let credits = usage.resetCreditsAvailable, credits > 0 else { continue }
            if remaining <= drainedRemainingPercent, !entry.firedDrained {
                candidates.append(ResetHint(accountID: usage.id, accountLabel: usage.accountLabel,
                                            reason: .drained, bindingRemainingPercent: remaining,
                                            creditExpiresAt: usage.resetCreditsNextExpiry,
                                            bindingResetsAt: resetsAt))
                continue
            }
            // Each spendable credit on its own clock; the account offers its most urgent one.
            let hints = usage.spendableResetCredits.compactMap { credit -> ResetHint? in
                guard let creditKey = creditKey(credit),
                      let stage = expiryStage(expiresAt: credit.expiresAt, remaining: remaining,
                                              bindingResetsAt: resetsAt, now: now) else { return nil }
                let fired = (stages[creditKey] ?? []).compactMap(ResetHintReason.init(rawValue:))
                // A stage speaks once, and never after a later one already spoke.
                guard fired.allSatisfy({ $0 < stage }) else { return nil }
                return ResetHint(accountID: usage.id, accountLabel: usage.accountLabel,
                                 reason: stage, bindingRemainingPercent: remaining,
                                 creditExpiresAt: credit.expiresAt, creditKey: creditKey,
                                 bindingResetsAt: resetsAt)
            }
            if let best = hints.min(by: leastWasteful) { candidates.append(best) }
        }

        guard let hint = candidates.min(by: leastWasteful) else { return (next, nil) }
        if hint.reason == .drained {
            next.accounts[hint.accountID]?.firedDrained = true
        } else if let creditKey = hint.creditKey {
            next.accounts[hint.accountID]?.expiryStages[creditKey, default: []]
                .append(hint.reason.rawValue)
        }
        return (next, hint)
    }

    /// Hand back the one announcement a hint just spent, because the system refused to deliver it.
    /// Only that stage's fired mark is undone, so someone who turns notifications on later still
    /// hears about a credit that is about to go.
    ///
    /// Bounded to one retry per account per cycle (drained) or per credit per stage (expiry). The
    /// refusal is only as good as the authorization answer `SystemAlert.post` reads it from; were
    /// it ever wrong about a notification that did land, an unbounded retry would repeat one hint
    /// forever. Past the one retry the hint stays told.
    static func rearm(state: ResetHintState, hint: ResetHint) -> ResetHintState {
        var next = state
        guard var entry = next.accounts[hint.accountID] else { return next }
        if hint.reason == .drained {
            guard !entry.rearmedDrained else { return next }
            entry.rearmedDrained = true
            entry.firedDrained = false
        } else {
            guard let key = hint.creditKey else { return next }
            let stage = hint.reason.rawValue
            guard !(entry.expiryRearmed[key] ?? []).contains(stage) else { return next }
            entry.expiryRearmed[key, default: []].append(stage)
            entry.expiryStages[key]?.removeAll { $0 == stage }
        }
        next.accounts[hint.accountID] = entry
        return next
    }

    /// Least waste first: the emptiest account recovers the most from one credit. Ties go to the
    /// later stage (a credit about to vanish outranks one with a day left), then to the credit that
    /// disappears soonest, then to the id, so the same fleet always produces the same pick.
    private static func leastWasteful(_ a: ResetHint, _ b: ResetHint) -> Bool {
        if a.bindingRemainingPercent != b.bindingRemainingPercent {
            return a.bindingRemainingPercent < b.bindingRemainingPercent
        }
        if a.reason != b.reason { return a.reason > b.reason }
        let aExpiry = a.creditExpiresAt ?? .distantFuture
        let bExpiry = b.creditExpiresAt ?? .distantFuture
        if aExpiry != bExpiry { return aExpiry < bExpiry }
        return a.accountID < b.accountID
    }
}
