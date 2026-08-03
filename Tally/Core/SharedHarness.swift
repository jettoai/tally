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
/// skills, hooks, agents, settings) plus the conversation record - one setup maintained
/// once, and cross-account resume/handoff continues the same history with no copying. An
/// allowlist on purpose: identity (credentials, .claude.json / auth.json) and runtime state
/// (tasks, caches, sqlite stores - concurrent writers would fight over them) must stay
/// per-account, and new runtime directories the CLIs grow later must default to
/// independent, not shared.
let sharedHarnessItems = [
    "CLAUDE.md", "settings.json", "settings.local.json",
    "agents", "skills", "hooks", "commands", "plugins",
    "memory", "projects",
]

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

/// Removes share links a PREVIOUS run created: only symlinks whose destination is exactly
/// the corresponding main-home item are touched - a real file, a user's own directory, or
/// a link pointing anywhere else survives. This is what makes `--no-share` mean what it
/// says when an aborted login left the directory (and its links) behind.
func unlinkSharedHarness(from source: URL, to target: URL, items: [String]) -> [String] {
    let fm = FileManager.default
    var removed: [String] = []
    for item in items {
        let targetItem = target.appendingPathComponent(item)
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: targetItem.path),
              destination == source.appendingPathComponent(item).path,
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
