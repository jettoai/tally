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

/// The note `prepareAddedAccountHome` leaves in a home it just created, and the only thing that
/// makes an EXISTING directory reusable (see `addAccountHomeIsFree`).
///
/// Deliberately not any of the other traces a preparation leaves. The share links and the trust
/// seed (`.tally-trust-seed.json`) outlive the login by design - a fully signed-in account keeps
/// them - so reading one of those as "unfinished" would hand a working account's home to a new
/// login the moment it signed out. This marker's life ends WITH the login: it is written before the
/// provider's CLI is started and removed the first time Tally sees an account signed in there
/// (`clearAddAccountPendingMarker`, called from KnownAccountsStore).
let addAccountPendingMarker = ".tally-pending-add"

/// What the marker HOLDS: the home exactly as the preparation left it.
///
/// The marker's presence alone is not proof that a home is still an unfinished attempt, because
/// nothing can guarantee the marker is removed on time. `tally add` execs the provider's login over
/// its own process, so the only surface that can clear it is a Tally that is RUNNING when discovery
/// next sees the login - and a user who finishes a login with the app closed and later signs out
/// leaves a marker sitting on a directory full of their conversations. Reuse would then overwrite
/// it, which is the very bug the slot rule exists to close.
///
/// So reuse asks for evidence the marker cannot fake: is this directory still, entry for entry, the
/// preparation? A login writes into its home (`sessions/`, `history.jsonl`, `projects/`, a rewritten
/// `.claude.json`), so a home that has ever been signed in to no longer matches, marker or not. The
/// failure direction is deliberate: an unrecognized, unreadable or absent note means "not reusable",
/// which costs an abandoned attempt its number and never costs anybody their history.
struct AddAccountPendingNote: Codable, Equatable, Sendable {
    /// When the preparation ran. For a human reading the file; nothing decides on it.
    var createdAt: String
    /// The home's entries when the preparation finished, this marker excluded, sorted.
    var entries: [String]
}

/// What is at one numbered config home right now - existence first, contents second, because
/// existence is what decides occupancy.
enum AddAccountHomeContents: Equatable {
    /// Nothing at this path: the home is this add's to create.
    case absent
    /// A directory, and everything in it. An empty array is a directory with nothing in it.
    case entries([String])
    /// Not a usable directory: a file standing in the way, or one that cannot be read. Occupied by
    /// something, whatever it is.
    case blocked
}

/// The next config home a new login may be pointed at, or nil when all 99 are taken.
///
/// THE RULE: a directory that EXISTS is somebody's, full stop. Two exceptions, and only two:
///
///   1. a home this very flow prepared and nobody has signed into yet (it carries
///      `addAccountPendingMarker`, and no login has landed in it since), so an aborted attempt is
///      resumed rather than burning a number;
///   2. a directory with nothing at all in it, which holds nobody by definition.
///
/// "Is there a login in it?" was the whole occupancy test until 2026-08-03, and that is what broke
/// this: an account whose login had EXPIRED (Codex 2, a Team seat whose `auth.json` was gone) read
/// as a free slot, so adding an account reused `~/.codex2` - and the browser round trip signed that
/// existing account's home in as a different account, on top of its conversations and settings.
/// The earlier version of the same bug (2026-07-28) was narrower: a Keychain-only claude login left
/// no credentials file, so a fully signed-in home read as an aborted one. Both have the same shape:
/// a credential is a fact about NOW, and a directory full of somebody's history is not free just
/// because nobody is signed in to it this minute.
///
/// The login question survives as the completion signal INSIDE exception 1, and it is not the only
/// one: a marker that outlived its login (the CLI's `tally add` execs the provider and can never
/// come back to tidy up) must not re-open the very hole above, so the marker has to still DESCRIBE
/// the directory it sits in (`AddAccountPendingNote`). A signed-out home whose marker was never
/// cleared fails that second question even though it passes the first.
///
/// Every probe is injected so the choice is testable without a Keychain, a Trash or a home
/// directory. The Keychain one is only ever consulted for claude: a codex login is a file
/// (`auth.json`), so asking the Keychain about it would be asking a question with no answer.
func nextFreeSlot(base: String, authFile: String, home: URL,
                  contents: (URL) -> AddAccountHomeContents = AddAccountProbe.contents,
                  fileExists: (String) -> Bool = AddAccountProbe.fileExists,
                  keychainLogin: (URL) -> Bool = AddAccountProbe.keychainLogin,
                  pendingNote: (URL) -> AddAccountPendingNote? = AddAccountProbe.pendingNote)
    -> (dir: URL, name: String)? {
    for n in 1 ... 99 {
        let name = n == 1 ? base : "\(base)\(n)"
        let dir = home.appendingPathComponent(name)
        if addAccountHomeIsFree(base: base, authFile: authFile, dir: dir, contents: contents,
                                fileExists: fileExists, keychainLogin: keychainLogin,
                                pendingNote: pendingNote) {
            return (dir, name)
        }
    }
    return nil
}

/// Whether one config home may be handed to a new login: the rule above, asked of a single
/// directory.
func addAccountHomeIsFree(base: String, authFile: String, dir: URL,
                          contents: (URL) -> AddAccountHomeContents,
                          fileExists: (String) -> Bool,
                          keychainLogin: (URL) -> Bool,
                          pendingNote: (URL) -> AddAccountPendingNote?) -> Bool {
    switch contents(dir) {
    case .absent:
        return true
    case .blocked:
        return false
    case .entries(let entries):
        if entries.isEmpty { return true }
        guard entries.contains(addAccountPendingMarker),
              !addAccountHomeHasLogin(base: base, authFile: authFile, dir: dir,
                                      fileExists: fileExists, keychainLogin: keychainLogin),
              let note = pendingNote(dir)
        else { return false }
        // The stronger half of the evidence: nothing has happened in here since the preparation.
        return note.entries == addAccountHomeSnapshot(entries)
    }
}

/// A home's entries as the marker records them: the marker itself excluded (it is written INTO the
/// directory it describes), sorted so two listings of one unchanged directory always compare equal.
func addAccountHomeSnapshot(_ entries: [String]) -> [String] {
    entries.filter { $0 != addAccountPendingMarker }.sorted()
}

/// Whether one config home HOLDS a login, asked of both places a credential can live: Claude Code
/// has two generations of credential storage in the field at once, older logins wrote
/// `<dir>/.credentials.json` and newer ones put the OAuth token in the Keychain and write no file
/// at all.
///
/// Named once because two callers ask it for opposite reasons and must not diverge: the slot walk
/// refuses to resume a pending home once one appears, and the add flow decides a login FINISHED
/// because one appeared. A second copy of this rule would have Tally hand out a home it also
/// considers signed in.
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

    /// What is at a numbered home. A path that is not a readable directory is `blocked` rather than
    /// absent: the add then moves to the next number instead of trying to create a home over
    /// whatever is standing there and failing the whole flow.
    static func contents(_ dir: URL) -> AddAccountHomeContents {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory)
        else { return .absent }
        guard isDirectory.boolValue,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return .blocked }
        return .entries(entries)
    }

    /// An attribute check (KeychainReader.exists): it returns no secret and raises no consent
    /// prompt, so adding an account never touches a credential to find out where to put one.
    static func keychainLogin(_ dir: URL) -> Bool {
        KeychainReader.exists(service: claudeKeychainService(forConfigDir: dir))
    }

    /// The marker's own contents. Unreadable, or written by something that is not this flow, is
    /// nil - which reads as "no evidence", and therefore as a home nobody may reuse.
    static func pendingNote(_ dir: URL) -> AddAccountPendingNote? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(addAccountPendingMarker))
        else { return nil }
        return try? JSONDecoder().decode(AddAccountPendingNote.self, from: data)
    }
}

/// The config home this provider's next account would get, or nil when all 99 are taken.
func nextFreeAccountHome(providerID: String,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> (dir: URL, name: String)? {
    nextFreeSlot(base: addAccountConfigBase(providerID: providerID),
                 authFile: addAccountAuthFile(providerID: providerID), home: home)
}

/// Forget that a home was ever pending, because Tally has now SEEN an account signed in there.
///
/// Best-effort, and safe to call about any home: the marker is only ever written by the preparation
/// below, so a home that never had one has nothing to lose here. Left behind, it would make a home
/// that later signs out look reusable again, which is the whole bug the slot rule exists to close.
func clearAddAccountPendingMarker(in dir: URL) {
    try? FileManager.default.removeItem(at: dir.appendingPathComponent(addAccountPendingMarker))
}

/// Clear the marker from every numbered home of this provider that now HOLDS a login.
///
/// The app clears one the moment discovery sees the login (KnownAccountsStore), but the app is not
/// always running, and the surface that needs this most cannot do it at all: `tally add` execs the
/// provider's login over its own process and never comes back. So each run of `tally add` first
/// tidies up after the runs before it, and a marker whose login has since arrived stops being a
/// question the next add has to answer from the directory listing alone.
///
/// The marker check comes first on purpose: it is a string test against a listing the walk already
/// needs, and it keeps the login probe (a Keychain attribute read, for claude) off the 99 homes that
/// have no marker to clear.
@discardableResult
func clearFinishedPendingMarkers(
    providerID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
    contents: (URL) -> AddAccountHomeContents = AddAccountProbe.contents,
    fileExists: (String) -> Bool = AddAccountProbe.fileExists,
    keychainLogin: (URL) -> Bool = AddAccountProbe.keychainLogin
) -> [String] {
    let base = addAccountConfigBase(providerID: providerID)
    let authFile = addAccountAuthFile(providerID: providerID)
    var cleared: [String] = []
    for n in 1 ... 99 {
        let name = n == 1 ? base : "\(base)\(n)"
        let dir = home.appendingPathComponent(name)
        guard case .entries(let entries) = contents(dir),
              entries.contains(addAccountPendingMarker),
              addAccountHomeHasLogin(base: base, authFile: authFile, dir: dir,
                                     fileExists: fileExists, keychainLogin: keychainLogin)
        else { continue }
        clearAddAccountPendingMarker(in: dir)
        cleared.append(name)
    }
    return cleared
}

/// Mark a home as prepared-but-not-signed-in-yet, recording what is in it right now so a later add
/// can tell this preparation from a directory somebody has since lived in.
///
/// Best-effort like the other side errands: a marker that fails to land costs the next attempt a
/// fresh number, never the login the user asked for. The listing is read from the real directory
/// rather than from an injected probe - this writes a file into that same real directory, and a
/// note describing a directory other than the one it lands in would be worse than no note.
private func writeAddAccountPendingMarker(in dir: URL) {
    var entries: [String] = []
    if case .entries(let found) = AddAccountProbe.contents(dir) {
        entries = addAccountHomeSnapshot(found)
    }
    let note = AddAccountPendingNote(createdAt: ISO8601DateFormatter().string(from: Date()),
                                     entries: entries)
    guard let data = try? JSONEncoder().encode(note) else { return }
    try? data.write(to: dir.appendingPathComponent(addAccountPendingMarker), options: .atomic)
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
    contents: (URL) -> AddAccountHomeContents = AddAccountProbe.contents,
    fileExists: (String) -> Bool = AddAccountProbe.fileExists,
    keychainLogin: (URL) -> Bool = AddAccountProbe.keychainLogin,
    pendingNote: (URL) -> AddAccountPendingNote? = AddAccountProbe.pendingNote
) throws -> AddedAccountHome {
    let base = addAccountConfigBase(providerID: providerID)
    guard let (dir, name) = nextFreeSlot(
        base: base, authFile: addAccountAuthFile(providerID: providerID), home: home,
        contents: contents, fileExists: fileExists, keychainLogin: keychainLogin,
        pendingNote: pendingNote)
    else { throw AddAccountFailure.noFreeSlot(base: base) }

    let fm = FileManager.default
    // codex refuses a CODEX_HOME that doesn't exist; creating it is harmless for claude.
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw AddAccountFailure.couldNotCreateHome(path: dir.path)
    }
    // Written before anything else goes in, because from here on the directory EXISTS - and an
    // existing directory is occupied unless this marker says it is this flow's own unfinished work.
    writeAddAccountPendingMarker(in: dir)

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
    // Written a second time, now that the sharing and the seeding are done: the note has to
    // describe the home the login is about to run against, or the next add would read this very
    // preparation's own links as somebody having lived here.
    writeAddAccountPendingMarker(in: dir)
    return AddedAccountHome(
        dir: dir, name: name, isMainHome: isMainHome,
        linked: linked, kept: kept, failed: failed, unlinked: unlinked, trustCleared: trustCleared,
        // The privacy truth follows the ACTUAL state, not this run's work: shared is shared whether
        // it happened now, on an earlier run, or by hand.
        sharesConversations: !isMainHome
            && sharesConversations(providerID: providerID, source: mainHome, target: dir),
        trustSeeded: trustSeeded)
}
