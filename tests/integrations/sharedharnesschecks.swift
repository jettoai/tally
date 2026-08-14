import Foundation

// Which homes the "Shared harness" row may offer to share at all
// (Tally/Stores/IntegrationsSharedHarness.swift).
//
// The rest of that row is asserted in tests/addshare, on fixtures made of real directories: what a
// share moves and what an unshare takes back. What lives here is the one question that is asked of
// the machine rather than of a pair of homes - is this home the provider's own primary setup - and
// it is here because this suite is the one that compiles the store.
//
// Runs as a function main.swift calls, which owns the shared harness (`check`).

@MainActor
func runSharedHarnessTargetChecks(tmp: URL) throws {
    // A home that IS the primary setup is no target: linking it into itself would move the fleet's
    // one setup aside and leave a link to itself where it had been. INCLUDING under a second name -
    // `~/.claude2` a symlink to `~/.claude` is exactly how somebody joins two homes up by hand, and
    // that is one setup wearing two names rather than a second account.
    //
    // Left out of the LIST rather than refused at the press (2026-08-14). Carrying it meant every
    // consumer of the list defended itself separately, and one of them could not: an alias-only
    // fleet counted nothing out of nothing and read as fully shared, so the row said "Installed"
    // beside a Remove button that could only ever refuse.
    let fleet = tmp.appendingPathComponent("fleet")
    let fm = FileManager.default
    for name in [".claude", ".claude3", ".config/codex"] {
        try fm.createDirectory(at: fleet.appendingPathComponent(name),
                               withIntermediateDirectories: true)
    }
    try fm.createSymbolicLink(at: fleet.appendingPathComponent(".claude2"),
                              withDestinationURL: fleet.appendingPathComponent(".claude"))
    func primary(_ name: String, _ providerID: String = "claude") -> Bool {
        IntegrationsStore.isPrimarySetup(fleet.appendingPathComponent(name),
                                         providerID: providerID, userHome: fleet)
    }
    check("the main home is not a target of its own", primary(".claude"))
    check("…nor is the same home reached under another name", primary(".claude2"))
    check("…while an account with a home of its own is one to share with", !primary(".claude3"))
    // Codex has two primary homes, because its CLI reads `~/.codex` first and the XDG location when
    // there is no `~/.codex*` login at all. RemoveAccount.swift owns that list and the removal
    // protection reads the same one: a home nobody may delete is a home nobody may link away.
    check("codex's second primary home is primary here too", primary(".config/codex", "codex"))
    check("…and one provider's home is not the other's", !primary(".claude", "codex"))

    // And the list the row draws and acts on applies that rule, rather than carrying the alias for
    // each consumer to notice: the press has nothing to refuse, the coverage counts only the
    // accounts something can be done about, and a fleet with nothing else in it gets no row.
    func targets(_ names: [String], _ providerID: String = "claude") -> [String] {
        IntegrationsStore.sharedHarnessTargets(
            userHome: fleet,
            homes: names.map { (providerID, fleet.appendingPathComponent($0)) })
            .map(\.home.lastPathComponent)
    }
    check("the list leaves out both the main home and its alias, and keeps the real account",
          targets([".claude", ".claude2", ".claude3"]) == [".claude3"])
    check("…so a fleet that is one home under two names has no targets at all",
          targets([".claude", ".claude2"]).isEmpty)
    // The other half of the same guard, unchanged by any of this: no main account, nothing to share
    // FROM, whatever else the machine has.
    check("a provider with no main account offers nothing either",
          targets([".codex2"], "codex").isEmpty)
}
