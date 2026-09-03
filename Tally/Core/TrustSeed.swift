import Foundation

// Carrying folder trust to a newly added account, so the fleet does not re-interrogate the user.
//
// Claude Code asks "is this a project you trust?" once per folder per config dir, and remembers the
// answer in `<state>.claude.json` under `projects[<path>].hasTrustDialogAccepted`. That file is
// deliberately NOT part of the shared harness (SharedHarness.swift): it is an identity file, it
// carries `oauthAccount`, and every running session rewrites it constantly, so symlinking it would
// braid two accounts together. The cost of that correct decision is that account number three is
// asked about every folder the user already vouched for on account number one.
//
// So adding an account seeds it instead of sharing it: at login time, the trusted PATHS are copied
// across and nothing else. A copy, once, of a list of directories the user has already approved.
//
// Compiled into both targets (it moved out of TallyCLI/ on 2026-08-03): `tally add` and Settings'
// own "Add account" flow prepare a new home the same way, from one implementation.
//
// MEASURED 2026-07-28, because seeding a file another program owns is only safe if that program
// merges rather than overwrites. Against claude 2.1.220, in a throwaway config dir:
//
//   - a `.claude.json` pre-seeded with `projects[<cwd>].hasTrustDialogAccepted = true` launched
//     straight to the prompt, and afterwards still held that value, with claude's own per-project
//     fields (`lastVersionBase` and friends) added ALONGSIDE it. It merges; it does not reset.
//   - the control, same config dir and same launch, in a cwd absent from that map: the trust
//     dialog appeared. So the skip above is caused by the seeded value rather than by anything
//     else about the run.

// The state file is addressed through the shared `claudeStateFile(forConfigDir:)`
// (Tally/Core/ClaudeStatePath.swift), because the app reads the same file for the same dirs. Get
// that path wrong and this seeds nothing, which looks exactly like "nothing was trusted yet".

/// The trust seed to write into a new account's state: every path the source account has ACCEPTED,
/// each reduced to that single fact.
///
/// Reduced rather than copied. The source entries carry per-project history (onboarding counters,
/// last version, shutdown state) and the file around them carries the account's identity; none of
/// that belongs to the new account, and a copy that took the whole map would be one edit away from
/// carrying `oauthAccount` too. Paths that were never accepted are left out entirely, so the new
/// account asks about them exactly as the old one did.
func trustedProjectSeed(fromState raw: Data) -> [String: [String: Bool]] {
    guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
          let projects = root["projects"] as? [String: Any] else { return [:] }
    var seed: [String: [String: Bool]] = [:]
    for (path, entry) in projects {
        guard let entry = entry as? [String: Any],
              entry["hasTrustDialogAccepted"] as? Bool == true else { continue }
        seed[path] = ["hasTrustDialogAccepted": true]
    }
    return seed
}

/// Write the seed into a config dir that has no state file yet.
///
/// Returns the number of paths seeded, or 0 when there was nothing to do. Never overwrites: an
/// existing file belongs either to a real account or to an aborted login that already has its own
/// answers, and this is a convenience, not a migration. Best-effort throughout, like every other
/// side errand `tally add` runs before handing the terminal over: a failure here must cost the user
/// a trust prompt, never the login they actually asked for.
///
/// A record of what was written goes down beside it (`writeTrustSeedRecord`), because the undo
/// below deletes a file, and deleting is only ever safe against a file we can PROVE we wrote.
/// The two are written as a PAIR, and rolled back together: a seed whose record failed to land can
/// never be taken back (the undo would find no proof and refuse), so opting out on the retry would
/// silently keep the main account's answers. Either both exist or neither does.
@discardableResult
func seedFolderTrust(from source: URL, to target: URL) -> Int {
    let targetFile = claudeStateFile(forConfigDir: target)
    guard !FileManager.default.fileExists(atPath: targetFile.path),
          let raw = try? Data(contentsOf: claudeStateFile(forConfigDir: source)) else { return 0 }
    let seed = trustedProjectSeed(fromState: raw)
    guard !seed.isEmpty,
          let body = try? JSONSerialization.data(withJSONObject: ["projects": seed]) else { return 0 }
    try? FileManager.default.createDirectory(at: targetFile.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard (try? body.write(to: targetFile, options: .atomic)) != nil else { return 0 }
    guard writeTrustSeedRecord(paths: Set(seed.keys), in: target) else {
        // Safe to delete unconditionally: the guard above proved this path held no file before
        // this call, so the only thing being dropped is what these two lines just wrote.
        try? FileManager.default.removeItem(at: targetFile)
        return 0
    }
    return seed.count
}

/// The paths a state file carries IF its content is still exactly the shape `seedFolderTrust`
/// writes, and nil for anything else.
///
/// The seed is one top-level key (`projects`) whose every entry is the single fact
/// `hasTrustDialogAccepted: true`. Claude Code writing to that file at all adds its own top-level
/// fields (`userID`, `oauthAccount`, …) and its own per-project history, and a user who edited it by
/// hand leaves something else again.
///
/// A shape is NOT provenance, though, and this must never be read as one: a user who prepared
/// `~/.claude4` themselves, and answered the trust prompt there before any account was signed in,
/// owns a file that matches this exactly. That is why the undo asks the record as well.
func trustSeedPaths(inState raw: Data) -> Set<String>? {
    guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
          root.count == 1, let projects = root["projects"] as? [String: Any],
          !projects.isEmpty else { return nil }
    for (_, entry) in projects {
        guard let entry = entry as? [String: Any], entry.count == 1,
              entry["hasTrustDialogAccepted"] as? Bool == true else { return nil }
    }
    return Set(projects.keys)
}

// MARK: Provenance - the note Tally leaves about a seed it wrote

/// Where a seed's record lives: inside the config home it seeded, next to nothing of Claude Code's.
///
/// Deliberately NOT a marker field inside the state file. That document belongs to another program:
/// a key of ours in it is a foreign field in somebody else's schema, and the first rewrite that
/// keeps only the fields it knows about would drop it - silently disarming the undo, or worse,
/// leaving the file looking unowned while it is ours.
func trustSeedRecordFile(inConfigDir dir: URL) -> URL {
    dir.appendingPathComponent(".tally-trust-seed.json")
}

private struct TrustSeedRecord: Codable {
    var version = 1
    /// Exactly the paths written, so the undo can check the file it is about to delete is still the
    /// one described here rather than merely shaped like it.
    var paths: [String]
    var writtenAt: Date
}

/// Whether the record actually landed. Reported rather than best-effort because the seed it
/// describes is only undoable while it exists (see `seedFolderTrust`).
private func writeTrustSeedRecord(paths: Set<String>, in dir: URL) -> Bool {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(TrustSeedRecord(paths: paths.sorted(),
                                                         writtenAt: Date())) else { return false }
    return (try? data.write(to: trustSeedRecordFile(inConfigDir: dir), options: .atomic)) != nil
}

private func readTrustSeedRecord(in dir: URL) -> Set<String>? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: trustSeedRecordFile(inConfigDir: dir)),
          let record = try? decoder.decode(TrustSeedRecord.self, from: data),
          !record.paths.isEmpty else { return nil }
    return Set(record.paths)
}

/// Undo a seed an earlier, shared run wrote into a home this run is preparing UNSHARED.
///
/// Returns the number of paths removed, 0 when there was nothing of ours to remove. The counterpart
/// to `unlinkSharedHarness`, and for the same reason: a first attempt at adding an account defaults
/// to sharing, an aborted one leaves its home to be resumed, and opting out on the retry has to undo
/// what that first attempt put there. Without this the new account skips the trust prompt for every
/// project the main account vouched for, while the sheet says it starts empty.
///
/// TWO things must hold before anything is deleted, and the first is the one that matters: Tally
/// must have RECORDED writing this seed, into this home. The shape alone was the whole test until
/// 2026-08-03, and a user's own `~/.claudeN` whose `.claude.json` held nothing but accepted trust
/// dialogs matched it exactly - so preparing that home unshared deleted the user's file. A shape
/// cannot say who wrote something. Then, and only then, the file still has to BE that seed
/// (same paths, still nothing else in it): once the account or the user has written to it, it is
/// theirs, record or no record.
///
/// A seed written before the record existed therefore stays forever. That is the deliberate side to
/// fail on: the cost is a home that skips some trust prompts it should have asked about, against
/// deleting a file somebody else owns.
@discardableResult
func removeSeededFolderTrust(from target: URL) -> Int {
    let record = trustSeedRecordFile(inConfigDir: target)
    guard let recorded = readTrustSeedRecord(in: target) else { return 0 }
    let file = claudeStateFile(forConfigDir: target)
    guard let raw = try? Data(contentsOf: file) else {
        // The file the record describes is already gone; the note about it is just litter.
        try? FileManager.default.removeItem(at: record)
        return 0
    }
    guard let paths = trustSeedPaths(inState: raw), paths == recorded,
          (try? FileManager.default.removeItem(at: file)) != nil else { return 0 }
    try? FileManager.default.removeItem(at: record)
    return paths.count
}

// MARK: Folder trust for a relaunch Tally itself decided on

/// Mark `directory` trusted in the state file of `home`, so a child this program restarts is not
/// asked a question the session it continues has already lived past.
///
/// WHY THIS IS NOT A GRANT TALLY INVENTED. Claude Code decides trust once, at start-up, and
/// remembers the answer for the life of that process. On 2026-09-02 a session was launched in a
/// directory that was not yet a git repository, so the trust walk climbed unbounded, found
/// `~/workspace` already accepted, and asked nothing. That conversation then ran `git init`. Three
/// hours later the supervisor self-updated and relaunched the same conversation with `--resume`,
/// and the new child re-ran the decision from scratch: the directory was now its own git root, the
/// walk was bounded to it, no entry named it, and the trust dialog appeared. The session sat
/// behind that dialog for three minutes with nobody at the machine, and every line the supervisor
/// types into a session would have queued behind it too.
///
/// So this is for RELAUNCHES ONLY (TallyCLI/Supervisor.swift): a directory whose session is already
/// running in it, restarted by a decision of Tally's rather than of the user's. Their own first
/// launch is left to Claude Code untouched, which is the line this must not cross. Tally never
/// answers a trust question the user has not already answered by being there.
///
/// THE KEY IS THE REALPATH OF THE DIRECTORY ITSELF, which is sufficient whatever Claude Code picks
/// as its own project key. Its walk (read out of 2.1.258) starts at the realpath of the cwd and
/// climbs towards the git root, accepting as soon as one of those paths carries the flag, so the
/// first step of that walk is this entry. Keyed any other way this would seed a path nothing reads.
///
/// Returns whether the file was CHANGED, and it changes it in EXACTLY ONE CASE: the entry for this
/// directory does not carry `hasTrustDialogAccepted` at all. Present with any value at all and this
/// declines, `false` above all. A `false` there is the user having been asked and having SAID NO,
/// which is the one answer this must never overturn (the account seed above reads it the same way:
/// a declined path is not carried to a new account). Present but not a boolean is a schema this
/// does not understand, and overwriting what it means would be a guess. Best-effort otherwise, like
/// the MCP seeding beside it at the call site: what a failure costs is the dialog the user would
/// have been shown anyway.
///
/// NOTHING ELSE IN THE FILE IS TOUCHED. This is the live state of a signed-in account, not the
/// fresh home `seedFolderTrust(from:to:)` above writes whole: it carries `oauthAccount`, start-up
/// counters, and every other project's history. So it is read, given one key, and written back.
///
/// WHICH IS WHY "NO FILE" AND "A FILE I CANNOT READ" ARE DIFFERENT ANSWERS, and conflating them is
/// the expensive mistake available here: an empty starting point plus an atomic write is how a real
/// `~/.claude.json` gets REPLACED by a document holding nothing but our one key, taking the
/// account's identity and every project's history with it. A permission error, a directory in its
/// place, a read that fails halfway: all of those exist, and none of them means the file is absent.
///
/// So "genuinely missing" is asked with `lstat` and means ENOENT ALONE: the kernel looked at that
/// path and there was nothing there. Only that starts from an empty root. Anything `lstat` CAN see
/// (a regular file, a directory, a symlink of any kind) has to be read and parsed, and a read or a
/// parse that fails declines. Any other errno declines as well: EACCES on a parent directory,
/// ENOTDIR, ELOOP are all "I could not find out", which is not an absence.
///
/// `FileManager.fileExists(atPath:)` cannot draw that line, which is why it is not the question
/// asked here. It follows symlinks and answers false for BOTH "nothing is there" and "I could not
/// find out", so a `.claude.json` that is a symlink to a target that has gone, or to one this
/// process cannot reach, read as absent - and the atomic write below then replaced the LINK with a
/// real file holding one key of ours. `lstat` sees the link itself, the read through it fails, and
/// this declines.
///
/// STATED LIMITATION, measured on macOS 2026-09-03: a `.claude.json` that IS a symlink to a
/// readable file is seeded, and the atomic write replaces the link with a regular file carrying the
/// merged content. The original target keeps its old content and the path stops leading to it. That
/// is left as it is rather than followed, because a symlinked state file is not a supported layout:
/// the file is an identity document that every running session rewrites, which is exactly why the
/// shared harness (SharedHarness.swift) refuses to link it in the first place.
///
/// The same rule covers a file that will not parse, which is left alone rather than replaced by a
/// valid one of ours.
///
/// RESIDUAL RACE, stated rather than locked: a Claude Code on this account rewriting the same file
/// between the read and the write loses whatever it wrote in that window (and this seed is lost the
/// other way round). Read, modify, write, atomic rename keeps that window at the width of one JSON
/// serialisation, and a lock here would be a lock the program that owns the file does not take.
@discardableResult
func seedFolderTrust(forDirectory directory: String, inConfigDir home: URL) -> Bool {
    let key = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
    let file = claudeStateFile(forConfigDir: home)
    var root: [String: Any] = [:]
    // `lstat`, so a symlink answers for itself rather than for what it leads to. Nothing here reads
    // the buffer it fills: the only question is whether the kernel found anything at that path.
    var info = stat()
    let present = lstat(file.path, &info) == 0
    // Absent means ENOENT and nothing else. Every other errno is "I could not find out", and an
    // unanswered question is not an empty file. Read straight after the call, before anything that
    // could set it.
    guard present || errno == ENOENT else { return false }
    if present {
        // Something is there, so from here on the only safe outcomes are "read it" and "leave it
        // alone". A dangling symlink lands here too, and declines because the read through it fails.
        guard let raw = try? Data(contentsOf: file),
              let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return false }
        root = parsed
    }
    // A `projects` or an entry that is there but is not an object belongs to a schema this does not
    // understand, and reading it as absent would overwrite it. Decline instead.
    if let existing = root["projects"], !(existing is [String: Any]) { return false }
    var projects = root["projects"] as? [String: Any] ?? [:]
    if let existing = projects[key], !(existing is [String: Any]) { return false }
    var entry = projects[key] as? [String: Any] ?? [:]
    // ABSENT, not "not true": the field carries the user's own answer, and `false` is a refusal.
    if entry["hasTrustDialogAccepted"] != nil { return false }
    entry["hasTrustDialogAccepted"] = true
    projects[key] = entry
    root["projects"] = projects
    guard let body = try? JSONSerialization.data(withJSONObject: root) else { return false }
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    return (try? body.write(to: file, options: .atomic)) != nil
}
