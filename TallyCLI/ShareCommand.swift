import Foundation

// `tally share` - point an account that ALREADY EXISTS at the main account's harness.
//
// The engine (Tally/Core/ShareExisting.swift, which the app compiles too) is the part that says
// what happens to a file standing where a link belongs. This file is the terminal's half: which
// accounts were asked about, and what the run is reported as afterwards. Split out of main.swift
// for the reason AddCommand.swift was, the command it completes:
//
//   tally add    shares by DEFAULT, so every account created since has one setup and one history;
//   tally share  is the way in for the accounts that predate it, or that somebody made by hand.
//
// Without it the answer to "I already have four accounts" is a terminal full of `mv` and `ln -s`,
// which is exactly how this machine's own numbered homes were joined up (2026-08-13).

let shareUsage = """
usage: tally share <\(providers.map(\.id).joined(separator: "|"))> <account>
       tally share <\(providers.map(\.id).joined(separator: "|"))> --all

<account> is a label or a config-dir name, as `tally status` lists them. The main account's
harness (instructions, skills, hooks, agents, settings) and its conversation record are linked
into that account, so one setup serves the fleet and a conversation continues on any of them.
NOTHING IS DELETED: an accumulating directory (the conversations, the inboxes, the memory notes)
is merged into the main account file by file, and anything else already in the way is renamed to
<name>.local-<date> and left where it is.
"""

/// The one flag this command has.
let shareAllRequest = "--all"

/// What a `tally share` command line asks for, or nil when it asks for something this command
/// cannot act on. Pure, so the two rules worth stating - one account or all of them, and no flag
/// but that one - are testable, the way `switchIntent` is (SwitchCommand.swift).
struct ShareIntent: Equatable {
    let providerID: String
    /// The one account named, or nil for `--all`: the whole fleet.
    let account: String?
}

func shareIntent(_ args: [String]) -> ShareIntent? {
    // A leading dash is a flag rather than a name, the way `switchIntent` reads the same position:
    // labels are matched against what `tally status` prints, and nothing there starts with one.
    // Any dash-led word that is not the one flag is REFUSED rather than dropped, because dropping
    // it leaves a line that reads as a complete instruction: `tally share codex work --help` filtered
    // the word out and went on to move that account's files aside, which is the opposite of what
    // somebody typing --help is asking for (codex review, 2026-08-13). Usage and exit 2 is what
    // every other subcommand answers a word it does not know with, --help included
    // (`tally worktree --help`, WorktreeTree.swift); the whole binary's help is `tally help`.
    guard !args.contains(where: { $0.hasPrefix("-") && $0 != shareAllRequest }) else { return nil }
    let words = args.filter { $0 != shareAllRequest }
    guard let providerID = words.first, providers.contains(where: { $0.id == providerID })
    else { return nil }
    let named = Array(words.dropFirst())
    // One name or `--all`, never both and never neither. Refused rather than guessed for the reason
    // the account matcher refuses an ambiguous name: this command writes to somebody's config home,
    // and the wrong home is invisible until much later.
    guard named.count <= 1, args.contains(shareAllRequest) == named.isEmpty else { return nil }
    return ShareIntent(providerID: providerID, account: named.first)
}

/// `tally share <provider> <account>|--all`.
func runShare(args: [String]) -> Int32 {
    guard let intent = shareIntent(args),
          let provider = providers.first(where: { $0.id == intent.providerID }) else {
        warn(shareUsage)
        return 2
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let mainHome = home.appendingPathComponent(addAccountConfigBase(providerID: provider.id))
    guard FileManager.default.fileExists(atPath: mainHome.path) else {
        warn("no main \(provider.id) account at \(mainHome.path) - there is nothing to share from")
        return 1
    }
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }

    let targets: [Snapshot.Account]
    if let name = intent.account {
        switch accountMatching(name, provider: provider.id, in: snapshot) {
        case .one(let account):
            targets = [account]
        case .none:
            warn("no \(provider.id) account matches \"\(name)\" - try `tally status`")
            return 1
        case .several(let candidates):
            warn(accountMatchAmbiguity(name, provider: provider.id, candidates: candidates)
                + "; nothing was changed")
            return 1
        }
    } else {
        // The main account is walked past rather than refused: `--all` is a statement about the
        // fleet, and the one home there is nothing to share INTO is not an error in it. Compared
        // the way the engine compares it - after resolution, so a home that reaches the main one
        // through a symlink is the same home to both - because a `--all` run and the engine
        // disagreeing about which home is being shared FROM is how one of them acts on it.
        targets = (snapshot?.accounts ?? []).filter { account in
            guard account.provider == provider.id, let home = account.launchHome else { return false }
            return URL(fileURLWithPath: home).resolvingSymlinksInPath().path
                != mainHome.resolvingSymlinksInPath().path
        }
        guard !targets.isEmpty else {
            warn("no other \(provider.id) account to share with - `tally status` lists the ones "
                + "Tally can see")
            return 1
        }
    }

    var failed = 0
    var conversationsShared = false
    for account in targets {
        // Both ways of building that list require a launch home (the matcher does not resolve an
        // account without one, and the `--all` filter asks for it), so this unwrap has no case of
        // its own to report: it is the compiler's question rather than the user's.
        guard let launchHome = account.launchHome else { continue }
        let report = shareExistingHarness(providerID: provider.id, mainHome: mainHome,
                                          target: URL(fileURLWithPath: launchHome))
        for line in shareReportLines(account: account.label, home: launchHome, report: report) {
            print(line)
        }
        failed += report.failed.count
        conversationsShared = conversationsShared || report.sharesConversations
    }
    // Said once, at the end, however many accounts were shared: it is one fact about the fleet, and
    // repeating it per account would bury the per-account lines it is about.
    if conversationsShared {
        warn("note: \(conversationEntry(provider.id))/ is shared - every account can read every "
            + "account's conversations (Settings -> Integrations -> Shared harness unlinks it again)")
    }
    return failed == 0 ? 0 : 1
}

/// One account's report, as the lines it prints. A value rather than a series of `print` calls so
/// what this command says can be read back in a test without capturing stdout (the same reason
/// `launchExportLines` is a value, LaunchDir.swift).
func shareReportLines(account: String, home: String, report: ShareExistingReport) -> [String] {
    let name = URL(fileURLWithPath: home).lastPathComponent
    guard !report.isMainHome else {
        return ["\(account) (\(name)) is the main account - nothing to share into it"]
    }
    var lines = ["\(account) (\(name))"]
    if !report.linked.isEmpty {
        lines.append("  linked: \(report.linked.joined(separator: ", "))")
    }
    for result in report.results {
        guard case .merged(let moved, let kept, _) = result.outcome else { continue }
        // The kept count is said out loud even though nothing was done about it: those files are
        // the reason a backup exists, and a merge reported as moved-only reads like a merge that
        // took everything.
        lines.append("  merged \(result.item): \(moved) file\(moved == 1 ? "" : "s") moved into the "
            + "main account" + (kept == 0 ? "" : ", \(kept) already there and kept"))
    }
    if !report.backups.isEmpty {
        lines.append("  backed up in place, nothing deleted: "
            + report.backups.map { "\($0.item) -> \($0.name)" }.joined(separator: ", "))
    }
    if !report.alreadyShared.isEmpty {
        lines.append("  already shared: \(report.alreadyShared.joined(separator: ", "))")
    }
    for result in report.results {
        guard case .failed(let reason) = result.outcome else { continue }
        lines.append("  could not share \(result.item): \(reason)")
    }
    if !report.changed, report.failed.isEmpty {
        lines.append("  nothing to do: this account already shares the main account's harness")
    }
    return lines
}
