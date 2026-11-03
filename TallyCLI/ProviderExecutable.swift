import Foundation

// Resolving a provider CLI to the REAL binary, deliberately skipping Tally's own PATH shim.
//
// Tally installs `~/.tally/bin/claude` (and the same for codex): a shim that asks
// `tally launch-dir` which account a BARE invocation should land on. That is exactly right when
// the user types `claude` by hand, and exactly wrong for a launch Tally itself starts, because by
// then the account HAS been chosen and the shim would choose again, against a snapshot that may
// have moved.
//
// The failure this prevents (session c80ebeb2, 2026-07-26). A cap handoff moved the session from
// Claude 2 to Claude, the DEFAULT home, which must launch with CLAUDE_CONFIG_DIR unset (setting it
// to the default path makes the CLI look for a Keychain item that does not exist). The supervisor
// therefore respawned the child as the bare string "claude"; posix_spawnp walked PATH, PATH's first
// `claude` was the shim, and the shim saw an empty CLAUDE_CONFIG_DIR, read that as a fresh launch,
// ran its own pick, and steered the child back to Claude 2. Everything downstream then disagreed
// with reality: handoff.log recorded "Claude 2->Claude reason=cap" at 05:03:28Z while the child
// kept hitting Claude 2's session limit, the live pin guard compared the pin against the account
// the supervisor THOUGHT it was on and so never moved the session, the cap warning named the wrong
// account, and the status line (which reads the child's real environment) contradicted all of it.
//
// The defense belongs on this side rather than in the shim: shims already written to user machines
// do not change when the app updates.

/// Tally's shim directory (`~/.tally/bin`), the one place on PATH a provider CLI must never come
/// from once Tally has picked the account. Mirrors `IntegrationsStore.binDirURL` in the app.
let tallyShimDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/bin", isDirectory: true)

/// The fixed places a provider CLI is installed, the same list the app searches (`CLISearchPath.resolve`
/// in Tally/Core/CLISearchPath.swift, which cannot be imported here because the small test suites
/// compile this file on its own; keep the two in step). Claude Code's official installer puts the
/// binary in `~/.local/bin` and does not add that directory to PATH, so a fresh Terminal window
/// cannot see a CLI the app already reads usage from.
func providerFallbackDirectories(home: String = FileManager.default.homeDirectoryForCurrentUser.path)
    -> [String] {
    ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local"]
}

/// The program to run for `name`: the first executable on PATH, exactly as posix_spawnp and execvp
/// would find it, except that anything inside the shim directory is passed over. When PATH has none,
/// the fixed install locations (`fallbackDirectories`) are tried in order, under the same shim rule.
///
/// Falls back to the bare `name` when nothing else matches, so a machine with no shim installed
/// behaves precisely as before (the caller hands the name to the system and the system walks PATH).
/// PATH itself is left untouched on purpose: the child's own shell commands must still see the
/// user's normal PATH, shim included.
func resolveProviderExecutable(_ name: String,
                               path: String? = ProcessInfo.processInfo.environment["PATH"],
                               shimDirectory: URL = tallyShimDirectory,
                               fallbackDirectories: [String] = providerFallbackDirectories()) -> String {
    let shim = shimDirectory.resolvingSymlinksInPath().path
    // An empty PATH entry means the current directory, as in every other PATH walker.
    let pathEntries = (path ?? "").split(separator: ":", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "." : String($0) }
    for entry in pathEntries + fallbackDirectories {
        let candidate = URL(fileURLWithPath: entry).appendingPathComponent(name)
        guard isRunnableFile(candidate.path) else { continue }
        // Resolved two ways, because either link can lead to the shim: a PATH entry that is a
        // symlink ONTO the shim directory (resolve the directory, keep the file name), and an
        // entry whose file is a symlink pointing AT the shim script (resolve the whole path).
        let viaDirectory = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(name).path
        if isUnder(viaDirectory, shim) || isUnder(candidate.resolvingSymlinksInPath().path, shim) {
            continue
        }
        return candidate.path
    }
    return name
}

/// An existing, executable, non-directory file. The directory test is not pedantry: a searchable
/// directory passes `access(X_OK)`, and PATH walkers skip those rather than trying to run them.
private func isRunnableFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          !isDirectory.boolValue else { return false }
    return FileManager.default.isExecutableFile(atPath: path)
}

private func isUnder(_ path: String, _ directory: String) -> Bool {
    path == directory || path.hasPrefix(directory + "/")
}

/// What to tell a person whose `name` could not be started because it is not installed: one line
/// that installs it, or, when the binary is already in `~/.local/bin` but the terminal cannot see
/// it, the two lines that put that directory on PATH (the official installer prints the same fix and
/// leaves PATH alone). nil for a CLI Tally has no install route for. Install commands are the
/// vendors' own: code.claude.com/docs/en/setup and github.com/openai/codex.
func missingCLIHint(_ name: String,
                    home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String]? {
    if isRunnableFile("\(home)/.local/bin/\(name)") {
        return ["`\(name)` is in ~/.local/bin, which is not on your PATH. Run:",
                "  echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc",
                "Then open a new Terminal window and run tally again."]
    }
    let install: String
    switch name {
    case "claude": install = "curl -fsSL https://claude.ai/install.sh | bash"
    case "codex": install = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
    default: return nil
    }
    return ["`\(name)` is not installed. To install it, run:", "  \(install)",
            "Then open a new Terminal window and run tally again."]
}
