import Foundation

// Adding one more provider account: which config home it gets, and everything that is put in that
// home before the provider's own login is started.
//
// Compiled into BOTH targets, because `tally add` and the Settings "Add account" flow are the same
// act from two surfaces. Two copies of the slot rule would have the CLI and the app disagree about
// which number is next (each would happily point a login at a home the other considers taken); two
// copies of the preparation would let one surface share a harness, seed folder trust and undo an
// earlier share while the other quietly did less. Only the WORDS differ per surface: the CLI prints
// lines to a terminal, the app draws a sheet, and both describe the same returned report.

/// A provider's config-home naming: the default home's name, which every numbered sibling is
/// derived from (`~/.claude2`, `~/.claude3`, …).
func addAccountConfigBase(providerID: String) -> String {
    providerID == "claude" ? ".claude" : ".codex"
}

/// The file a finished login writes into that home. Claude Code also has a Keychain-only shape,
/// which is why the slot probe below asks two questions rather than one.
func addAccountAuthFile(providerID: String) -> String {
    providerID == "claude" ? ".credentials.json" : "auth.json"
}

/// The next config home that is not already logged in, or nil when all 99 are taken.
///
/// A numbered home that exists but never finished logging in is handed back rather than skipped, so
/// an aborted login doesn't burn a number. The default home counts too: on a machine with no account
/// at all, adding one is simply the first login.
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
        if addAccountHomeHasLogin(base: base, authFile: authFile, dir: dir,
                                  fileExists: fileExists, keychainLogin: keychainLogin) { continue }
        return (dir, name)
    }
    return nil
}

/// Whether one config home already HOLDS a login: the two-generation question above, asked of a
/// single directory.
///
/// Named once because two callers ask it for opposite reasons and must not diverge: the slot walk
/// skips a home that has one, and the add flow decides a login FINISHED because one appeared. A
/// second copy of this rule would have Tally hand out a home it also considers signed in.
func addAccountHomeHasLogin(base: String, authFile: String, dir: URL,
                            fileExists: (String) -> Bool,
                            keychainLogin: (URL) -> Bool) -> Bool {
    if fileExists(dir.appendingPathComponent(authFile).path) { return true }
    return base == ".claude" && keychainLogin(dir)
}

/// The same question by provider, for the surfaces that hold a provider id rather than a base name.
func addedAccountHomeHasLogin(providerID: String, dir: URL,
                              fileExists: (String) -> Bool = AddAccountProbe.fileExists,
                              keychainLogin: (URL) -> Bool = AddAccountProbe.keychainLogin) -> Bool {
    addAccountHomeHasLogin(base: addAccountConfigBase(providerID: providerID),
                           authFile: addAccountAuthFile(providerID: providerID), dir: dir,
                           fileExists: fileExists, keychainLogin: keychainLogin)
}

/// The two questions above, asked of this machine. Named once so the preview a surface shows
/// ("Tally will create ~/.claude3") and the home it actually creates cannot be answered differently.
enum AddAccountProbe {
    static func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// An attribute check (KeychainReader.exists): it returns no secret and raises no consent
    /// prompt, so adding an account never touches a credential to find out where to put one.
    static func keychainLogin(_ dir: URL) -> Bool {
        KeychainReader.exists(service: claudeKeychainService(forConfigDir: dir))
    }
}

/// The config home this provider's next account would get, or nil when all 99 are taken.
func nextFreeAccountHome(providerID: String,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> (dir: URL, name: String)? {
    nextFreeSlot(base: addAccountConfigBase(providerID: providerID),
                 authFile: addAccountAuthFile(providerID: providerID), home: home,
                 fileExists: AddAccountProbe.fileExists, keychainLogin: AddAccountProbe.keychainLogin)
}

/// What preparing a new account's home actually did, so the surface that asked can say so. Every
/// field is an OUTCOME, never an intention: a share that failed on permissions has to be reportable
/// as a share that did not happen, or the user walks away believing one that never was.
struct AddedAccountHome: Sendable, Equatable {
    /// The config home the login will run against.
    let dir: URL
    /// Its directory name (`.claude3`), which is what the user is shown.
    let name: String
    /// This IS the main home - the machine had no account at all, so there is nothing to share
    /// FROM and this add is simply the first login.
    let isMainHome: Bool
    let linked: [String]
    /// Present already and therefore left exactly as the user built it.
    let kept: [String]
    /// Could not be linked (permissions, exotic filesystems): the share is incomplete.
    let failed: [String]
    /// Share links an EARLIER run left behind, removed because this run opted out.
    let unlinked: [String]
    /// Folder trust an EARLIER run seeded, removed for the same reason: opting out has to undo the
    /// shared default, or the "starts empty" this run promises is only true of the symlinks.
    let trustCleared: Int
    /// Whether the conversation record actually resolves to the main account's - the truth behind
    /// the privacy note, independent of how it got that way.
    let sharesConversations: Bool
    /// How many already-trusted project folders were carried over.
    let trustSeeded: Int
}

enum AddAccountFailure: Error, Sendable, Equatable {
    /// Every numbered home through 99 already has a login.
    case noFreeSlot(base: String)
    /// The home could not be created (an unwritable home directory, a file in the way). Reported
    /// rather than pushed downstream: a login started against a home that does not exist fails
    /// later, further from the cause, and with a message about the provider instead.
    case couldNotCreateHome(path: String)
}

/// Pick the next free config home, create it, and put in it everything a new account should start
/// with. Stops short of the login itself - starting the provider's CLI is the caller's business
/// (a terminal handoff for `tally add`, a background run with a browser round trip for the app).
///
/// `share` is the default everywhere it is offered: one harness maintained once, and one
/// conversation record so cross-account resume continues the same history. Opting out must also
/// UNDO what an earlier (aborted, default-shared) run linked into a reused directory, or
/// `--no-share` leaves the conversations shared.
///
/// Every side errand here is best-effort by design: a failure to link or to seed trust costs the
/// user a re-share or a trust prompt, never the login they actually asked for.
func prepareAddedAccountHome(
    providerID: String, share: Bool,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileExists: (String) -> Bool = AddAccountProbe.fileExists,
    keychainLogin: (URL) -> Bool = AddAccountProbe.keychainLogin
) throws -> AddedAccountHome {
    let base = addAccountConfigBase(providerID: providerID)
    guard let (dir, name) = nextFreeSlot(
        base: base, authFile: addAccountAuthFile(providerID: providerID), home: home,
        fileExists: fileExists, keychainLogin: keychainLogin)
    else { throw AddAccountFailure.noFreeSlot(base: base) }

    let fm = FileManager.default
    // codex refuses a CODEX_HOME that doesn't exist; creating it is harmless for claude.
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw AddAccountFailure.couldNotCreateHome(path: dir.path)
    }

    let mainHome = home.appendingPathComponent(base)
    let isMainHome = dir.path == mainHome.path
    let items = harnessItems(for: providerID, in: mainHome)
    var unlinked: [String] = [], linked: [String] = [], kept: [String] = [], failed: [String] = []
    var trustCleared = 0
    if !share, !isMainHome {
        unlinked = unlinkSharedHarness(from: mainHome, to: dir, items: items)
        // The other half of the undo. The links are only the visible half of what a shared run put
        // here: it also seeded folder trust, and a home resumed with --no-share that kept the seed
        // would silently skip the trust prompt for every project the main account vouched for.
        // Claude only, because it is the only provider that ever gets a seed.
        if providerID == "claude" { trustCleared = removeSeededFolderTrust(from: dir) }
    }
    if share, !isMainHome {
        (linked, kept, failed) = linkSharedHarness(from: mainHome, to: dir, items: items)
    }
    // Carry over the folders the main account already trusts, so the new one does not re-ask about
    // every project (TrustSeed.swift). Claude only: codex has no such prompt. Same condition as the
    // harness share, because it is the same intent - these accounts are one person's fleet.
    var trustSeeded = 0
    if share, providerID == "claude", !isMainHome {
        trustSeeded = seedFolderTrust(from: mainHome, to: dir)
    }
    return AddedAccountHome(
        dir: dir, name: name, isMainHome: isMainHome,
        linked: linked, kept: kept, failed: failed, unlinked: unlinked, trustCleared: trustCleared,
        // The privacy truth follows the ACTUAL state, not this run's work: shared is shared whether
        // it happened now, on an earlier run, or by hand.
        sharesConversations: !isMainHome
            && sharesConversations(providerID: providerID, source: mainHome, target: dir),
        trustSeeded: trustSeeded)
}
