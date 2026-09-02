import Foundation

// THE BURN-RATE SCORING BEHIND THE PANEL BADGE, split out of LaunchPolicyStore.swift for file
// size. Every function here is pure arithmetic over one account's published windows, and every one
// of them is a MIRROR of the launcher's own (TallyCLI/AccountPick.swift): the badge exists to predict
// what `tally` will do, so a drift between the two sides is a badge sitting on an account a launch
// would not pick. Keep both sides in lockstep.
//
// THE RESERVE RIDES THROUGH HERE FOR THE SAME REASON (Tally/Core/AccountReserve.swift): the launcher
// ranks the fleet on what it may SPEND of each account, so a badge ranking on the raw percentage
// would sit on the personal account right up until it crossed the line - which is the opposite of
// what its owner asked for. Every entry point takes it as a plain number of percentage points, 0 by
// default, so a fleet where nobody marked an account computes exactly what it did before.

extension LaunchPolicyStore {
    /// The tightest of the windows the account reports (mirrors `UsageSnapshot.make` fields).
    /// Mirror of the CLI's `headroom(_:primaryModel:)`: the flagship window only binds when the
    /// declared primary model IS that tier, so a drained fable window never vetoes an account
    /// whose primary is sonnet. Keep both sides in lockstep.
    static func headroom(_ usage: AccountUsage, primaryModel: String? = nil) -> Double? {
        var windows = [
            usage.metrics.first { $0.kind == .session }?.remainingPercent,
            usage.metrics.first { $0.kind == .weeklyAll }?.remainingPercent,
        ].compactMap { $0 }
        let model = usage.headline.flatMap { $0.isModelScoped ? $0 : nil }
        let windowModel = model?.modelName?.lowercased()
        let primary = primaryModel?.lowercased()
        let modelWindowCounts = primary == nil || windowModel == nil
            || windowModel!.contains(primary!) || primary!.contains(windowModel!)
        if modelWindowCounts, let remaining = model?.remainingPercent { windows.append(remaining) }
        return windows.min()
    }

    /// Mirror of the CLI's burn-rate scoring (TallyCLI/AccountPick.swift `ratedWindows`): each
    /// window's sustainable rate is remaining% ÷ hours until it resets, and the flagship window
    /// only counts when the declared primary model is that tier. Keep both sides in lockstep.
    ///
    /// `resetsAt` is what the provider reported and `anchor` is what the rate was measured
    /// against, and they differ wherever the anchor is inferred. Two inferences, in this order
    /// (the CLI side carries the measurements and the reasoning):
    ///
    ///   - a flagship window reporting no reset borrows the account's weekly one, because both
    ///     turn over on the account's single fixed weekly moment;
    ///   - a FIXED-CYCLE window still at 100% with no reset was never opened (the provider
    ///     publishes a reset only once usage opens the window), so its phase is unknown and it is
    ///     rated against the midpoint of its own length. Without this a never-launched account is
    ///     rated at its worst case, loses every pick, and so never earns a reset to be rated by.
    ///
    /// The session window is the exception to the second inference: its 5h clock starts on the
    /// first message rather than on a moment the provider fixes, so an untouched session window has
    /// its phase KNOWN and its whole 5h ahead of it. Halving it would rate every idle account's
    /// session at 100/2.5 = 40 %/h instead of the true 100/5 = 20 %/h.
    ///
    /// A window BELOW 100% with no reset was spent by someone and simply has no reading (a v1
    /// snapshot, an unpolled account): the conservative full-window assumption stays in place.
    /// Both anchors are inferences, so the badge's REASON quotes `resetsAt` and never the anchor.
    ///
    /// `reserve` is the percentage points its owner keeps for their own use in each window this
    /// account shares with their browser, and it is subtracted from the RATE exactly as the CLI does
    /// it: ranking is where "spend somewhere else if you can" has to bite. It reaches the weekly
    /// all-models window and the 5h session one (`AccountRoles.reservedWindowNames`, which states
    /// why the flagship window is outside the feature), and it never touches `remaining`, which is
    /// the provider's own number and the one a person reads (`smartReason`).
    static func ratedWindows(_ usage: AccountUsage, primaryModel: String?, reserve: Double = 0,
                             now: Date)
        -> [(name: String, remaining: Double, resetsAt: Date?, anchor: Date?, reserve: Double,
             rate: Double)] {
        /// `fixedCycle` marks a window that turns over on a moment the account does not set: the
        /// weekly one, and the flagship window riding on it. Only those get the midpoint reading,
        /// because only their phase is unknown while untouched (above).
        func window(_ name: String, _ metric: UsageMetric?, inferredAnchor: Date? = nil,
                    fullWindowHours: Double, fixedCycle: Bool = false, reserved: Bool = false)
            -> (name: String, remaining: Double, resetsAt: Date?, anchor: Date?, reserve: Double,
                rate: Double)? {
            guard let metric else { return nil }
            let untouchedAnchor = fixedCycle && metric.remainingPercent >= 100
                ? now.addingTimeInterval(fullWindowHours / 2 * 3600) : nil
            let anchor = metric.resetsAt ?? inferredAnchor ?? untouchedAnchor
            let hours = anchor.map { max($0.timeIntervalSince(now) / 3600, 0.05) }
                ?? fullWindowHours
            // The reserve reaches the windows this account shares with the user's browser and no
            // other, marked at the same point the CLI marks it (Tally/Core/AccountReserve.swift
            // owns the ruling). Both conditions, so this fails closed in either direction: the
            // call site has to opt in AND the ruling has to name the window.
            let held = reserved && AccountRoles.reservedWindowNames.contains(name) ? reserve : 0
            return (name, metric.remainingPercent, metric.resetsAt, anchor, held,
                    (metric.remainingPercent - held) / hours)
        }
        let weekly = usage.metrics.first { $0.kind == .weeklyAll }
        var windows = [
            window(AccountRoles.sessionWindowName, usage.metrics.first { $0.kind == .session },
                   fullWindowHours: 5, reserved: true),
            window(AccountRoles.weeklyWindowName, weekly, fullWindowHours: 168, fixedCycle: true,
                   reserved: true),
        ].compactMap { $0 }
        let model = usage.headline.flatMap { $0.isModelScoped ? $0 : nil }
        let windowModel = model?.modelName?.lowercased()
        let primary = primaryModel?.lowercased()
        let modelWindowCounts = primary == nil || windowModel == nil
            || windowModel!.contains(primary!) || primary!.contains(windowModel!)
        if modelWindowCounts,
           let m = window(model?.modelName?.lowercased() ?? "model", model,
                          inferredAnchor: weekly?.resetsAt, fullWindowHours: 168,
                          fixedCycle: true) {
            windows.append(m)
        }
        return windows
    }

    /// The account's score is its TIGHTEST window's sustainable rate (the binding constraint).
    static func smartScore(_ usage: AccountUsage, primaryModel: String?, reserve: Double = 0,
                                   now: Date = Date()) -> Double {
        ratedWindows(usage, primaryModel: primaryModel, reserve: reserve, now: now)
            .map { $0.rate }.min() ?? -1
    }

    /// What the nearly-dry gate weighs for this account: exactly the windows the declared primary
    /// model spends, keyed on the ANCHOR (mirror of the CLI's `comfortWindow`, TallyCLI/
    /// AccountBinding.swift) - the gate asks when the wall comes down, and a flagship window with no
    /// reset of its own hits the account's weekly one. The reserve rides across with them, so the
    /// gate weighs the same windows the score did.
    static func comfortWindows(_ usage: AccountUsage, primaryModel: String?, reserve: Double = 0,
                               now: Date) -> [ComfortWindow] {
        ratedWindows(usage, primaryModel: primaryModel, reserve: reserve, now: now)
            .map { ComfortWindow(remaining: $0.remaining, resetsAt: $0.anchor, reserve: $0.reserve) }
    }

    /// Whether this account still has quota above the line its owner drew - EVERY reserved window
    /// read through the gate's own scale. Mirror of the CLI's `aboveReserve`, lookup included: the
    /// line is drawn on the weekly all-models window and the 5h session one, so an account under it
    /// on either of them is under its water line, and a drained flagship window is not. Every
    /// reserved window and not the first one found: two carry the number now, and reading one would
    /// make which of them binds depend on the order this array happens to be built in.
    ///
    /// It answers yes for every account nobody reserved anything on, which is what keeps the drought
    /// fallback in `autoPickID` unreachable on an unmarked fleet - and yes for an account reporting
    /// no reserved window at all, which is the missing-data reading `accountIsSpent` names.
    static func aboveReserve(_ usage: AccountUsage, primaryModel: String?, reserve: Double,
                             now: Date) -> Bool {
        guard reserve > 0 else { return true }
        return comfortWindows(usage, primaryModel: primaryModel, reserve: reserve, now: now)
            .filter { $0.reserve > 0 }
            .allSatisfy { effectiveRemaining($0, now: now) > 0 }
    }

    /// Badge-facing reason for the smart pick, mirroring the CLI's `pickReason`:
    /// the binding window and its reset, e.g. "weekly 94% · resets 4d".
    ///
    /// RESERVE-BLIND, and it takes no reserve to be so, exactly as `pickReason` is: this is a
    /// sentence for a person, and "weekly 94%" has to mean the same thing here, on the card's own
    /// meters and on claude.ai. A reserve can shift which window binds a PICK; it may never make a
    /// tooltip quote a figure the provider did not publish.
    static func smartReason(_ usage: AccountUsage, primaryModel: String?,
                            now: Date = Date()) -> String? {
        guard let binding = ratedWindows(usage, primaryModel: primaryModel, now: now)
            .min(by: { $0.rate < $1.rate }) else { return nil }
        var text = "\(binding.name) \(Int(binding.remaining.rounded()))%"
        if let resetsAt = binding.resetsAt {
            let minutes = max(Int((resetsAt.timeIntervalSince(now) / 60).rounded()), 0)
            let eta = minutes < 60 ? "\(minutes)m"
                : minutes < 48 * 60 ? "\(minutes / 60)h" : "\(minutes / (24 * 60))d"
            text += " · resets \(eta)"
        }
        return text
    }}
