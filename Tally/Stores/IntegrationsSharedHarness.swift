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

    /// Every non-main account Tally can see, per provider.
    ///
    /// Asked of DISCOVERY rather than of the snapshot, like every other row here: the snapshot is
    /// the app's published view for the CLI and can be a poll behind, while this row is drawn
    /// beside buttons that act on the filesystem right now.
    static func sharedHarnessTargets() -> [SharedHarnessTarget] {
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        var targets: [SharedHarnessTarget] = []
        for (providerID, accounts) in [(ClaudeAccounts.providerID, ClaudeAccounts.discover()),
                                       (CodexAccounts.providerID, CodexAccounts.discover())] {
            let main = userHome.appendingPathComponent(addAccountConfigBase(providerID: providerID))
            // No main account, nothing to share from. A machine whose only codex login lives in the
            // XDG location (`~/.config/codex`) lands here, and offering to link it into itself
            // would be offering to do nothing.
            guard FileManager.default.fileExists(atPath: main.path) else { continue }
            // Every home that IS this provider's primary setup, which for codex is two paths
            // rather than one (RemoveAccount.swift owns that list, and the removal protection
            // reads the same one: a home nobody may delete is a home nobody may link away either).
            let primary = Set(mainAccountHomes(providerID: providerID, userHome: userHome)
                .map(\.standardizedFileURL.path))
            for account in accounts {
                guard let home = account.launchHome else { continue }
                let url = URL(fileURLWithPath: home)
                guard !primary.contains(url.standardizedFileURL.path) else { continue }
                targets.append(SharedHarnessTarget(providerID: providerID, main: main, home: url))
            }
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
