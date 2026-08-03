import Foundation

/// The Claude (Max/Pro) usage provider - read entirely through the official CLI
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
        guard let home = account.launchHome else {
            return .failure(account: account, providerID: id, message: L("No usage data"))
        }
        // Who the account is comes from a plain local file, not from the poll, so it is read up
        // front and carried by every outcome: a card whose first poll failed still names its
        // account, and a config dir signed in as somebody else reports the new identity even while
        // the last-good numbers are the old account's.
        let profile = ClaudeAccounts.profile(configDir: home)
        func failed(_ message: String) -> AccountUsage {
            .failure(account: account, providerID: id, message: message,
                     planName: profile.plan, accountEmail: profile.email)
        }
        guard CLIRunner.resolve("claude") != nil else {
            return failed(L("Claude CLI not found"))
        }
        // Default home runs with CLAUDE_CONFIG_DIR unset (Keychain-namespacing rule; see
        // ClaudeUsageCLI.fetchUsageText).
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").path
        let configDir = (home == defaultHome) ? nil : home

        guard let text = await ClaudeUsageCLI.fetchUsageText(configDir: configDir) else {
            return failed(L("Claude CLI read failed"))
        }
        if text.contains("Not logged in") || text.contains("/login") {
            return failed(L("No credentials: run `claude` to sign in"))
        }
        let metrics = ClaudeUsageTextMapper.map(text: text)
        guard !metrics.isEmpty else {
            return failed(L("No usage data"))
        }
        return AccountUsage(
            id: account.id, providerID: id, accountLabel: account.label,
            planName: profile.plan, accountEmail: profile.email, metrics: metrics,
            refreshedAt: Date(), error: nil
        )
    }
}
