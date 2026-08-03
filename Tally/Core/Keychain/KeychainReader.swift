import Foundation
import Security

/// Probes generic-password Keychain items for account discovery.
///
/// Probe only - Tally NEVER reads a secret: usage is fetched through each provider's official CLI
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

    /// When the item was last written, by attributes only - the same query as above with the
    /// modification date asked for, so still no secret and still no consent prompt.
    ///
    /// For telling "a login landed here" from "a credential was already here", which existence
    /// alone cannot answer for the Keychain-only Claude Code shape: a signed-in item and an item
    /// whose refresh token was revoked look identical from outside. Nil for an item that is not
    /// there, and for one macOS will not describe (a locked Keychain answers
    /// `errSecInteractionNotAllowed` with no attributes) - both read as "no news", so a caller
    /// comparing two readings learns nothing rather than learning something wrong.
    static func modifiedAt(service: String, account: String? = nil) -> Date? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }
}
