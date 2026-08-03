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
