import Foundation
import Security

/// Probes generic-password Keychain items for account discovery.
///
/// Probe only — Tally NEVER reads a secret: usage is fetched through each provider's official CLI
/// (`ClaudeUsageCLI` / `CodexAppServerClient`), which handles its own credentials. The attribute
/// query below returns no secret data, so it never raises a macOS consent prompt either.
enum KeychainReader {
    /// Existence probe by attributes only (no secret returned). Used for account discovery.
    static func exists(service: String, account: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecInteractionNotAllowed = item exists but is locked; still "present".
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}
