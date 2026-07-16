import Foundation

/// The Claude (Max/Pro) usage provider. Reads each `~/.claude*` account's OAuth token from the
/// Keychain and fetches its live session/weekly/per-model limits.
///
/// Read-only by design: if a token is expired, Tally skips that poll and lets the running `claude`
/// CLI refresh it, rather than racing the CLI's refresh-token rotation (which would invalidate the
/// CLI's login). See NORTH_STAR "不在範圍".
struct ClaudeProvider: UsageProvider {
    let id = ClaudeAccounts.providerID
    let displayName = "Claude"

    private let client = ClaudeUsageClient()
    private let tokenCache = ClaudeTokenCache()

    func discoverAccounts() -> [ProviderAccount] {
        ClaudeAccounts.discover()
    }

    func fetchUsage(for account: ProviderAccount, userInitiated: Bool) async -> AccountUsage {
        guard let service = account.locator["service"] else {
            return .failure(account: account, providerID: id, message: L("Missing keychain locator"))
        }
        // Read the token via the session cache so the Keychain (and its access prompt) is hit at most
        // once per account per session; background refreshes never re-prompt a declined read.
        guard let credentials = await tokenCache.credentials(service: service, userInitiated: userInitiated) else {
            return .failure(account: account, providerID: id, message: L("No credentials — run `claude` to sign in"))
        }

        if let expiry = expiryDate(credentials.expiresAt), expiry < Date() {
            return .failure(account: account, providerID: id, message: L("Token expired — run `claude` to refresh"))
        }

        do {
            let response = try await client.fetchUsage(accessToken: credentials.accessToken)
            switch response.statusCode {
            case 200:
                let metrics = ClaudeUsageMapper.map(data: response.body)
                if metrics.isEmpty {
                    return .failure(account: account, providerID: id, message: L("No usage data"))
                }
                return AccountUsage(
                    id: account.id, providerID: id, accountLabel: account.label,
                    planName: ClaudeUsageMapper.plan(credentials), metrics: metrics,
                    refreshedAt: Date(), error: nil
                )
            case 401, 403:
                await tokenCache.invalidate(service: service)  // CLI may have refreshed; re-read next time
                return .failure(account: account, providerID: id, message: L("Re-login for live usage (run `claude`)"))
            case 429:
                return .failure(account: account, providerID: id, message: L("Rate limited — try again later"))
            default:
                return .failure(account: account, providerID: id, message: "HTTP \(response.statusCode)")
            }
        } catch {
            return .failure(account: account, providerID: id, message: L("Network error"))
        }
    }

    /// `expiresAt` may be seconds or milliseconds since epoch; treat large values as ms.
    private func expiryDate(_ raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}
