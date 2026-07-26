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
    var chosen: (dir: URL, name: String)?
    for n in 1 ... 99 {
        let name = n == 1 ? base : "\(base)\(n)"
        let dir = home.appendingPathComponent(name)
        if !fm.fileExists(atPath: dir.appendingPathComponent(authFile).path) {
            chosen = (dir, name)
            break
        }
    }
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
