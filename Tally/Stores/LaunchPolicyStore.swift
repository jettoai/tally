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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(StateFile(launch: policies)) else { return }
        try? FileManager.default.createDirectory(at: UsageSnapshot.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: Auto-pick preview

    /// The account auto mode would launch right now - the same rule as the CLI's `best()`
    /// (greatest min(session, weekly, model remaining); capped/stale/errored accounts are out),
    /// so the panel's badge always predicts what `tally` will actually do.
    func autoPickID(providerID: String, accounts: [AccountUsage], launchable: Set<String>) -> String? {
        accounts
            .filter { $0.providerID == providerID && $0.error == nil && !$0.isStale
                && launchable.contains($0.id) }
            .compactMap { usage in Self.headroom(usage).map { (usage.id, $0) } }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
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
}
