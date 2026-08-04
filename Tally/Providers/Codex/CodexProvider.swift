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
        // Who the account is comes out of the same session as the numbers (CodexIdentity.swift) and
        // is carried by every outcome below - the same rule as Claude: a card whose poll failed
        // still names its account. Nil here is "this round could not tell", and the surfaces fall
        // back to the last address Tally knew (AccountIdentity.swift).
        let answer = await CodexAppServerClient.read(codexHome: home)
        let email = answer.accountEmail
        func failed(_ message: String) -> AccountUsage {
            .failure(account: account, providerID: id, message: message, accountEmail: email)
        }
        let reading: CodexAppServerClient.Reading
        switch answer.outcome {
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
