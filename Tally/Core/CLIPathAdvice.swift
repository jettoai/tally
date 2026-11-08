import Foundation

/// What a user's own Terminal can do about a provider CLI that Tally found, kept Foundation-only so
/// tests/welcome and tests/clipath compile it alone. Tally finds a CLI in fixed directories such as
/// `~/.local/bin` whether or not the user's shell has them on its PATH, so "Tally found it" says
/// nothing about whether typing `claude` in Terminal works (B-3745). Nothing here runs anything or
/// edits a shell file: the fix is a line the user chooses to paste.
enum CLIPathAdvice {
    /// Whether a new Terminal window would find `cli` by name. nil = unknown (the login PATH has
    /// not been read, or the read failed): callers stay quiet. True when the executable's own
    /// directory is on the login PATH, or when any login PATH entry holds a runnable file named
    /// `cli` (another install, or Tally's own shim: either way the name works in Terminal).
    static func terminalFinds(cli: String, executable: String, loginPATH: [String]?,
                              isRunnable: (String) -> Bool) -> Bool? {
        guard let loginPATH else { return nil }
        let directory = canonical((executable as NSString).deletingLastPathComponent)
        if loginPATH.contains(where: { canonical($0) == directory }) { return true }
        return loginPATH.contains { isRunnable(($0 as NSString).appendingPathComponent(cli)) }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// `~/.local/bin` style, for display only.
    static func display(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Characters that need no quoting in a shell word or inside a double-quoted PATH entry.
    private static func isPlain(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            ($0.value < 128 && CharacterSet.alphanumerics.contains($0)) || "_./+-".unicodeScalars.contains($0)
        }
    }

    /// One line the user pastes to put `directory` on their shell's PATH, or nil when no safe line
    /// exists (an unknown shell, or a directory that would need quoting). Under home it reads
    /// `$HOME/<rest>`, elsewhere the absolute directory.
    static func fixCommand(directory: String, home: String, shell: String) -> String? {
        var entry = directory, plainPart = directory
        if directory == home { entry = "$HOME"; plainPart = "" }
        else if directory.hasPrefix(home + "/") {
            plainPart = String(directory.dropFirst(home.count))
            entry = "$HOME" + plainPart
        }
        guard isPlain(plainPart) else { return nil }
        let rc: String
        switch shell {
        case "zsh": rc = "~/.zshrc"
        case "bash": rc = "~/.bash_profile"
        case "sh", "ksh", "dash": rc = "~/.profile"
        case "fish": return "fish_add_path \"\(entry)\""
        default: return nil
        }
        return "echo 'export PATH=\"\(entry):$PATH\"' >> \(rc)"
    }

    /// The word to type for the CLI in a copyable command: the bare name when Terminal finds it,
    /// else the full path (`~/.local/bin/claude`, or single-quoted when it holds characters outside
    /// the plain set). Unknown gets the full path too: it works either way. No executable (nothing
    /// found) gives the bare name.
    static func commandWord(cli: String, executable: String?, terminalFinds: Bool?, home: String) -> String {
        guard let executable, terminalFinds != true else { return cli }
        let shown = display(executable, home: home)
        if isPlain(shown.hasPrefix("~/") ? String(shown.dropFirst(2)) : shown) { return shown }
        return "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What the signIn card's detail line says. `.foundIn` unless it is known that Terminal cannot
    /// find the CLI (the misleading line B-3745 removes).
    enum InstalledDetail: Equatable { case foundIn(String), none }

    static func installedDetail(location: String?, terminalFinds: Bool?) -> InstalledDetail {
        guard let location, terminalFinds != false else { return .none }
        return .foundIn(location)
    }

    /// Settings' fallback for a sign-in that did not finish in the app: the plain CLI for a first
    /// account, else the provider's config-home variable pointed at the first unused numbered
    /// sibling. `cliWord` is `commandWord`'s answer.
    static func addAccountCommand(providerID: String, homes: [String], tallyInstalled: Bool,
                                  cliWord: String) -> String {
        if tallyInstalled { return "tally add \(providerID)" }
        let claude = providerID == "claude"
        guard !homes.isEmpty else { return claude ? cliWord : "\(cliWord) login" }
        let base = claude ? ".claude" : ".codex"
        let taken = Set(homes.map { URL(fileURLWithPath: $0).lastPathComponent })
        let suffix = (2 ... 99).first { !taken.contains("\(base)\($0)") } ?? 2
        return claude
            ? "CLAUDE_CONFIG_DIR=~/\(base)\(suffix) \(cliWord)"
            // codex refuses a CODEX_HOME that doesn't exist yet (claude creates its own), so the
            // copyable command must create it or it fails on paste.
            : "mkdir -p ~/\(base)\(suffix) && CODEX_HOME=~/\(base)\(suffix) \(cliWord) login"
    }
}
