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
        func failed(_ message: String, detail: String? = nil) -> AccountUsage {
            .failure(account: account, providerID: id, message: message, accountEmail: email,
                     errorDetail: detail)
        }
        let reading: CodexAppServerClient.Reading
        switch answer.outcome {
        case .ok(let value):
            reading = value
        case .cliBroken:
            return failed(L("Codex CLI outdated, update it"))
        case .failed(let why):
            // The row keeps the one short line it always had, whatever the vendor said: the reason
            // rides in the callout, where a sentence has room and a width cannot be pushed around
            // by a message this app did not write (`AccountCardView.errorRow`).
            return failed(L("Codex CLI read failed"), detail: why.map(Self.detail))
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

    /// A FAILED READ IN THE APP'S OWN VOICE, one sentence for the callout. The translation lives
    /// here rather than beside the classification so that stays pure and assertable
    /// (`CodexReadFailure`), which is where the redeem outcome next door also splits the two
    /// (`RedeemAction.outcomeMessage`).
    ///
    /// The server's own words are QUOTED AS THE SERVER'S rather than printed as though this app
    /// had written them: an English protocol error under a translated line reads as a bug in the
    /// translation otherwise, and a reader who cannot act on the words can at least see whose
    /// they are.
    static func detail(_ failure: CodexReadFailure) -> String {
        switch failure {
        case .serverSaid(let message):
            return String(format: L("Codex app-server said: %@"), message)
        case .unreadableAnswer:
            return L("Unexpected reply shape from the Codex app-server")
        case .silent(let seconds):
            return String(format: L("No reply within %ds"), seconds)
        }
    }
}
