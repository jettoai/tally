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

    func policy(_ providerID: String) -> ProviderPolicy {
        policies[providerID] ?? ProviderPolicy()
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

    /// The account auto mode would launch right now - the same rule as the CLI's `best()`
    /// (burn-rate scoring; capped/stale/errored accounts are out), so the panel's badge always
    /// predicts what `tally` will actually do.
    /// Mirror of the CLI's `smartPickMargin` / `smartPickMinGain` - keep in lockstep.
    /// Two gates: the ratio alone lies at the low end (2% vs 3% remaining reads as +50%), so a
    /// challenger must also win by an absolute rate gain or nearly-drained siblings ping-pong.
    private static let smartPickMargin = 1.15
    private static let smartPickMinGain = 0.05   // %/h

    func autoPickID(providerID: String, accounts: [AccountUsage], launchable: Set<String>) -> String? {
        let primary = policy(providerID).model
        let candidates = accounts
            .filter { $0.providerID == providerID && $0.error == nil && !$0.isStale
                && launchable.contains($0.id) && (Self.headroom($0) ?? -1) > 0 }
        guard var leader = candidates.first else { return nil }
        var leaderScore = Self.smartScore(leader, primaryModel: primary)
        for candidate in candidates.dropFirst() {
            let score = Self.smartScore(candidate, primaryModel: primary)
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
    private static func headroom(_ usage: AccountUsage) -> Double? {
        let windows = [
            usage.metrics.first { $0.kind == .session }?.remainingPercent,
            usage.metrics.first { $0.kind == .weeklyAll }?.remainingPercent,
            usage.headline.flatMap { $0.isModelScoped ? $0.remainingPercent : nil },
        ].compactMap { $0 }
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
