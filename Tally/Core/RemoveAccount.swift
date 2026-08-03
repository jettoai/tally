import Foundation

// Removing one account from this machine: its config home goes to the Trash, and everything Tally
// remembered ABOUT that account is forgotten with it.
//
// The counterpart to AddAccount.swift, and the reason that file's slot rule can be strict: a home
// that exists is somebody's, so the only honest way to free a number is for the user to say this
// account is finished. Dormant accounts are the ones that need it most - a signed-out account is
// exactly the one that sits in the list with nothing left to renew.
//
// Foundation-only and probe-injected, so every rule here is testable without a Trash, a home
// directory or the stores that hold the settings.

/// Codex's XDG-style config home, relative to the user's home directory.
///
/// Never a slot the add flow hands out (the walk numbers `~/.codex*`), but discovery falls back to
/// it when no `~/.codex*` login exists, matching the CLI's own lookup order - see
/// `CodexAccounts.discover`, which reads this same constant. On such a machine it IS the user's
/// primary setup, which is why the protection below has to cover it.
let codexXDGConfigHome = ".config/codex"

/// The homes that ARE the user's primary setup for this provider, and therefore never removable.
///
/// One list rather than one path, because a provider can have more than one place its CLI calls
/// home: codex reads `~/.codex` first and `~/.config/codex` when there is no `~/.codex*` login at
/// all, and a machine using only the second has its whole setup there.
func mainAccountHomes(providerID: String,
                      userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
    var homes = [userHome.appendingPathComponent(addAccountConfigBase(providerID: providerID))]
    if providerID == "codex" { homes.append(userHome.appendingPathComponent(codexXDGConfigHome)) }
    return homes
}

/// Whether Tally may offer to remove the account living in this config home.
///
/// A provider's DEFAULT home never qualifies. It is where the provider's own CLI lands with no
/// configuration at all, so removing it is not "removing an account Tally added" but deleting the
/// user's primary setup - and the numbered homes' whole share (harness links, seeded folder trust)
/// points INTO it. A home Tally has nothing to act on (nil) is not removable either.
func accountHomeIsRemovable(providerID: String, home: String?,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> Bool {
    guard let home, !home.isEmpty else { return false }
    let candidate = normalizedPath(URL(fileURLWithPath: home))
    return !mainAccountHomes(providerID: providerID, userHome: userHome)
        .contains { normalizedPath($0) == candidate }
}

/// Symlinks resolved and `..`/`.` collapsed on both sides: `/var/…` and `/private/var/…` are the
/// same directory, and a comparison that said otherwise would offer to remove the main home.
private func normalizedPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

/// Everything the user's settings remember about accounts, all keyed by account id.
///
/// Gathered into one value so removal clears them in ONE pass: these four collections are written
/// by four different surfaces (rename, drag-reorder, the menu-bar checkbox, the on/off switch), and
/// a removal that forgot one of them would hand the next account to take that id - which is derived
/// from the config home's name, so `~/.claude3` recreated IS `claude:.claude3` again - a stranger's
/// nickname, position, or a switched-off state with no visible cause.
struct AccountSettingsTraces: Equatable {
    var labels: [String: String]
    var order: [String]
    var menuBarHidden: Set<String>
    var disabled: Set<String>

    func forgetting(_ accountID: String) -> AccountSettingsTraces {
        AccountSettingsTraces(labels: labels.filter { $0.key != accountID },
                              order: order.filter { $0 != accountID },
                              menuBarHidden: menuBarHidden.subtracting([accountID]),
                              disabled: disabled.subtracting([accountID]))
    }
}

/// Put a config home in the Trash, and say whether it actually left.
///
/// The Trash rather than a delete, because this directory holds the account's conversations: the
/// undo is the user's own Finder, and Tally never has to be the program that permanently destroyed
/// somebody's history. A failure is reported rather than swallowed - the surfaces that forget the
/// account afterwards must not run over a home that is still there.
func trashAccountHome(at path: String,
                      trash: (URL) throws -> Void = RemoveAccountProbe.trash) -> Bool {
    do {
        try trash(URL(fileURLWithPath: path))
        return true
    } catch {
        return false
    }
}

enum RemoveAccountProbe {
    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
