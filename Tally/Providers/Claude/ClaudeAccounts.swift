import Foundation
import CryptoKit

/// Discovers Claude Code accounts on this machine and reads their OAuth credential.
///
/// Claude Code namespaces its Keychain item by config dir: the default `~/.claude` uses the bare
/// service name; any dir set via `CLAUDE_CONFIG_DIR` (e.g. `~/.claude2`) appends
/// `-<first 8 hex of SHA-256 of the absolute dir path>`. This is what lets Tally monitor two Max
/// accounts independently — the whole point of the project.
enum ClaudeAccounts {
    static let providerID = "claude"
    private static let baseService = "Claude Code-credentials"

    /// The OAuth blob stored (as JSON) in the Keychain item, under key `claudeAiOauth`.
    struct Credentials: Decodable, Sendable {
        var accessToken: String
        var expiresAt: Double?
        var subscriptionType: String?
        var rateLimitTier: String?
    }

    private struct Wrapper: Decodable { var claudeAiOauth: Credentials }

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

    /// Read and decode the OAuth credential for a discovered account. The token is never logged.
    static func readCredentials(service: String) -> Credentials? {
        guard let data = KeychainReader.genericPassword(service: service),
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { return nil }
        return wrapper.claudeAiOauth
    }
}
