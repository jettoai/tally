import Foundation
import Security

// Seeding the config home a session is about to start in with the MCP authorizations its siblings
// already hold, at the one moment when it is known which home that is: just before the child is
// launched (main.swift for a plain exec, Supervisor.swift for a supervised one, and both again on
// every relaunch, which is the case this exists for - a cap handoff moves a session to an account
// that has never authorized anything).
//
// WHY AT LAUNCH AND NOT ON A TIMER: "a home is used for the first time" is the whole of the problem,
// and it has exactly one entrance. A poller would have to watch five directories to answer a question
// the launcher already knows the answer to (design doc, 2026-08-21).
//
// FAIL-OPEN IS THE CONTRACT, and it is stated once here rather than at each of the dozen early
// returns below: every failure this code can meet leaves the target home exactly as Claude Code left
// it, and Claude Code then asks for the authorization the way it does today. A stale grant that gets
// seeded and turns out to be revoked is the same: the CLI's own 401 path re-authorizes. So nothing
// here reports an error, retries, or stops a launch, and the worst outcome of the whole feature is
// the behaviour of the machine before it existed.
//
// WHAT IT WILL NOT DO, in order of how much it would cost to get wrong:
//
//   1. It never writes the login credential. The blob holding the grants holds `claudeAiOauth` too,
//      and that one is another account's identity: it is carried through as an opaque value and the
//      write is refused unless it is byte-for-byte the same afterwards (MCPAuthMerge.swift).
//   2. It never CREATES a Keychain item, only updates one that is already there. A home with no
//      login has no item, and an item holding grants but no login is a document Claude Code never
//      writes (KeychainSecret.swift).
//   3. It never removes anything, from either face.
//   4. It never logs a token, an entry, or any part of one. What can be said out loud is a server
//      key, and the current design says nothing at all.
//
// KNOWN, MEASURED, AND ACCEPTED (2026-08-21, this machine, Release-signed binary): reading another
// program's Keychain item raises the macOS consent dialog and the read BLOCKS until it is answered
// or the process dies, while WRITING one is silent and needs no consent (SecItemUpdate returned 0
// and the item's modification date moved). Which is the wrong way round for a launcher: the cost
// lands on the read, and the read is the first thing this does.
//
// SO THE DIALOG IS ALLOWED ON EXACTLY ONE KIND OF PATH: the ones where a person just typed a command
// and is looking at the screen. That is `tally claude`, `tally resume`, and the supervisor's FIRST
// spawn, which happens in the same second as the command that started it. Every later spawn the
// supervisor makes - a cap handoff at 3am, a relaunch after a settings change, a self-update
// resupervise - runs with this process's Keychain dialogs turned OFF (`setKeychainInteractionAllowed`,
// KeychainSecret.swift), so an ungranted home fails in 9 ms instead of hanging a session nobody is
// watching.
//
// WHY THAT STILL CONVERGES, which is the part worth checking rather than believing: the dialog is a
// once-per-item event ("Always Allow" adds this binary to the item's ACL and the signature is stable
// across rebuilds), and the interactive paths are the ordinary way sessions start. So the grants are
// picked up the first time a person launches onto a home, and every unattended relaunch afterwards
// reads them without asking anybody. A machine that only ever relaunched, never launched, would
// never seed - and would behave exactly as it does today, which is the whole fail-open contract.
//
// The registration face below is plain file I/O and raises nothing, so it runs on every path.

/// Bring the MCP authorizations of `home` up to date from the other config homes of this provider,
/// immediately before a session starts there.
///
/// `interactive` is whether a PERSON IS WATCHING: true when this runs in the same second as a command
/// somebody typed, false for every spawn the supervisor makes later on its own. It is not a verbosity
/// setting and nothing here prints either way - it decides whether the Keychain may stop and ask, and
/// therefore whether this call can take an unbounded amount of time (the header says why, and why the
/// grants still converge with the unattended paths declining to ask).
func seedMCPAuthorization(provider: Provider, home: String, interactive: Bool) {
    // Claude Code only: the Keychain naming, the blob layout and the state file rule below are all
    // that CLI's, and codex keeps none of them.
    guard provider.id == "claude" else { return }
    let siblings = claudeSeedingHomes(excluding: home)
    guard !siblings.isEmpty else { return }
    seedMCPGrants(into: home, from: siblings, interactive: interactive)
    seedMCPRegistrations(into: home, from: siblings)
}

/// Replace this process with the provider CLI, seeding the home it is about to run in first.
///
/// EVERY launch this binary performs goes through here rather than calling `exec` directly, because
/// the home is settled in half a dozen different branches (an exported variable, a `--account` pin, a
/// panel pin, this project's pin, the headroom pick, the bare fallback) and the seeding belongs to
/// all of them equally. The supervised launch does not pass through here at all - it spawns a child
/// per relaunch rather than replacing this process once - so it carries its own call at its own
/// spawn, which is also what makes a cap handoff seed the account it hands off TO (Supervisor.swift).
///
/// Every launch through here is INTERACTIVE by definition: this function is only reached from a
/// subcommand somebody typed, and it replaces this process, so there is no later pass of it to be
/// unattended. The supervisor is where that distinction lives, because it is the thing that spawns
/// again without being asked.
func launchProvider(_ provider: Provider, args: [String], home: String,
                    env: (key: String, value: String)?) -> Never {
    seedMCPAuthorization(provider: provider, home: home, interactive: true)
    exec(provider.cli, args: args, env: env)
}

/// The other config homes this machine has a Claude account in.
///
/// From the snapshot rather than from a directory scan: that document IS the fleet Tally manages, and
/// a scan here would be a fourth spelling of "which `~/.claude*` directories are accounts"
/// (ClaudeAccounts.discover writes the first, AccountHome.swift the second, AddAccount.swift the
/// third). A missing or stale snapshot therefore means no seeding, which is the fail-open answer:
/// homes do not come and go between two minutes, so a stale list is a fine list, and no list at all
/// leaves Claude Code to ask.
///
/// The target is excluded by both spellings of "the same place": the path as written, and the object
/// it arrives at (PathIdentity.swift), because a home reached through an alias would otherwise be
/// read a second time and cost a second consent dialog to merge with itself.
func claudeSeedingHomes(excluding target: String) -> [String] {
    let (snapshot, _) = loadSnapshot()
    guard let snapshot else { return [] }
    let targetURL = URL(fileURLWithPath: target)
    return snapshot.accounts.compactMap { account in
        guard account.provider == "claude", let home = account.launchHome else { return nil }
        let url = URL(fileURLWithPath: home)
        guard url.standardizedFileURL.path != targetURL.standardizedFileURL.path,
              !pathsAreOne(url, targetURL) else { return nil }
        return home
    }
}

// MARK: - The grant (Keychain)

private func seedMCPGrants(into home: String, from siblings: [String], interactive: Bool) {
    // Unattended: turn this process's Keychain dialogs off before the first read, and REFUSE TO READ
    // AT ALL if that switch cannot be thrown (KeychainSecret.swift). A safety switch that silently
    // did nothing would leave a 3am cap handoff hanging on a dialog with nobody at the machine, which
    // is the one outcome this whole axis exists to prevent, so its absence fails closed.
    //
    // Not turned back on afterwards, and that is deliberate rather than an oversight: the switch is
    // process-global, this process is a supervisor whose remaining Keychain work is this same seeding
    // on later spawns, and those must not ask either. The interactive paths never come through here
    // (they exec, so their process is replaced by the child).
    if !interactive, !setKeychainInteractionAllowed(false) { return }
    // The Keychain account attribute every Claude Code credentials item carries: the login name,
    // which is what the CLI writes and what this machine's five items were all observed under
    // (2026-08-21). Asked for exactly, rather than matching on the service alone, because
    // `SecItemUpdate` has no match limit: a service that somehow held two items would have both of
    // them overwritten by a query that named only it.
    let account = NSUserName()
    let targetService = claudeKeychainService(forConfigDir: URL(fileURLWithPath: home))
    // The target's own document, which is the one being merged INTO, so nothing can proceed without
    // it: no item (a home with no login), a locked keychain, a declined consent dialog all land here.
    guard let targetData = keychainSecret(service: targetService, account: account),
          let targetBlob = mcpJSONDocument(from: targetData)
    else { return }

    var sources: [(data: Data, writtenAt: Date?)] = []
    for sibling in siblings {
        let service = claudeKeychainService(forConfigDir: URL(fileURLWithPath: sibling))
        // Asked BEFORE the secret, and by attributes only: a home whose item is not there at all is
        // skipped without ever raising a dialog for it (KeychainReader.swift).
        guard KeychainReader.exists(service: service, account: account) else { continue }
        let writtenAt = KeychainReader.modifiedAt(service: service, account: account)
        guard let data = keychainSecret(service: service, account: account) else { continue }
        sources.append((data, writtenAt))
    }

    guard let seeded = seededCredentialData(
        target: targetData,
        targetWrittenAt: KeychainReader.modifiedAt(service: targetService, account: account),
        sources: sources) else { return }
    guard updateKeychainSecret(service: targetService, account: account,
                               data: seeded.data) == errSecSuccess else { return }
    // And once more from the Keychain itself, because the refusals inside `seededCredentialData` are
    // about this process's arithmetic and this one is about what macOS now holds. The re-read costs
    // no second dialog: consent granted for the read at the top of this function holds for the rest
    // of the process.
    //
    // Anything short of "the login is still the same one" puts the original bytes back, which is a
    // restore of the document EXACTLY as it was read rather than a rebuild of it.
    if let data = keychainSecret(service: targetService, account: account),
       let blob = mcpJSONDocument(from: data),
       credentialBlobLoginIsIntact(before: targetBlob, after: blob) { return }
    _ = updateKeychainSecret(service: targetService, account: account, data: targetData)
}

// MARK: - The registration (.claude.json)

/// The backup this feature leaves beside a state file it rewrote. One generation, overwritten each
/// time: it is a way back from the write that just happened, not a history.
let mcpSeedBackupSuffix = ".tally-backup"

/// No `interactive` axis: this face is plain file I/O and asks nobody anything, so it runs on every
/// path including the unattended ones.
///
/// A target home with NO state file yet is skipped rather than created, which is a home Claude Code
/// has never been run in (it writes the file on first start). Not a gap: the first launch there
/// creates it, and the launch after that finds it and seeds it. Creating one here would mean this
/// launcher inventing the shape of another program's state document from scratch, on a guess about
/// which of its keys are mandatory.
private func seedMCPRegistrations(into home: String, from siblings: [String]) {
    let targetFile = claudeStateFile(forConfigDir: URL(fileURLWithPath: home))
    guard let targetData = try? Data(contentsOf: targetFile) else { return }

    var sources: [(data: Data, writtenAt: Date)] = []
    for sibling in siblings {
        let file = claudeStateFile(forConfigDir: URL(fileURLWithPath: sibling))
        guard let data = try? Data(contentsOf: file) else { continue }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        sources.append((data, modified ?? .distantPast))
    }

    guard let seeded = seededStateData(target: targetData, sources: sources) else { return }
    writeSeededState(seeded.data, to: targetFile, original: targetData)
}

/// Replace a state file with `data`, keeping a copy of what was there.
///
/// Backup first, then a temporary file, then one replacement: at no point is the target a partial
/// document. `replaceItemAt` is the rename, and it carries the original file's permissions and
/// ownership onto the replacement rather than leaving whatever the temporary was created with.
///
/// THE RACE THIS DOES NOT SOLVE, and is not meant to: a Claude Code running on this same home
/// rewrites the whole file whenever it changes anything in it, so a session that saved between the
/// read above and the replacement here has its change overwritten. That is the accepted cost of the
/// design (fail-open, and the file is rewritten wholesale by its owner too); the backup beside it is
/// the way back if it ever bites.
private func writeSeededState(_ data: Data, to file: URL, original: Data) {
    let backup = URL(fileURLWithPath: file.path + mcpSeedBackupSuffix)
    guard (try? original.write(to: backup, options: .atomic)) != nil else { return }
    let temporary = URL(fileURLWithPath: file.path + ".tally-seed-\(getpid())")
    guard (try? data.write(to: temporary, options: .atomic)) != nil else { return }
    if (try? FileManager.default.replaceItemAt(file, withItemAt: temporary)) == nil {
        try? FileManager.default.removeItem(at: temporary)
    }
}
