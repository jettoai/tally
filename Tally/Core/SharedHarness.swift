import Foundation

// Harness sharing when an account is added: what a new account links from the main one, and how
// that link set is created, undone, and reported on.
//
// Split out of Snapshot.swift (2026-07-26) when that file reached its 500-line cap. The seam is
// the concern: everything here is filesystem work for ONE act and touches neither the snapshot,
// the account scoring, nor the launch plumbing that the rest of Snapshot.swift is about, so it is
// the part a reader of either file never needs to have in front of them.
//
// It moved from TallyCLI/ into Core (2026-08-03) when Settings grew its own "Add account" flow:
// both targets compile this file, because `tally add` and the in-app flow must link the same set
// (a second copy would leave one surface sharing what the other does not).

/// What a shared add links from the main account into a new one: the HARNESS (instructions,
/// skills, hooks, agents, settings) plus what sessions leave for each other: the
/// conversation record, and `inboxes`, the messages one session drops for the next - one
/// setup maintained once, and cross-account resume/handoff continues the same history with
/// no copying. An allowlist on purpose: identity (credentials, .claude.json / auth.json)
/// and runtime state (tasks, caches, sqlite stores - concurrent writers would fight over
/// them) must stay per-account, and new runtime directories the CLIs grow later must
/// default to independent, not shared. `inboxes` sits on the shared side of that line
/// because it is a directory of files rather than a store two accounts lock, and a message
/// dropped while on one account has to be there when the next session lands on another.
let sharedHarnessItems = [
    "CLAUDE.md", "settings.json", "settings.local.json",
    "agents", "skills", "hooks", "commands", "plugins",
    "memory", "projects", inboxesItem,
]

/// The messages sessions drop for each other. Named rather than spelled twice: the rule below has
/// to be about the same directory this list shares, and two literals is how those drift apart.
let inboxesItem = "inboxes"

/// Makes sure the main account HAS an inbox directory before a share links it.
///
/// `linkSharedHarness` links what exists and skips what does not, which is the right rule for every
/// other name on the list: those are the provider CLI's own directories, and creating `projects` or
/// `memory` on its behalf would change what claude finds on its first run. `inboxes` is Tally's own
/// concept, and it does not exist until the first cross-session message is left - so an account
/// added before that day got no link at all, grew its own inbox the first time something wrote one,
/// and the two stayed separate for good: the link is made once, while the account is being added,
/// and nothing revisits the home afterwards. An empty directory is the entire price of not letting
/// that happen.
///
/// Asked of the share list rather than of the provider id, so it follows the list it exists to
/// serve: codex carries no inbox notion, and creating one there would be creating a directory
/// nothing reads.
///
/// Answers whether the main account now HAS one, because the two ways this fails are both silent:
/// a main home that cannot be written to, and a plain file already sitting on that name. Either way
/// `linkSharedHarness` then does what it does for every name the main account lacks - skips it,
/// reporting neither a link nor a failure - and the surface says the share worked while the one
/// item the fleet needs most stays split per account (codex review, 2026-08-13). A file is not
/// pretended into a directory either: a link to it would make `inboxes/<sender>/` unwritable in
/// every account at once.
@discardableResult
func ensureSharedInboxes(in mainHome: URL, items: [String]) -> Bool {
    guard items.contains(inboxesItem) else { return true }
    let dir = mainHome.appendingPathComponent(inboxesItem)
    // Asked of the filesystem afterwards rather than of the create's own error: an existing
    // directory is success, and the one shape that matters (a file at that name) reports the same
    // "file exists" as that one does.
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
}

/// The codex face of the same idea. `sessions` plus `archived_sessions` are codex's
/// conversation record (archiving MOVES a conversation between them - sharing only one
/// would make archived chats vanish from the other accounts); the memory sqlite stores
/// stay per-account on purpose (two accounts writing one database is a lock fight, unlike
/// claude's per-session transcript files).
let codexSharedItems = [
    "AGENTS.md", "config.toml",
    "agents", "skills", "hooks", "hooks.json", "rules", "plugins", "prompts",
    "sessions", "archived_sessions",
]

/// The share list for one provider, resolved against the actual main home: codex profile
/// v2 layers (`-p work` reads `$CODEX_HOME/work.config.toml`) are discovered dynamically,
/// so "one setup serves every account" covers every named profile the main account has.
func harnessItems(for providerID: String, in source: URL) -> [String] {
    var items = providerID == "codex" ? codexSharedItems : sharedHarnessItems
    if providerID == "codex" {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
        items += names.filter {
            $0.hasSuffix(".config.toml") && $0 != "config.toml" && $0 != ".config.toml"
        }.sorted()
    }
    return items
}

/// The conversation-record entry per provider - the item the privacy note is about.
func conversationEntry(_ providerID: String) -> String {
    providerID == "codex" ? "sessions" : "projects"
}

/// Symlinks each allowlisted item of `source` into `target`. Only items that exist at the
/// source are linked; a target entry that already exists is NEVER touched (a half-shared
/// account stays exactly as the user built it). Returns what was linked, what was left
/// alone, and what FAILED to link (permissions, exotic filesystems) - failures must reach
/// the launch report, or the user walks away believing a share that never happened.
func linkSharedHarness(from source: URL, to target: URL,
                       items: [String] = sharedHarnessItems)
    -> (linked: [String], kept: [String], failed: [String]) {
    let fm = FileManager.default
    var linked: [String] = [], kept: [String] = [], failed: [String] = []
    for item in items {
        let sourceItem = source.appendingPathComponent(item)
        let targetItem = target.appendingPathComponent(item)
        guard fm.fileExists(atPath: sourceItem.path) else { continue }
        // lstat, not stat (attributesOfItem never traverses links): an existing symlink,
        // even a dangling one, is "already there" too and must not be replaced.
        if (try? fm.attributesOfItem(atPath: targetItem.path)) != nil {
            kept.append(item)
            continue
        }
        do {
            try fm.createSymbolicLink(at: targetItem, withDestinationURL: sourceItem)
            linked.append(item)
        } catch {
            failed.append(item)
        }
    }
    return (linked, kept, failed)
}

/// Where a link WOULD lead, given the text it holds and the directory it sits in: a relative
/// destination (`../.claude/projects`) is read from that directory, and everything ahead of the last
/// component is handed to the FILESYSTEM to resolve. The last component is deliberately left as
/// written, which is the whole reason this exists next to plain resolution: an item the main account
/// no longer has resolves to nothing, and a link to it still has to be recognisable as the one we
/// wrote.
///
/// Nil when what leads up to that component does not exist, and it says so rather than guessing: the
/// only path this is ever compared against is one inside a home that DOES exist, so "cannot be
/// walked" and "is not ours" are the same answer, and the safe one.
///
/// The resolving is left to the filesystem because a path is walked one component at a time, and
/// `..` means the parent of wherever the walk has ARRIVED - so `away/../main` with `away` a link to
/// `elsewhere/deep` leads to `elsewhere/main`, not to `main`. Collapsing the text instead reads that
/// as the main account's own item, which is wrong in both directions: a link of the user's aimed
/// anywhere else gets removed, and the reverse topology (`hop/alias/../main`, `hop/alias` a link to
/// `../main`) is a link of ours that never gets taken back (codex review, 2026-08-14).
///
/// Handing the WHOLE path to `standardizedFileURL` or `resolvingSymlinksInPath` does not do the
/// same job: measured, both walk a path properly while every component of it exists and fall back to
/// collapsing the text the moment one does not. That makes them right about every link that can be
/// checked by hand and wrong about exactly the ones this function is here for, the dangling ones,
/// whose last component is missing BY DEFINITION. Hence the stop short of that component, and hence
/// these rules were read off what the kernel does when a file is opened THROUGH each of these texts
/// rather than off the documentation.
private func pathLeadingTo(_ destination: String, from parent: URL) -> String? {
    let joined = destination.hasPrefix("/")
        ? URL(fileURLWithPath: destination)
        : parent.resolvingSymlinksInPath().appendingPathComponent(destination)
    let leadIn = joined.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: leadIn.path) else { return nil }
    return leadIn.resolvingSymlinksInPath()
        .appendingPathComponent(joined.lastPathComponent).path
}

/// Whether a link's text says it leads to `source`'s own `item` - false when either end cannot be
/// walked, so two unwalkable paths are never mistaken for one place.
private func linkLeadsToItem(_ destination: String, in target: URL,
                             matching item: String, in source: URL) -> Bool {
    guard let led = pathLeadingTo(destination, from: target),
          let ours = pathLeadingTo(item, from: source) else { return false }
    return led == ours
}

/// Removes share links a PREVIOUS run created: only symlinks that lead to the corresponding
/// main-home item are touched - a real file, a user's own directory, or a link pointing
/// anywhere else survives. This is what makes `--no-share` mean what it says when an aborted
/// login left the directory (and its links) behind, and it is what Settings' Remove does.
///
/// WHERE a link leads is asked two ways, because neither alone answers the whole question and the
/// two disagreeing is a row that can never be turned off: a link that reads as shared going in and
/// is walked past coming out leaves Settings saying "Installed" with a Remove button that does
/// nothing (codex review, 2026-08-13).
///
///  - RESOLUTION, the way every detector here asks it (`sharesConversations`,
///    `sharedHarnessProgress`, `shareExistingItem`). This is the half that follows a CHAIN of links
///    to the main item, which reading one link's text can never do.
///  - The link's own TEXT, expanded against the home it sits in (`pathLeadingTo`). This is the half
///    that answers a link to an item the main account no longer HAS: it resolves to nothing, it is
///    still ours, and `--no-share` has to be able to take it back. Expanded rather than compared
///    literally, because a relative destination names the same item an absolute one does while
///    reading nothing like it: the dangling relative ones stayed behind for good, and revived the
///    share by themselves the day the main item came back (codex review, 2026-08-14).
///
/// Both halves ask what a link LEADS to, so both answer "yes" when the two homes are one home under
/// two names (`~/.claude2` a symlink to `~/.claude`, an item inside it a link of the main account's
/// own): every path here then lands inside the main account, and removing "the target's link" would
/// remove the main account's. Nothing is ever shared with itself, so that case is refused whole
/// rather than defended item by item (codex review, 2026-08-14).
func unlinkSharedHarness(from source: URL, to target: URL, items: [String]) -> [String] {
    let fm = FileManager.default
    guard source.resolvingSymlinksInPath().standardizedFileURL.path
        != target.resolvingSymlinksInPath().standardizedFileURL.path else { return [] }
    var removed: [String] = []
    for item in items {
        let targetItem = target.appendingPathComponent(item)
        let sourceItem = source.appendingPathComponent(item)
        // It must BE a link before anything else is asked, which is what this reads (an lstat that
        // never traverses): only links are ever removed here, never a file of the user's own.
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: targetItem.path),
              linkLeadsToItem(destination, in: target, matching: item, in: source)
                  || targetItem.resolvingSymlinksInPath().path
                      == sourceItem.resolvingSymlinksInPath().path,
              (try? fm.removeItem(at: targetItem)) != nil else { continue }
        removed.append(item)
    }
    return removed
}

/// Whether `target`'s conversation record actually resolves to `source`'s - the truth
/// behind the privacy note, independent of HOW it got shared (this run, an earlier run, or
/// by hand).
func sharesConversations(providerID: String, source: URL, target: URL) -> Bool {
    let entry = conversationEntry(providerID)
    let sourceEntry = source.appendingPathComponent(entry)
    let targetEntry = target.appendingPathComponent(entry)
    guard FileManager.default.fileExists(atPath: sourceEntry.path) else { return false }
    return targetEntry.resolvingSymlinksInPath().path
        == sourceEntry.resolvingSymlinksInPath().path
}
