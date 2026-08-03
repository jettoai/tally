import Foundation
import Observation

/// Which account new CLI sessions launch on, per provider - the USER-INTENT half of the app↔CLI
/// contract, published to `~/.tally/state.json`. The facts half is `UsageSnapshot` (usage numbers,
/// app → CLI, read-only); this file carries choices (UI writes, the `tally` CLI reads on every
/// launch). Separate files so the two writers never race over one document.
///
/// Modes, per provider:
/// - `off`     - observe only: Tally never steers a launch (a dashboard, nothing more).
/// - `manual`  - the user pinned one account (clicking a card in the panel); every launch uses it.
/// - `auto`    - every launch picks the account with the most proven headroom at that moment.
@MainActor
@Observable
final class LaunchPolicyStore {
    enum Mode: String, Codable, CaseIterable { case off, manual, auto }

    /// Claude Code permission mode injected at launch ("default" injects nothing). User-typed
    /// permission flags always win over this setting.
    enum PermissionMode: String, Codable, CaseIterable {
        case standard = "default", plan, acceptEdits, bypass
    }

    struct ProviderPolicy: Codable, Equatable {
        var mode: Mode = .auto
        /// The pinned account (manual mode): id for the UI, launch home denormalized alongside so
        /// the CLI can still launch it even when the account drops out of the snapshot briefly.
        var pinnedAccountID: String?
        var pinnedHome: String?
        var permissionMode: PermissionMode?
        /// "continue" = bare launches resume the directory's latest conversation (escape hatch:
        /// `tally claude --new`). nil = start fresh, the CLI's own default.
        var startMode: String?
        /// Launch defaults appended by the tally launcher; nil = inject nothing. Free text for
        /// model names (they drift too fast for a hard-coded picker).
        var model: String?
        var fallbackModel: String?
        var effort: String?
        /// Fallback pairing, applied by the supervisor ONLY after the session's actual model
        /// has degraded to the fallback: a weaker model can deserve a different depth and flags.
        var fallbackEffort: String?
        var fallbackArgs: String?
    }

    static let shared = LaunchPolicyStore()
    static let fileURL = UsageSnapshot.directory.appendingPathComponent("state.json")

    private struct StateFile: Codable {
        var version = 1
        var launch: [String: ProviderPolicy]
    }

    private(set) var policies: [String: ProviderPolicy]

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let file = try? JSONDecoder().decode(StateFile.self, from: data) {
            policies = file.launch
        } else {
            policies = [:]
        }
    }

    /// Factory defaults for a provider the user has never configured (Albert's call, 2026-07-20):
    /// the target user runs several paid accounts hard, so bare launches continue the last
    /// conversation without permission prompts, on the flagship tier with a deep-reasoning
    /// fallback pairing. "fable" / "opus" are stable aliases (tier 1 / tier 2); "ultracode" is
    /// accepted by `claude --effort` even though its help enum omits it (parse-verified on
    /// 2.1.215). The first user edit persists an entry and wins forever after.
    static func factoryDefault(_ providerID: String) -> ProviderPolicy {
        var policy = ProviderPolicy()
        policy.permissionMode = .bypass
        policy.startMode = "continue"
        if providerID == "claude" {
            policy.model = "fable"
            policy.effort = "high"
            policy.fallbackModel = "opus"
            policy.fallbackEffort = "ultracode"
        } else {
            policy.model = "gpt-5.6-sol"   // tier 1, same rationale as fable above
            policy.effort = "xhigh"
        }
        return policy
    }

    func policy(_ providerID: String) -> ProviderPolicy {
        policies[providerID] ?? Self.factoryDefault(providerID)
    }

    func mode(_ providerID: String) -> Mode { policy(providerID).mode }

    func setMode(_ providerID: String, _ mode: Mode) {
        var updated = policy(providerID)
        updated.mode = mode
        policies[providerID] = updated
        persist()
    }

    func setPermissionMode(_ providerID: String, _ mode: PermissionMode) {
        var updated = policy(providerID)
        updated.permissionMode = mode == .standard ? nil : mode
        policies[providerID] = updated
        persist()
    }

    /// Generic launch-default setter: empty/whitespace collapses to nil (= inject nothing).
    func setLaunchDefault(_ providerID: String, _ keyPath: WritableKeyPath<ProviderPolicy, String?>,
                          _ value: String?) {
        var updated = policy(providerID)
        let trimmed = value?.trimmingCharacters(in: .whitespaces)
        updated[keyPath: keyPath] = (trimmed?.isEmpty == false) ? trimmed : nil
        policies[providerID] = updated
        persist()
    }

    /// Write the model+effort pair in ONE persist, so a running session's follow sees a single
    /// atomic change rather than two writes seconds apart (model, then effort) that the supervisor
    /// had to debounce. The Settings row stages both and calls this once on Apply. Empty/whitespace
    /// collapses to nil, same rule as `setLaunchDefault`.
    func setLaunchPair(_ providerID: String, model: String?, effort: String?) {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespaces)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        var updated = policy(providerID)
        updated.model = clean(model)
        updated.effort = clean(effort)
        policies[providerID] = updated
        persist()
    }

    /// Pin one account (and switch the provider to manual - pinning IS choosing manual).
    /// Mutates in place so unrelated settings (e.g. permission mode) survive the click.
    func pin(_ providerID: String, accountID: String, home: String?) {
        var updated = policy(providerID)
        updated.mode = .manual
        updated.pinnedAccountID = accountID
        updated.pinnedHome = home
        policies[providerID] = updated
        persist()
    }

    /// Let go of the denormalized launch home of any pin whose account has gone DORMANT (signed out
    /// with its config home still on disk).
    ///
    /// The home is the half the CLI can act on without asking anything: `pinnedHome` is published so
    /// a pin survives its account briefly dropping out of the snapshot, so a stale one kept `tally`
    /// exec'ing a signed-out config dir long after the panel stopped offering the pin (2026-08-03).
    /// The launcher ignores it too (`pinnedLaunchHome`, TallyCLI/AccountPick.swift) - both halves,
    /// because either alone still leaves a version of the pair that launches a dormant home.
    ///
    /// The pinned ID deliberately STAYS: the pin is the user's choice, and renewing the login makes
    /// it steer launches again with no second click. And this is driven by a POSITIVE fact (this
    /// account exists and is dormant), never by absence - a discovery hiccup must not silently
    /// rewrite what the user chose.
    func releasePinnedHome(dormant: Set<String>) {
        guard !dormant.isEmpty else { return }
        var changed = false
        for (providerID, policy) in policies where policy.pinnedHome != nil {
            guard let pinnedID = policy.pinnedAccountID, dormant.contains(pinnedID) else { continue }
            var updated = policy
            updated.pinnedHome = nil
            policies[providerID] = updated
            changed = true
        }
        if changed { persist() }
    }

    /// Drop a pin whose account has been REMOVED (its config home is in the Trash).
    ///
    /// Both halves go, unlike `releasePinnedHome` above: that one keeps the id because a signed-out
    /// account can be renewed and should steer launches again with no second click, while this one
    /// is about an account that no longer exists. Manual mode goes back to Smart with it - manual
    /// with nothing pinned is a provider whose launches are steered by an id that resolves to
    /// nothing.
    func forget(accountID: String) {
        var changed = false
        for (providerID, policy) in policies where policy.pinnedAccountID == accountID {
            var updated = policy
            updated.pinnedAccountID = nil
            updated.pinnedHome = nil
            if updated.mode == .manual { updated.mode = .auto }
            policies[providerID] = updated
            changed = true
        }
        if changed { persist() }
    }

    func isPinned(_ accountID: String, providerID: String) -> Bool {
        let p = policy(providerID)
        return p.mode == .manual && p.pinnedAccountID == accountID
    }

    private func persist() {
        // The dev variant edits its policies in memory only (the UI stays testable) but never
        // publishes: ~/.tally/state.json is what the CLI steers real launches by, and that
        // contract belongs to the installed release app alone.
        guard !BuildVariant.isDev else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(StateFile(launch: policies)) else { return }
        try? FileManager.default.createDirectory(at: UsageSnapshot.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: Auto-pick preview

    /// The account auto mode would launch right now - the same rule as the CLI's `launchPick()`
    /// (burn-rate scoring; capped/stale/errored/quarantined accounts are out), so the panel's
    /// badge always predicts what `tally` will actually do.
    /// Mirror of the CLI's `smartPickMargin` / `smartPickMinGain` - keep in lockstep.
    /// Two gates: the ratio alone lies at the low end (2% vs 3% remaining reads as +50%), so a
    /// challenger must also win by an absolute rate gain or nearly-drained siblings ping-pong.
    private static let smartPickMargin = 1.15
    private static let smartPickMinGain = 0.05   // %/h

    /// How long a quarantine read is reused. `autoPickID` runs inside a SwiftUI body (once per
    /// account card, on every redraw) and the records are files, so reading them straight would
    /// put a directory scan plus a read per record on the render path. Missing a cap for a few
    /// seconds costs nothing: the badge is a prediction that redraws continuously, and the
    /// launcher itself never uses this cache - it reads the records fresh on every launch.
    private static let quarantineCacheTTL: TimeInterval = 5

    /// Kept out of the observation graph on purpose: a body that mutated observed state would
    /// invalidate the view it is drawing.
    @ObservationIgnored
    private var quarantineCache: (model: String?, readAt: Date, accounts: Set<String>)?

    private func quarantinedNow(primaryModel: String?, now: Date) -> Set<String> {
        if let cache = quarantineCache, cache.model == primaryModel,
           now.timeIntervalSince(cache.readAt) < Self.quarantineCacheTTL, cache.readAt <= now {
            return cache.accounts
        }
        let live = quarantinedAccounts(forPrimary: primaryModel, now: now)
        quarantineCache = (primaryModel, now, live)
        return live
    }

    /// The badge the panel shows. Two steps, exactly as the launcher picks (`launchPick` on the
    /// CLI side): the cap quarantine is applied first, and when it empties the field the
    /// unfiltered pick is shown rather than no badge at all, because that is the account a launch
    /// would still land on. The app had no notion of quarantine until 2026-07-26; on 2026-07-25
    /// the badge sat on a quarantined account and its reader concluded the picker was broken.
    func autoPickID(providerID: String, accounts: [AccountUsage], launchable: Set<String>,
                    now: Date = Date()) -> String? {
        let excluded = quarantinedNow(primaryModel: policy(providerID).model, now: now)
        return autoPickID(providerID: providerID, accounts: accounts, launchable: launchable,
                          excluding: excluded, now: now)
            ?? autoPickID(providerID: providerID, accounts: accounts, launchable: launchable,
                          excluding: [], now: now)
    }

    private func autoPickID(providerID: String, accounts: [AccountUsage], launchable: Set<String>,
                            excluding: Set<String>, now: Date) -> String? {
        let primary = policy(providerID).model
        // The CLI's nearly-dry gate, from the file both targets compile (AccountComfort.swift):
        // the badge has to predict the launch, so the same accounts leave before the ordering.
        let eligibleAccounts = accounts.filter {
            $0.providerID == providerID && $0.error == nil && !$0.isStale
                && launchable.contains($0.id) && !excluding.contains($0.id)
                && (Self.headroom($0, primaryModel: primary) ?? -1) > 0
        }
        let candidates = preferringComfortable(eligibleAccounts, now: now) {
            Self.ratedWindows($0, primaryModel: primary, now: now)
                .map { ComfortWindow(remaining: $0.remaining, resetsAt: $0.resetsAt) }
        }
        guard var leader = candidates.first else { return nil }
        var leaderScore = Self.smartScore(leader, primaryModel: primary, now: now)
        for candidate in candidates.dropFirst() {
            let score = Self.smartScore(candidate, primaryModel: primary, now: now)
            if score > leaderScore * Self.smartPickMargin,
               score > leaderScore + Self.smartPickMinGain {
                leader = candidate
                leaderScore = score
            } else if score >= leaderScore,
                      (candidate.resetCreditsAvailable ?? 0) > (leader.resetCreditsAvailable ?? 0) {
                // Mirror of the CLI's near-tie tie-breaker: a wall with banked resets behind
                // it is softer. Reads the count only; never spends.
                leader = candidate
                leaderScore = score
            }
        }
        return leader.id
    }

    /// The tightest of the windows the account reports (mirrors `UsageSnapshot.make` fields).
    /// Mirror of the CLI's `headroom(_:primaryModel:)`: the flagship window only binds when the
    /// declared primary model IS that tier, so a drained fable window never vetoes an account
    /// whose primary is sonnet. Keep both sides in lockstep.
    private static func headroom(_ usage: AccountUsage, primaryModel: String? = nil) -> Double? {
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

    /// Mirror of the CLI's burn-rate scoring (TallyCLI/Snapshot.swift `ratedWindows`): each
    /// window's sustainable rate is remaining% ÷ hours until it resets (missing reset = assume a
    /// full window), and the flagship window only counts when the declared primary model is that
    /// tier. Keep both sides in lockstep.
    private static func ratedWindows(_ usage: AccountUsage, primaryModel: String?, now: Date)
        -> [(name: String, remaining: Double, resetsAt: Date?, rate: Double)] {
        func window(_ name: String, _ metric: UsageMetric?, fullWindowHours: Double)
            -> (name: String, remaining: Double, resetsAt: Date?, rate: Double)? {
            guard let metric else { return nil }
            let hours = metric.resetsAt.map { max($0.timeIntervalSince(now) / 3600, 0.05) }
                ?? fullWindowHours
            return (name, metric.remainingPercent, metric.resetsAt, metric.remainingPercent / hours)
        }
        var windows = [
            window("session", usage.metrics.first { $0.kind == .session }, fullWindowHours: 5),
            window("weekly", usage.metrics.first { $0.kind == .weeklyAll }, fullWindowHours: 168),
        ].compactMap { $0 }
        let model = usage.headline.flatMap { $0.isModelScoped ? $0 : nil }
        let windowModel = model?.modelName?.lowercased()
        let primary = primaryModel?.lowercased()
        let modelWindowCounts = primary == nil || windowModel == nil
            || windowModel!.contains(primary!) || primary!.contains(windowModel!)
        if modelWindowCounts,
           let m = window(model?.modelName?.lowercased() ?? "model", model, fullWindowHours: 168) {
            windows.append(m)
        }
        return windows
    }

    /// The account's score is its TIGHTEST window's sustainable rate (the binding constraint).
    private static func smartScore(_ usage: AccountUsage, primaryModel: String?,
                                   now: Date = Date()) -> Double {
        ratedWindows(usage, primaryModel: primaryModel, now: now).map { $0.rate }.min() ?? -1
    }

    /// Badge-facing reason for the smart pick, mirroring the CLI's `pickReason`:
    /// the binding window and its reset, e.g. "weekly 94% · resets 4d".
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
    }
}
