import Foundation

// `tally add` - logging one more provider account into the next free numbered config home. Split
// out of main.swift purely for file size (same reason as UpdateCommand.swift); behavior unchanged.

/// `tally add claude|codex`: create the next numbered config home and hand this terminal to the
/// official login flow. A numbered home that exists but never finished logging in is resumed
/// rather than skipped, so an aborted login doesn't burn a number. The default home counts too:
/// on a machine with no account at all, `tally add` is simply the first login.
///
/// Sharing is the DEFAULT (opt out with --no-share): before the login, the main account's
/// harness is symlinked into the new home (see `harnessItems(for:)`) - one set of
/// instructions/skills/hooks/agents/settings maintained once, and one conversation record,
/// so cross-account resume and handoff continue the same history. Multi-account in Tally
/// means one person's accounts working as one fleet; separate setups are the special case,
/// not the default. The launch report says out loud when conversations are shared.
/// The next config home that is not already logged in, or nil when all 99 are taken.
///
/// "Logged in" is asked of BOTH places a credential can live, because Claude Code has two
/// generations of credential storage in the field at once: older logins wrote
/// `<dir>/.credentials.json`, newer ones put the OAuth token in the Keychain and write no file at
/// all. A dir with either one is somebody's account.
///
/// Asking only about the file is what broke this (2026-07-28): on a machine whose third account was
/// a Keychain-only login, `~/.claude3` looked like the aborted-login case above, so `tally add
/// claude` reused it, exec'd claude there, and claude found the Keychain token and simply opened a
/// session on that existing account. The report was "add opened an existing account instead of
/// logging me in", with no error anywhere, because every step did exactly what it was told.
///
/// Both probes are injected so the choice is testable without a Keychain or a home directory. The
/// Keychain one is only ever consulted for claude: a codex login is a file (`auth.json`), so asking
/// the Keychain about it would be asking a question with no answer.
func nextFreeSlot(base: String, authFile: String, home: URL,
                  fileExists: (String) -> Bool,
                  keychainLogin: (URL) -> Bool) -> (dir: URL, name: String)? {
    for n in 1 ... 99 {
        let name = n == 1 ? base : "\(base)\(n)"
        let dir = home.appendingPathComponent(name)
        if fileExists(dir.appendingPathComponent(authFile).path) { continue }
        if base == ".claude", keychainLogin(dir) { continue }
        return (dir, name)
    }
    return nil
}

func runAdd(args: [String]) -> Never {
    let share = !args.contains("--no-share")
    let providerID = args.first { !$0.hasPrefix("--") } ?? ""
    guard let provider = providers.first(where: { $0.id == providerID }) else {
        warn("usage: tally add <claude|codex> [--no-share]")
        exit(2)
    }
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let base = provider.id == "claude" ? ".claude" : ".codex"
    let authFile = provider.id == "claude" ? ".credentials.json" : "auth.json"
    // The Keychain probe is an attribute check (KeychainReader.exists): it returns no secret and
    // raises no consent prompt, so `tally add` never touches a credential to find this out.
    let chosen = nextFreeSlot(
        base: base, authFile: authFile, home: home,
        fileExists: { fm.fileExists(atPath: $0) },
        keychainLogin: { KeychainReader.exists(service: claudeKeychainService(forConfigDir: $0)) })
    guard let (dir, name) = chosen else {
        warn("no free slot: ~/\(base) through ~/\(base)99 all have logins")
        exit(1)
    }
    // codex refuses a CODEX_HOME that doesn't exist; creating it is harmless for claude.
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let mainHome = home.appendingPathComponent(base)
    if !share, dir.path != mainHome.path {
        // Opting out must UNDO what an earlier (aborted, default-shared) run linked into
        // this reused directory - otherwise --no-share leaves the conversations shared.
        let removed = unlinkSharedHarness(from: mainHome, to: dir,
                                          items: harnessItems(for: provider.id, in: mainHome))
        if !removed.isEmpty {
            warn("share opted out - removed earlier share links: \(removed.joined(separator: ", "))")
        }
    }
    if share {
        if dir.path == mainHome.path {
            warn("share skipped: ~/\(base) IS the main account (nothing to link yet)")
        } else {
            let (linked, kept, failed) = linkSharedHarness(from: mainHome, to: dir,
                                                           items: harnessItems(for: provider.id, in: mainHome))
            if !linked.isEmpty {
                warn("sharing the main account's harness: \(linked.joined(separator: ", "))")
            }
            if !kept.isEmpty {
                warn("left as-is (already present): \(kept.joined(separator: ", "))")
            }
            if !failed.isEmpty {
                warn("could not link: \(failed.joined(separator: ", ")) - check permissions; the share is incomplete")
            }
            // The privacy note follows the ACTUAL state, not this run's work: shared is
            // shared whether it happened now, on an earlier run, or by hand.
            if sharesConversations(providerID: provider.id, source: mainHome, target: dir) {
                warn("note: \(conversationEntry(provider.id))/ is shared - every account can read every account's conversations (next time: --no-share)")
            }
        }
    }
    warn("adding a \(provider.id) account at ~/\(name) - finish the login below; the account shows up in Tally within a minute")
    exec(provider.cli, args: provider.id == "codex" ? ["login"] : [],
         env: launchEnv(provider, home: dir.path))
}
