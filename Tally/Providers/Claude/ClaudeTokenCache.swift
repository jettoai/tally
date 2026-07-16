import Foundation

/// Gates Keychain reads of Claude credentials. It does NOT cache the token across refreshes.
///
/// Why not cache: Claude Code rotates its OAuth token periodically. A cached token whose local
/// `expiresAt` is still in the future can be one the server has already rotated out, so sending it
/// returns 401 ("re-login") even though the Keychain holds a fresh, valid token. Reading the Keychain
/// is silent once the user has granted access ("Always Allow"), so we read fresh every time and always
/// use the current token.
///
/// The one thing worth remembering is a FAILED read (denied / locked / missing): we don't auto-retry
/// it on a background refresh, so a user who declined the access prompt isn't re-prompted every cycle.
/// A user-initiated refresh always retries.
actor ClaudeTokenCache {
    private var failedReads: Set<String> = []

    func credentials(service: String, userInitiated: Bool) -> ClaudeAccounts.Credentials? {
        if !userInitiated && failedReads.contains(service) {
            return nil
        }
        if let credentials = ClaudeAccounts.readCredentials(service: service) {
            failedReads.remove(service)
            return credentials
        }
        failedReads.insert(service)
        return nil
    }

    /// Allow the next read to retry — used after a 401 (the CLI may have refreshed the login) so a
    /// declined/failed service isn't stuck.
    func invalidate(service: String) {
        failedReads.remove(service)
    }
}
