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
        guard CLIRunner.resolve("codex") != nil else {
            return .failure(account: account, providerID: id, message: L("Codex CLI not found"))
        }
        let reading: CodexAppServerClient.Reading
        switch await CodexAppServerClient.read(codexHome: home) {
        case .ok(let value):
            reading = value
        case .cliBroken:
            return .failure(account: account, providerID: id,
                            message: L("Codex CLI outdated, update it"))
        case .failed:
            return .failure(account: account, providerID: id, message: L("Codex CLI read failed"))
        }
        guard !reading.metrics.isEmpty else {
            return .failure(account: account, providerID: id, message: L("No usage data"))
        }
        return AccountUsage(
            id: account.id, providerID: id, accountLabel: account.label,
            planName: reading.plan, metrics: reading.metrics,
            refreshedAt: Date(), error: nil,
            resetCreditsAvailable: reading.resetCreditsAvailable,
            resetCreditsNextExpiry: reading.resetCreditsNextExpiry
        )
    }
}
