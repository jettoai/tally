import Foundation

/// Discovers the Codex (ChatGPT) account and reads its OAuth token from `auth.json`.
///
/// Unlike Claude, Codex stores its token in a plain file (`~/.codex/auth.json`), so reading it needs
/// no Keychain access and raises no macOS prompt.
enum CodexAccounts {
    static let providerID = "codex"

    struct Credentials: Sendable {
        var accessToken: String
        var accountId: String
    }

    private struct AuthFile: Decodable {
        struct Tokens: Decodable { var access_token: String; var account_id: String }
        var tokens: Tokens
    }

    /// auth.json candidate locations, in priority order.
    private static func candidatePaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [URL] = []
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            paths.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"))
        }
        paths.append(home.appendingPathComponent(".codex/auth.json"))
        paths.append(home.appendingPathComponent(".config/codex/auth.json"))
        return paths
    }

    static func discover() -> [ProviderAccount] {
        for path in candidatePaths() where FileManager.default.fileExists(atPath: path.path) {
            return [ProviderAccount(
                id: "\(providerID):default",
                providerID: providerID,
                label: "Codex",
                locator: ["path": path.path],
                launchHome: path.deletingLastPathComponent().path
            )]
        }
        return []
    }

    static func readCredentials(path: String) -> Credentials? {
        guard let data = FileManager.default.contents(atPath: path),
              let auth = try? JSONDecoder().decode(AuthFile.self, from: data) else { return nil }
        return Credentials(accessToken: auth.tokens.access_token, accountId: auth.tokens.account_id)
    }
}
