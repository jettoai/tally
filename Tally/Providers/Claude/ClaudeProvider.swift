import Foundation

/// The Claude (Max/Pro) usage provider — read entirely through the official CLI
/// (`claude -p "/usage"` per account), so Tally never touches an OAuth token or a vendor endpoint.
/// The CLI runs with its own first-party identity, refreshes its own token when expired, and its
/// requests land in the identified client's rate-limit bucket. See NORTH_STAR "不在範圍".
struct ClaudeProvider: UsageProvider {
    let id = ClaudeAccounts.providerID
    let displayName = "Claude"

    func discoverAccounts() -> [ProviderAccount] {
        ClaudeAccounts.discover()
    }

    func fetchUsage(for account: ProviderAccount, userInitiated: Bool) async -> AccountUsage {
        guard CLIRunner.resolve("claude") != nil else {
            return .failure(account: account, providerID: id, message: L("Claude CLI not found"))
        }
        guard let home = account.launchHome else {
            return .failure(account: account, providerID: id, message: L("No usage data"))
        }
        // Default home runs with CLAUDE_CONFIG_DIR unset (Keychain-namespacing rule; see
        // ClaudeUsageCLI.fetchUsageText).
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").path
        let configDir = (home == defaultHome) ? nil : home

        guard let text = await ClaudeUsageCLI.fetchUsageText(configDir: configDir) else {
            return .failure(account: account, providerID: id, message: L("Claude CLI read failed"))
        }
        if text.contains("Not logged in") || text.contains("/login") {
            return .failure(account: account, providerID: id, message: L("No credentials — run `claude` to sign in"))
        }
        let metrics = ClaudeUsageTextMapper.map(text: text)
        guard !metrics.isEmpty else {
            return .failure(account: account, providerID: id, message: L("No usage data"))
        }
        return AccountUsage(
            id: account.id, providerID: id, accountLabel: account.label,
            planName: ClaudeAccounts.planLabel(configDir: home), metrics: metrics,
            refreshedAt: Date(), error: nil
        )
    }
}
