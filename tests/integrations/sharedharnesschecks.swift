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

// One account taken off the shared setup while the rest stay on it (B-1388): the Settings account
// row's "Stop sharing settings". Asserted on a fleet of real directories, through the same static
// act the store's press calls, so what is checked is what runs.
@MainActor
func runStopSharingChecks(tmp: URL) throws {
    let fleet = tmp.appendingPathComponent("stop-sharing")
    let fm = FileManager.default
    let main = fleet.appendingPathComponent(".claude")
    for dir in ["skills", "projects"] {
        try fm.createDirectory(at: main.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try "main".write(to: main.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    for name in [".claude3", ".claude4"] {
        let home = fleet.appendingPathComponent(name)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        _ = linkSharedHarness(from: main, to: home, items: harnessItems(for: "claude", in: main))
    }
    // A second account name for .claude4's folder, and an alias of the main home.
    try fm.createSymbolicLink(at: fleet.appendingPathComponent(".claude5"),
                              withDestinationURL: fleet.appendingPathComponent(".claude4"))
    try fm.createSymbolicLink(at: fleet.appendingPathComponent(".claude2"), withDestinationURL: main)
    let names = [".claude", ".claude2", ".claude3", ".claude4", ".claude5"]
    let homes = names.map { ("claude", fleet.appendingPathComponent($0)) }
    func isLink(_ name: String, _ item: String) -> Bool {
        (try? fm.destinationOfSymbolicLink(
            atPath: fleet.appendingPathComponent(name).appendingPathComponent(item).path)) != nil
    }
    func stop(_ name: String) -> String? {
        IntegrationsStore.stopSharing(providerID: "claude", home: fleet.appendingPathComponent(name),
                                      userHome: fleet, homes: homes)?.home.lastPathComponent
    }

    check("the premise: both accounts are linked to the main one",
          ["skills", "projects", "CLAUDE.md"].allSatisfy { isLink(".claude3", $0) && isLink(".claude4", $0) })
    check("stopping one account acts on that account", stop(".claude3") == ".claude3")
    check("…which no longer has a single link to the main account",
          !["skills", "projects", "CLAUDE.md"].contains { isLink(".claude3", $0) })
    check("…while the other account is still shared, every item of it",
          ["skills", "projects", "CLAUDE.md"].allSatisfy { isLink(".claude4", $0) })
    check("…and the main account's own items are where they were",
          fm.fileExists(atPath: main.appendingPathComponent("skills").path)
              && (try? String(contentsOf: main.appendingPathComponent("CLAUDE.md"), encoding: .utf8)) == "main")
    check("the main account is not an account to stop sharing", stop(".claude") == nil)
    check("…nor is it under a second name", stop(".claude2") == nil)
    check("…and asking about either left the main account whole",
          fm.fileExists(atPath: main.appendingPathComponent("projects").path))
    check("a home that is not on disk finds nothing to act on", stop(".claude9") == nil)
    check("a second name for an account's folder finds that folder", stop(".claude5") != nil
          && !isLink(".claude4", "skills"))

    // The provenance record: this home out, the rest kept, nothing left reads as no record at all.
    let c3 = fleet.appendingPathComponent(".claude3"), c4 = fleet.appendingPathComponent(".claude4")
    check("the record loses the stopped home and keeps the others",
          IntegrationsStore.sharedHarnessPaths([c3.path, c4.path], removing: c3) == [c4.path])
    check("…and once nothing is left it is dropped, as the bulk Remove leaves it",
          IntegrationsStore.sharedHarnessPaths([c3.path], removing: c3) == nil)
    check("…matching a second name for the same folder too",
          IntegrationsStore.sharedHarnessPaths([c4.path],
                                               removing: fleet.appendingPathComponent(".claude5")) == nil)
    check("…and a recorded home that is gone from disk still by its spelling",
          IntegrationsStore.sharedHarnessPaths([fleet.appendingPathComponent(".claude9").path],
                                               removing: fleet.appendingPathComponent(".claude9")) == nil)

    // The surfaces, read as text (SwiftUI does not compile into this harness).
    func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    let store = source("Tally/Stores/IntegrationsSharedHarness.swift")
    let pane = source("Tally/Views/SettingsAccountsView.swift")
    let menu = source("Tally/Views/AccountCardMenu.swift")
    let card = menu.components(separatedBy: "struct AccountActionsMenu").first ?? ""
    check("the surfaces are readable from this suite", !store.isEmpty && !pane.isEmpty && !menu.isEmpty)
    if let body = store.range(of: "func stopSharingHarness(") {
        let rest = store[body.upperBound...]
        let gate = rest.range(of: "guard guardNotDev()"), act = rest.range(of: "Self.stopSharing(")
        check("the press is refused on the dev build before anything is touched",
              gate != nil && act != nil && gate!.lowerBound < act!.lowerBound)
    } else {
        check("the press is refused on the dev build before anything is touched", false)
    }
    check("the row offers it only off the main home and only where the mark is drawn",
          pane.contains("accountHomeIsRemovable(providerID: item.providerID, home: home(of: item))")
              && pane.contains("sharing[item.id]?.tag != nil")
              && pane.contains("stopSharing: canStopSharing(item) ? { stopSharing(item) } : nil"))
    check("the card's right-click does not offer it", !card.contains("stopSharing"))
    check("the menu greys it on the dev build outside a demo capture",
          menu.contains(".disabled(BuildVariant.isUnshipped && !DemoUsage.isActive)"))
}
