import Foundation

/// Discovers the Codex (ChatGPT) account. Discovery only checks that `auth.json` EXISTS (a
/// logged-in signal) - its contents are never read; usage comes through the official CLI's
/// app-server (`CodexAppServerClient`), so Tally never touches the token inside.
enum CodexAccounts {
    static let providerID = "codex"

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

}
