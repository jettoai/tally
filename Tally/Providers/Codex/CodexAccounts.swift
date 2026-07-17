import Foundation

/// Discovers Codex (ChatGPT) accounts on this machine. Discovery only checks that each home's
/// `auth.json` EXISTS (a logged-in signal); its contents are never read; usage comes through the
/// official CLI's app-server (`CodexAppServerClient`), so Tally never touches the token inside.
///
/// Codex namespaces everything by its home directory (`CODEX_HOME`, default `~/.codex`), so every
/// `~/.codex*` directory holding an `auth.json` is its own account; one ChatGPT login can hold a
/// different workspace (and therefore a separate quota) in each home. This mirrors
/// `ClaudeAccounts`' `~/.claude*` scan; multi-account side by side is the whole point of the project.
enum CodexAccounts {
    static let providerID = "codex"

    /// Every `~/.codex*` directory (plus `$CODEX_HOME` if set) whose `auth.json` exists,
    /// `~/.codex` first. The XDG location (`~/.config/codex`) stays a fallback for when no
    /// `~/.codex*` login exists, matching the CLI's own lookup order.
    static func discover() -> [ProviderAccount] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = [home.appendingPathComponent(".codex", isDirectory: true)]

        if let entries = try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) {
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                guard name.hasPrefix(".codex"), name != ".codex" else { continue }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                dirs.append(url)
            }
        }
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            dirs.append(URL(fileURLWithPath: codexHome, isDirectory: true))
        }

        var seen = Set<String>()
        var accounts = dirs.compactMap { account(forHome: $0, seen: &seen) }
        if accounts.isEmpty,
           let fallback = account(forHome: home.appendingPathComponent(".config/codex", isDirectory: true),
                                  seen: &seen) {
            accounts.append(fallback)
        }
        return accounts
    }

    private static func account(forHome dir: URL, seen: inout Set<String>) -> ProviderAccount? {
        let standardized = dir.standardizedFileURL.path
        let authPath = dir.appendingPathComponent("auth.json").path
        guard seen.insert(standardized).inserted,
              FileManager.default.fileExists(atPath: authPath) else { return nil }
        return ProviderAccount(
            id: "\(providerID):\(dir.lastPathComponent)",
            providerID: providerID,
            label: label(forHome: dir),
            locator: ["path": authPath],
            launchHome: standardized
        )
    }

    /// Human label = provider name + the dir's distinguisher: `~/.codex` → "Codex",
    /// `~/.codex2` → "Codex 2", `~/.codex-work` → "Codex work". Users can override with a nickname.
    private static func label(forHome dir: URL) -> String {
        let name = dir.lastPathComponent
        guard name.hasPrefix(".codex") else { return "Codex" }
        let distinguisher = name.dropFirst(".codex".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return distinguisher.isEmpty ? "Codex" : "Codex \(distinguisher)"
    }
}
