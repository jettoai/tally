import Foundation
import CryptoKit

/// Discovers Claude Code accounts on this machine. Discovery only PROBES that each config dir's
/// Keychain login exists (an attribute check — the secret is never read); usage itself is fetched
/// through the official CLI (`ClaudeUsageCLI`), so Tally never touches a credential.
///
/// Claude Code namespaces its Keychain item by config dir: the default `~/.claude` uses the bare
/// service name; any dir set via `CLAUDE_CONFIG_DIR` (e.g. `~/.claude2`) appends
/// `-<first 8 hex of SHA-256 of the absolute dir path>`. This is what lets Tally monitor two Max
/// accounts independently — the whole point of the project.
enum ClaudeAccounts {
    static let providerID = "claude"
    private static let baseService = "Claude Code-credentials"

    /// Keychain service name for a given config dir. `~/.claude` → bare; others → hashed suffix.
    static func service(forConfigDir dir: URL) -> String {
        if dir.lastPathComponent == ".claude" { return baseService }
        let normalized = dir.path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(baseService)-\(suffix)"
    }

    /// Human label = provider name + the dir's distinguisher: `~/.claude` → "Claude",
    /// `~/.claude2` → "Claude 2", `~/.claude-work` → "Claude work". Users can override with a nickname.
    private static func label(forConfigDir dir: URL) -> String {
        let suffix = dir.lastPathComponent.dropFirst(".claude".count)  // "", "2", "-work"
        let distinguisher = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return distinguisher.isEmpty ? "Claude" : "Claude \(distinguisher)"
    }

    /// Every `~/.claude*` directory whose Keychain login exists, `~/.claude` first.
    static func discover() -> [ProviderAccount] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = []

        let defaultDir = home.appendingPathComponent(".claude", isDirectory: true)
        dirs.append(defaultDir)

        if let entries = try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) {
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                guard name.hasPrefix(".claude"), name != ".claude" else { continue }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                dirs.append(url)
            }
        }

        return dirs.compactMap { dir in
            let svc = service(forConfigDir: dir)
            guard KeychainReader.exists(service: svc) else { return nil }
            return ProviderAccount(
                id: "\(providerID):\(dir.lastPathComponent)",
                providerID: providerID,
                label: label(forConfigDir: dir),
                locator: ["service": svc, "configDir": dir.path],
                launchHome: dir.path
            )
        }
    }

    /// Plan label from the account's non-secret CLI config (`<dir>/.claude.json` →
    /// `oauthAccount.organizationRateLimitTier`, e.g. "default_claude_max_20x" → "Max 20x").
    /// The config file carries no credentials; per-account dirs each have their own copy.
    static func planLabel(configDir: String) -> String? {
        struct Config: Decodable {
            struct Account: Decodable {
                var organizationRateLimitTier: String?
                var organizationType: String?
            }
            var oauthAccount: Account?
        }
        let url = URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data),
              let account = config.oauthAccount else { return nil }

        if let tier = account.organizationRateLimitTier, !tier.isEmpty {
            let trimmed = tier
                .replacingOccurrences(of: "default_", with: "")
                .replacingOccurrences(of: "claude_", with: "")
            let pretty = trimmed.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            if !pretty.isEmpty { return pretty }
        }
        // Fallback: organizationType "claude_max" → "Max".
        if let type = account.organizationType?.split(separator: "_").last {
            return type.prefix(1).uppercased() + type.dropFirst()
        }
        return nil
    }
}
