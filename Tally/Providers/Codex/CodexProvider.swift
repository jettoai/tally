import Foundation

/// The Codex (ChatGPT) usage provider. Reads `~/.codex/auth.json` (no Keychain prompt) and fetches
/// the account's rate-limit windows. Read-only: on 401 it surfaces a re-login hint rather than
/// attempting a token refresh.
struct CodexProvider: UsageProvider {
    let id = CodexAccounts.providerID
    let displayName = "Codex"

    private let client = CodexUsageClient()

    func discoverAccounts() -> [ProviderAccount] {
        CodexAccounts.discover()
    }

    func fetchUsage(for account: ProviderAccount, userInitiated: Bool) async -> AccountUsage {
        guard let path = account.locator["path"] else {
            return .failure(account: account, providerID: id, message: L("Missing auth path"))
        }
        guard let credentials = CodexAccounts.readCredentials(path: path) else {
            return .failure(account: account, providerID: id, message: L("No credentials — run `codex` to sign in"))
        }

        do {
            let response = try await client.fetchUsage(accessToken: credentials.accessToken,
                                                       accountId: credentials.accountId)
            switch response.statusCode {
            case 200:
                let metrics = CodexUsageMapper.map(data: response.body)
                if metrics.isEmpty {
                    return .failure(account: account, providerID: id, message: L("No usage data"))
                }
                return AccountUsage(
                    id: account.id, providerID: id, accountLabel: account.label,
                    planName: CodexUsageMapper.plan(data: response.body), metrics: metrics,
                    refreshedAt: Date(), error: nil)
            case 401, 403:
                return .failure(account: account, providerID: id, message: L("Re-login for live usage (run `codex`)"))
            case 429:
                return .failure(account: account, providerID: id, message: L("Rate limited — try again later"))
            default:
                return .failure(account: account, providerID: id, message: "HTTP \(response.statusCode)")
            }
        } catch {
            return .failure(account: account, providerID: id, message: L("Network error"))
        }
    }
}
