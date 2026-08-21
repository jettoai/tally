import Foundation
import Security

/// Probes generic-password Keychain items for account discovery.
///
/// Probe only - nothing HERE reads a secret: usage is fetched through each provider's official CLI
/// (`ClaudeUsageCLI` / `CodexAppServerClient`), which handles its own credentials. The attribute
/// queries below return no secret data, so they never raise a macOS consent prompt either, and that
/// property is load-bearing for both callers (discovery runs every minute).
///
/// THE ONE PLACE THAT DOES READ A SECRET is the `tally` CLI's MCP authorization seeding
/// (TallyCLI/KeychainSecret.swift, TallyCLI/MCPAuthSync.swift): it merges one config home's MCP
/// grants into another at launch, which cannot be done from attributes. It is in the CLI only, it
/// runs once per launch rather than on a timer, and it never touches the login credential in the
/// same blob. Named here because "Tally never reads a secret" was true of the whole app when this
/// file was written, and a reader who still believes it would be wrong about the CLI.
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
