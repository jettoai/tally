import Foundation

// A Mac that has only just been set up: Claude Code lives where its installer put it and PATH does
// not name that directory, there are no developer tools behind /usr/bin/git, and a CLI may not be
// installed at all. Every case here is a way `tally claude` used to leave a first-time user with a
// bare error (or a system dialog) and no next step (B-3753).

func runFreshMacChecks() {
    let fm = FileManager.default
    let root = tmp.appendingPathComponent("fresh-mac-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    func executable(_ url: URL) {
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let home = root.appendingPathComponent("home")
    let shimDir = home.appendingPathComponent(".tally/bin")
    let localBin = home.appendingPathComponent(".local/bin")
    let fallbacks = providerFallbackDirectories(home: home.path)
    let onPath = root.appendingPathComponent("on-path")

    check("the fixed install places are the app's, in the app's order",
          fallbacks == ["\(home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                        "\(home.path)/.claude/local"])

    // 1. PATH does not name ~/.local/bin; the installer's binary is still found.
    executable(localBin.appendingPathComponent("claude"))
    check("a claude only in ~/.local/bin is found when PATH does not name it",
          resolveProviderExecutable("claude", path: "/usr/bin:/bin", shimDirectory: shimDir,
                                    fallbackDirectories: fallbacks)
              == localBin.appendingPathComponent("claude").path)
    executable(onPath.appendingPathComponent("claude"))
    check("a claude on PATH still wins over the fixed places",
          resolveProviderExecutable("claude", path: onPath.path, shimDirectory: shimDir,
                                    fallbackDirectories: fallbacks)
              == onPath.appendingPathComponent("claude").path)

    // 2. A shim in a fixed place is not a match, same as on PATH.
    executable(shimDir.appendingPathComponent("claude"))
    check("the shim directory is skipped among the fixed places too",
          resolveProviderExecutable("claude", path: "", shimDirectory: shimDir,
                                    fallbackDirectories: [shimDir.path]) == "claude")
    check("nothing anywhere falls back to the bare name",
          resolveProviderExecutable("no-such-cli-b3753", path: "/usr/bin", shimDirectory: shimDir,
                                    fallbackDirectories: fallbacks) == "no-such-cli-b3753")

    // 3. No developer tools: git is not started, and the answer is the ordinary "not a repo" one.
    let withoutTools = runGit(["--version"], gitIsInstalled: { false })
    check("with no developer tools runGit reports exit 127 instead of starting git",
          withoutTools.code == 127 && withoutTools.out.isEmpty)
    var asked = false
    let notARepo = runGit(["rev-parse", "--git-common-dir"], cwd: tmp.path,
                          gitIsInstalled: { asked = true; return false })
    check("with no developer tools the ordinary not-a-repo answer comes back and the probe was asked",
          notARepo.code != 0 && notARepo.out.isEmpty && asked)
    let withTools = runGit(["--version"], gitIsInstalled: { true })
    check("with the tools present git runs as before",
          withTools.code == 0 && withTools.out.hasPrefix("git version"))

    // 4. The hint a missing CLI gets.
    let noHome = root.appendingPathComponent("empty-home").path
    check("a missing claude is told how to install it",
          missingCLIHint("claude", home: noHome)?.joined(separator: "\n")
              .contains("curl -fsSL https://claude.ai/install.sh | bash") == true)
    check("a missing codex is told how to install it",
          missingCLIHint("codex", home: noHome)?.joined(separator: "\n")
              .contains("curl -fsSL https://chatgpt.com/codex/install.sh | sh") == true)
    check("the install hint ends with the new-window instruction",
          missingCLIHint("claude", home: noHome)?.last
              == "Then open a new Terminal window and run tally again.")
    check("a CLI Tally has no install route for gets no hint", missingCLIHint("vim", home: noHome) == nil)
    let pathHint = missingCLIHint("claude", home: home.path)?.joined(separator: "\n") ?? ""
    check("a claude sitting in ~/.local/bin is told to fix PATH, not to reinstall",
          pathHint.contains(".local/bin:$PATH") && !pathHint.contains("install.sh"))
}
