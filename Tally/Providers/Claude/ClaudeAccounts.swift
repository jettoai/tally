import Foundation

/// Discovers Claude Code accounts on this machine. Discovery only PROBES that each config dir's
/// Keychain login exists (an attribute check - the secret is never read); usage itself is fetched
/// through the official CLI (`ClaudeUsageCLI`), so Tally never touches a credential.
///
/// Claude Code namespaces its Keychain item by config dir: the default `~/.claude` uses the bare
/// service name; any dir set via `CLAUDE_CONFIG_DIR` (e.g. `~/.claude2`) appends
/// `-<first 8 hex of SHA-256 of the absolute dir path>`. This is what lets Tally monitor two Max
/// accounts independently - the whole point of the project.
enum ClaudeAccounts {
    static let providerID = "claude"

    /// Keychain service name for a given config dir. `~/.claude` → bare; others → hashed suffix.
    ///
    /// The derivation itself lives in Core/Keychain/ClaudeKeychainService.swift because `tally add`
    /// needs the identical name to tell a logged-in home from a free slot, and two copies of a hash
    /// rule fail silently when they drift (a wrong name simply finds nothing, which is
    /// indistinguishable from "not logged in").
    static func service(forConfigDir dir: URL) -> String {
        claudeKeychainService(forConfigDir: dir)
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

    /// What the account's non-secret CLI config (`.claude.json` → `oauthAccount`) can say about the
    /// account itself. The config file carries no credentials - the OAuth token lives in the
    /// Keychain, which Tally never reads - and per-account dirs each have their own copy.
    struct Profile {
        /// e.g. `organizationRateLimitTier` "default_claude_max_20x" → "Max 20x".
        var plan: String?
        /// The signed-in email, shown only as the card's hover tooltip. Never logged or published.
        var email: String?
    }

    /// Both config-derived account facts in one decode: the file runs to six figures of bytes
    /// (chat history lives there too), so parsing it once per refresh rather than once per field
    /// matters.
    /// Addressed through the shared `claudeStateFile(forConfigDir:)`: the default home keeps its
    /// state one level up, at `~/.claude.json`, and a `~/.claude/.claude.json` that happens to sit
    /// there is a stale copy that names whoever was signed in when it was left behind.
    static func profile(configDir: String) -> Profile {
        let url = claudeStateFile(forConfigDir: URL(fileURLWithPath: configDir, isDirectory: true))
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data),
              let account = config.oauthAccount else { return Profile() }
        return Profile(plan: account.planLabel, email: account.email)
    }

    private struct Config: Decodable {
        var oauthAccount: Account?

        struct Account: Decodable {
            var organizationRateLimitTier: String?
            var organizationType: String?
            var emailAddress: String?

            var email: String? {
                guard let value = emailAddress, !value.isEmpty else { return nil }
                return value
            }

            var planLabel: String? {
                if let tier = organizationRateLimitTier, !tier.isEmpty {
                    let trimmed = tier
                        .replacingOccurrences(of: "default_", with: "")
                        .replacingOccurrences(of: "claude_", with: "")
                    let pretty = trimmed.split(separator: "_")
                        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                        .joined(separator: " ")
                    if !pretty.isEmpty { return pretty }
                }
                // Fallback: organizationType "claude_max" → "Max".
                if let type = organizationType?.split(separator: "_").last {
                    return type.prefix(1).uppercased() + type.dropFirst()
                }
                return nil
            }
        }
    }
}
