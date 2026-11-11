import Foundation
import Observation
import OSLog

/// Each Claude account's limit-reset inventory (`ClaudeResetInventory`), for the card and the
/// snapshot. Read-only: nothing here spends a reset.
///
/// ON ITS OWN CADENCE, NOT THE USAGE ROUND'S. The usage endpoint rate-limits, and the inventory
/// changes when Anthropic grants or the user spends, not by the minute, so each account is asked at
/// most once per `interval`; an explicit refresh asks sooner, down to `userFloor`.
///
/// A FAILED READ CHANGES NOTHING ELSE. The account's quota reading and login state are not this
/// store's; a 401, 429 or dropped connection only marks a held-over inventory stale, and an account
/// never read stays absent, which the card draws as nothing rather than as "no resets".
@MainActor
@Observable
final class ClaudeResetInventoryStore {
    static let shared = ClaudeResetInventoryStore()

    typealias Entry = ClaudeResetInventoryLedger.Entry

    /// Readings, cadence and which answers still count (ClaudeResetInventoryLedger: a reading
    /// belongs to the login it was taken under, not to the home).
    private var ledger = ClaudeResetInventoryLedger()
    var entries: [String: Entry] { ledger.entries }

    static let interval: TimeInterval = 600
    static let userFloor: TimeInterval = 30
    private static let log = Logger(subsystem: "ai.jetto.tally", category: "reset-inventory")
    /// Claude Code's installed version for the request's User-Agent, resolved once, on first use,
    /// inside the fetch's detached task (never on the main thread, never by running the CLI).
    nonisolated private static let claudeVersion =
        ClaudeResetInventoryFetch.version(executable: CLIRunner.resolve("claude"))

    private init() {}

    func entry(_ accountID: String) -> Entry? { ledger.entries[accountID] }

    /// Ask every due Claude account in `accounts`; `known` prunes readings of accounts that are gone.
    func evaluate(accounts: [ProviderAccount], known: Set<String>, userInitiated: Bool) {
        guard !DemoUsage.isActive else { return }
        ledger.prune(known: known)
        let now = Date()
        let wait = userInitiated ? Self.userFloor : Self.interval
        for account in accounts where account.providerID == "claude" && !account.isDormant {
            guard let home = account.launchHome,
                  let generation = ledger.begin(account.id, now: now, wait: wait) else { continue }
            let id = account.id
            Task { [weak self] in
                // Whose login this asks under, read beside the token so the answer is filed to it.
                let identity = await Task.detached(priority: .utility) {
                    ClaudeAccounts.profile(configDir: home).accountUUID
                }.value
                let outcome = await ClaudeResetInventoryFetch.fetch(home: home,
                                                                    clientVersion: { Self.claudeVersion })
                self?.land(id, generation: generation, outcome: outcome, identity: identity)
            }
        }
    }

    /// A login landed or was renewed in this account's home, which may be another login than the
    /// one the reading belongs to: the reading goes now and the next round asks again.
    func invalidate(_ accountID: String) {
        if ledger.invalidate(accountID) { UsageStore.shared.republishSnapshot() }
    }

    /// What each home's config named this refresh (`oauthAccount.accountUuid`). A home now naming
    /// another login than its reading was taken under loses the reading. In memory only.
    func note(identities: [String: String?]) {
        var dropped = false
        for (id, identity) in identities where ledger.note(id, identity: identity) { dropped = true }
        if dropped { UsageStore.shared.republishSnapshot() }
    }

    private func land(_ id: String, generation: Int, outcome: ClaudeResetInventoryFetch.Outcome,
                      identity: String?) {
        let before = ledger.entries[id]
        guard ledger.land(id, generation: generation, outcome: outcome, identity: identity, now: Date()) else {
            Self.log.info("state=superseded account=\(id, privacy: .private(mask: .hash))")
            return
        }
        switch outcome {
        case .read(let inventory):
            Self.log.info("state=read account=\(id, privacy: .private(mask: .hash)) eligible=\(inventory.eligible, privacy: .public) left=\(inventory.left, privacy: .public)")
        case .noCredential:
            Self.log.info("state=no-credential account=\(id, privacy: .private(mask: .hash))")
        case .failed(let status):
            Self.log.info("state=failed account=\(id, privacy: .private(mask: .hash)) status=\(status ?? 0, privacy: .public)")
        }
        if ledger.entries[id] != before { UsageStore.shared.republishSnapshot() }
    }

    /// The snapshot's per-account fields (`UsageSnapshot.LimitResets`). Kinds and counts only.
    var snapshotFields: [String: UsageSnapshot.LimitResets] {
        entries.mapValues { entry in
            UsageSnapshot.LimitResets(
                eligible: entry.inventory.eligible,
                resets: entry.inventory.grants.map {
                    .init(kind: $0.name, left: $0.left, total: $0.total, endsAt: $0.endsAt)
                },
                source: "oauth", checkedAt: entry.checkedAt, isStale: entry.isStale)
        }
    }
}
