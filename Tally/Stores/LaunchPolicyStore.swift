import Foundation
import Observation

/// Which account new CLI sessions launch on, per provider - the USER-INTENT half of the app↔CLI
/// contract, published to `~/.tally/state.json`. The facts half is `UsageSnapshot` (usage numbers,
/// app → CLI, read-only); this file carries choices (UI writes, the `tally` CLI reads on every
/// launch). Separate files so the two writers never race over one document.
///
/// Modes, per provider:
/// - `off`     - observe only: Tally never steers a launch (a dashboard, nothing more), and never
///               moves a RUNNING session between accounts either - no cap handoff, no rebalance,
///               no repick when a window closes, no move at a `tally session clear`. The supervisor
///               still runs everything that is not an account decision (the status line, the board,
///               `tally session send`, the model follow, self-update). Asking `tally claude` for a
///               launch is still an explicit ask and still picks; what off forbids is the choices
///               nobody asked for. The CLI end is TallyCLI/AutoSteering.swift, which lists every
///               mover this reaches.
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
        /// The account artifacts are published from. TOP LEVEL rather than inside a provider's
        /// policy, because it is not a launch decision: it says which Claude account the person at
        /// this machine is signed into in their BROWSER, which is the one fact a session cannot see
        /// and the one the Artifact guard compares against (Tally/Core/ArtifactHookContract.swift).
        ///
        /// Optional, and the schema only ever GAINS keys: `version` does not move, a supervisor
        /// from an older build decodes this document exactly as it did before, and a state file
        /// written before this key existed simply has no answer here.
        var artifactAccount: String?
    }

    private(set) var policies: [String: ProviderPolicy]

    /// The Claude config home artifacts are published from, or nil while nobody has chosen one.
    ///
    /// NIL IS AN ANSWER, and it is the one the CLI abstains on: the guard is a convenience rather
    /// than a gate, so a machine that has never named an account is never told it may not publish
    /// (TallyCLI/HookArtifact.swift). What stops the row from being inert is the install seeding
    /// this (`artifactAccountSeed`), never a default invented at read time here.
    private(set) var artifactAccount: String?

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let file = try? JSONDecoder().decode(StateFile.self, from: data) {
            policies = file.launch
            artifactAccount = file.artifactAccount
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

    /// Name the account artifacts are published from. Empty/whitespace collapses to nil, the same
    /// rule as `setLaunchDefault`: nothing chosen is a state the guard understands.
    func setArtifactAccount(_ home: String?) {
        let trimmed = home?.trimmingCharacters(in: .whitespaces)
        artifactAccount = (trimmed?.isEmpty == false) ? trimmed : nil
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
    func forget(accountID: String, home: String) {
        // THE ARTIFACT ACCOUNT IS STORED AS A HOME, so the id above cannot reach it: it is the one
        // setting here that names a directory rather than an account, and a removal that left it
        // standing pointed the guard at a config home in the Trash. What that costs is not a stale
        // string - it is every publish on the machine refused, with an instruction to move to a
        // folder that is gone, and a later `~/.claude3` silently inheriting the choice (codex review
        // of 7113edc). The CLI carries its own defence for the versions that do not do this
        // (`artifactAccountStanding`); this is the one that keeps the file honest.
        artifactAccount = Self.artifactAccountAfterRemoving(artifactAccount, home: home)
        for (providerID, policy) in policies where policy.pinnedAccountID == accountID {
            var updated = policy
            updated.pinnedAccountID = nil
            updated.pinnedHome = nil
            if updated.mode == .manual { updated.mode = .auto }
            policies[providerID] = updated
        }
        // Written whether or not a PIN moved: the account being removed is frequently not the pinned
        // one, and a clearing that only reached the disk when something else also changed is a
        // clearing that survives in memory and nowhere else.
        persist()
    }

    /// The Artifact publishing account after a config home has been removed: nil when that home IS
    /// the chosen one, and the choice untouched otherwise.
    ///
    /// Compared through `artifactAccountHome`, the same normalization the CLI compares with, so a
    /// choice stored with a trailing slash or through a symlink is still recognised as the home
    /// being removed. Text rather than a filesystem identity read because by the time this is asked
    /// the directory has already gone to the Trash (`artifactAccountHome` states it in full).
    ///
    /// Pure, so the rule is assertable without a state file to write into.
    static func artifactAccountAfterRemoving(_ current: String?, home: String) -> String? {
        guard let current, let removed = artifactAccountHome(home),
              artifactAccountHome(current) == removed else { return current }
        return nil
    }

    func isPinned(_ accountID: String, providerID: String) -> Bool {
        let p = policy(providerID)
        return p.mode == .manual && p.pinnedAccountID == accountID
    }

    private func persist() {
        // A build nobody installed edits its policies in memory only (the UI stays testable) but
        // never publishes: ~/.tally/state.json is what the CLI steers real launches by, and that
        // contract belongs to the installed release app alone. The dev variant is one such build; a
        // locally built Release is the other, and it would pin the user's real launches to whichever
        // account a test window happened to select (`isUnshipped`).
        guard !BuildVariant.isUnshipped else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(StateFile(launch: policies,
                                                       artifactAccount: artifactAccount))
        else { return }
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
                // The ANCHOR, exactly as the CLI's `comfortWindow` does: the gate asks when the
                // wall comes down, and a flagship window with no reset of its own hits the
                // account's weekly one.
                .map { ComfortWindow(remaining: $0.remaining, resetsAt: $0.anchor) }
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
    private static func ratedWindows(_ usage: AccountUsage, primaryModel: String?, now: Date)
        -> [(name: String, remaining: Double, resetsAt: Date?, anchor: Date?, rate: Double)] {
        /// `fixedCycle` marks a window that turns over on a moment the account does not set: the
        /// weekly one, and the flagship window riding on it. Only those get the midpoint reading,
        /// because only their phase is unknown while untouched (above).
        func window(_ name: String, _ metric: UsageMetric?, inferredAnchor: Date? = nil,
                    fullWindowHours: Double, fixedCycle: Bool = false)
            -> (name: String, remaining: Double, resetsAt: Date?, anchor: Date?, rate: Double)? {
            guard let metric else { return nil }
            let untouchedAnchor = fixedCycle && metric.remainingPercent >= 100
                ? now.addingTimeInterval(fullWindowHours / 2 * 3600) : nil
            let anchor = metric.resetsAt ?? inferredAnchor ?? untouchedAnchor
            let hours = anchor.map { max($0.timeIntervalSince(now) / 3600, 0.05) }
                ?? fullWindowHours
            return (name, metric.remainingPercent, metric.resetsAt, anchor,
                    metric.remainingPercent / hours)
        }
        let weekly = usage.metrics.first { $0.kind == .weeklyAll }
        var windows = [
            window("session", usage.metrics.first { $0.kind == .session }, fullWindowHours: 5),
            window("weekly", weekly, fullWindowHours: 168, fixedCycle: true),
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
