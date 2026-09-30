import Foundation

// The Settings row for one setup across every account: instructions, skills, hooks, agents and
// settings maintained once, and one conversation record so a session continues wherever it lands.
//
// `tally add` has done this for accounts it creates since 2026-07 (AddAccount.swift). This row is
// for the accounts that came BEFORE that, or that somebody made by hand: the same act, applied to a
// home that is already full, which is the part `linkSharedHarness` cannot do and
// Tally/Core/ShareExisting.swift is. `tally share` is the same engine from a terminal.
//
// AN INTEGRATION IN THE SENSE THE OTHERS ARE: it writes outside this app's bundle, it is explicit,
// and it is reversible (Remove unlinks, leaving every backup where it is). It is NOT in the "All
// integrations" set, which is the one deliberate difference and is stated where that set is built
// (SettingsView.swift).
extension IntegrationsStore {
    /// One account this row would share, paired with the account it shares FROM.
    struct SharedHarnessTarget: Equatable {
        let providerID: String
        /// The main account's home (`~/.claude`, `~/.codex`), which is the source of every link.
        let main: URL
        /// The account being pointed at it.
        let home: URL
    }

    /// Whether this home IS one of the provider's own primary setups, under any name.
    ///
    /// The list of them is RemoveAccount.swift's, and the removal protection reads the same one: a
    /// home nobody may delete is a home nobody may link away either. Codex has two of them, because
    /// its CLI reads `~/.codex` first and `~/.config/codex` when there is no `~/.codex*` login.
    ///
    /// Asked as the OBJECT each path arrives at (PathIdentity.swift), which is what makes an ALIAS
    /// of the main home - `~/.claude2` a symlink to `~/.claude`, exactly how somebody joins two
    /// homes up by hand - the main home here too. It is one setup wearing two names, so it is not a
    /// second account to share anything with, and a list that carried it made every consumer defend
    /// itself against it separately.
    static func isPrimarySetup(_ home: URL, providerID: String, userHome: URL) -> Bool {
        mainAccountHomes(providerID: providerID, userHome: userHome)
            .contains { harnessHomesAreOne($0, home) }
    }

    /// Every home Tally can see right now, paired with the provider it belongs to.
    ///
    /// Asked of DISCOVERY rather than of the snapshot, like every other row here: the snapshot is
    /// the app's published view for the CLI and can be a poll behind, while this row is drawn
    /// beside buttons that act on the filesystem right now. Kept apart from the rule that filters
    /// it so that rule can be run over a fleet made in a temporary directory.
    static func discoveredHomes() -> [(providerID: String, home: URL)] {
        [(ClaudeAccounts.providerID, ClaudeAccounts.discover()),
         (CodexAccounts.providerID, CodexAccounts.discover())].flatMap { providerID, accounts in
            accounts.compactMap { account in
                account.launchHome.map { (providerID, URL(fileURLWithPath: $0)) }
            }
        }
    }

    /// Every account this row would share INTO, per provider: the homes above, less the ones that
    /// ARE the main account already.
    ///
    /// A fleet whose only other home is an alias of the main one therefore has no targets at all,
    /// and the row is left out entirely - the same rule that leaves it out on a one-account machine,
    /// which is what such a fleet is: one setup, two names. `tally share --all` reads its own list
    /// the same way (ShareCommand.swift), so the terminal and the window agree about which homes
    /// there are to act on. The read-only sharing row in the launch pane still reports the two homes
    /// as sharing everything, because that is true and observing it is its whole job
    /// (HarnessSharing.swift).
    static func sharedHarnessTargets(
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        homes: [(providerID: String, home: URL)]? = nil) -> [SharedHarnessTarget] {
        var targets: [SharedHarnessTarget] = []
        for (providerID, home) in homes ?? discoveredHomes() {
            let main = userHome.appendingPathComponent(addAccountConfigBase(providerID: providerID))
            // No main account, nothing to share from. A machine whose only codex login lives in the
            // XDG location (`~/.config/codex`) lands here, and offering to link it into itself
            // would be offering to do nothing - which is the second half of this guard as well, for
            // a home that IS the main account under whatever name it is written.
            guard FileManager.default.fileExists(atPath: main.path),
                  !isPrimarySetup(home, providerID: providerID, userHome: userHome) else { continue }
            targets.append(SharedHarnessTarget(providerID: providerID, main: main, home: home))
        }
        return targets
    }

    /// The row's word, or nil when the row has no business being on screen at all: one account is
    /// the ordinary case for most people, and a button that can only ever refuse is worse than no
    /// button (`integrationsRows` leaves the row out entirely on nil).
    static func detectSharedHarness() -> Status? {
        let targets = sharedHarnessTargets()
        guard !targets.isEmpty else { return nil }
        let progress = targets.map {
            sharedHarnessProgress(providerID: $0.providerID, mainHome: $0.main, target: $0.home)
        }
        switch sharedHarnessCoverage(progress) {
        case .complete:
            return .installed
        case .none:
            return .notInstalled
        case .partial:
            // The same word the status line uses for the same shape, and for the same reason: some
            // accounts are on the shared setup and some are not, which is a state somebody meant to
            // leave only if they know it is there.
            return .broken(L("Not shared with every account"))
        }
    }

    /// Share the main account's harness into every account that is not already on it.
    ///
    /// Synchronous, like the other installs, and the reason it can be: everything it moves stays on
    /// one volume, so a merge is a series of renames rather than of copies.
    func installSharedHarness() {
        guard guardNotDev() else { return }
        lastError = nil
        let targets = Self.sharedHarnessTargets()
        var failures: [String] = []
        for target in targets {
            let report = shareExistingHarness(providerID: target.providerID,
                                              mainHome: target.main, target: target.home)
            failures += report.failed.map { "\(target.home.lastPathComponent)/\($0)" }
        }
        // Provenance, as for every other component: what this app touched outside its bundle. The
        // removal below does not read it (a link is only removed when it still points at the main
        // account, which is a stronger test than a path list), so this is the record rather than
        // the mechanism.
        recordManifest("sharedHarness", paths: targets.isEmpty ? nil : targets.map(\.home.path))
        if !failures.isEmpty {
            lastError = L("Some items could not be shared: ") + failures.joined(separator: ", ")
        }
        refresh()
    }

    /// Undo the links, and ONLY the links: `unlinkSharedHarness` removes a symlink whose
    /// destination is exactly the main account's item and leaves everything else alone
    /// (SharedHarness.swift).
    ///
    /// What it deliberately does not do is put a backup back. A share renames the file that was in
    /// the way to `<name>.local-<date>` and leaves it in that account's own home, where its owner
    /// can see it; moving it back on their behalf would be this app deciding that the setup they
    /// have been running since is the one to throw away.
    ///
    /// There is no press that can only refuse, so there is nothing to explain afterwards. One home
    /// reachable under two names (`~/.claude2` a symlink to `~/.claude`) reads as fully shared on
    /// the way in - every item of it IS the main account's - and unlinking it would take the main
    /// account's own links away, so it is not on the list this walks (`sharedHarnessTargets`). The
    /// act refuses such a pair on its own as well (`unlinkSharedHarness`), which is the depth behind
    /// the list rather than a second answer to the same question.
    func removeSharedHarness() {
        guard guardNotDev() else { return }
        lastError = nil
        for target in Self.sharedHarnessTargets() {
            _ = unlinkSharedHarness(from: target.main, to: target.home,
                                    items: harnessItems(for: target.providerID, in: target.main))
        }
        recordManifest("sharedHarness", paths: nil)
        refresh()
    }
}
