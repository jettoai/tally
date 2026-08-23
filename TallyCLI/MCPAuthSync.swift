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
//      write is refused unless everything except the grants comes back the same value it went in as
//      (MCPAuthMerge.swift, which also states what that comparison can and cannot see).
//   2. It never CREATES a Keychain item, only updates one that is already there. A home with no
//      login has no item, and an item holding grants but no login is a document Claude Code never
//      writes (KeychainSecret.swift).
//   3. It never removes anything, from either face.
//   4. It never logs a token, an entry, or any part of one. What can be said out loud is a server
//      key, and the current design says nothing at all.
//
// THE WINDOW BETWEEN READING AND WRITING, which is the only thing here that can destroy something.
// The Keychain keeps a credentials blob as ONE opaque secret: there is no way to change a key inside
// it without writing the whole document back, and no compare-and-swap either, so "store this only if
// the item is still what I read" cannot be expressed. A Claude Code writing that same item in
// between - a login refresh, an authorization it has just been given - would be rolled back by the
// write. Which is why the target's own document is read as LATE as it can be: after every sibling
// has been read, so that what is merged and stored is the item as it was milliseconds ago rather
// than as it was before a row of subprocess reads. What is left is a window of a few milliseconds
// that can be kept small and not closed. The same reading is the base for the merge, for the
// verification after the write and for the restore, because a restore that put back an older copy
// than the one it verified against would be the very damage this is about.
//
// NO PATH THROUGH THIS ASKS THE USER ANYTHING ANY MORE, and that is a correction of what this
// header used to say rather than a new property. Reading another program's Keychain item from this
// binary DOES raise the macOS consent panel and DOES block on it: the ACL of a `Claude Code-*`
// credentials item names the program that created it, which is `/usr/bin/security`, and never this
// one. The header of KeychainSecret.swift has the measurements. What changed is that the secret read
// is now performed BY `/usr/bin/security`, the program already in that entry, so it returns in about
// 80 ms and draws nothing, on every path, on the first launch as much as the thousandth.
//
// The version of this feature that shipped before assumed the panel was a once-per-item price:
// answer it with "Always Allow" and the binary joins the ACL. That did not hold in practice - the
// panel came back at every launch, in every project - and it cost a dialog per config home per
// launch until it was replaced.
//
// THE `interactive` AXIS SURVIVES THAT and is worth strictly less than it was: what it decides is
// whether this process turns its own Keychain consent off, and KeychainSecret.swift states how far
// that now reaches rather than saying it twice here.
//
// The registration face below is plain file I/O and raises nothing, so it runs on every path.

/// Bring the MCP authorizations of `home` up to date from the other config homes of this provider,
/// immediately before a session starts there.
///
/// `interactive` is whether a PERSON IS WATCHING: true when this runs in the same second as a command
/// somebody typed, false for every spawn the supervisor makes later on its own. It is not a verbosity
/// setting and nothing here prints either way - it decides whether this process leaves its own
/// Keychain consent on, which since the secret read moved to `/usr/bin/security` covers the write and
/// the attribute probes and nothing else (the header says how much less that is than it was).
func seedMCPAuthorization(provider: Provider, home: String, interactive: Bool) {
    // Claude Code only: the Keychain naming, the blob layout and the state file rule below are all
    // that CLI's, and codex keeps none of them.
    guard provider.id == "claude" else { return }
    let siblings = claudeSeedingHomes(excluding: home)
    guard !siblings.isEmpty else { return }
    // Passed down rather than asked for again below, because it is the same question both faces put
    // to MCPAuthMerge: which of these homes, if any, is the one Claude Code addresses without being
    // told (`defaultHome`, Snapshot.swift, and the one spelling of that rule this repo has).
    let providerDefaultHome = URL(fileURLWithPath: defaultHome(provider))
    seedMCPGrants(into: home, from: siblings, defaultHome: providerDefaultHome,
                  interactive: interactive)
    seedMCPRegistrations(into: home, from: siblings, defaultHome: providerDefaultHome)
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
/// WHETHER A PERSON IS WATCHING is a question about the shell line, not about the subcommand, and
/// this used to be written down as `true` on the strength of "somebody typed it". Somebody also typed
/// `tally claude -p … | jq` and `tally claude > log`, and those produce output for a program rather
/// than for a person - nobody would see a consent panel, and nobody would dismiss it either. They
/// arrive here exactly like an interactive launch, too: a launch whose stdout is not a terminal is
/// the one the supervisor declines to take (LaunchFlags.swift), so it falls through to this plain
/// exec.
///
/// Asked here rather than passed in by each of the eight call sites, because it is a property of this
/// process and of none of them: a site that forgot to pass it would look exactly like a site that
/// meant `true`, and a site that meant `true` is one that leaves this process able to stop and ask.
func launchProvider(_ provider: Provider, args: [String], home: String,
                    env: (key: String, value: String)?) -> Never {
    seedMCPAuthorization(provider: provider, home: home,
                         interactive: isatty(STDOUT_FILENO) == 1)
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
/// read a second time and spend a second secret read merging with itself.
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

private func seedMCPGrants(into home: String, from siblings: [String], defaultHome: URL,
                           interactive: Bool) {
    // OFF UNLESS OPTED IN (v0.64.1 hotfix, 2026-08-23): on a real machine v0.64.0 raised a Keychain
    // dialog for every sibling item at every launch, from the security tool this time, which the
    // probe that preceded d6619b7 did not reproduce. Until the difference between that probe and a
    // real launch is understood, this face stays off; the registration sync below it needs no
    // Keychain and keeps running. TALLY_MCP_GRANT_SEEDING=1 turns it back on for investigation.
    guard ProcessInfo.processInfo.environment["TALLY_MCP_GRANT_SEEDING"] == "1" else { return }
    // Unattended: turn this process's Keychain consent off before any of the work below, and GIVE UP
    // ENTIRELY if that switch cannot be thrown (KeychainSecret.swift, which states how far it now
    // reaches: the write and the attribute probes, not the secret read, which is another process). A
    // safety switch that silently did nothing would leave a 3am cap handoff able to stop on a panel
    // with nobody at the machine, so its absence fails closed rather than falling through.
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
    // Nil when the name would be a guess rather than a rule, which is a home this feature declines
    // to write to at all rather than writing to whichever item the guess landed on
    // (MCPAuthMerge.swift: `claudeSeedingKeychainService`).
    guard let targetService = claudeSeedingKeychainService(forConfigDir: URL(fileURLWithPath: home),
                                                           defaultHome: defaultHome) else { return }
    // Whether there is anything to merge INTO, asked by ATTRIBUTES so it reads no secret at all
    // (KeychainReader.swift) and costs no subprocess. Asked before the siblings rather than after,
    // because the siblings are what the secret reads are spent on: a home with no login has no item,
    // and N reads to build a merge with nowhere to go is the one thing this ordering could get
    // wrong.
    guard KeychainReader.exists(service: targetService, account: account) else { return }

    // THE ATTRIBUTE PASS, and it is a separate loop from the secret reads below for one reason: an
    // attribute query returns no secret and needs no subprocess (KeychainReader.swift), so everything
    // that can be decided without paying for a read is decided here.
    var probes: [MCPSeedProbe] = []
    var services: [String: String] = [:]
    for sibling in siblings {
        guard let service = claudeSeedingKeychainService(
            forConfigDir: URL(fileURLWithPath: sibling), defaultHome: defaultHome) else { continue }
        // Asked BEFORE the secret, and by attributes only: a home whose item is not there at all is
        // skipped without ever spending a read on it (KeychainReader.swift).
        guard KeychainReader.exists(service: service, account: account) else { continue }
        services[sibling] = service
        probes.append(MCPSeedProbe(home: sibling,
                                   modifiedAt: KeychainReader.modifiedAt(service: service,
                                                                         account: account)))
    }
    // THE FRESHNESS GATE (MCPSeedGate.swift states the rule, what it cannot see, and what it
    // changes). A launch where no sibling's item has been written since this home last merged from
    // it stops HERE, having read no secret at all, which is the ordinary case and the whole point of
    // the gate.
    let stale = mcpSeedSourcesToRead(probed: probes, record: loadMCPSeedRecord(for: home))
    guard !stale.isEmpty else { return }

    var sources: [(data: Data, writtenAt: Date?)] = []
    var observed: MCPSeedRecord = [:]
    // Sampled BEFORE the reads rather than beside each one, because of what the clamp below asks:
    // "can this item still be written inside the second this record is about". A second that had
    // not elapsed when the pass began is the whole of that risk, and a later reading of the clock
    // would only shrink it (`mcpSeedRecordedDate`).
    let readingAt = Date()
    for probe in stale {
        guard let service = services[probe.home],
              let data = keychainSecret(service: service, account: account) else { continue }
        // The merge gets the date the probe returned, unclamped: there it is evidence of which
        // document is newer, and the clamp is about what may be trusted at the NEXT launch.
        sources.append((data, probe.modifiedAt))
        // Recorded only where the secret ACTUALLY CAME BACK, and only where the probe gave a date to
        // record. A read that was declined, or an item macOS would not describe, leaves no record, so
        // the next launch asks again rather than treating a home it never merged as merged.
        if let modifiedAt = probe.modifiedAt {
            observed[probe.home] = mcpSeedRecordedDate(modifiedAt, readingAt: readingAt)
        }
    }
    guard !sources.isEmpty else { return }

    // THE TARGET'S OWN DOCUMENT, AND IT IS READ HERE FOR THE REASON THE HEADER GIVES: everything
    // above this line is one subprocess per stale sibling, and everything below it is arithmetic and
    // one write. So this reading is the freshest one that can be had, and it is the base of all three
    // things that follow - the merge, the check afterwards, and the restore if that check fails.
    // Every way this can come back empty is a home that cannot be seeded: a locked keychain, a read
    // that ran out of time, a truncated document, an item that has gone.
    guard let targetData = keychainSecret(service: targetService, account: account),
          let targetBlob = mcpJSONDocument(from: targetData) else { return }
    let targetWrittenAt = KeychainReader.modifiedAt(service: targetService, account: account)

    guard let seeded = seededCredentialData(target: targetData, targetWrittenAt: targetWrittenAt,
                                            sources: sources) else {
        // A pass that found NOTHING TO ADOPT is a concluded pass, and recording it is most of what
        // the gate buys: "these siblings hold nothing this home lacks" is the ordinary answer on a
        // machine whose homes have all been seeded, and an answer nobody wrote down would be bought
        // again with a secret read at every launch for ever.
        recordMCPSeed(observed, for: home)
        return
    }
    guard updateKeychainSecret(service: targetService, account: account,
                               data: seeded.data) == errSecSuccess else { return }
    // And once more from the Keychain itself, because the refusals inside `seededCredentialData` are
    // about this process's arithmetic and this one is about what macOS now holds. The re-read costs
    // one more subprocess and about 80 ms, and asks nobody anything, exactly like the one above.
    //
    // Anything short of "everything but the grants is still the same" puts back the bytes read just
    // above, which is a restore of the document EXACTLY as it was read rather than a rebuild of it,
    // and exactly the document this check compared against rather than an older reading of it.
    if let data = keychainSecret(service: targetService, account: account),
       let blob = mcpJSONDocument(from: data),
       credentialBlobIsIntactApartFromGrants(before: targetBlob, after: blob) {
        recordMCPSeed(observed, for: home)
        return
    }
    // Nothing is recorded on the way out of here: what this path leaves behind is the document as it
    // was before, so the merge did not happen and the next launch has to try it again.
    _ = updateKeychainSecret(service: targetService, account: account, data: targetData)
}

// MARK: - The record (~/.tally/mcp-seed.json)

/// Which of a config home's siblings this launcher has already merged MCP grants from, and what
/// each of those items' modification dates was when it did (MCPSeedGate.swift holds the shape and
/// every rule over it).
///
/// A FILE OF ITS OWN, which is the whole reason it is not a block of `~/.tally/state.json` where it
/// first lived. That document is the app's: `LaunchPolicyStore` rewrites it WHOLE from its own model
/// whenever somebody changes a launch setting. A record kept in it would have to be read here before
/// the Keychain work and written back after, and a pin or a model default the user chose in between
/// would be reverted by that write - a lost update, on the user's own intent, to save a Keychain
/// read. One writer per file; this file's writer is the CLI, and the app never reads it.
let mcpSeedURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/mcp-seed.json")

/// What this target home last merged from each of its siblings.
///
/// A missing or unreadable document reads as NO RECORD AT ALL, which is fail-open in the same
/// direction as everything else here: every sibling is then read, exactly as this feature behaved
/// before the gate existed.
private func loadMCPSeedRecord(for home: String) -> MCPSeedRecord {
    guard let data = try? Data(contentsOf: mcpSeedURL),
          let document = mcpJSONDocument(from: data) else { return [:] }
    return mcpSeedRecord(in: document, for: home)
}

/// Write down what this pass read, so the next launch can skip it.
///
/// READ AGAIN HERE rather than patched onto the copy the gate read, because two launches can be
/// seeding two different homes at once and the one that writes second would otherwise publish a
/// document that has forgotten the first. Created when it is absent: this is the CLI's own document,
/// with no other program's schema to guess at.
///
/// A document that will not parse is REPLACED rather than refused, which is the opposite of what
/// `loadProjectPoliciesForWrite` does with its file and for a reason worth stating: what is lost
/// there is profiles the user typed, and what is lost here is the knowledge that some Keychain items
/// were already read. Refusing would leave the gate switched off for good on a machine whose file
/// got truncated once; overwriting costs one launch its saved reads.
private func recordMCPSeed(_ observed: MCPSeedRecord, for home: String) {
    guard !observed.isEmpty else { return }
    let document = (try? Data(contentsOf: mcpSeedURL)).flatMap(mcpJSONDocument(from:)) ?? [:]
    let merged = mcpSeedRecord(in: document, for: home).merging(observed) { _, fresh in fresh }
    guard let bytes = try? JSONSerialization.data(
        withJSONObject: mcpSeedDocument(document, setting: merged, for: home),
        options: [.prettyPrinted, .sortedKeys]) else { return }
    try? FileManager.default.createDirectory(at: mcpSeedURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? bytes.write(to: mcpSeedURL, options: .atomic)
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
private func seedMCPRegistrations(into home: String, from siblings: [String], defaultHome: URL) {
    // Nil for the same reason the Keychain face has one, and with more at stake: an unguarded guess
    // here names a path that belongs to no config home, and this function BACKS UP AND REWRITES the
    // file it is given (MCPAuthMerge.swift: `claudeSeedingStateFile`).
    guard let targetFile = claudeSeedingStateFile(forConfigDir: URL(fileURLWithPath: home),
                                                  defaultHome: defaultHome) else { return }
    guard let targetData = try? Data(contentsOf: targetFile) else { return }

    var sources: [(data: Data, writtenAt: Date)] = []
    for sibling in siblings {
        guard let file = claudeSeedingStateFile(forConfigDir: URL(fileURLWithPath: sibling),
                                                defaultHome: defaultHome) else { continue }
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
/// THE COPIES ARE AS PRIVATE AS THE ORIGINAL, which they do not become by themselves. A state file
/// holds the `env` and the `headers` of every MCP server registered in it, which is where API keys
/// are kept, along with every project this account has ever trusted; the config homes on this machine
/// keep theirs at 0600 (three of five, measured 2026-08-21). `Data.write` has no mode of its own and
/// creates at 0644 under the usual umask, so both copies are given the original's mode instead - and
/// if that cannot be done they are removed rather than left lying there, because the backup is never
/// cleaned up. It is the way back from the write that just happened, and it stays beside the file.
///
/// THE RACE THIS DOES NOT SOLVE, and is not meant to: a Claude Code running on this same home
/// rewrites the whole file whenever it changes anything in it, so a session that saved between the
/// read above and the replacement here has its change overwritten. That is the accepted cost of the
/// design (fail-open, and the file is rewritten wholesale by its owner too); the backup beside it is
/// the way back if it ever bites.
private func writeSeededState(_ data: Data, to file: URL, original: Data) {
    // 0600 when the original will not say, which is the private answer rather than the convenient
    // one: what is about to be created is a copy of that file's contents.
    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    let mode = attributes?[.posixPermissions] as? NSNumber ?? NSNumber(value: 0o600)
    let backup = URL(fileURLWithPath: file.path + mcpSeedBackupSuffix)
    guard writeCopy(original, to: backup, mode: mode) else { return }
    let temporary = URL(fileURLWithPath: file.path + ".tally-seed-\(getpid())")
    guard writeCopy(data, to: temporary, mode: mode) else { return }
    if (try? FileManager.default.replaceItemAt(file, withItemAt: temporary)) == nil {
        try? FileManager.default.removeItem(at: temporary)
    }
}

/// Write `data` to `file` with `mode`, answering whether it is now there with that mode.
///
/// The mode is applied after the write rather than at creation, because Foundation's atomic write
/// takes no mode: the file is at the umask's default for the microseconds in between, and that much
/// cannot be removed without giving up either the atomicity or `Data.write`. What CAN be removed is a
/// file LEFT BEHIND at that default, so a chmod that fails takes the file with it and the caller
/// gives up - the fail-open answer, which leaves the home exactly as Claude Code left it.
private func writeCopy(_ data: Data, to file: URL, mode: NSNumber) -> Bool {
    guard (try? data.write(to: file, options: .atomic)) != nil else { return false }
    guard (try? FileManager.default.setAttributes([.posixPermissions: mode],
                                                  ofItemAtPath: file.path)) != nil else {
        try? FileManager.default.removeItem(at: file)
        return false
    }
    return true
}
