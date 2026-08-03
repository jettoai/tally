import Foundation

/// The Codex (ChatGPT) usage provider - read entirely through the official CLI's app-server, so
/// Tally never touches Codex credentials. See `CodexAppServerClient`.
struct CodexProvider: UsageProvider {
    let id = CodexAccounts.providerID
    let displayName = "Codex"

    func discoverAccounts() -> [ProviderAccount] {
        CodexAccounts.discover()
    }

    func fetchUsage(for account: ProviderAccount, userInitiated: Bool) async -> AccountUsage {
        guard let home = account.launchHome else {
            return .failure(account: account, providerID: id, message: L("No usage data"))
        }
        // Who the account is comes from the home's own login record rather than from the poll
        // (CodexIdentity.swift), so it is read up front and carried by every outcome below - the
        // same rule as Claude: a card whose poll failed still names its account.
        let email = CodexIdentity.email(codexHome: home)
        func failed(_ message: String) -> AccountUsage {
            .failure(account: account, providerID: id, message: message, accountEmail: email)
        }
        guard CLIRunner.resolve("codex") != nil else {
            return failed(L("Codex CLI not found"))
        }
        let reading: CodexAppServerClient.Reading
        switch await CodexAppServerClient.read(codexHome: home) {
        case .ok(let value):
            reading = value
        case .cliBroken:
            return failed(L("Codex CLI outdated, update it"))
        case .failed:
            return failed(L("Codex CLI read failed"))
        }
        guard !reading.metrics.isEmpty else {
            return failed(L("No usage data"))
        }
        return AccountUsage(
            id: account.id, providerID: id, accountLabel: account.label,
            planName: reading.plan, accountEmail: email, metrics: reading.metrics,
            refreshedAt: Date(), error: nil,
            resetCreditsAvailable: reading.resetCreditsAvailable,
            resetCreditsNextExpiry: reading.resetCreditsNextExpiry
        )
    }
}
